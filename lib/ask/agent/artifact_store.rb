# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module Ask
  module Agent
    # Session-scoped storage for tool-produced deliverables ("artifacts").
    #
    # Artifacts come in two kinds, chosen by the producing tool:
    #
    # - **content** — small text deliverables (reports, CSVs, patches,
    #   generated code) stored inline in the state store.
    # - **uri** — large or binary deliverables stored externally (object
    #   storage, a file service); the store keeps the reference and
    #   metadata only.
    #
    # Metadata always lives in the state store (pure KV, same adapter as
    # sessions/checkpoints/memory — works with every backend and with the
    # in-process Memory fallback):
    #   artifact:<session_id>:<artifact_id>   — one key per artifact
    #   artifact:<session_id>:index           — JSON array of ids
    #
    # An optional +uploader+ callback lifts inline content to a URI before
    # storage (e.g. upload to S3), so apps that prefer object storage never
    # grow the database: the tool returns content, the session uploads, the
    # store keeps the reference.
    class ArtifactStore
      KEY_PREFIX = "artifact:"
      INDEX_SUFFIX = ":index"

      # @param state [Ask::State::Adapter] backing store
      # @param max_content_size [Integer] inline content cap (chars)
      # @param uploader [Proc, nil] called with (content:, filename:,
      #   mime_type:) when a tool provides inline content; must return a URI
      #   string. When set, inline content is uploaded and the URI stored.
      def initialize(state:, max_content_size: 100_000, uploader: nil)
        @state = state
        @max_content_size = max_content_size
        @uploader = uploader
        @mutex = Monitor.new
      end

      # @return [Ask::State::Adapter] the underlying adapter
      attr_reader :state

      # @return [Proc, nil] the uploader callback, if any
      attr_reader :uploader

      # Store an artifact for a session.
      #
      # @param session_id [String]
      # @param filename [String] required
      # @param mime_type [String, nil]
      # @param content [String, nil] inline content (small text); xor +uri+
      # @param uri [String, nil] external reference (large/binary); xor
      #   +content+
      # @return [Hash] the stored record {id:, filename:, mime_type:, size:,
      #   created_at:, content: | uri:}
      # @raise [ArgumentError] on invalid input
      def store(session_id, filename:, mime_type: nil, content: nil, uri: nil)
        raise ArgumentError, "filename is required" if filename.to_s.strip.empty?
        raise ArgumentError, "pass either content: or uri:, not both" if content && uri
        raise ArgumentError, "pass either content: or uri:" unless content || uri

        if content
          content = content.to_s
          if content.length > @max_content_size
            raise ArgumentError, "content exceeds #{@max_content_size} chars; use uri: for large artifacts"
          end
          if @uploader
            uri = @uploader.call(content: content, filename: filename.to_s, mime_type: mime_type)
            content = nil
          end
        end

        id = SecureRandom.uuid
        record = {
          id: id,
          filename: filename.to_s,
          mime_type: mime_type,
          size: content ? content.length : nil,
          created_at: Time.now.iso8601
        }
        record[:content] = content if content
        record[:uri] = uri if uri

        @mutex.synchronize do
          @state.set(entry_key(session_id, id), record)
          @state.set(index_key(session_id), (load_index(session_id) + [id]).to_json)
        end
        record
      end

      # @param session_id [String]
      # @return [Array<Hash>] artifact summaries (id, filename, mime_type,
      #   size, uri) newest first — content is not included
      def list(session_id)
        load_index(session_id)
          .filter_map { |id| fetch(session_id, id) }
          .reverse
          .map { |r| r.slice(:id, :filename, :mime_type, :size, :uri) }
      end

      # @param session_id [String]
      # @param id [String]
      # @return [Hash, nil] the full record (content or uri)
      def fetch(session_id, id)
        data = @state.get(entry_key(session_id, id))
        return nil unless data

        symbolize(data)
      end

      # Remove every artifact for a session (called by Session#delete).
      #
      # @param session_id [String]
      # @return [void]
      def delete(session_id)
        @mutex.synchronize do
          load_index(session_id).each { |id| @state.delete(entry_key(session_id, id)) }
          @state.delete(index_key(session_id))
        end
        nil
      end

      private

      def load_index(session_id)
        raw = @state.get(index_key(session_id))
        raw ? JSON.parse(raw) : []
      end

      def entry_key(session_id, id)
        "#{KEY_PREFIX}#{session_id}:#{id}"
      end

      def index_key(session_id)
        "#{KEY_PREFIX}#{session_id}#{INDEX_SUFFIX}"
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
