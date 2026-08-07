# frozen_string_literal: true

require "ask/tools/tool"
require "ask/result"

module Ask
  module Agent
    # Tool that searches the session's durable memory ({Memory}). Injected
    # into the session by `Session.new(memory: memory)`.
    class MemorySearch < Ask::Tool
      description "Search durable memory for facts from previous sessions. " \
                   "Use this to recall user preferences, decisions, conventions, " \
                   "or resolved problems before answering."

      param :query, type: :string, desc: "Search query", required: true
      param :limit, type: :integer, desc: "Maximum number of results", required: false

      # @param memory [Ask::Agent::Memory]
      def initialize(memory:)
        @memory = memory
        super()
      end

      def execute(query:, limit: 5)
        hits = @memory.search(query, limit: limit)
        return Ask::Result.ok(data: "(no matching memories)") if hits.empty?

        Ask::Result.ok(data: hits.map { |e| "- #{e.content}" }.join("\n"))
      end
    end
  end
end
