# frozen_string_literal: true

module Ask
  module Agent
    # Response message returned by {Chat#ask}.
    # Includes token counts and cost when available from the provider.
    ResponseMessage = Data.define(:content, :tool_calls, :thinking, :input_tokens, :output_tokens, :cost) do
      def tool_call? = !tool_calls.empty?
      def to_s = content.to_s
    end

    ToolCallInfo = Data.define(:id, :name, :arguments)

    ChatChunk = Data.define(:content, :tool_calls, :thinking, :input_tokens, :output_tokens) do
      def tool_call? = !tool_calls.empty?
    end

    class Chat
      attr_reader :model_id

      def model
        @model_id
      end

      attr_reader :messages

      def initialize(model:, tools: [], temperature: nil, schema: nil, provider: nil, **)
        @model_id = model.respond_to?(:id) ? model.id : model.to_s
        @model_info = Ask::ModelCatalog.find(@model_id)
        @tools = tools
        @temperature = temperature
        @schema = schema
        @messages = []
        @provider_override = provider
        @provider = nil
      end

      def ask(message = nil, &block)
        @messages << Ask::Message.new(role: :user, content: message.to_s) if message

        stream = block_given?
        tool_defs = @tools.map { |t| Ask::ToolDef.from_tool(t) }

        calls_acc = {}

        provider_model = @model_id
        provider_tools = tool_defs
        provider_temp = @temperature
        provider_schema = @schema&.respond_to?(:to_json_schema) ? @schema.to_json_schema : @schema
        provider_params = @extra_params || {}

        result = chat_with_retry(stream, calls_acc, &block)

        response_msg = if result.respond_to?(:chunks)
          build_stream_response(result, calls_acc)
        else
          build_response(result)
        end

        @messages << Ask::Message.new(
          role: :assistant,
          content: response_msg.content,
          tool_calls: response_msg.tool_calls&.values&.map { |tc|
            { id: tc.id, type: "function", name: tc.name, arguments: tc.arguments }
          },
          metadata: {
            input_tokens: response_msg.input_tokens,
            output_tokens: response_msg.output_tokens,
            cost: response_msg.cost
          }.compact
        )

        emit_instrumentation(stream, response_msg)

        response_msg
      end

      def add_message(role:, content: nil, tool_call_id: nil, tool_calls: nil)
        @messages << Ask::Message.new(
          role: role,
          content: content,
          tool_call_id: tool_call_id,
          tool_calls: tool_calls
        )
      end

      def with_instructions(prompt)
        @messages.reject! { |m| m.role == :system }
        @messages.unshift(Ask::Message.new(role: :system, content: prompt))
        self
      end

      def with_params(**params)
        @extra_params = (@extra_params || {}).merge(params)
        self
      end

      def with_schema(schema)
        @schema = schema.respond_to?(:to_json_schema) ? schema.to_json_schema : schema
        self
      end

      def reset_messages!
        @messages.clear
      end

      attr_writer :test_provider

      private

      def provider
        @test_provider || @provider ||= build_provider
      end

      def build_provider
        slug = @provider_override&.to_s || @model_info.provider
        klass = Ask::Provider.resolve(slug)
        klass.new(provider_config(slug))
      end

      def provider_config(slug)
        # Try credential names from most to least specific:
        #   1. Flat key with full slug (opencode_go_api_key)
        #   2. Nested path with full slug ([:opencode, :go, :api_key])
        #   3. Flat key with base slug  (opencode_api_key)
        #   4. Nested path with base slug ([:opencode, :api_key])
        slug_s = slug.to_s
        base_s = slug_s.include?("_") ? slug_s.split("_").first : nil

        cred_names = [:"#{slug_s}_api_key"]
        cred_names << slug_s.split("_").map(&:to_sym).push(:api_key) if slug_s.include?("_")
        if base_s
          cred_names << :"#{base_s}_api_key"
          cred_names << [base_s.to_sym, :api_key]
        end

        key = Ask::Auth.resolve(*cred_names) rescue nil

        base_url = Ask::Auth.resolve(:"#{slug}_api_base") rescue nil
        config = { api_key: key }
        config[:"#{slug}_api_key"] = key
        config[:"#{slug}_api_base"] = base_url if base_url
        Ask::LLM::Config.new(config)
      end

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

      def build_stream_response(stream, calls_acc)
        tokens = accumulated_tokens(stream)
        cost = calculate_cost(tokens[:input], tokens[:output])
        ResponseMessage.new(
          content: stream.accumulated_text,
          tool_calls: build_current_tool_calls(calls_acc),
          thinking: stream.chunks.filter_map(&:thinking).last,
          input_tokens: tokens[:input],
          output_tokens: tokens[:output],
          cost: cost
        )
      end

      def build_response(msg)
        tool_calls = msg.tool_calls ? build_tool_call_hash(msg.tool_calls) : {}
        thinking = msg.respond_to?(:thinking) ? msg.thinking : nil
        metadata = msg.metadata || {}
        input_tokens = metadata[:input_tokens] || metadata["input_tokens"]
        output_tokens = metadata[:output_tokens] || metadata["output_tokens"]
        cost = calculate_cost(input_tokens, output_tokens)
        ResponseMessage.new(
          content: msg.content.to_s,
          tool_calls: tool_calls,
          thinking: thinking,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cost: cost
        )
      end

      def accumulated_tokens(stream)
        input = 0
        output = 0
        stream.chunks.each do |chunk|
          if chunk.usage
            input = chunk.usage[:input_tokens] || chunk.usage["input_tokens"] || input
            output = chunk.usage[:output_tokens] || chunk.usage["output_tokens"] || output
          end
          output += 1 if chunk.content.to_s.length > 0
        end
        { input: input, output: output }
      end

      def calculate_cost(input_tokens, output_tokens)
        return nil unless input_tokens || output_tokens
        Ask::LLM::CostCalculator.calculate(@model_info, input_tokens: input_tokens || 0, output_tokens: output_tokens || 0)
      rescue StandardError
        nil
      end

      MAX_CHAT_RETRIES = 3

      def chat_with_retry(stream, calls_acc, &block)
        MAX_CHAT_RETRIES.times do |attempt|
          begin
            return provider.chat(
              @messages.map(&:to_h),
              model: @model_id,
              tools: @tools.map { |t| Ask::ToolDef.from_tool(t) },
              temperature: @temperature,
              stream: stream,
              schema: @schema&.respond_to?(:to_json_schema) ? @schema.to_json_schema : @schema,
              **(@extra_params || {})
            ) do |raw_chunk|
              next unless block

              accumulate_tool_calls(raw_chunk, calls_acc)

              block.call(ChatChunk.new(
                content: raw_chunk.content,
                tool_calls: build_current_tool_calls(calls_acc),
                thinking: raw_chunk.respond_to?(:thinking) ? raw_chunk.thinking : nil,
                input_tokens: nil,
                output_tokens: nil
              ))
            end
          rescue Ask::RateLimitError => e
            raise if attempt >= MAX_CHAT_RETRIES - 1

            delay = e.retry_after || ((2 ** attempt) + rand(0.0..1.0))
            sleep(delay)
          end
        end
      end

      def emit_instrumentation(stream, response_msg)
        return unless defined?(Ask::Instrumentation)

        payload = {
          model: @model_id,
          provider: @model_info.provider,
          input_tokens: response_msg.input_tokens,
          output_tokens: response_msg.output_tokens,
          cost: response_msg.cost,
          tool_calls: response_msg.tool_call?,
          stream: stream
        }.compact

        if stream
          Ask::Instrumentation.instrument("chat.stream.ask", payload)
        else
          Ask::Instrumentation.instrument("chat.ask", payload)
        end
      rescue StandardError
        nil
      end
    end
  end
end
