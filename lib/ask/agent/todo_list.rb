# frozen_string_literal: true

module Ask
  module Agent
    # Session-scoped task list maintained by the model through the
    # {TodoWrite} tool.
    #
    # The list is the externalized plan: the model writes it once and checks
    # it against each step, humans see progress live (via the TodoUpdated
    # event), and checkpoints carry it across rollbacks and forks.
    class TodoList
      STATUSES = %w[pending in_progress completed blocked].freeze

      Entry = Data.define(:id, :title, :status) do
        def to_h = { id: id, title: title, status: status }
      end

      def initialize
        @entries = []
        @next_id = 1
        @mutex = Mutex.new
        @listeners = []
      end

      # @return [Array<Entry>] snapshot of the current entries
      def all
        @mutex.synchronize { @entries.dup }
      end

      # Register a listener called with the full entry list after every
      # change (used to emit TodoUpdated events for live rendering).
      #
      # @return [self]
      def subscribe(&block)
        @listeners << block
        self
      end

      # @param title [String]
      # @param status [String] pending, in_progress, completed, or blocked
      # @return [Entry]
      # @raise [ArgumentError] on empty title or invalid status
      def add(title, status: "pending")
        raise ArgumentError, "title is required" if title.to_s.strip.empty?

        entry = @mutex.synchronize do
          e = Entry.new(id: "todo_#{@next_id}", title: title.to_s, status: validate_status(status || "pending"))
          @next_id += 1
          @entries << e
          e
        end
        notify
        entry
      end

      # @param id [String] entry id from {Entry#id}
      # @param status [String, nil]
      # @param title [String, nil]
      # @return [Entry] the updated entry
      # @raise [ArgumentError] on unknown id or invalid status
      def update(id, status: nil, title: nil)
        entry = @mutex.synchronize do
          index = @entries.index { |e| e.id == id }
          raise ArgumentError, "no todo with id #{id.inspect}" unless index

          @entries[index] = Entry.new(
            id: id,
            title: title.nil? ? @entries[index].title : title.to_s,
            status: status.nil? ? @entries[index].status : validate_status(status)
          )
          @entries[index]
        end
        notify
        entry
      end

      # @return [void]
      def clear
        @mutex.synchronize { @entries.clear }
        notify
        nil
      end

      # @return [Hash] serialized form for persistence (checkpoints)
      def to_h
        { entries: all.map(&:to_h) }
      end

      # Rebuild from a serialized snapshot (rollback, fork, load). Fires no
      # events.
      #
      # @param data [Hash, nil]
      # @return [void]
      def restore(data)
        @mutex.synchronize do
          raw = Array(data&.dig(:entries) || data&.dig("entries") || [])
          @entries = raw.map do |e|
            Entry.new(
              id: (e[:id] || e["id"]).to_s,
              title: (e[:title] || e["title"]).to_s,
              status: (e[:status] || e["status"]).to_s
            )
          end
          @next_id = @entries.size + 1
        end
        nil
      end

      # @return [String] human-readable list
      def to_s
        entries = all
        return "(no todos)" if entries.empty?

        entries.map { |e| "[#{e.status}] #{e.title} (#{e.id})" }.join("\n")
      end

      private

      def validate_status(status)
        s = status.to_s
        raise ArgumentError, "invalid status #{s.inspect}; valid: #{STATUSES.join(', ')}" unless STATUSES.include?(s)

        s
      end

      def notify
        snapshot = all
        @listeners.each { |listener| listener.call(snapshot) }
      end
    end
  end
end
