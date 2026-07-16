# frozen_string_literal: true

module Ask
  module Agent
    module Test
      # Holds stubs, tracks called tools and final response for a test session.
      class Mode
        attr_reader :stubs, :called_tools, :final_response

        def initialize
          @stubs = []
          @called_tools = []
          @final_response = nil
        end

        def stub_tool_call(name, arguments = {})
          @stubs << { type: :tool_call, name: name.to_s, arguments: arguments }
        end

        def stub_text(content)
          @stubs << { type: :text, content: content }
        end

        def record_tool_call(name)
          @called_tools << name
        end

        def record_final_response(response)
          @final_response = response
        end

        def unused_stubs
          @stubs
        end
      end

      # Stub provider that returns canned responses instead of calling an LLM.
      class StubProvider
        def initialize(mode)
          @mode = mode
        end

        def chat(messages, model: nil, tools: nil, temperature: nil, stream: nil, schema: nil, **params)
          stub = @mode.stubs.shift or raise "No more stubs available. Unconsumed messages: #{messages.length}"

          case stub[:type]
          when :tool_call
            Ask::Message.new(
              role: :assistant,
              content: nil,
              tool_calls: [{
                id: "call_test_#{SecureRandom.hex(4)}",
                type: "function",
                name: stub[:name],
                arguments: JSON.generate(stub[:arguments])
              }],
              metadata: { input_tokens: 10, output_tokens: 5 }
            )
          when :text
            Ask::Message.new(
              role: :assistant,
              content: stub[:content],
              metadata: { input_tokens: 10, output_tokens: 5 }
            )
          else
            raise "Unknown stub type: #{stub[:type].inspect}"
          end
        end

        def headers
          {}
        end
      end

      # Methods added to Session when in test mode.
      module SessionOverride
        def test_mode
          return @test_mode if @test_mode

          @test_mode = Mode.new
          @chat&.test_provider = StubProvider.new(@test_mode) if @chat
          @test_mode
        end

        def stub_tool_call(name, arguments = {})
          test_mode.stub_tool_call(name, arguments)
        end

        def stub_text(content)
          test_mode.stub_text(content)
        end

        def called_tool?(name)
          test_mode.called_tools.include?(name.to_s)
        end

        private

        def build_chat(model, system_prompt, tools, **chat_options)
          if @test_mode
            chat = Ask::Agent::Chat.new(model: model, tools: tools, **chat_options)
            chat.with_instructions(system_prompt) if system_prompt
            chat.test_provider = StubProvider.new(@test_mode)
            chat
          else
            super
          end
        end

        def emit(event)
          super
          return unless @test_mode

          case event
          when Ask::Agent::Events::ToolExecutionStart
            @test_mode.record_tool_call(event.name)
          when Ask::Agent::Events::SessionEnd
            @test_mode.record_final_response(event.result)
          end
        end

        public :emit
      end

      # Test assertions to include in Minitest test classes.
      module Assertions
        def session
          @session || raise("@session not set — define it in setup")
        end

        def assert_called_tool(name, msg = nil)
          assert session.called_tool?(name),
                 msg || "Expected tool #{name.inspect} to be called. Called: #{session.test_mode.called_tools.inspect}"
        end

        def refute_called_tool(name, msg = nil)
          refute session.called_tool?(name),
                 msg || "Expected tool #{name.inspect} not to be called. Called: #{session.test_mode.called_tools.inspect}"
        end

        def assert_tool_order(names, msg = nil)
          expected = names.map(&:to_s)
          called = session.test_mode.called_tools
          matched = called.first(expected.length)
          assert_equal expected, matched,
                       msg || "Tool call order mismatch. Expected: #{expected.inspect}, Got: #{matched.inspect}"
        end

        def assert_final_response(match, msg = nil)
          assert_match match, session.test_mode.final_response.to_s, msg
        end

        def assert_no_unused_stubs(msg = nil)
          assert_empty session.test_mode.unused_stubs,
                       msg || "Unused stubs: #{session.test_mode.unused_stubs.inspect}"
        end
      end

      Ask::Agent::Session.prepend(SessionOverride)
    end
  end
end
