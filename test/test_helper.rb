# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ask-tools/lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ask-tools-shell/lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ask-schema/lib", __dir__)

require "ask/version"
require "ask/tools/tool"
require "ask/tools"
require "ask/tools/shell"
require "ask/agent"

require "minitest/autorun"
require "mocha/minitest"
