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

    module Extensions
      autoload :PermissionGate, "ask/agent/extensions/permission_gate"
      autoload :RateLimiter, "ask/agent/extensions/rate_limiter"
      autoload :AuditLog, "ask/agent/extensions/audit_log"
    end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield configuration
      end

      def load_extensions
        Dir[File.expand_path("agent/extensions/*.rb", __dir__)].each { |f| require f }
      rescue Errno::ENOENT
      end
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
