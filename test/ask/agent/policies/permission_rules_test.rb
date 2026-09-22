# frozen_string_literal: true

require_relative "../../../test_helper"

module Ask
  module Permissions
    # Contract tests for Ask::Permissions::PermissionRules (from
    # ask-permissions), the ruleset ask-agent's approval option accepts.
    class PermissionRulesTest < Minitest::Test
      def rules(&block)
        PermissionRules.new(&block)
      end

      # -------------------------------------------------------------
      # Tool patterns
      # -------------------------------------------------------------

      def test_string_tool_pattern_matches_exact_name
        r = rules { allow "git_pull" }
        assert_equal :allow, r.classify("git_pull")
        assert_nil r.classify("git_push")
      end

      def test_symbol_tool_pattern_matches_name
        r = rules { allow :read }
        assert_equal :allow, r.classify("read")
        assert_nil r.classify("reader")
      end

      def test_regexp_tool_pattern_matches_name
        r = rules { allow(/^git_/) }
        assert_equal :allow, r.classify("git_pull")
        assert_equal :allow, r.classify("git_push")
        assert_nil r.classify("github")
      end

      def test_all_matches_every_tool
        r = rules { ask :all }
        assert_equal :ask, r.classify("bash")
        assert_equal :ask, r.classify("write")
      end

      # -------------------------------------------------------------
      # Argument patterns
      # -------------------------------------------------------------

      def test_nil_argument_pattern_matches_anything
        r = rules { ask :bash }
        assert_equal :ask, r.classify("bash", "ls -la")
        assert_equal :ask, r.classify("bash", { "command" => "whoami" })
      end

      def test_regexp_argument_pattern
        r = rules { allow :bash, /^git (pull|push)/ }
        assert_equal :allow, r.classify("bash", "git pull origin main")
        assert_nil r.classify("bash", "rm -rf /")
      end

      def test_string_argument_pattern_is_substring_match
        r = rules { deny :write, ".env" }
        assert_equal :deny, r.classify("write", %q({"path": "config/.env.local"}))
        assert_nil r.classify("write", %q({"path": "README.md"}))
      end

      def test_hash_arguments_are_json_normalized_for_matching
        r = rules { allow :bash, /git pull/ }
        assert_equal :allow, r.classify("bash", { "command" => "git pull origin main" })
      end

      # -------------------------------------------------------------
      # Ordering
      # -------------------------------------------------------------

      def test_first_matching_rule_wins
        r = rules do
          ask  :bash, /^rm/
          allow :bash, /^rm -rf/
        end
        assert_equal :ask, r.classify("bash", "rm -rf /tmp/x")
      end

      def test_no_match_returns_nil
        r = rules { deny :write, ".env" }
        assert_nil r.classify("bash", "ls")
      end

      # -------------------------------------------------------------
      # Dangerous-rule guard
      # -------------------------------------------------------------

      def test_unrestricted_allow_on_bash_is_downgraded_to_ask
        r = rules { allow :bash }
        assert_equal :ask, r.classify("bash", "anything")
        assert_equal :ask, r.classify("bash")
      end

      def test_unrestricted_allow_on_code_and_repl_is_downgraded
        assert_equal :ask, rules { allow :code }.classify("code", "puts 1")
        assert_equal :ask, rules { allow :repl }.classify("repl")
      end

      def test_unrestricted_allow_on_all_is_downgraded
        r = rules { allow :all }
        assert_equal :ask, r.classify("bash")
        assert_equal :ask, r.classify("write")
      end

      def test_restricted_allow_on_bash_is_not_dangerous
        r = rules { allow :bash, /^git status/ }
        assert_equal :allow, r.classify("bash", "git status")
      end

      def test_non_code_tools_are_not_dangerous
        r = rules { allow :read }
        assert_equal :allow, r.classify("read", "/etc/hosts")
      end

      def test_auto_allow_dangerous_keeps_unrestricted_allows
        r = PermissionRules.new(auto_allow_dangerous: true) { allow :bash }
        assert_equal :allow, r.classify("bash", "anything")
      end

      def test_dangerous_rules_introspection
        r = rules do
          allow :bash
          allow :bash, /^git status/
        end
        dangerous = r.dangerous_rules
        assert_equal 1, dangerous.size
        assert_equal :allow, dangerous.first.decision
      end
    end
  end
end
