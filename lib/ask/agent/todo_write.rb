# frozen_string_literal: true

require "ask/tools/tool"
require "ask/result"

module Ask
  module Agent
    # Tool that maintains the session's task list ({TodoList}). The model
    # writes and updates todos as it works; every result returns the full
    # list, so one call both mutates and shows state. A TodoUpdated event
    # fires on every change for live rendering.
    #
    # Injected into the session by `Session.new(todos: true)`.
    class TodoWrite < Ask::Tool
      description "Maintain a task list for the current job. " \
                   "Use it to plan multi-step work and update statuses as steps finish. " \
                   "Actions: add (with title), update (with id and status or title), list, clear."

      param :action, type: :string, desc: "add, update, list, or clear", required: true
      param :title, type: :string, desc: "Task title (required for add)", required: false
      param :id, type: :string, desc: "Task id (required for update)", required: false
      param :status, type: :string, desc: "pending, in_progress, completed, or blocked", required: false

      # @param todo_list [Ask::Agent::TodoList] the session's task list
      def initialize(todo_list:)
        @todo_list = todo_list
        super()
      end

      def execute(action:, title: nil, id: nil, status: nil)
        case action
        when "add"
          @todo_list.add(title, status: status)
        when "update"
          @todo_list.update(id, status: status, title: title)
        when "list"
          # no-op — the result carries the full list
        when "clear"
          @todo_list.clear
        else
          return Ask::Result.error(message: "Unknown action #{action.inspect}; valid: add, update, list, clear")
        end

        Ask::Result.ok(data: format_list)
      rescue ArgumentError => e
        Ask::Result.error(message: e.message)
      end

      private

      def format_list
        entries = @todo_list.all
        return "(no todos)" if entries.empty?

        entries.map { |e| "[#{e.status}] #{e.title} (#{e.id})" }.join("\n")
      end
    end
  end
end
