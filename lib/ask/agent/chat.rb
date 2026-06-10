# frozen_string_literal: true

module Ask
  module Agent
    # Response message returned by {Chat#ask}.
    # Presents a message-like response interface for ask-agent internal use.
    ResponseMessage = Data.define(:content, :tool_calls, :thinking) do
      def tool_call? = !tool_calls.empty?
      def to_s = content.to_s
    end

    # Tool call data used in {ResponseMessage} and {ChatChunk}.
    ToolCallInfo = Data.define(:id, :name, :arguments)

    # Chunk yielded during streaming from {Chat#ask}.
    ChatChunk = Data.define(:content, :tool_calls, :thinking) do
      def tool_call? = !tool_calls.empty?
    end

    # Thin wrapper around {Ask::Provider} + an internal message array that
    # presents a Chat-like API for ask-agent internal use.
    #
    # Manages conversation history, resolves the correct provider/model,
    # handles streaming chunk accumulation, and normalises tool call
    # formats between Ask::Provider (Array of Hashes) and ask-agent
    # internal usage (Hash of { id => ToolCallInfo }).
    class Chat
      # @return [String] model ID (e.g. "gpt-4o")
        attr_reader :model_id
      # @return [String] model ID (e.g. "gpt-4o")
      def model
        @model_id
      end
      # @return [Array<Ask::Message>] all messages in the conversation
      attr_reader :messages

      # @param model [String, #ask] model ID or chat-like object
      # @param tools [Array<Ask::Tool>] tool instances available to the chat
      # @param temperature [Float, nil] sampling temperature
      # @param schema [Ask::Schema, Hash, nil] structured output schema
      # @param assume_model_exists [Boolean] whether to skip model catalog lookup
      # @param provider [String, Symbol, nil] provider slug to use (overrides model catalog)
      def initialize(model:, tools: [], temperature: nil, schema: nil,
                     assume_model_exists: false, provider: nil, **)
        @model_id = model.respond_to?(:id) ? model.id : model.to_s
        @model_info = resolve_model(@model_id) unless assume_model_exists
        @tools = tools
        @temperature = temperature
        @schema = schema
        @messages = []
        @provider_override = provider
        @provider = nil
      end

      # Send a user message and get a completion response.
      #
      # @param message [String, nil] user message text
      # @yield [ChatChunk] streaming chunks (only when a block is given)
      # @return [ResponseMessage] the assistant's response
      def ask(message = nil, &block)
        @messages << Ask::Message.new(role: :user, content: message.to_s) if message

        stream = block_given?
        tool_defs = @tools.map { |t| Ask::ToolDef.from_tool(t) }

        # Accumulator for tool calls during streaming (keyed by index)
        calls_acc = {}

        result = provider.chat(@extra_params || {}, 
          @messages.map(&:to_h),
          model: @model_id,
          tools: tool_defs,
          temperature: @temperature,
          stream: stream,
          schema: @schema&.respond_to?(:to_json_schema) ? @schema.to_json_schema : @schema
        ) do |raw_chunk|
          next unless block_given?

          # Accumulate tool calls by index during streaming
          accumulate_tool_calls(raw_chunk, calls_acc)

          # Yield adapted chunk with current tool call state
          yield ChatChunk.new(
            content: raw_chunk.content,
            tool_calls: build_current_tool_calls(calls_acc),
            thinking: raw_chunk.respond_to?(:thinking) ? raw_chunk.thinking : nil
          )
        end

        response_msg = if stream
          build_stream_response(result, calls_acc)
        else
          build_response(result)
        end

        # Store assistant response in conversation history
        @messages << Ask::Message.new(
          role: :assistant,
          content: response_msg.content,
          tool_calls: response_msg.tool_calls&.values&.map { |tc|
            { id: tc.id, type: "function", name: tc.name, arguments: tc.arguments }
          }
        )

        response_msg
      end

      # Add a message to the conversation history.
      #
      # @param role [Symbol] :system, :user, :assistant, :tool
      # @param content [String, nil] message content
      # @param tool_call_id [String, nil] tool call ID (for tool results)
      # @param tool_calls [Array<Hash>, nil] tool call invocations
      def add_message(role:, content: nil, tool_call_id: nil, tool_calls: nil)
        @messages << Ask::Message.new(
          role: role,
          content: content,
          tool_call_id: tool_call_id,
          tool_calls: tool_calls
        )
      end

      # Set or replace the system prompt.
      #
      # @param prompt [String] system instructions
      # @return [self]
      def with_instructions(prompt)
        @messages.reject! { |m| m.role == :system }
        @messages.unshift(Ask::Message.new(role: :system, content: prompt))
        self
      end

      # Set the structured output schema and return self.
      #
      # @param schema [Ask::Schema, Hash] structured output schema
      # @return [self]
  # Set additional parameters for the provider call and return self.
  #
  # @param params [Hash] extra parameters passed to the provider
  # @return [self]
  def with_params(**params)
    @extra_params = (@extra_params || {}).merge(params)
    self
  end

      def with_schema(schema)
        @schema = schema.respond_to?(:to_json_schema) ? schema.to_json_schema : schema
        self
      end

      # Clear all messages from the conversation.
      def reset_messages!
        @messages.clear
      end

      private

      # Resolve model info from the catalog.
      def resolve_model(model_id)
        Ask::ModelCatalog.find(model_id)
      rescue Ask::ModelNotFound
        nil
      end

      # Lazily resolve and instantiate the LLM provider.
      def provider
        @provider ||= build_provider
      end

      def build_provider
        slug = @provider_override&.to_s || @model_info&.provider || "openai"
        klass = Ask::Provider.resolve(slug)
        klass.new(provider_config(slug))
      end

      def provider_config(slug, extra_keys: {})
        env_key = "#{slug.upcase}_API_KEY"
        key = ENV[env_key] || ENV["OPENCODE_API_KEY"] || ENV["OPENAI_API_KEY"]
        base = ENV["#{slug.upcase}_API_BASE"] || ENV["OPENCODE_API_BASE"]
        config = { api_key: key }
        config[:"#{slug}_api_key"] = key
        config[:"#{slug}_api_base"] = base if base
        Ask::LLM::Config.new(config)
      end

      # Accumulate partial tool calls from streaming chunks.
      def accumulate_tool_calls(raw_chunk, calls_acc)
        return unless raw_chunk.tool_call?

        raw_chunk.tool_calls.each do |tc|
          idx = tc[:index] || 0
          calls_acc[idx] ||= { id: tc[:id], name: tc[:name], arguments: +"" }
          calls_acc[idx][:id] ||= tc[:id]
          calls_acc[idx][:name] ||= tc[:name]
          calls_acc[idx][:arguments] << tc[:arguments].to_s if tc[:arguments]
        end
      end

      # Build current snapshot of tool calls from accumulator.
      def build_current_tool_calls(calls_acc)
        hash = {}
        calls_acc.each_value do |tc_data|
          next unless tc_data[:id]
          hash[tc_data[:id]] = ToolCallInfo.new(
            id: tc_data[:id],
            name: tc_data[:name] || "",
            arguments: tc_data[:arguments]
          )
        end
        hash
      end

      # Convert Ask::Provider tool_calls (Array of Hashes) to Hash.
      def build_tool_call_hash(raw_calls)
        hash = {}
        raw_calls.each do |tc|
          id = tc[:id] || tc["id"]
          next unless id
          hash[id] = ToolCallInfo.new(
            id: id,
            name: tc[:name] || tc["name"] || "",
            arguments: tc[:arguments] || tc["arguments"] || ""
          )
        end
        hash
      end

      # Build response from streaming result.
      def build_stream_response(stream, calls_acc)
        thinking = stream.chunks.filter_map(&:thinking).last
        ResponseMessage.new(
          content: stream.accumulated_text,
          tool_calls: build_current_tool_calls(calls_acc),
          thinking: thinking
        )
      end

      # Build response from non-streaming result.
      def build_response(msg)
        tool_calls = msg.tool_calls ? build_tool_call_hash(msg.tool_calls) : {}
        thinking = msg.respond_to?(:thinking) ? msg.thinking : nil
        ResponseMessage.new(content: msg.content.to_s, tool_calls: tool_calls, thinking: thinking)
      end
    end
  end
end
