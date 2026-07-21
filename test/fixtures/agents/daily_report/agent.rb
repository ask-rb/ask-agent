# frozen_string_literal: true

class DailyReportAgent < Ask::Agent::Definition
  model "claude-sonnet-4"
  tools :bash, :grep
  schedule "0 9 * * 1-5"
end
