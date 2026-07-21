# frozen_string_literal: true

module Ask
  module Agent
    # A typed, independently observable piece of the system context.
    #
    # Each source has a unique +key+, a +load+ function that returns its
    # current value, a +baseline+ render for initial prompt inclusion,
    # and an +update+ render for mid-conversation change notifications.
    #
    # @example
    #   class DateSource < Ask::Agent::ContextSource
    #     key "core/date"
    #
    #     def load
    #       Date.today.iso8601
    #     end
    #
    #     def baseline(date)
    #       "Today is #{date}."
    #     end
    #
    #     def update(prev, curr)
    #       "Earlier I said the date was #{prev}, but it is now #{curr}."
    #     end
    #   end
    class ContextSource
      class << self
        # Unique namespaced key for this source (e.g., "core/date").
        # Used for change detection and deterministic ordering.
        def key(value = :__no_value__)
          if value == :__no_value__
            @key
          else
            @key = value
          end
        end

        def inherited(subclass)
          super
          # Register source type for discovery
          @registered_sources ||= []
          @registered_sources << subclass
        end

        def registered_sources
          @registered_sources || []
        end
      end

      # @return [String] unique key for this source
      def key
        self.class.key
      end

      # Load the current value of this source.
      # @return [Object] any value that will be passed to +baseline+ and +update+
      def load
        raise NotImplementedError
      end

      # Render the initial text for this source.
      # @param value [Object] the value returned by +load+
      # @return [String]
      def baseline(value)
        raise NotImplementedError
      end

      # Render a mid-conversation update message.
      # Called when +load+ returns a value different from the previous one.
      # @param previous [Object] the value from the last load
      # @param current [Object] the current value
      # @return [String, nil] nil if no update is needed
      def update(previous, current)
        nil
      end
    end
  end
end
