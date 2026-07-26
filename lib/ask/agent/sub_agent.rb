# frozen_string_literal: true

module Ask
  module Agent
    # A tool that delegates a task to a specialized sub-agent.
    #
    # The coordinator agent sees this as a regular tool — when the LLM calls it,
    # a fresh sub-agent session runs independently with its own model, tools,
    # and instructions, and returns the result.
    #
    # Satisfies the tool duck type (name, description, params_schema, call)
    # so it can be passed directly in the tools array.
    #
    # @example From a filesystem definition
    #   # agents/web_search/agent.rb defines a WebSearch agent.
    #   # Use it as a sub-agent by passing its name:
    #
    #   search = Ask::Agent::SubAgent.new("web_search")
    #
    #   coordinator = Ask::Agent::Session.new(
    #     model: "gpt-4o",
    #     tools: [search, Ask::Tools::Shell::Bash]
    #   )
    #
    # @example Inline configuration
    #   search = Ask::Agent::SubAgent.new(
    #     name: "web_search",
    #     description: "Search the web for current information",
    #     model: "gpt-4o-mini",
    #     tools: [Ask::Tools::WebSearch],
    #     system_prompt: "You are a research assistant."
    #   )
    #
    # @example Using with a different provider
    #   review = Ask::Agent::SubAgent.new(
    #     name: "code_review",
    #     model: "claude-sonnet-4",
    #     provider: :anthropic,
    #     tools: [Ask::Tools::Shell::Read, Ask::Tools::Shell::Grep],
    #     system_prompt: "You are a senior code reviewer."
    #   )
    class SubAgent
      # @return [String] tool name visible to the LLM
      attr_reader :name

      # @return [String] tool description visible to the LLM
      attr_reader :description

      # Create a new SubAgent tool.
      #
      # When given a String, looks up a filesystem agent definition by name
      # (matching the convention used by {Ask::Agent.new}). Model, tools,
      # instructions, and other settings are read from the definition files.
      #
      # When given keyword arguments, configures the sub-agent inline.
      #
      # @overload initialize(definition_name)
      #   @param definition_name [String] Name of a filesystem agent definition.
      #   @raise [Ask::Agent::UnknownAgent] If no definition is found.
      #
      # @overload initialize(name:, description: nil, model:, tools: [],
      #           system_prompt: nil, provider: nil, max_turns: 10, **session_opts)
      #   @param name [String] Tool name (e.g. "web_search").
      #   @param description [String, nil] Tool description. Auto-generated
      #     from the model and tools count if not provided.
      #   @param model [String] Model identifier for the sub-agent session.
      #   @param tools [Array<Class, Object>] Tools available to the sub-agent.
      #   @param system_prompt [String, nil] Instructions for the sub-agent.
      #   @param provider [Symbol, nil] Provider override.
      #   @param max_turns [Integer] Max conversation turns for the sub-agent.
      #   @param session_opts [Hash] Additional options forwarded to Session.new.
      def initialize(definition_name = nil, name: nil, description: nil, model: nil,
                     tools: [], system_prompt: nil, provider: nil,
                     max_turns: 10, **session_opts)
        if definition_name
          from_definition(definition_name, **session_opts)
        else
          @name = name
          @description = description || default_description(model, tools)
          @model = model
          @tools = tools.map { |t| t.is_a?(Class) ? t.new : t }
          @system_prompt = system_prompt
          @provider = provider
          @max_turns = max_turns
          @session_opts = session_opts
        end
      end

      # JSON Schema for the tool's parameter.
      #
      # @return [Hash]
      def params_schema
        {
          type: "object",
          properties: {
            "task" => {
              type: "string",
              description: "The task to delegate to the sub-agent"
            }
          },
          required: ["task"],
          additionalProperties: false
        }
      end

      # Provider-specific parameters (none by default).
      #
      # @return [Hash]
      def provider_params
        {}
      end

      # Execute the sub-agent with the given task.
      #
      # Creates a fresh session for each call, runs the task, and returns the
      # result. If the sub-agent fails, returns an error result — the
      # coordinator can decide how to proceed.
      #
      # @param args [Hash, String] Arguments from the LLM.
      # @param abort_controller [Object, nil] Optional abort controller.
      # @return [Ask::Result]
      def call(args = {}, abort_controller = nil)
        task = extract_task(args)

        session_opts = {
          model: @model,
          tools: @tools.map(&:class),
          max_turns: @max_turns
        }
        session_opts[:provider] = @provider if @provider
        session_opts[:system_prompt] = @system_prompt if @system_prompt
        session_opts.merge!(@session_opts)

        session = Session.new(**session_opts)
        result = session.run(task.to_s)
        Ask::Result.ok(data: result.to_s)
      rescue StandardError => e
        Ask::Result.failure("SubAgent '#{@name}' error: #{e.message}")
      end

      # Human-readable representation.
      #
      # @return [String]
      def inspect
        "#<Ask::Agent::SubAgent name=#{@name.inspect}>"
      end

      private

      def from_definition(definition_name, **session_opts)
        Ask::Agent.rediscover!
        entry = Ask::Agent.definitions[definition_name.to_s]
        raise UnknownAgent, "Unknown agent: #{definition_name.inspect}" unless entry

        klass, dir = entry
        config = klass._config

        @name = definition_name
        @model = config[:model]
        @description = "Delegate to #{definition_name} sub-agent (#{@model})"
        @provider = config[:provider]

        # Resolve tools from definition
        resolved_tools = Ask::Agent.__send__(:resolve_definition_tools, config[:tools] || [], dir)
        @tools = resolved_tools.map { |t| t.is_a?(Class) ? t.new : t }

        # Load instructions from definition
        prompt = klass.instructions_content
        @system_prompt = prompt

        @max_turns = config[:max_turns] || 10
        # Merge any options from the definition config
        @session_opts = (config[:options] || {}).merge(session_opts)
      end

      def extract_task(args)
        case args
        when Hash then (args["task"] || args[:task] || args.to_s).to_s
        else args.to_s
        end
      end

      def default_description(model, tools)
        desc = "Delegate to a sub-agent (#{model}"
        desc += " with #{tools.size} tool(s)" if tools.any?
        desc + ")"
      end
    end
  end
end
