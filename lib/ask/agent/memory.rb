# frozen_string_literal: true

require "json"
require "monitor"
require "securerandom"
require "time"

module Ask
  module Agent
    # Durable, namespaced memory on any {Ask::State::Adapter} — the same
    # storage layer as sessions and checkpoints.
    #
    # Entries are plain facts ("the deploy window is Tuesday", "the user
    # prefers concise answers") that outlive a session: session A writes
    # them, session B (same adapter + namespace) retrieves them via keyword
    # search and has them injected into context. The abstraction is
    # domain-agnostic — nothing here assumes a coding agent.
    #
    # Storage shape (pure KV, no list primitives — works with every backend
    # including custom get/set/delete adapters):
    #   memory:<namespace>:<id>      — one key per entry
    #   memory:<namespace>:index     — JSON array of entry ids (write order)
    #
    #   store = Ask::State::Providers::SQLite.new(path: "agent.db")
    #   memory = Ask::Agent::Memory.new(state: store, namespace: "user:42")
    #   memory.write("Deploy window is Tuesday")
    #   memory.search("when can we deploy?")   # => [Entry]
    #
    # Namespaces isolate memory: a support agent's facts never leak into a
    # finance agent's, and tenants share one backend safely.
    class Memory
      Entry = Data.define(:id, :content, :metadata, :created_at) do
        def to_h = { id: id, content: content, metadata: metadata, created_at: created_at.iso8601 }
      end

      KEY_PREFIX = "memory:"
      INDEX_SUFFIX = ":index"

      # @param state [Ask::State::Adapter] backing store
      # @param namespace [String] isolation scope (user id, project id, ...)
      # @param max_entries [Integer, nil] when set, the oldest entries are
      #   pruned once the namespace exceeds this many entries
      def initialize(state:, namespace:, max_entries: nil)
        @state = state
        @namespace = namespace.to_s
        @max_entries = max_entries
        @mutex = Monitor.new
      end

      # @return [Ask::State::Adapter] the underlying adapter
      attr_reader :state

      # @return [String] the namespace this memory is scoped to
      attr_reader :namespace

      # Save a fact. Writing an identical content again is a no-op (returns
      # the existing entry).
      #
      # @param content [String] the fact to remember
      # @param metadata [Hash] optional provenance (session id, tags, ...)
      # @return [Entry]
      # @raise [ArgumentError] on empty content
      def write(content, metadata: {})
        content = content.to_s
        raise ArgumentError, "content is required" if content.strip.empty?

        @mutex.synchronize do
          existing = entries.find { |e| e.content == content }
          return existing if existing

          entry = Entry.new(id: SecureRandom.uuid, content: content, metadata: metadata, created_at: Time.now)
          @state.set(entry_key(entry.id), entry.to_h)
          @state.set(index_key, (load_index + [entry.id]).to_json)
          prune_oldest if @max_entries
          entry
        end
      end

      # Keyword search over the namespace's entries: entries matching any
      # query term (case-insensitive substring), ranked by matched-term
      # count, newest first on ties.
      #
      # @param query [String]
      # @param limit [Integer] max results
      # @return [Array<Entry>]
      def search(query, limit: 5)
        terms = query.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").split(/\s+/).reject(&:empty?)
        return [] if terms.empty?

        scored = entries.filter_map do |entry|
          text = entry.content.downcase
          hits = terms.count { |term| text.include?(term) }
          [hits, entry] if hits.positive?
        end
        scored.sort_by { |hits, entry| [-hits, entry.created_at] }.first(limit).map(&:last)
      end

      # @param limit [Integer]
      # @return [Array<Entry>] entries, newest first
      def list(limit: 50)
        entries.last(limit).reverse
      end

      # Remove an entry by id.
      #
      # @param id [String]
      # @return [void]
      def delete(id)
        @mutex.synchronize do
          @state.delete(entry_key(id))
          @state.set(index_key, (load_index - [id]).to_json)
        end
        nil
      end

      # @return [Integer] number of entries in this namespace
      def count
        entries.size
      end

      private

      # Drop the oldest entries beyond the max_entries cap (called under the
      # write mutex; delete re-enters it, which is safe).
      def prune_oldest
        current = entries
        return if current.size <= @max_entries

        current.first(current.size - @max_entries).each { |entry| delete(entry.id) }
      end

      def entries
        load_index.filter_map { |id| load_entry(id) }
      end

      def load_index
        raw = @state.get(index_key)
        raw ? JSON.parse(raw) : []
      end

      def load_entry(id)
        data = @state.get(entry_key(id))
        return nil unless data

        data = symbolize(data)
        Entry.new(
          id: id,
          content: data[:content].to_s,
          metadata: data[:metadata] || {},
          created_at: Time.parse(data[:created_at])
        )
      rescue ArgumentError, TypeError
        nil
      end

      def entry_key(id)
        "#{KEY_PREFIX}#{@namespace}:#{id}"
      end

      def index_key
        "#{KEY_PREFIX}#{@namespace}#{INDEX_SUFFIX}"
      end

      def symbolize(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = symbolize(v) }
        when Array
          obj.map { |e| symbolize(e) }
        else
          obj
        end
      end
    end
  end
end
