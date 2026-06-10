# frozen_string_literal: true

module Ask
  module Agent
    class Compactor
      CONTEXT_WINDOWS = {
        "gpt-4o" => 128_000,
        "gpt-4o-mini" => 128_000,
        "gpt-4-turbo" => 128_000,
        "claude-sonnet-4" => 200_000,
        "claude-4" => 200_000,
        "gemini-2.0-flash" => 1_048_576,
        "gemini-2.5-pro" => 1_048_576,
        "deepseek-v4-flash" => 1_000_000,
        "deepseek-v4-pro" => 1_000_000,
      }.tap { |h| h.default = 128_000 }

      attr_accessor :chat, :llm

      def initialize(threshold: 0.8, strategy: :proactive, llm: nil)
        @threshold = threshold
        @strategy = strategy
        @llm = llm
        @already_compacted = false
        @overflow_recovered = false
      end

      def overflow_recovered? = @overflow_recovered

      def should_compact?
        return false unless @chat
        current = estimate_total_tokens
        window = context_window
        current >= window * @threshold
      end

      def run(event_emitter: nil)
        return unless @chat

        tokens_before = estimate_total_tokens
        event_emitter&.emit(Events::CompactionStart.new(tokens_before: tokens_before, reason: :threshold))
        compact!
        tokens_after = estimate_total_tokens
        @already_compacted = true
        event_emitter&.emit(Events::CompactionEnd.new(tokens_before: tokens_before, tokens_after: tokens_after, summary: extract_summary))
      end

      def compact!
        return unless @chat
        messages = @chat.messages.dup
        return if messages.size < 6

        keep_count = [messages.size, 8].min
        recent = messages.last(keep_count)
        older = messages.first(messages.size - keep_count)
        return if older.empty?

        summary = if @llm
          generate_llm_summary(older) || generate_summary(older)
        else
          generate_summary(older)
        end

        older.size.times { @chat.messages.delete_at(0) }
        @chat.add_message(role: :system, content: "[Previous conversation summary]: #{summary}")
      end

      def microcompact!
        return unless @chat
        @chat.messages.each do |msg|
          next unless msg.role == :tool
          msg.content = "[Tool result cleared by compaction]" if msg.content.to_s.length > 200
        end
      end

      def recover_from_overflow
        if @already_compacted then microcompact! else compact! end
        @already_compacted = true
        @overflow_recovered = true
      end

      def estimate_tokens(text)
        (text.to_s.length / 4.0).ceil
      end

      def estimate_total_tokens
        return 0 unless @chat
        @chat.messages.sum { |msg| estimate_message_tokens(msg) }
      end

      def context_window
        model = @chat.model.to_s
        CONTEXT_WINDOWS[model]
      end

      private

      def estimate_message_tokens(message)
        base = estimate_tokens(message.content.to_s)
        if message.tool_call? && message.respond_to?(:tool_calls) && message.tool_calls
          base + message.tool_calls.sum { |_, tc| estimate_tokens(tc.name.to_s) + estimate_tokens(tc.arguments.to_s) }
        else
          base
        end
      end

      def generate_summary(messages)
        lines = messages.each_cons(2)
          .select { |a, _b| a.role == :user }
          .map { |u, a| "- Asked: #{u.content.to_s[0, 80]} → #{a.content.to_s[0, 120]}" }
        lines.empty? ? "Previous conversation context." : lines.join("\n")
      end

      def generate_llm_summary(messages)
        prompt = "Summarize this conversation concisely. Focus on goals accomplished, key info, decisions, and pending actions.\n\n#{serialize_conversation(messages)}"
        response = build_llm_chat.ask(prompt)
        text = response.content.to_s.strip
        text.empty? ? nil : text
      rescue
        nil
      end

      def serialize_conversation(messages)
        messages.map { |m|
          role = m.role == :user ? "Human" : "Assistant"
          content = if m.tool_call? && m.respond_to?(:tool_calls) && m.tool_calls
                      details = m.tool_calls.map { |_, tc| "  - Called #{tc.name} with #{tc.arguments}" }.join("\n")
                      "#{m.content}\n#{details}"
                    elsif m.role == :tool
                      c = m.content.to_s[0, 500]
                      "[Tool result]: #{c}"
                    else
                      m.content.to_s
                    end
          "#{role}: #{content}"
        }.join("\n---\n")
      end

      def build_llm_chat
        if @llm.respond_to?(:ask) then @llm
        elsif @llm.is_a?(String) then Ask::Agent::Chat.new(model: @llm)
        else Ask::Agent::Chat.new(model: Ask::Agent.configuration.default_model) end
      end

      def extract_summary
        @chat.messages.each { |msg| return msg.content.to_s if msg.content.to_s.start_with?("[Previous conversation summary]") }
        ""
      end
    end
  end
end
