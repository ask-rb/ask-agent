# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

module Ask
  module Agent
    class MemoryTest < Minitest::Test
      class HashAdapter
        attr_reader :data

        def initialize
          @data = {}
        end

        def get(key) = @data[key]
        def set(key, value, ttl: nil) = @data[key] = value
        def delete(key) = @data.delete(key)
      end

      # Simulates JSON-serializing backends (SQLite, Redis, Postgres):
      # values round-trip through JSON, so keys become strings.
      class JsonAdapter < HashAdapter
        def get(key) = @data[key] && JSON.parse(JSON.generate(@data[key]))
        def set(key, value, ttl: nil) = @data[key] = value
      end

      def setup
        @adapter = HashAdapter.new
        @memory = Memory.new(state: @adapter, namespace: "user:42")
      end

      # -----------------------------------------------------------------
      # Write / read
      # -----------------------------------------------------------------

      def test_write_creates_entries_with_metadata
        entry = @memory.write("Deploy window is Tuesday", metadata: { session_id: "s1" })

        refute_nil entry.id
        assert_equal "Deploy window is Tuesday", entry.content
        assert_equal "s1", entry.metadata[:session_id]
        assert_kind_of Time, entry.created_at
        assert_equal 1, @memory.count
      end

      def test_write_rejects_empty_content
        assert_raises(ArgumentError) { @memory.write("") }
        assert_raises(ArgumentError) { @memory.write("   ") }
      end

      def test_write_dedupes_identical_content
        first = @memory.write("Deploy window is Tuesday")
        second = @memory.write("Deploy window is Tuesday")

        assert_equal first.id, second.id
        assert_equal 1, @memory.count
      end

      def test_list_returns_newest_first
        @memory.write("First")
        @memory.write("Second")
        @memory.write("Third")

        assert_equal %w[Third Second First], @memory.list.map(&:content)
        assert_equal %w[Third Second], @memory.list(limit: 2).map(&:content)
      end

      def test_delete_removes_entry_and_index
        entry = @memory.write("Old fact")
        @memory.write("Keep this")

        @memory.delete(entry.id)

        assert_equal 1, @memory.count
        refute @memory.search("Old").any?
        # No stray keys remain.
        assert_empty @adapter.data.keys.grep(/#{entry.id}/)
      end

      # -----------------------------------------------------------------
      # Search
      # -----------------------------------------------------------------

      def test_search_matches_substring_case_insensitively
        @memory.write("The user prefers email over SMS")
        @memory.write("Deploy window is Tuesday")

        hits = @memory.search("email")
        assert_equal ["The user prefers email over SMS"], hits.map(&:content)
        hits = @memory.search("EMAIL")
        assert_equal 1, hits.size
      end

      def test_search_ranks_by_matched_terms
        @memory.write("Prefers email")
        @memory.write("The user prefers email over SMS for urgent alerts")

        hits = @memory.search("email urgent alerts")
        assert_equal "The user prefers email over SMS for urgent alerts", hits.first.content
        assert_equal 2, hits.size
      end

      def test_search_strips_punctuation_from_query_terms
        @memory.write("The deploy window is Tuesday")
        hits = @memory.search("When can we deploy?")
        assert_equal ["The deploy window is Tuesday"], hits.map(&:content)
      end

      def test_search_empty_or_no_match
        @memory.write("Something else")
        assert_empty @memory.search("")
        assert_empty @memory.search("   ")
        assert_empty @memory.search("zzz-nothing")
      end

      def test_search_respects_limit
        3.times { |i| @memory.write("fact number #{i} about deploy") }
        assert_equal 2, @memory.search("deploy", limit: 2).size
      end

      # -----------------------------------------------------------------
      # Namespace isolation & durability
      # -----------------------------------------------------------------

      def test_namespaces_are_isolated
        other = Memory.new(state: @adapter, namespace: "user:99")
        @memory.write("Private to 42")

        assert_empty other.search("Private")
        assert_equal 0, other.count
        assert_equal 1, @memory.count
      end

      def test_json_round_trip_survives_serialization
        json_adapter = JsonAdapter.new
        memory = Memory.new(state: json_adapter, namespace: "user:42")
        memory.write("The deploy window is Tuesday", metadata: { session_id: "s1" })

        # A fresh Memory over the same adapter sees the stored entries.
        reloaded = Memory.new(state: json_adapter, namespace: "user:42")
        assert_equal 1, reloaded.count
        assert_equal "The deploy window is Tuesday", reloaded.list.first.content
        assert_equal "s1", reloaded.list.first.metadata[:session_id]
        assert_kind_of Time, reloaded.list.first.created_at
      end

      def test_works_with_minimal_get_set_adapter
        minimal = Memory.new(state: HashAdapter.new, namespace: "n")
        minimal.write("fact one")
        minimal.write("fact two")

        assert_equal 2, minimal.count
        assert_equal ["fact one"], minimal.search("one").map(&:content)
      end

      def test_concurrent_writes_are_safe
        threads = 8.times.map { |i| Thread.new { @memory.write("fact #{i}") } }
        threads.each(&:join)

        assert_equal 8, @memory.count
        assert_equal 8, @memory.list.size
      end

      # -----------------------------------------------------------------
      # Tools
      # -----------------------------------------------------------------

      def test_memory_write_tool
        tool = MemoryWrite.new(memory: @memory, session_id: "session-abc")

        result = tool.call(content: "Prefers concise answers")
        assert_predicate result, :ok?
        assert_match(/Saved to memory/, result.to_s)
        assert_equal "Prefers concise answers", @memory.list.first.content
        assert_equal "session-abc", @memory.list.first.metadata[:session_id]

        assert_predicate tool.call(content: " "), :error
      end

      def test_memory_search_tool
        @memory.write("Prefers email over SMS")
        tool = MemorySearch.new(memory: @memory)

        result = tool.call(query: "email")
        assert_predicate result, :ok?
        assert_match(/Prefers email over SMS/, result.to_s)

        result = tool.call(query: "nothing-here")
        assert_predicate result, :ok?
        assert_match(/no matching memories/, result.to_s)
      end

      def test_tool_names
        assert_equal "memory_write", MemoryWrite.new(memory: @memory, session_id: "s").name
        assert_equal "memory_search", MemorySearch.new(memory: @memory).name
      end

      # -----------------------------------------------------------------
      # Session integration
      # -----------------------------------------------------------------

      class TurnChat
        attr_reader :messages, :model, :model_id

        def initialize(*responses)
          @responses = responses
          @messages = []
          @model = OpenStruct.new(id: "gpt-4o")
          @model_id = "gpt-4o"
        end

        def with_instructions(*) = self

        def ask(message = nil, attachments: nil)
          @messages << Ask::Message.new(role: :user, content: message.to_s) if message
          response = @responses.shift || ResponseMessage.new(content: "done")
          @messages << Ask::Message.new(role: :assistant, content: response.content)
          response
        end

        def add_message(role:, content: nil, tool_call_id: nil, tool_calls: nil)
          @messages << Ask::Message.new(role: role, content: content, tool_call_id: tool_call_id, tool_calls: tool_calls)
        end

        def reset_messages! = @messages.clear
      end

      ResponseMessage = Data.define(:content, :tool_calls, :tool_results, :thinking, :input_tokens, :output_tokens, :cost) do
        def initialize(content:, tool_calls: {}, tool_results: {}, thinking: nil, input_tokens: nil, output_tokens: nil, cost: nil)
          super(content: content, tool_calls: tool_calls, tool_results: tool_results, thinking: thinking,
                input_tokens: input_tokens, output_tokens: output_tokens, cost: cost)
        end

        def tool_call? = !tool_calls.empty?
        def to_s = content.to_s
      end

      def tool_call(id, name, arguments = "{}")
        ToolCallInfo.new(id: id, name: name, arguments: arguments)
      end

      def test_session_injects_memory_tools
        session = Session.new(model: "gpt-4o", memory: @memory)
        names = session.instance_variable_get(:@tools).map(&:name)
        assert_includes names, "memory_write"
        assert_includes names, "memory_search"
        assert_same @memory, session.memory
      end

      def test_session_without_memory_has_no_memory_tools
        session = Session.new(model: "gpt-4o")
        names = session.instance_variable_get(:@tools).map(&:name)
        refute_includes names, "memory_write"
        refute_includes names, "memory_search"
        assert_nil session.memory
      end

      def test_session_injects_relevant_memories_at_run_start
        @memory.write("The user prefers email over SMS")
        @memory.write("Unrelated fact about gardening")

        chat = TurnChat.new(ResponseMessage.new(content: "hello"))
        Ask::Agent::Chat.stubs(:new).returns(chat)
        session = Session.new(model: "gpt-4o", memory: @memory)

        session.run("Contact user by email")

        injected = chat.messages.find { |m| m.role == :system }
        refute_nil injected
        assert_match(/Relevant memories/, injected.content)
        assert_match(/prefers email/, injected.content)
        refute_match(/gardening/, injected.content)
      ensure
        Ask::Agent::Chat.unstub(:new)
      end

      def test_memory_persists_across_sessions_end_to_end
        # Session A: the model writes a fact through the tool.
        chat_a = TurnChat.new(
          ResponseMessage.new(content: "", tool_calls: {
            "t1" => tool_call("t1", "memory_write", JSON.generate(content: "The deploy window is Tuesday"))
          }),
          ResponseMessage.new(content: "remembered")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat_a)
        session_a = Session.new(model: "gpt-4o", memory: @memory)
        assert_equal "remembered", session_a.run("Remember this")
        Ask::Agent::Chat.unstub(:new)

        # Session B: the fact is injected into context and searchable.
        chat_b = TurnChat.new(
          ResponseMessage.new(content: "", tool_calls: {
            "t2" => tool_call("t2", "memory_search", JSON.generate(query: "deploy"))
          }),
          ResponseMessage.new(content: "found it")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat_b)
        session_b = Session.new(model: "gpt-4o", memory: @memory)
        assert_equal "found it", session_b.run("When can we deploy?")

        injected = chat_b.messages.find { |m| m.role == :system }
        assert_match(/deploy window is Tuesday/, injected.content)
      ensure
        Ask::Agent::Chat.unstub(:new)
      end
      # -----------------------------------------------------------------
      # Memory: max_entries pruning
      # -----------------------------------------------------------------

      def test_memory_prunes_oldest_beyond_max_entries
        capped = Memory.new(state: HashAdapter.new, namespace: "n", max_entries: 3)
        5.times { |i| capped.write("fact #{i}") }

        assert_equal 3, capped.count
        assert_equal ["fact 4", "fact 3", "fact 2"], capped.list.map(&:content)
      end

      # -----------------------------------------------------------------
      # MemoryExtractor
      # -----------------------------------------------------------------

      class StubChat
        attr_reader :prompt

        def initialize(content, raise_on_ask: false)
          @content = content
          @raise_on_ask = raise_on_ask
        end

        def ask(prompt, attachments: nil)
          raise "ask failed" if @raise_on_ask

          @prompt = prompt
          OpenStruct.new(content: @content)
        end
      end

      def build_extractor(chat, **opts)
        MemoryExtractor.new(model: "gpt-4o", memory: @memory, chat: chat, **opts)
      end

      def transcript(messages)
        messages.map { |(role, content)| Ask::Message.new(role: role, content: content) }
      end

      def test_extractor_writes_facts_with_provenance
        chat = StubChat.new(%q({"facts": ["The user prefers email", "Deploy window is Tuesday"]}))
        extractor = build_extractor(chat)

        result = extractor.extract(transcript: transcript([%i[user hi], %i[assistant hello]]), session_id: "sess-1")

        assert_equal 2, result[:extracted].size
        assert_empty result[:skipped]
        assert_nil result[:error]
        assert_equal 2, @memory.count
        entry = @memory.list.first
        assert_equal true, entry.metadata[:extracted]
        assert_equal "sess-1", entry.metadata[:session_id]
      end

      def test_extractor_dedupes_against_existing_memory
        @memory.write("The user prefers email over SMS")
        chat = StubChat.new(%q({"facts": ["The user prefers email over SMS", "New fact"]}))
        extractor = build_extractor(chat)

        result = extractor.extract(transcript: transcript([%i[user hi]]), session_id: "s1")

        assert_equal ["New fact"], result[:extracted]
        assert_equal ["The user prefers email over SMS"], result[:skipped]
        assert_equal 2, @memory.count
      end

      def test_extractor_caps_candidates
        chat = StubChat.new(%q({"facts": ["a", "b", "c", "d"]}))
        extractor = build_extractor(chat, max_candidates: 2)

        result = extractor.extract(transcript: transcript([%i[user hi]]))

        assert_equal %w[a b], result[:extracted]
        assert_equal 2, @memory.count
      end

      def test_extractor_returns_empty_for_empty_transcript
        chat = StubChat.new(%q({"facts": ["x"]}))
        extractor = build_extractor(chat)

        result = extractor.extract(transcript: [])

        assert_equal [], result[:extracted]
        assert_nil chat.prompt # the model was never called
      end

      def test_extractor_handles_unparseable_response
        # First response is not JSON at all; fallback array extraction works.
        chat = StubChat.new("Sure, here you go: [\"fact one\"]")
        extractor = build_extractor(chat)

        result = extractor.extract(transcript: transcript([%i[user hi]]))

        assert_equal ["fact one"], result[:extracted]
      end

      def test_extractor_returns_error_result_on_garbage
        chat = StubChat.new("no facts here")
        extractor = build_extractor(chat)

        result = extractor.extract(transcript: transcript([%i[user hi]]))

        assert_empty result[:extracted]
        assert_equal "no facts returned", result[:error]
      end

      def test_extractor_never_raises_on_chat_failure
        chat = StubChat.new("", raise_on_ask: true)
        extractor = build_extractor(chat)

        result = extractor.extract(transcript: transcript([%i[user hi]]))

        assert_empty result[:extracted]
        assert_equal "ask failed", result[:error]
      end

      def test_extractor_filters_transcript_and_caps_messages
        chat = StubChat.new(%q({"facts": []}))
        extractor = build_extractor(chat, max_transcript_messages: 2)

        extractor.extract(transcript: transcript([
          %i[system system-noise],
          %i[user first],
          %i[tool tool-noise],
          %i[assistant second],
          %i[user third]
        ]))

        assert_match(/assistant: second/, chat.prompt)
        assert_match(/user: third/, chat.prompt)
        refute_match(/first/, chat.prompt)     # oldest dropped beyond cap
        refute_match(/system-noise/, chat.prompt)
        refute_match(/tool-noise/, chat.prompt)
      end

      # -----------------------------------------------------------------
      # Session: memory_learning
      # -----------------------------------------------------------------

      def test_memory_learning_requires_memory
        assert_raises(ArgumentError) do
          Session.new(model: "gpt-4o", memory_learning: true)
        end
      end

      def test_session_extracts_memories_after_run
        # First Chat.new: the session's chat; second: the extractor's chat.
        session_chat = TurnChat.new(ResponseMessage.new(content: "hello"))
        extractor_chat = StubChat.new(%q({"facts": ["The user prefers email"]}))
        Ask::Agent::Chat.stubs(:new).returns(session_chat, extractor_chat)

        session = Session.new(model: "gpt-4o", memory: @memory, memory_learning: true)
        session.run("Hi")

        assert_equal 1, @memory.count
        assert_equal "The user prefers email", @memory.list.first.content
        assert_equal true, @memory.list.first.metadata[:extracted]
      ensure
        Ask::Agent::Chat.unstub(:new)
      end

      def test_session_without_learning_does_not_extract
        session_chat = TurnChat.new(ResponseMessage.new(content: "hello"))
        Ask::Agent::Chat.stubs(:new).returns(session_chat)

        session = Session.new(model: "gpt-4o", memory: @memory)
        session.run("Hi")

        assert_equal 0, @memory.count
      ensure
        Ask::Agent::Chat.unstub(:new)
      end

    end
  end
end
