# frozen_string_literal: true

require "json"

module Ask
  module Agent
    # Extracts durable facts from a finished session's transcript and writes
    # them to the session's {Memory} — the "learning" half of durable memory
    # (codex two-phase pattern, phase 1).
    #
    # One LLM call with a structured-output prompt: the model reads the
    # memory-relevant messages and returns a JSON list of durable facts.
    # Candidates are deduped against the store (exact + near-duplicate via
    # search), written with provenance (extracted: true, source session id),
    # and capped at +max_candidates+.
    #
    # Extraction never raises: a failed call or unparseable response yields
    # an empty result hash, never a broken session.
    #
    # Session wiring: `Session.new(memory: memory, memory_learning: true)`.
    class MemoryExtractor
      DEFAULT_SYSTEM_PROMPT = <<~PROMPT.strip
        You are a memory curator. Read the conversation transcript and extract
        durable facts worth remembering across sessions: user preferences,
        decisions, conventions, resolved problems, and standing instructions.
        Skip ephemeral details, session-specific chatter, secrets, and facts
        already obvious from the conversation itself.
        Respond with JSON only: {"facts": ["fact one", "fact two", ...]}.
        Return an empty list if nothing is worth remembering.
      PROMPT

      # @param model [String] model to extract with
      # @param memory [Ask::Agent::Memory] store to write into
      # @param chat [Ask::Agent::Chat, nil] chat to use (built from +model+
      #   when nil; inject a stub in tests)
      # @param system_prompt [String] domain-specific extraction instructions
      # @param max_candidates [Integer] cap on facts written per extraction
      # @param max_transcript_messages [Integer] cap on transcript messages
      #   sent to the model (oldest dropped first)
      def initialize(model:, memory:, chat: nil, system_prompt: DEFAULT_SYSTEM_PROMPT,
                     max_candidates: 10, max_transcript_messages: 60)
        @model = model
        @memory = memory
        @chat = chat
        @system_prompt = system_prompt
        @max_candidates = max_candidates
        @max_transcript_messages = max_transcript_messages
      end

      # @param transcript [Array<Ask::Message>] the finished session's messages
      # @param session_id [String, nil] stamped into extracted entries as
      #   provenance
      # @return [Hash] {extracted: [String], skipped: [String], error: [String, nil]}
      def extract(transcript:, session_id: nil)
        relevant = memory_relevant_messages(transcript)
        return { extracted: [], skipped: [], error: nil } if relevant.empty?

        facts = request_facts(relevant)
        return { extracted: [], skipped: [], error: "no facts returned" } if facts.empty?

        extracted = []
        skipped = []
        facts.first(@max_candidates).each do |fact|
          if duplicate?(fact)
            skipped << fact
          else
            @memory.write(
              fact,
              metadata: { extracted: true, session_id: session_id, extracted_at: Time.now.iso8601 }
            )
            extracted << fact
          end
        end
        { extracted: extracted, skipped: skipped, error: nil }
      rescue StandardError => e
        { extracted: [], skipped: [], error: e.message }
      end

      private

      # User and assistant messages with content, oldest dropped first beyond
      # the cap. Tool and system messages never reach the model.
      def memory_relevant_messages(transcript)
        transcript
          .select { |m| %i[user assistant].include?(m.role.to_sym) && m.content.to_s.strip.length.positive? }
          .last(@max_transcript_messages)
      end

      def request_facts(messages)
        body = messages.map { |m| "#{m.role}: #{m.content}" }.join("\n")
        response = chat.ask("#{@system_prompt}\n\nTranscript:\n#{body}")
        parse_facts(response.content.to_s)
      end

      def chat
        @chat ||= Chat.new(model: @model, tools: [])
      end

      def parse_facts(content)
        parsed = JSON.parse(content)
        facts = parsed.is_a?(Hash) ? (parsed["facts"] || parsed[:facts]) : parsed
        Array(facts).map(&:to_s).map(&:strip).reject(&:empty?)
      rescue JSON::ParserError
        # Fallback: the first JSON array in the response.
        match = content.match(/\[.*\]/m)
        match ? JSON.parse(match[0]).map(&:to_s).map(&:strip).reject(&:empty?) : []
      end

      def duplicate?(fact)
        @memory.search(fact, limit: 1).any? { |entry| similar?(entry.content, fact) }
      end

      def similar?(a, b)
        a == b || a.include?(b) || b.include?(a)
      end
    end
  end
end
