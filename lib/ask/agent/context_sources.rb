# frozen_string_literal: true

module Ask
  module Agent
    module ContextSources
      # The agent's core instructions (system prompt / instructions.md).
      class Instructions < Ask::Agent::ContextSource
        key "core/instructions"

        def initialize(content)
          @content = content.to_s
        end

        def load
          @content
        end

        def baseline(content)
          content
        end
      end

      # The "## Available Skills" listing from the skills registry.
      # Only renders when the registry has skills to list.
      class SkillsList < Ask::Agent::ContextSource
        key "core/skills"

        def initialize(registry)
          @registry = registry
        end

        def load
          @registry&.format_for_prompt.to_s
        end

        def baseline(listing)
          listing.empty? ? nil : listing
        end

        def update(prev, curr)
          return nil if prev == curr
          return "Skills have been updated:\n#{curr}"
        end
      end

      # Full instructions for always-active skills (those with +always: true+).
      class AlwaysActiveSkills < Ask::Agent::ContextSource
        key "core/skills.always_active"

        def initialize(registry)
          @registry = registry
        end

        def load
          return "" unless @registry

          @registry.always_active_skills.map { |s|
            "## Skill: #{s.name}\n#{s.description}\n\n#{s.instructions}"
          }.join("\n\n")
        end

        def baseline(instructions)
          instructions.empty? ? nil : instructions
        end
      end

      # Today's date in ISO 8601 format.
      class Date < Ask::Agent::ContextSource
        key "core/date"

        def load
          ::Date.today.iso8601
        end

        def baseline(date)
          "Today's date is #{date}."
        end

        def update(prev, curr)
          "I previously said the date was #{prev}, but it is now #{curr}."
        end
      end
    end
  end
end
