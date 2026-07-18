# frozen_string_literal: true

module Ask
  module Agent
    module Skills
      # Built-in tool that lets the LLM load a discovered skill's full
      # instructions on demand. Skills are listed by name and description
      # via progressive disclosure — the LLM decides which to load.
      #
      # Usage by the LLM: call load_skill with the skill name.
      class LoadSkillTool < Ask::Tool
        description "Load the full instructions for a skill by name. Use this when a listed skill seems relevant to the current task."

        param :name, type: :string, desc: "Name of the skill to load (e.g., writing-guide)", required: true

        def initialize(registry:)
          @registry = registry
          super()
        end

        def execute(name:)
          skill = @registry&.[](name)
          unless skill
            available = @registry&.names&.join(", ") || "none"
            return Ask::Result.failure("Skill '#{name}' not found. Available skills: #{available}")
          end

          # Return the full skill content so it can be injected into conversation
          content = "## Skill: #{skill.name}\n#{skill.description}\n\n#{skill.instructions}"
          Ask::Result.ok(data: { name: skill.name, content: content })
        end

        def name
          "load_skill"
        end
      end
    end
  end
end
