# frozen_string_literal: true

# Legacy alias — PermissionGate has been renamed to Permissions.
# This file will be removed in the next major version.
require_relative "permissions"

module Ask
  module Agent
    module Extensions
      PermissionGate = Permissions
    end
  end
end
