# frozen_string_literal: true

class Notify < Ask::Tool
  description "Send a notification"
  param :message, type: "string", desc: "Message to send", required: true

  unless instance_methods(false).include?(:execute)
    def execute(message:)
      Ask::Result.ok(data: "Sent: #{message}")
    end
  end
end
