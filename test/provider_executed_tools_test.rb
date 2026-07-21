# frozen_string_literal: true

require_relative "test_helper"

class ProviderExecutedToolsTest < Minitest::Test
  def setup
    Ask::ModelCatalog.reset_instance!
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "gpt-4o", provider: "openai"))
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "claude-sonnet-4", provider: "anthropic"))
  end

  # -- ResponseMessage with tool_results --

  def test_response_message_default_tool_results
    msg = Ask::Agent::ResponseMessage.new(content: "Hello", tool_calls: {})
    assert_equal ({}), msg.tool_results
  end

  def test_response_message_with_tool_results
    results = { "call_1" => { provider_executed: true, tool_name: "web_search", message: "results", status: "success" } }
    msg = Ask::Agent::ResponseMessage.new(content: "", tool_calls: {}, tool_results: results)
    assert_equal results, msg.tool_results
  end

  def test_response_message_with_both
    tool_calls = { "call_1" => Ask::Agent::ToolCallInfo.new(id: "call_1", name: "bash", arguments: "ls") }
    results = { "call_2" => { provider_executed: true, tool_name: "web_search", message: "found", status: "success" } }
    msg = Ask::Agent::ResponseMessage.new(content: "", tool_calls: tool_calls, tool_results: results)
    assert msg.tool_call?
    assert results.key?("call_2")
  end

  # -- Loop integration --

  def test_loop_executes_user_tools_and_skips_provider_tools
    loop_instance = Ask::Agent::Loop.new(max_turns: 5)
    chat = build_chat_with_mixed_tools
    stub_tools = [stub_tool("bash")]
    hooks = Ask::Agent::Hooks.new({})
    event_emitter = build_event_emitter

    result = loop_instance.run_turn(
      chat: chat,
      message: "Search and then list files",
      tools: stub_tools,
      tool_executor: Ask::Agent::ToolExecutor.new,
      compactor: nil,
      hooks: hooks,
      event_emitter: event_emitter,
      session_id: "test"
    )

    assert result.is_a?(String)
    assert result.length > 0
  end

  def test_loop_with_only_provider_tools
    loop_instance = Ask::Agent::Loop.new(max_turns: 5)
    chat = build_chat_with_only_provider_tools
    hooks = Ask::Agent::Hooks.new({})
    event_emitter = build_event_emitter

    result = loop_instance.run_turn(
      chat: chat,
      message: "Search the web",
      tools: [],
      tool_executor: Ask::Agent::ToolExecutor.new,
      compactor: nil,
      hooks: hooks,
      event_emitter: event_emitter,
      session_id: "test"
    )

    assert result.is_a?(String)
  end

  # -- OpenAI provider split_tools --

  def test_split_tools_separates_provider_tools
    provider = Ask::Providers::OpenAI.new(api_key: "test")
    bash_tool = Ask::ToolDef.new(name: "bash", description: "Run bash")
    web_tool = Ask::ProviderTool.web_search

    regular, provider_tools = provider.send(:split_tools, [bash_tool, web_tool])

    assert_equal 1, regular.length
    assert_equal "bash", regular.first.name
    assert_equal 1, provider_tools.length
    assert_equal "openai.web_search", provider_tools.first.id
  end

  def test_split_tools_all_regular
    provider = Ask::Providers::OpenAI.new(api_key: "test")
    tools = [
      Ask::ToolDef.new(name: "bash", description: "Run"),
      Ask::ToolDef.new(name: "read", description: "Read")
    ]

    regular, provider_tools = provider.send(:split_tools, tools)

    assert_equal 2, regular.length
    assert_equal 0, provider_tools.length
  end

  def test_split_tools_all_provider
    provider = Ask::Providers::OpenAI.new(api_key: "test")
    tools = [
      Ask::ProviderTool.web_search,
      Ask::ProviderTool.file_search(vector_store_ids: ["vs_1"])
    ]

    regular, provider_tools = provider.send(:split_tools, tools)

    assert_equal 0, regular.length
    assert_equal 2, provider_tools.length
  end

  def test_split_tools_nil
    provider = Ask::Providers::OpenAI.new(api_key: "test")
    regular, provider_tools = provider.send(:split_tools, nil)
    assert_equal [], regular
    assert_equal [], provider_tools
  end

  def test_split_tools_empty
    provider = Ask::Providers::OpenAI.new(api_key: "test")
    regular, provider_tools = provider.send(:split_tools, [])
    assert_equal [], regular
    assert_equal [], provider_tools
  end

  # -- OpenAI format_responses_tools --

  def test_format_responses_web_search
    provider = Ask::Providers::OpenAI.new(api_key: "test")
    pt = Ask::ProviderTool.web_search(search_context_size: "high")

    formatted = provider.send(:format_responses_tools, [pt])
    assert_equal 1, formatted.length
    assert_equal "web_search", formatted[0][:type]
    assert_equal "high", formatted[0][:search_context_size]
  end

  def test_format_responses_file_search
    provider = Ask::Providers::OpenAI.new(api_key: "test")
    pt = Ask::ProviderTool.file_search(vector_store_ids: ["vs_1"], max_num_results: 5)

    formatted = provider.send(:format_responses_tools, [pt])
    assert_equal 1, formatted.length
    assert_equal "file_search", formatted[0][:type]
    assert_equal ["vs_1"], formatted[0][:vector_store_ids]
  end

  def test_format_responses_code_interpreter
    provider = Ask::Providers::OpenAI.new(api_key: "test")
    pt = Ask::ProviderTool.code_interpreter(file_ids: ["f_1"])

    formatted = provider.send(:format_responses_tools, [pt])
    assert_equal 1, formatted.length
    assert_equal "code_interpreter", formatted[0][:type]
    assert_equal ["f_1"], formatted[0][:file_ids]
  end

  private

  def stub_tool(name)
    tool = stub(name: name, description: "A tool")
    tool
  end

  def build_chat_with_mixed_tools
    chat = Ask::Agent::Chat.new(model: "gpt-4o")
    call_count = 0

    # First call returns tool calls + provider results; subsequent calls return text
    chat.define_singleton_method(:ask) do |*args, **kwargs, &block|
      call_count += 1
      if call_count == 1
        Ask::Agent::ResponseMessage.new(
          content: "",
          tool_calls: { "call_user_1" => Ask::Agent::ToolCallInfo.new(id: "call_user_1", name: "bash", arguments: "ls") },
          tool_results: { "call_provider_1" => { provider_executed: true, tool_name: "web_search", message: "Found results", status: "success" } }
        )
      else
        Ask::Agent::ResponseMessage.new(content: "Done with all tools")
      end
    end
    chat
  end

  def build_chat_with_only_provider_tools
    chat = Ask::Agent::Chat.new(model: "gpt-4o")
    call_count = 0

    chat.define_singleton_method(:ask) do |*args, **kwargs, &block|
      call_count += 1
      if call_count == 1
        Ask::Agent::ResponseMessage.new(
          content: "",
          tool_calls: {},
          tool_results: {
            "call_ws" => { provider_executed: true, tool_name: "web_search", message: "Search complete", status: "success" }
          }
        )
      else
        Ask::Agent::ResponseMessage.new(content: "Search results processed")
      end
    end
    chat
  end

  def build_event_emitter
    emitter = Object.new
    emitter.define_singleton_method(:emit) { |_| }
    emitter
  end
end
