# frozen_string_literal: true

class HealthCheckAgent < Ask::Agent::Definition
  model "gpt-4o"
  tools :bash, :read, :grep
end
