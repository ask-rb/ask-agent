# frozen_string_literal: true

require "set"
require "json"

module Ask
  module Agent
    class MetaAgent
      Result = Data.define(:issue, :file, :line, :confidence, :suggestion, :evidence, :meta_pr, :recommendation_id, :suggested_code)

      def initialize(telemetry: nil, model: nil, **chat_options)
        @telemetry = telemetry || Telemetry.new
        @model = model || Ask::Agent.configuration.default_model
        @chat_options = chat_options
        @agent_source = nil
      end

      def analyze(error_threshold: 3, loop_threshold: 2, max_turns_threshold: 2)
        load_source
        telemetry_data = @telemetry.read
        resolved_ids = resolved_recommendation_ids
        recommendations = @telemetry.read_recommendations(status: "open")

        unless has_data?(telemetry_data, error_threshold, loop_threshold, max_turns_threshold)
          return []
        end

        results = call_llm_for_analysis(telemetry_data, recommendations, resolved_ids)
        return [] if results.empty?

        results.each do |r|
          r[:recommendation_id] = @telemetry.track_recommendation(build_result(r))
        end

        results.map { |r| build_result(r) }
      end

      def generate_report(results = nil)
        results ||= analyze
        return "No improvement opportunities found." if results.empty?

        lines = []
        lines << "# Agent Self-Improvement Report"
        lines << "*Generated: #{Time.now.utc.iso8601}*"
        lines << ""

        results.each_with_index do |result, i|
          lines << "## #{i + 1}. #{result.issue}"
          lines << ""
          lines << "| | |"
          lines << "|---|---|"
          lines << "| **File** | `#{result.file}:#{result.line}` |"
          lines << "| **Confidence** | #{result.confidence} |"
          lines << "| **Recommendation ID** | `#{result.recommendation_id}` |"
          lines << ""
          if result.suggested_code
            lines << "### Suggested Code"
            lines << ""
            lines << "```ruby"
            lines << result.suggested_code
            lines << "```"
          end
          lines << "---"
        end

        lines.join("\n")
      end

      def track_resolution(recommendation_id)
        return false unless recommendation_id
        @telemetry.track_resolution(recommendation_id)
      end

      def auto_resolve!
        load_source
        count = 0

        @telemetry.read_recommendations(status: "open").each do |rec|
          source = @agent_source[rec["file"]]
          next unless source && rec["suggested_code"]
          if source.include?(rec["suggested_code"].strip)
            @telemetry.track_resolution(rec["recommendation_id"])
            count += 1
          end
        end
        count
      end

      private

      def has_data?(telemetry_data, error_threshold, loop_threshold, max_turns_threshold)
        telemetry_data["tool_error"]&.size.to_i >= error_threshold ||
          telemetry_data["loop_detected"]&.size.to_i >= loop_threshold ||
          telemetry_data["max_turns_exceeded"]&.size.to_i >= max_turns_threshold
      end

      def resolved_recommendation_ids
        @telemetry.read_recommendations(status: "resolved").map { |r| r["recommendation_id"] }
      end

      def call_llm_for_analysis(telemetry_data, existing_recommendations, resolved_ids)
        prompt = build_analysis_prompt(telemetry_data, existing_recommendations, resolved_ids)
        chat = Ask::Agent::Chat.new(model: @model, **@chat_options)
        response = chat.ask(prompt)
        parse_llm_response(response.content.to_s)
      rescue => e
        warn "[MetaAgent] LLM analysis failed: #{e.class}: #{e.message}"
        []
      end

      def build_analysis_prompt(telemetry_data, existing_recommendations, resolved_ids)
        parts = []
        parts << "You are analyzing telemetry from the Agent runtime."
        parts << "Detect patterns in errors and suggest specific code improvements."
        parts << ""

        tool_errors = telemetry_data["tool_error"] || []
        loop_events = telemetry_data["loop_detected"] || []
        max_turn_events = telemetry_data["max_turns_exceeded"] || []

        parts << "=== Telemetry Summary ==="
        parts << "Tool errors: #{tool_errors.size} total"
        unless tool_errors.empty?
          by_error = tool_errors.group_by { |e| [e.dig("details", "tool_name"), e.dig("details", "error_class")] }
          by_error.each do |(tool_name, error_class), entries|
            parts << "  - `#{tool_name}` raised `#{error_class}` (#{entries.size}x)"
          end
        end
        parts << "Loop detections: #{loop_events.size} total"
        parts << "Max turns exceeded: #{max_turn_events.size} total"
        parts << ""
        parts << "=== Instructions ==="
        parts << 'Respond with a JSON array only: [{"issue": "...", "confidence": "high", "file": "...", "line": 0, "suggestion": "...", "suggested_code": ""}]'
        parts << 'If no issues, respond with []'

        parts.join("\n")
      end

      def parse_llm_response(text)
        text = text.strip
        text = text[/\[.*\]/m] || text
        JSON.parse(text)
      rescue JSON::ParserError
        []
      end

      def build_result(r)
        Result.new(
          issue: r[:issue] || r["issue"],
          file: r[:file] || r["file"],
          line: (r[:line] || r["line"]).to_i,
          confidence: r[:confidence] || r["confidence"],
          suggestion: r[:suggestion] || r["suggestion"],
          evidence: r[:evidence] || r["evidence"] || [],
          meta_pr: r[:meta_pr] || r["meta_pr"],
          recommendation_id: r[:recommendation_id] || r["recommendation_id"],
          suggested_code: r[:suggested_code] || r["suggested_code"]
        )
      end

      def load_source
        return @agent_source if @agent_source
        source = {}
        Dir[File.expand_path("../**/*.rb", __dir__)].each do |file|
          rel = file.sub("#{File.expand_path("../..", __dir__)}/", "")
          source[rel] = File.read(file)
        end
        @agent_source = source
      end
    end
  end
end
