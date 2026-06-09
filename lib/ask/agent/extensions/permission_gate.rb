# frozen_string_literal: true

module Ask
  module Agent
    module Extensions
      class PermissionGate
        DEFAULT_TOOLS = %i[write edit bash destroy].freeze

        def initialize(blocked_tools: DEFAULT_TOOLS, timeout: nil)
          @blocked_tools = Array(blocked_tools).map(&:to_sym)
          @timeout = timeout
          @pending = {}
          @mutex = Mutex.new
        end

        def before_tool_call(tool_call, _context)
          return { action: :proceed } unless @blocked_tools.include?(tool_call.name.to_sym)

          if approved?(tool_call)
            { action: :proceed }
          else
            request_approval(tool_call)
          end
        end

        def approve(tool_call_id)
          @mutex.synchronize do
            entry = @pending[tool_call_id]
            return false unless entry
            entry[:approved] = true
          end
        end

        def pending_approvals
          @mutex.synchronize { @pending.values.reject { |e| e[:approved] } }
        end

        private

        def approved?(tool_call)
          @mutex.synchronize do
            key = tool_call.id
            entry = @pending[key]
            return false unless entry

            if @timeout && (Time.now - entry[:created_at]) > @timeout
              @pending.delete(key)
              return false
            end

            entry[:approved]
          end
        end

        def request_approval(tool_call)
          @mutex.synchronize do
            @pending[tool_call.id] = {
              tool_call: tool_call,
              approved: false,
              created_at: Time.now
            }
          end

          warn "[PermissionGate] Tool '#{tool_call.name}' requires approval. Call approve('#{tool_call.id}') to allow."
          { action: :block, reason: "Tool '#{tool_call.name}' requires approval" }
        end
      end
    end
  end
end
