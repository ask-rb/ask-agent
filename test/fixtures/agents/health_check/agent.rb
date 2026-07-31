# frozen_string_literal: true

module HealthCheck
  class Agent < Ask::Agent::Definition
    model "gpt-4o"
    tools :bash, :read, :grep
  end
end
