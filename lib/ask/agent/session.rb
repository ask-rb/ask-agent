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
                     compactor: nil, hooks: {}, state: nil, persistence: nil,
                     id: nil, system_prompt: nil, parallel_tools: true,
                     reflector: nil, telemetry: true, meta_agent: nil,
                     agent_dir: nil, **chat_options)
        @id = id || SecureRandom.uuid
        @agent_dir = agent_dir
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

        @system_context = build_system_context(system_prompt)
        apply_system_context

        @state = state || persistence

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

        active_tools = @tools

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
	            session_id: @id,
	            persist: @state ? method(:persist!) : nil
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
          persist! if @state
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
        persist! if @state
      end

      def self.load(id, adapter:)
        data = adapter.get(id)
        return nil unless data

        data = deep_symbolize_keys(data)

        session = new(
          id: data[:id],
          model: data.dig(:metadata, :model),
          tools: data.dig(:metadata, :tools)&.map(&:constantize) || [],
          state: adapter
        )

	        data[:messages].each do |msg|
	          session.chat.add_message(
	            role: msg[:role].to_sym,
	            content: msg[:content],
	            tool_call_id: msg[:tool_call_id]
	          )
	        end
	
	        session.instance_variable_set(:@messages, session.chat.messages.dup)
	        session
      end

      def delete
        @deleted = true
        @state&.delete(@id)
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
        resolved = tools.map do |tool|
          tool.is_a?(Class) ? tool.new : tool
        end
        # Always include the load_skill tool for progressive skill disclosure,
        # unless the test framework is loaded (test mode keeps tools deterministic)
        unless defined?(Ask::Agent::Test) && Ask::Agent::Test
          resolved << Skills::LoadSkillTool.new(registry: @skills_registry) unless resolved.any? { |t| t.name == "load_skill" }
        end
        resolved
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
        @state.set(@id, {
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

      # Build the system context from typed sources.
      def build_system_context(prompt)
        sources = []
        sources << Ask::Agent::ContextSources::Instructions.new(prompt) if prompt

        # Auto-discover skills (shared + per-agent if agent_dir is given)
        @skills_registry = Ask::Skills.discover(agent_dir: @agent_dir) rescue nil
        if @skills_registry && !@skills_registry.names.empty?
          sources << Ask::Agent::ContextSources::SkillsList.new(@skills_registry)
          if @skills_registry.always_active_skills.any?
            sources << Ask::Agent::ContextSources::AlwaysActiveSkills.new(@skills_registry)
          end
        end

        SystemContext.new(sources)
      end

      # Recursively convert string keys to symbol keys in hashes.
      # Needed when loading session data that was serialized through JSON.
      def self.deep_symbolize_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize_keys(v) }
        when Array
          obj.map { |e| deep_symbolize_keys(e) }
        else
          obj
        end
      end

      # Render the system context and apply it to the chat.
      def apply_system_context
        rendered = @system_context.render
        return if rendered.empty?
        return unless @chat.messages.any? { |m| m.role == :system }

        @chat.with_instructions(rendered)
      end
    end
  end
end
