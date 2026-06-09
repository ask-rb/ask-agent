# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module Ask
  module Agent
    class Telemetry
      TELEMETRY_DIR = File.expand_path("~/.ask/agent/telemetry")
      EVENT_TYPES = %i[tool_error loop_detected max_turns_exceeded compaction_end reflection_end].freeze

      attr_reader :enabled

      def initialize(enabled: true, dir: nil)
        @enabled = enabled
        @dir = dir || TELEMETRY_DIR
        @mutex = Mutex.new
      end

      def log(event_type, data)
        return unless @enabled
        return unless EVENT_TYPES.include?(event_type)

        entry = {
          timestamp: Time.now.utc.iso8601(3),
          event_type: event_type,
          session_id: data[:session_id],
          details: data.reject { |k, _| k == :session_id }
        }

        dir = File.join(@dir, event_type.to_s)
        FileUtils.mkdir_p(dir)

        filename = "#{entry[:timestamp].tr(':', '-')}_#{SecureRandom.hex(4)}.json"

        @mutex.synchronize do
          File.write(File.join(dir, filename), JSON.pretty_generate(entry) + "\n")
        end
      end

      def read(event_type = nil)
        return {} unless File.directory?(@dir)

        entries = []
        dirs = event_type ? [File.join(@dir, event_type.to_s)] : Dir[File.join(@dir, "*")].select { |d| File.directory?(d) }

        dirs.each do |dir|
          Dir[File.join(dir, "*.json")].sort.each do |file|
            entries << JSON.parse(File.read(file))
          rescue JSON::ParserError
            nil
          end
        end

        entries.group_by { |e| e["event_type"] }
      end

      def track_recommendation(recommendation)
        return unless @enabled

        entry = recommendation.to_h.merge(
          recommendation_id: "rec_#{SecureRandom.hex(8)}",
          timestamp: Time.now.utc.iso8601(3),
          status: "open"
        )

        rec_dir = File.join(@dir, "recommendations")
        FileUtils.mkdir_p(rec_dir)

        filename = "#{entry[:timestamp].tr(':', '-')}_#{entry[:recommendation_id]}.json"

        @mutex.synchronize do
          File.write(File.join(rec_dir, filename), JSON.pretty_generate(entry) + "\n")
        end

        entry[:recommendation_id]
      end

      def track_resolution(recommendation_id)
        return unless @enabled

        rec_dir = File.join(@dir, "recommendations")
        return unless File.directory?(rec_dir)

        Dir[File.join(rec_dir, "*.json")].each do |file|
          entry = JSON.parse(File.read(file))
          next unless entry["recommendation_id"] == recommendation_id

          entry["status"] = "resolved"
          entry["resolved_at"] = Time.now.utc.iso8601(3)

          @mutex.synchronize do
            File.write(file, JSON.pretty_generate(entry) + "\n")
          end
          return true
        rescue JSON::ParserError
          nil
        end

        false
      end

      def read_recommendations(status: nil)
        rec_dir = File.join(@dir, "recommendations")
        return [] unless File.directory?(rec_dir)

        entries = Dir[File.join(rec_dir, "*.json")].sort.map do |file|
          JSON.parse(File.read(file))
        rescue JSON::ParserError
          nil
        end.compact

        return entries unless status
        entries.select { |e| e["status"] == status }
      end

      def increment_session_count!
        return unless @enabled

        FileUtils.mkdir_p(@dir)
        path = File.join(@dir, "session_counter.json")

        @mutex.synchronize do
          count = File.exist?(path) ? JSON.parse(File.read(path))["count"] : 0
          File.write(path, JSON.pretty_generate({ count: count + 1, updated_at: Time.now.utc.iso8601(3) }) + "\n")
        end
      end

      def session_count
        return 0 unless @enabled

        path = File.join(@dir, "session_counter.json")
        return 0 unless File.exist?(path)

        JSON.parse(File.read(path))["count"]
      rescue JSON::ParserError
        0
      end

      def reset_session_count!
        return unless @enabled

        path = File.join(@dir, "session_counter.json")
        @mutex.synchronize do
          File.write(path, JSON.pretty_generate({ count: 0, updated_at: Time.now.utc.iso8601(3) }) + "\n")
        end
      end

      def clear!
        return unless File.directory?(@dir)

        Dir[File.join(@dir, "**/*.json")].each { |f| File.delete(f) }
      end
    end
  end
end
