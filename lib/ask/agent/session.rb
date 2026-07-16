# frozen_string_literal: true

require "securerandom"
require "time"

module Ask
  module Agent
    class Session
      attr_reader :id, :chat, :tools, :turn_count, :created_at, :messages
      attr_reader :tool_calls_made, :total_input_tokens, :total_output_tokens, :total_cost

      def reflection_count
        @reflector&.reflection_count || 0
      end

      attr_reader :meta_agent_results
      # @return [Ask::Skills::Registry, nil] auto-discovered skills registry
      attr_reader :skills_registry

      def initialize(model:, tools: [], max_turns: 25, max_tool_retries: 3,
                     compactor: nil, hooks: {}, persistence: nil,
                     id: nil, system_prompt: nil, parallel_tools: true,
                     reflector: nil, telemetry: true, meta_agent: nil, **chat_options)
        @id = id || SecureRandom.uuid
        @max_turns = max_turns
        @max_tool_retries = max_tool_retries
        @parallel_tools = parallel_tools
        @event_handlers = { all: [] }
        @running = false
        @deleted = false
        @abort_requested = false
        @turn_count = 0
        @created_at = Time.now
        @_no_tools_instructed = false

        @total_input_tokens = 0
        @total_output_tokens = 0
        @total_cost = 0.0

        @telemetry = telemetry.is_a?(Telemetry) ? telemetry : Telemetry.new(enabled: !!telemetry)

        @chat = build_chat(model, system_prompt, tools, **chat_options)
        @tools = resolve_tools(tools)
        @loop = Loop.new(max_turns: max_turns)
        @tool_executor = ToolExecutor.new(max_retries: max_tool_retries, parallel: parallel_tools)
        @compactor = compactor ? build_compactor(compactor) : nil
        @hooks = Hooks.new(hooks)

        # Auto-discover skills and inject into system prompt
        @skills_registry = Ask::Skills.discover rescue nil
        if @skills_registry && !@skills_registry.names.empty?
          skill_text = @skills_registry.format_for_prompt
          if !skill_text.empty? && @chat.messages.any? { |m| m.role == :system }
            current = @chat.messages.find { |m| m.role == :system }.content.to_s
            @chat.with_instructions(current + skill_text)
          end
        end
        @persistence = persistence

        reflector_opts = reflector.is_a?(Hash) ? reflector : {}
        @reflector = if reflector
          Reflector.new(
            model: @chat,
            max_reflections: reflector_opts[:max_reflections] || 1
          )
        end

        @meta_agent_config = meta_agent
        @meta_agent_results = nil

        @compactor&.chat = @chat
      end

      def run(message, tools: nil)
        raise "Session deleted" if @deleted
        raise "Session already running" if @running

        @running = true
        @abort_requested = false
        @turn_count = 0
        @loop.reset!

        emit(Events::SessionStart.new)

        active_tools = resolve_tools(tools || [])
        active_tools = @tools if active_tools.empty?

        if active_tools.empty? && !@_no_tools_instructed
          @chat.add_message(role: :system, content: "You have no tools available. Do not claim you can look up information or use tools of any kind. Just respond based on your existing knowledge.")
          @_no_tools_instructed = true
        end

        begin
          @tool_executor.telemetry = @telemetry

          response = @loop.run_turn(
            chat: @chat,
            message: message,
            tools: active_tools,
            tool_executor: @tool_executor,
            compactor: @compactor,
            hooks: @hooks,
            event_emitter: self,
            session_id: @id
          )

          @total_input_tokens += @loop.last_input_tokens.to_i
          @total_output_tokens += @loop.last_output_tokens.to_i
          @total_cost += @loop.last_cost.to_f
        rescue MaxTurnsExceeded => e
          emit(Events::MaxTurnsExceeded.new(max_turns: @max_turns))
          @telemetry.log(:max_turns_exceeded, session_id: @id, max_turns: @max_turns)
          response = last_content
        rescue LoopDetected => e
          emit(Events::LoopDetected.new(tool_name: e.message, repeated_count: 3))
          @telemetry.log(:loop_detected, session_id: @id, tool_name: e.message, repeated_count: 3)
          response = last_content
        rescue Ask::ContextLengthExceeded
          if @compactor && !@compactor.overflow_recovered?
            @compactor.recover_from_overflow
            retry
          end
          response = "I'm sorry, the conversation has grown too long. Please start a new session."
        rescue StandardError => e
          emit(Events::Error.new(error: e.message, recoverable: true))
          raise
        ensure
          @running = false
          persist! if @persistence
        end

        @tool_calls_made = @tool_executor.total_executions

        if @reflector && @reflector.reflect?(@tool_calls_made) && !@abort_requested
          eval_result = @reflector.evaluate(response: response, event_emitter: self)
          @telemetry.log(:reflection_end, session_id: @id, decision: eval_result[:decision], feedback: eval_result[:feedback])

          if eval_result[:decision] == :improve && !@abort_requested
            @chat.add_message(
              role: :system,
              content: "Improve your last response: #{eval_result[:feedback]}"
            )

            response = @loop.run_turn(
              chat: @chat,
              message: "",
              tools: active_tools,
              tool_executor: @tool_executor,
              compactor: @compactor,
              hooks: @hooks,
              event_emitter: self,
              session_id: @id
            )

            @total_input_tokens += @loop.last_input_tokens.to_i
            @total_output_tokens += @loop.last_output_tokens.to_i
            @total_cost += @loop.last_cost.to_f
          end
        end

        if @meta_agent_config
          @telemetry.increment_session_count!
          try_auto_meta_agent
        end

        emit(Events::SessionEnd.new(
          result: response,
          turn_count: @turn_count,
          tool_calls_made: @tool_calls_made,
          input_tokens: @total_input_tokens,
          output_tokens: @total_output_tokens,
          cost: @total_cost
        ))
        @messages = @chat.messages.dup

        response
      end

      def on_event(&block)
        @event_handlers[:all] << block
        self
      end

      def on(type, &block)
        @event_handlers[type] ||= []
        @event_handlers[type] << block
        self
      end

      def emit(event)
        @event_handlers[:all].each { |h| h.call(event) }
        handlers = @event_handlers[event.class]
        handlers&.each { |h| h.call(event) }
      end

      def running? = @running
      def deleted? = @deleted

      def save
        persist! if @persistence
      end

      def self.load(id, adapter:)
        data = adapter.load(id)
        return nil unless data

        session = new(
          id: data[:id],
          model: data.dig(:metadata, :model),
          tools: data.dig(:metadata, :tools)&.map(&:constantize) || [],
          persistence: adapter
        )

        data[:messages].each do |msg|
          session.chat.add_message(
            role: msg[:role].to_sym,
            content: msg[:content],
            tool_call_id: msg[:tool_call_id]
          )
        end

        session
      end

      def delete
        @deleted = true
        @persistence&.delete(@id)
      end

      def abort
        @abort_requested = true
      end

      def abort_requested? = @abort_requested

      # Load a skill by name or file path.
      # Injects the skill's full instructions into the conversation as a system message.
      #
      # @param name [String] skill name (e.g. "rails.db_debug") or path to a .md file
      # @raise [Ask::Skills::Error] if the skill is not found
      def skill(name)
        if @skills_registry && (s = @skills_registry[name])
          @chat.add_message(
            role: :system,
            content: "## Skill: #{s.name}\n\n#{s.description}\n\n---\n\n#{s.instructions}"
          )
        elsif File.exist?(name.to_s)
          content = File.read(name.to_s)
          @chat.add_message(
            role: :system,
            content: "## Skill: #{name}\n\n---\n\n#{content}"
          )
        else
          raise Ask::Skills::Error, "Skill not found: #{name.inspect}"
        end
      end

      def reset_messages!
        @chat.reset_messages!
        @messages = []
      end

      private

      def build_chat(model, system_prompt, tools, **chat_options)
        if model.respond_to?(:ask)
          model
        else
          chat = Ask::Agent::Chat.new(model: model, tools: tools, **chat_options)
          chat.with_instructions(system_prompt) if system_prompt
          chat
        end
      end

      def resolve_tools(tools)
        tools.map do |tool|
          tool.is_a?(Class) ? tool.new : tool
        end
      end

      def build_compactor(config)
        compactor = Compactor.new(
          threshold: config[:threshold] || 0.8,
          strategy: config[:strategy] || :proactive
        )
        compactor.chat = @chat
        compactor
      end

      def persist!
        @persistence.save(@id, {
          id: @id,
          messages: @chat.messages.map { |m|
            {
              role: m.role,
              content: m.content.to_s,
              tool_call_id: m.tool_call_id,
              created_at: Time.now.iso8601
            }
          },
          metadata: {
            model: @chat.model.respond_to?(:id) ? @chat.model.id : @chat.model,
            tools: @tools.map { |t| t.class.name },
            max_turns: @max_turns,
            turn_count: @turn_count,
            created_at: @created_at.iso8601,
            updated_at: Time.now.iso8601
          }
        })
      end

      def try_auto_meta_agent
        return unless @meta_agent_config
        return unless @meta_agent_config[:auto]

        interval = @meta_agent_config[:interval] || 10
        count = @telemetry.session_count
        return unless count >= interval

        agent = MetaAgent.new(
          telemetry: @telemetry,
          model: model_id_from(@chat),
          **@meta_agent_config[:chat_options].to_h
        )

        results = agent.analyze
        @meta_agent_results = results
        emit(Events::MetaAgentAnalysis.new(results: results, count: results.size))
        @telemetry.reset_session_count!
      end

      def model_id_from(chat)
        chat.model.respond_to?(:id) ? chat.model.id : chat.model.to_s
      end

      def last_content
        @chat.messages.reverse_each.lazy
          .select { |m| m.role == :assistant && m.content.to_s.strip.length > 0 }
          .first&.content.to_s
      end
    end
  end
end
