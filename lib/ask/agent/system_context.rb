# frozen_string_literal: true

module Ask
  module Agent
    # Composes typed context sources into a coherent system prompt.
    #
    # At initialization, each source renders its +baseline+ text. Sources
    # are ordered by their +key+ for deterministic output.
    #
    # At any point, +changes+ returns a list of update texts for sources
    # whose values have changed since the last snapshot. This enables
    # mid-conversation updates without rebuilding the entire prompt.
    #
    # @example
    #   ctx = SystemContext.new([
    #     InstructionsSource.new("You are a helper."),
    #     SkillsListSource.new(registry),
    #     DateSource.new,
    #   ])
    #
    #   prompt = ctx.render     # full system prompt
    #   updates = ctx.changes   # nil if nothing changed
    class SystemContext
      Snapshot = Data.define(:key, :value)

      def initialize(sources)
        @sources = sources
        @snapshots = {}
        take_snapshot
      end

      # Render the full baseline system prompt.
      # @return [String]
      def render
        parts = @sources.map do |source|
          value = @snapshots[source.key]&.value
          text = source.baseline(value) rescue nil
          text
        end
        parts.compact.join("\n\n")
      end

      # Detect changes since the last snapshot.
      # Returns update texts for sources whose value changed, or nil.
      # @return [Array<String>, nil]
      def changes
        updates = []
        @sources.each do |source|
          prev_value = @snapshots[source.key]&.value
          current_value = source.load
          next if prev_value == current_value

          update_text = source.update(prev_value, current_value)
          updates << update_text if update_text
          @snapshots[source.key] = Snapshot.new(key: source.key, value: current_value)
        end
        updates.any? ? updates : nil
      end

      # Access a source by key.
      # @param key [String]
      # @return [ContextSource, nil]
      def [](key)
        @sources.find { |s| s.key == key }
      end

      private

      def take_snapshot
        @sources.each do |source|
          value = source.load
          @snapshots[source.key] = Snapshot.new(key: source.key, value: value)
        end
      end
    end
  end
end
