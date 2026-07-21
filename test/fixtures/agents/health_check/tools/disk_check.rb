# frozen_string_literal: true

class DiskCheck < Ask::Tool
  description "Check disk usage on the server"
  param :path, type: "string", desc: "Path to check", required: false

  def execute(path: "/")
    Ask::Result.ok(data: "Disk usage for #{path}: 45%")
  end
end
