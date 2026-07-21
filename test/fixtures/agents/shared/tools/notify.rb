# frozen_string_literal: true

class Notify < Ask::Tool
  description "Send a notification"
  param :message, type: "string", desc: "Message to send", required: true

  def execute(message:)
    Ask::Result.ok(data: "Sent: #{message}")
  end
end
