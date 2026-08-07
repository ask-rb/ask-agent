# frozen_string_literal: true

require "ask/tools/tool"
require "ask/result"

module Ask
  module Agent
    # Tool that saves facts to the session's durable memory ({Memory}).
    # Injected into the session by `Session.new(memory: memory)`.
    class MemoryWrite < Ask::Tool
      description "Save a fact to durable memory. " \
                   "Use this for information worth remembering across sessions: " \
                   "user preferences, decisions, conventions, resolved problems. " \
                   "The fact will be available to future sessions with the same namespace."

      param :content, type: :string, desc: "The fact to remember", required: true

      # @param memory [Ask::Agent::Memory]
      # @param session_id [String] stamped into the entry metadata as
      #   provenance
      def initialize(memory:, session_id:)
        @memory = memory
        @session_id = session_id
        super()
      end

      def execute(content:)
        entry = @memory.write(
          content,
          metadata: { session_id: @session_id, written_at: Time.now.iso8601 }
        )
        Ask::Result.ok(data: "Saved to memory (#{entry.id}): #{entry.content}")
      rescue ArgumentError => e
        Ask::Result.error(message: e.message)
      end
    end
  end
end
