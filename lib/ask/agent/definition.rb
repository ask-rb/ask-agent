# frozen_string_literal: true

module Ask
  module Agent
    # Declarative agent definition backed by a file convention.
    #
    # Subclass +Definition+ inside an +agent.rb+ file under +agents/<name>/+
    # or +app/agents/<name>/+. The directory name becomes the agent name.
    # Instructions load automatically from a sibling +instructions.md+.
    #
    # @example +agents/health_check/agent.rb+
    #   class HealthCheckAgent < Ask::Agent::Definition
    #     model "gpt-4o"
    #     tools :bash, :read, :grep
    #     schedule "every 5 minutes"
    #   end
    #
    #   # agents/health_check/instructions.md is auto-loaded
    #
    # @example Using from Ruby
    #   agent = Ask::Agent.new("health_check")
    #   agent.run("Check server health")
    class Definition
      @subclasses = []

      class << self
        # All subclasses that have been loaded, in definition order.
        attr_reader :subclasses

        def inherited(subclass)
          @subclasses << subclass
          subclass.instance_variable_set(:@_config, { tools: [] })

          # Auto-detect the directory from the file where this class is defined
          # caller(1) is the file containing the `class ... < Definition` line
          path = caller(1)&.first&.sub(/:.*/, "")  # strip line number
          if path && File.basename(path) == "agent.rb"
            subclass._config[:dir] = File.dirname(path)
          end

          super
        end

        # @return [Hash] the raw config hash for this definition
        def _config
          @_config ||= { tools: [] }
        end

        # Set or get the model identifier.
        def model(value = :__no_value__)
          if value == :__no_value__
            _config[:model]
          else
            _config[:model] = value
          end
        end

        # Set or get the provider override.
        def provider(value = :__no_value__)
          if value == :__no_value__
            _config[:provider]
          else
            _config[:provider] = value
          end
        end

        # Set or get max turns for the session.
        def max_turns(value = :__no_value__)
          if value == :__no_value__
            _config[:max_turns]
          else
            _config[:max_turns] = value
          end
        end

        # Set or get parallel tool execution flag.
        def parallel_tools(value = :__no_value__)
          if value == :__no_value__
            _config.key?(:parallel_tools) ? _config[:parallel_tools] : true
          else
            _config[:parallel_tools] = value
          end
        end

        # Set an arbitrary Session option. Accepts any key that
        # Ask::Agent::Session.new understands.
        #
        #   option :temperature, 0.7
        #   option :reflector, true
        #   option :telemetry, false
        def option(key, value = :__no_value__)
          if value == :__no_value__
            _config[:options] ||= {}
            _config[:options][key]
          else
            _config[:options] ||= {}
            _config[:options][key] = value
          end
        end

        # Set tool symbols or classes.
        def tools(*values)
          if values.any?
            _config[:tools] = values
          else
            _config[:tools]
          end
        end

        # Set a cron or interval schedule for recurring runs.
        def schedule(value = :__no_value__)
          if value == :__no_value__
            _config[:schedule]
          else
            _config[:schedule] = value
          end
        end

        # Path to instructions.md relative to this definition's directory.
        # Returns nil if no instructions file exists.
        def instructions_path
          dir = _config[:dir]
          return nil unless dir

          path = File.join(dir, "instructions.md")
          File.exist?(path) ? path : nil
        end

        # Contents of the instructions.md file, or nil.
        def instructions_content
          path = instructions_path
          path ? File.read(path) : nil
        end
      end
    end
  end
end
