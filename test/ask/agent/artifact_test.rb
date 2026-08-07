# frozen_string_literal: true

require_relative "../../test_helper"
require "ostruct"

module Ask
  module Agent
    class ArtifactTest < Minitest::Test
      class ReportTool < Ask::Tool
        description "Produces a report artifact."
        def execute
          Ask::Result.ok(
            data: "Report generated",
            metadata: { artifact: { filename: "report.csv", mime_type: "text/csv", content: "a,b\n1,2\n" } }
          )
        end
      end

      class UriTool < Ask::Tool
        description "Produces an external artifact."
        def execute
          Ask::Result.ok(
            data: "Big file uploaded",
            metadata: { artifact: { filename: "scan.pdf", mime_type: "application/pdf", uri: "s3://bucket/scan.pdf" } }
          )
        end
      end

      class BadArtifactTool < Ask::Tool
        description "Produces a malformed artifact."
        def execute
          Ask::Result.ok(data: "oops", metadata: { artifact: { filename: "x.txt" } })
        end
      end

      class HashAdapter
        attr_reader :data

        def initialize
          @data = {}
        end

        def get(key) = @data[key]
        def set(key, value, ttl: nil) = @data[key] = value
        def delete(key) = @data.delete(key)
      end

      class JsonAdapter < HashAdapter
        def get(key) = @data[key] && JSON.parse(JSON.generate(@data[key]))
        def set(key, value, ttl: nil) = @data[key] = value
      end

      class NullEmitter
        def emit(*) = nil
      end

      def setup
        @adapter = HashAdapter.new
        @store = ArtifactStore.new(state: @adapter)
      end

      # -----------------------------------------------------------------
      # ArtifactStore
      # -----------------------------------------------------------------

      def test_store_and_fetch_content_artifact
        record = @store.store("s1", filename: "report.csv", mime_type: "text/csv", content: "a,b\n1,2\n")

        assert_equal "report.csv", record[:filename]
        assert_equal 8, record[:size]
        assert_nil record[:uri]
        fetched = @store.fetch("s1", record[:id])
        assert_equal "a,b\n1,2\n", fetched[:content]
      end

      def test_store_uri_artifact
        record = @store.store("s1", filename: "scan.pdf", mime_type: "application/pdf", uri: "s3://bucket/scan.pdf")

        assert_equal "s3://bucket/scan.pdf", record[:uri]
        assert_nil record[:content]
        assert_nil record[:size]
      end

      def test_list_excludes_content_and_is_newest_first
        first = @store.store("s1", filename: "one.txt", content: "one")
        second = @store.store("s1", filename: "two.txt", content: "two")

        list = @store.list("s1")

        assert_equal [second[:id], first[:id]], list.map { |a| a[:id] }
        refute list.first.key?(:content)
        assert_equal "two.txt", list.first[:filename]
      end

      def test_validation
        assert_raises(ArgumentError) { @store.store("s1", filename: "", content: "x") }
        assert_raises(ArgumentError) { @store.store("s1", filename: "x.txt") }
        assert_raises(ArgumentError) { @store.store("s1", filename: "x.txt", content: "a", uri: "s3://b") }
      end

      def test_content_size_cap
        capped = ArtifactStore.new(state: HashAdapter.new, max_content_size: 5)
        assert_raises(ArgumentError) { capped.store("s1", filename: "big.txt", content: "123456") }
        assert capped.store("s1", filename: "ok.txt", content: "12345")
      end

      def test_uploader_lifts_content_to_uri
        uploader = ->(content:, filename:, mime_type:) { "s3://uploads/#{filename}" }
        store = ArtifactStore.new(state: HashAdapter.new, uploader: uploader)

        record = store.store("s1", filename: "report.csv", content: "a,b")

        assert_equal "s3://uploads/report.csv", record[:uri]
        assert_nil record[:content]
        assert_nil store.fetch("s1", record[:id])[:content]
      end

      def test_delete_removes_all_artifacts_for_session
        r1 = @store.store("s1", filename: "a.txt", content: "a")
        @store.store("s2", filename: "b.txt", content: "b")

        @store.delete("s1")

        assert_nil @store.fetch("s1", r1[:id])
        assert_equal 1, @store.list("s2").size
        assert_empty @adapter.data.keys.grep(/s1/)
      end

      def test_json_round_trip
        adapter = JsonAdapter.new
        store = ArtifactStore.new(state: adapter)
        record = store.store("s1", filename: "r.csv", content: "a,b")

        reloaded = ArtifactStore.new(state: adapter)
        fetched = reloaded.fetch("s1", record[:id])
        assert_equal "r.csv", fetched[:filename]
        assert_equal "a,b", fetched[:content]
      end

      def test_sessions_are_isolated
        @store.store("s1", filename: "a.txt", content: "a")
        assert_empty @store.list("s2")
      end

      # -----------------------------------------------------------------
      # Executor collection
      # -----------------------------------------------------------------

      def run_tool(tool, **executor_opts)
        executor = ToolExecutor.new(max_retries: 1, parallel: false, artifact_store: @store, **executor_opts)
        executor.execute(
          { "c1" => ToolCallInfo.new(id: "c1", name: tool.name, arguments: "{}") },
          [tool],
          hooks: Hooks.new({}),
          event_emitter: NullEmitter.new,
          session_id: "s1"
        ).first
      end

      def test_executor_collects_content_artifact
        run_tool(ReportTool.new)

        artifacts = @store.list("s1")
        assert_equal 1, artifacts.size
        assert_equal "report.csv", artifacts.first[:filename]
      end

      def test_executor_collects_uri_artifact
        run_tool(UriTool.new)

        assert_equal "s3://bucket/scan.pdf", @store.list("s1").first[:uri]
      end

      def test_executor_notes_malformed_artifact
        result = run_tool(BadArtifactTool.new)

        assert_match(/artifact not stored/, result[:message])
        assert_empty @store.list("s1")
      end

      def test_executor_does_not_collect_without_store
        result = run_tool(ReportTool.new, artifact_store: nil)

        assert_equal "Report generated", result[:message]
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

        def ask(message = nil)
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

      def test_session_option_wiring
        session = Session.new(model: "gpt-4o", artifacts: true)
        assert_instance_of ArtifactStore, session.artifact_store

        plain = Session.new(model: "gpt-4o")
        assert_nil plain.artifact_store
        assert_raises(RuntimeError) { plain.artifacts }
      end

      def test_session_collects_artifacts_end_to_end
        chat = TurnChat.new(
          ResponseMessage.new(content: "", tool_calls: {
            "t1" => tool_call("t1", "report")
          }),
          ResponseMessage.new(content: "done")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat)

        session = Session.new(model: "gpt-4o", tools: [ReportTool.new], artifacts: true)
        session.run("Generate the report")

        artifacts = session.artifacts
        assert_equal 1, artifacts.size
        assert_equal "report.csv", artifacts.first[:filename]
        record = session.fetch_artifact(artifacts.first[:id])
        assert_equal "a,b\n1,2\n", record[:content]
      ensure
        Ask::Agent::Chat.unstub(:new)
      end

      def test_session_uploader_lifts_artifacts
        chat = TurnChat.new(
          ResponseMessage.new(content: "", tool_calls: {
            "t1" => tool_call("t1", "report")
          }),
          ResponseMessage.new(content: "done")
        )
        Ask::Agent::Chat.stubs(:new).returns(chat)

        session = Session.new(
          model: "gpt-4o", tools: [ReportTool.new], artifacts: true,
          artifact_uploader: ->(content:, filename:, mime_type:) { "s3://bucket/#{filename}" }
        )
        session.run("Generate the report")

        assert_equal "s3://bucket/report.csv", session.artifacts.first[:uri]
      ensure
        Ask::Agent::Chat.unstub(:new)
      end

      def test_session_delete_cleans_up_artifacts
        session = Session.new(model: "gpt-4o", artifacts: true)
        session.artifact_store.store(session.id, filename: "x.txt", content: "x")

        session.delete

        assert_empty session.artifact_store.list(session.id)
      end
    end
  end
end
