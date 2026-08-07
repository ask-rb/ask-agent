# frozen_string_literal: true

require "ask/tools/tool"
require "ask/result"

module Ask
  module Agent
    # Tool that retrieves an offloaded tool output by call id — the other
    # half of large-output offloading. The transcript keeps a preview plus a
    # reference ("output_read id: \"call_123\""); this tool fetches the full
    # output from the session's {ToolOutputStore}.
    #
    # Injected into the session when large-output offloading is enabled.
    class OutputRead < Ask::Tool
      description "Retrieve the full output of a tool call that was truncated in the conversation. " \
                   "Use the id from the truncation note (e.g. output_read id: \"call_123\")."

      param :id, type: :string, desc: "Tool call id from the truncation note", required: true

      # @param store [Ask::Agent::ToolOutputStore]
      # @param session_id [String] scopes lookups to this session
      def initialize(store:, session_id:)
        @store = store
        @session_id = session_id
        super()
      end

      def execute(id:)
        output = @store.fetch(@session_id, id)
        return Ask::Result.error(message: "No stored output for id #{id.inspect}") if output.nil?

        Ask::Result.ok(data: output)
      end
    end
  end
end
