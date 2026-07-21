# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require "ask/skills"
require "ask-llm-providers"
require "ask-tools"

module Ask
  module Agent
    class Error < StandardError; end
    class LoopDetected < Error; end
    class MaxTurnsExceeded < Error; end
    class Aborted < Error; end
    class ToolExecutionError < Error; end
    class CompactionFailed < Error; end
    class SessionNotPersisted < Error; end

    class UnknownAgent < Error; end

    module Extensions
      autoload :PermissionGate, "ask/agent/extensions/permission_gate"
      autoload :RateLimiter, "ask/agent/extensions/rate_limiter"
      autoload :AuditLog, "ask/agent/extensions/audit_log"
    end

    module Middleware
      autoload :Base, "ask/agent/middleware/base"
      autoload :Pipeline, "ask/agent/middleware/pipeline"
      autoload :RetryOnFailure, "ask/agent/middleware/retry_on_failure"
      autoload :LogCalls, "ask/agent/middleware/log_calls"
      autoload :DefaultSettings, "ask/agent/middleware/default_settings"
    end

    module StreamTransforms
      autoload :Base, "ask/agent/stream_transforms/base"
      autoload :Pipeline, "ask/agent/stream_transforms/pipeline"
      autoload :ThinkingSeparator, "ask/agent/stream_transforms/thinking_separator"
      autoload :TextBuffer, "ask/agent/stream_transforms/text_buffer"
      autoload :ExtractJson, "ask/agent/stream_transforms/extract_json"
    end

    @registry = {}
    @discovered = false
    @shared_tools = {}

    class << self
      # All discovered agent definitions, keyed by name.
      # Triggers discovery on first call.
      # @return [Hash<String, Array(Class, String)>] name → [Definition subclass, directory path]
      def definitions
        discover!
        @registry.dup
      end

      # Create a new agent session from a named definition.
      #
      # @param name [String, Symbol] the agent name (directory name under +agents/+)
      # @return [Session] a configured, ready-to-run session
      def new(name)
        discover!
        entry = @registry[name.to_s]
        raise UnknownAgent, "Unknown agent: #{name.inspect}. Searched agents/ and app/agents/." unless entry

        klass, dir = entry
        build_session_from_definition(klass, dir)
      end

      # Force re-discovery of agent definitions.
      def rediscover!
        @discovered = false
        @registry = {}
        discover!
      end

      # Paths where agent directories are discovered.
      def default_agent_paths
        [
          File.join(Dir.pwd, "agents"),
          File.join(Dir.pwd, "app", "agents")
        ]
      end

      # Resolve a tool symbol to a tool class.
      # Checks the shared tools directory first, then falls back to the
      # global tool registry from ask-tools.
      def resolve_tool_symbol(symbol)
        @shared_tools[symbol.to_s] || begin
          Ask::Tools[symbol.to_s]
        rescue StandardError
          nil
        end
      end

      private

      def discover!
        return if @discovered
        @discovered = true

        paths = default_agent_paths
        paths.each do |base|
          next unless File.directory?(base)

          # Discover shared tools
          discover_shared_tools(base)

          # Discover agent directories
          Dir["#{base}/*/agent.rb"].sort.each do |file|
            dir = File.dirname(file)
            name = File.basename(dir)
            next if name == "shared"

            require file

            # Find the Definition subclass whose directory matches
            match = Definition.subclasses.find { |klass|
              klass._config[:dir] == dir
            }

            if match
              @registry[name] = [match, dir]
            end
          end
        end
      end

      def discover_shared_tools(base)
        shared_tools_dir = File.join(base, "shared", "tools")
        return unless File.directory?(shared_tools_dir)

        Dir["#{shared_tools_dir}/*.rb"].sort.each do |file|
          tool_name = File.basename(file, ".rb")
          require file

          # Find the Ask::Tool subclass that was just loaded
          # (it registered itself in Ask::Tools on require)
          @shared_tools[tool_name] = tool_name
        end
      end

      def build_session_from_definition(klass, dir)
        config = klass._config
        session_opts = { model: config[:model] || Ask::Agent.configuration.default_model }

        # Pass optional config
        session_opts[:provider] = config[:provider] if config[:provider]
        session_opts[:max_turns] = config[:max_turns] if config[:max_turns]
        session_opts[:parallel_tools] = config[:parallel_tools] if config.key?(:parallel_tools)

        # Pass arbitrary session options
        if config[:options]
          session_opts.merge!(config[:options])
        end

        # Pass agent directory for per-agent skills discovery
        session_opts[:agent_dir] = dir

        # Resolve tools
        tools = resolve_definition_tools(config[:tools], dir)
        session_opts[:tools] = tools if tools.any?

        # Load instructions
        prompt = klass.instructions_content
        session_opts[:system_prompt] = prompt if prompt

        # Apply schedule if defined
        schedule = config[:schedule]
        if schedule
          task_block = ->(sess = nil) {
            agent = build_session_from_definition(klass, dir)
            agent.run("")
          }
          Ask::Agent.configuration.scheduler.every(schedule, name: File.basename(dir), &task_block)
        end

        Session.new(**session_opts)
      end

      def resolve_definition_tools(tool_specs, dir)
        tools = []
        tool_specs.each do |spec|
          case spec
          when Symbol, String
            name = spec.to_s
            # Try per-agent tools directory
            agent_tool_path = File.join(dir, "tools", "#{name}.rb")
            if File.exist?(agent_tool_path)
              require agent_tool_path
            end

            resolved = resolve_tool_symbol(name)
            if resolved
              tool_class = resolved.is_a?(Class) ? resolved : Ask::Tools[name]
              tools << tool_class if tool_class
            end
          when Class
            tools << spec
          end
        end
        tools
      end
    end

    # Register the global config
    def self.configuration
      @configuration ||= Configuration.new
    end

    def self.configure
      yield configuration
    end

    def self.load_extensions
      Dir[File.expand_path("agent/extensions/*.rb", __dir__)].each { |f| require f }
    rescue Errno::ENOENT
    end
  end
end

require_relative "agent/version"
require_relative "agent/events"
require_relative "agent/chat"
require_relative "agent/telemetry"
require_relative "agent/tool_abort_controller"
require_relative "agent/session"
require_relative "agent/loop"
require_relative "agent/reflector"
require_relative "agent/tool_executor"
require_relative "agent/compactor"
require_relative "agent/hooks"
require_relative "agent/configuration"
require_relative "agent/meta_agent"
require_relative "agent/persistence/base"
require_relative "agent/persistence/in_memory"
require_relative "agent/skills/load_skill_tool"
require_relative "agent/scheduler"
require_relative "agent/definition"
require_relative "agent/cli"

# Test helpers (loaded on demand)
autoload :Test, "ask/agent/test"
