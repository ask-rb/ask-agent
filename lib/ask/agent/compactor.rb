# frozen_string_literal: true

module Ask
  module Agent
    # Context compaction for long sessions. When conversation tokens approach
    # the model's context window, older messages are summarized and replaced
    # with a structured summary, preserving a recent tail verbatim.
    #
    # Trigger modes:
    # 1. Threshold — tokens exceed (context_window - reserve). Compact, no retry.
    # 2. Overflow — LLM returned context overflow. Compact, then auto-retry.
    #
    # Reserve is model-aware: it defaults to the model's declared max output
    # tokens (capped at {DEFAULT_RESERVE_TOKENS}), so compaction leaves exactly
    # the headroom a single turn can consume. For models without declared
    # limits, a static default applies. A safety floor clamps the reserve for
    # tiny-window models so threshold compaction can fire usefully instead of
    # triggering on every turn.
    #
    # The recent tail is also token-aware: {keep_recent_tokens} preserves the
    # last N tokens of conversation verbatim (recent-context fidelity depends
    # on the active work, not on message counts) and summarizes only what's
    # older. When not configured, the legacy fixed message-count behavior is
    # used for backward compatibility.
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

      # Default headroom reserved for a single model turn when the model's
      # max output tokens are unknown.
      DEFAULT_RESERVE_TOKENS = 20_000

      # Default verbatim recent-context tail preserved during compaction.
      DEFAULT_KEEP_RECENT_TOKENS = 8_000

      # Minimum reserve for tiny-window models (safety floor).
      MIN_RESERVE_TOKENS = 1_024

      # Legacy fixed message-count tail (backward compatibility).
      DEFAULT_KEEP_COUNT = 8

      # Conversations smaller than this are never compacted.
      MIN_MESSAGES = 6

      attr_accessor :chat, :llm

      # @param threshold [Float, nil] Compact when tokens exceed
      #   context_window * threshold. When nil (default), compaction triggers
      #   at context_window - reserve_tokens (model-aware).
      # @param strategy [Symbol] Reserved; :proactive is the only strategy.
      # @param llm [Object, String, nil] LLM used for summarization. When nil,
      #   a heuristic summary is generated instead.
      # @param reserve_tokens [Integer, nil] Explicit headroom for one turn.
      #   When nil, derived from the model's max output tokens (see
      #   {#derive_reserve}).
      # @param keep_recent_tokens [Integer, nil] Explicit verbatim recent-tail
      #   budget. When nil, the legacy fixed message-count tail is preserved.
      # @param keep_count [Integer] Legacy fixed tail in messages when
      #   keep_recent_tokens is nil.
      # @param min_messages [Integer] Conversations with fewer messages are
      #   never compacted.
      def initialize(threshold: nil, strategy: :proactive, llm: nil,
                     reserve_tokens: nil, keep_recent_tokens: nil,
                     keep_count: DEFAULT_KEEP_COUNT, min_messages: MIN_MESSAGES)
        @threshold = threshold
        @strategy = strategy
        @llm = llm
        @reserve_tokens = reserve_tokens
        @keep_recent_tokens = keep_recent_tokens
        @keep_count = keep_count
        @min_messages = min_messages
        @already_compacted = false
        @overflow_recovered = false
      end

      def overflow_recovered? = @overflow_recovered

      # Whether the conversation is close enough to the model's window that
      # compaction should run. Triggers at either threshold mode
      # (window * threshold) or reserve mode (window - reserve).
      def should_compact?
        return false unless @chat
        estimate_total_tokens >= compact_threshold_tokens
      end

      # The token count at which compaction triggers.
      #
      # @return [Integer]
      def compact_threshold_tokens
        window = context_window
        return (window * @threshold).round if @threshold

        window - reserve_tokens
      end

      # Run compaction, emitting start/end events.
      #
      # @param event_emitter [#emit, nil]
      def run(event_emitter: nil)
        return unless @chat

        tokens_before = estimate_total_tokens
        event_emitter&.emit(Events::CompactionStart.new(tokens_before: tokens_before, reason: :threshold))
        compact!
        tokens_after = estimate_total_tokens
        @already_compacted = true
        event_emitter&.emit(Events::CompactionEnd.new(tokens_before: tokens_before, tokens_after: tokens_after, summary: extract_summary))
      end

      # Summarize older messages and replace them with a summary, preserving
      # a recent tail. The tail is either token-based ({keep_recent_tokens})
      # or the legacy fixed message count.
      def compact!
        return unless @chat
        messages = @chat.messages.dup
        return if messages.size < @min_messages

        split_index = find_split_index(messages)
        older = messages.first(split_index)
        return if older.empty?

        summary = if @llm
          generate_llm_summary(older) || generate_summary(older)
        else
          generate_summary(older)
        end

        older.size.times { @chat.messages.delete_at(0) }
        @chat.add_message(role: :system, content: "[Previous conversation summary]: #{summary}")
      end

      # Aggressive overflow fallback: clears oversized tool results in place,
      # keeping the conversation structure intact.
      def microcompact!
        return unless @chat
        @chat.messages.map! do |msg|
          next msg unless msg.role == :tool
          next msg unless msg.content.to_s.length > 200

          Ask::Message.new(
            role: :tool,
            content: "[Tool result cleared by compaction]",
            tool_call_id: msg.tool_call_id,
            metadata: msg.metadata
          )
        end
      end

      # Recover from a context-overflow error: compact once, then fall back
      # to micro-compaction on subsequent overflows in the same session.
      def recover_from_overflow
        if @already_compacted then microcompact! else compact! end
        @already_compacted = true
        @overflow_recovered = true
      end

      # Rough token estimate: ~4 characters per token.
      #
      # @param text [String]
      # @return [Integer]
      def estimate_tokens(text)
        (text.to_s.length / 4.0).ceil
      end

      # Total estimated tokens across all messages, including tool-call
      # payloads.
      #
      # @return [Integer]
      def estimate_total_tokens
        return 0 unless @chat
        @chat.messages.sum { |msg| estimate_message_tokens(msg) }
      end

      # The model's context window. Consulted from the model catalog first,
      # then the bundled table, then the default.
      #
      # @return [Integer]
      def context_window
        info = model_info
        return info.context_window if info&.context_window

        CONTEXT_WINDOWS[@chat.model.to_s] || CONTEXT_WINDOWS.default
      end

      # Headroom reserved for one model turn. Explicit value wins; otherwise
      # derived from the model's max output tokens with a safety floor.
      #
      # @return [Integer]
      def reserve_tokens
        @reserve_tokens || derive_reserve
      end

      # Verbatim recent-tail budget in tokens.
      #
      # @return [Integer]
      def keep_recent_tokens
        @keep_recent_tokens || DEFAULT_KEEP_RECENT_TOKENS
      end

      # The text of the most recent injected summary, or "" if none exists.
      #
      # @return [String]
      def extract_summary
        @chat.messages.each { |msg| return msg.content.to_s if msg.content.to_s.start_with?("[Previous conversation summary]") }
        ""
      end

      private

      def model_info
        Ask::ModelCatalog.find(@chat.model.to_s)
      rescue Ask::ModelNotFound, NameError
        nil
      end

      # Derive the reserve from the model's declared max output tokens,
      # capped at {DEFAULT_RESERVE_TOKENS}. Applies a safety floor for
      # tiny-window models: if the reserve would consume half or more of the
      # window, clamp it to a third so threshold compaction can fire usefully
      # instead of triggering on every turn.
      #
      # @return [Integer]
      def derive_reserve
        info = model_info
        max_output = info&.max_output_tokens.to_i
        reserve = if max_output > 0
          [DEFAULT_RESERVE_TOKENS, max_output].min
        else
          DEFAULT_RESERVE_TOKENS
        end

        window = context_window
        if window > 0 && reserve * 2 >= window
          reserve = [MIN_RESERVE_TOKENS, window / 3].max
        end
        reserve
      end

      # Index of the first message in the recent tail. Token-based when
      # keep_recent_tokens is configured; otherwise the legacy fixed
      # message-count tail.
      #
      # @param messages [Array<Ask::Message>]
      # @return [Integer]
      def find_split_index(messages)
        if @keep_recent_tokens
          find_token_split_index(messages)
        else
          [messages.size - @keep_count, 0].max
        end
      end

      # Walk from the end of the conversation accumulating tokens until the
      # keep_recent_tokens budget is consumed. The split never keeps fewer
      # than MIN_MESSAGES recent messages — the tail always retains a recent
      # exchange intact.
      #
      # @param messages [Array<Ask::Message>]
      # @return [Integer]
      def find_token_split_index(messages)
        budget = keep_recent_tokens
        index = messages.size

        messages.reverse_each do |msg|
          budget -= estimate_message_tokens(msg)
          index -= 1
          break if budget <= 0
        end

        # Never keep fewer than MIN_MESSAGES recent messages
        [index, messages.size - MIN_MESSAGES].min
      end

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
    end
  end
end
