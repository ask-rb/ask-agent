# frozen_string_literal: true

class RailsBotAgent < Ask::Agent::Definition
  model "gpt-4o"
  tools :read, :grep
  schedule "every 1 hour"
end
