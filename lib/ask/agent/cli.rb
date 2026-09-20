# frozen_string_literal: true

require "fileutils"

module Ask
  module Agent
    module CLI
      module_function

      def run(argv)
        auto_sync_skills
        case argv.first
        when "run"
          cmd_run(argv[1..])
        when "list"
          cmd_list
        when "schedule"
          cmd_schedule
        when "new"
          cmd_new(argv[1..])
        when "skills"
          cmd_skills(argv[1..])
        when "help", "--help", "-h", nil
          cmd_help
        else
          puts "Unknown command: #{argv.first}"
          cmd_help
          exit 1
        end
      end

      def cmd_run(args)
        name = args.first
        unless name
          puts "Usage: askr run <agent-name> [prompt]"
          exit 1
        end

        prompt = args[1..]&.join(" ") || ""

        begin
          agent = Ask::Agent.new(name)

          if prompt.empty?
            puts "Starting interactive session with #{name}..."
            puts "Type your message (Ctrl+D to exit):"
            while (input = $stdin.gets)
              response = agent.run(input.strip)
              puts response
              puts "---"
            end
          else
            response = agent.run(prompt)
            puts response
          end
        rescue Ask::UnknownAgent => e
          puts e.message
          exit 1
        rescue => e
          puts "Error: #{e.message}"
          exit 1
        end
      end

      def cmd_list
        defs = Ask::Agent.definitions
        if defs.empty?
          puts "No agents found. Define one in agents/<name>/agent.rb or app/agents/<name>/agent.rb."
          return
        end

        puts "Discovered agents:"
        defs.each do |name, (klass, dir)|
          config = klass._config
          model = config[:model] || "(default)"
          schedule = config[:schedule]
          has_instructions = klass.instructions_path ? "yes" : "no"
          tools = config[:tools].any? ? config[:tools].join(", ") : "(none)"

          puts "  #{name}"
          puts "    model:       #{model}"
          puts "    tools:       #{tools}"
          puts "    instructions: #{has_instructions}"
          puts "    schedule:    #{schedule || "(none)"}" if schedule
          puts "    directory:   #{dir}"
        end
      end

      def cmd_schedule
        defs = Ask::Agent.definitions
        scheduled = defs.select { |_name, (klass, _dir)| klass._config[:schedule] }

        if scheduled.empty?
          puts "No scheduled agents found."
          return
        end

        scheduled.each do |name, (klass, _dir)|
          schedule = klass._config[:schedule]
          puts "Scheduling #{name} (#{schedule})..."
          Ask::Agent.new(name)
        end

        Ask::Agent::Scheduler.start
        puts "Scheduler started. Running #{scheduled.length} task(s)."
        puts "Press Ctrl+C to stop."

        loop do
          sleep 1
        rescue Interrupt
          puts "\nShutting down..."
          Ask::Agent::Scheduler.stop
          exit 0
        end
      end

      def cmd_new(args)
        name = args.first
        unless name
          puts "Usage: askr new <agent-name>"
          exit 1
        end

        dir = File.join(Dir.pwd, "agents", name)
        if File.exist?(dir)
          puts "Directory already exists: #{dir}"
          exit 1
        end

        FileUtils.mkdir_p(dir)

        File.write(File.join(dir, "agent.rb"), <<~RUBY)
          # frozen_string_literal: true

          class #{camelize(name)} < Ask::Agent::Definition
            model "gpt-4o"
            tools :bash, :read, :grep
          end
        RUBY

        File.write(File.join(dir, "instructions.md"), <<~MARKDOWN)
          # #{name}

          You are a helpful AI agent. Your goal is to assist the user with their tasks.

          ## Guidelines

          - Be concise and accurate
          - Use the available tools when needed
          - Ask for clarification if instructions are ambiguous
        MARKDOWN

        puts "Created agent: #{dir}"
        puts ""
        puts "Run it:  askr run #{name}"
      end

      def cmd_skills(args)
        sub = args.first

        case sub
        when "list"
          cmd_skills_list
        when "show"
          cmd_skills_show(args[1])
        when "search"
          cmd_skills_search(args[1])
        when "install"
          cmd_skills_install(args[1..])
        when "uninstall"
          cmd_skills_uninstall(args[1..])
        else
          puts "Usage: askr skills <list|show|search|install|uninstall>"
          puts ""
          puts "Commands:"
          puts "  list                  List all discovered skills"
          puts "  show <name>           Show skill details and sibling files"
          puts "  search <query>        Search skills by name, description, or tags"
          puts "  install [--global]    Install ask-agent skill to ~/.agents/skills/ (default)"
          puts "  install --local       Install to .agents/skills/ in current directory"
          puts "  uninstall [--global]  Remove installed skill"
          puts "  uninstall --local     Remove locally installed skill"
        end
      end

      def cmd_skills_list
        require "ask/skills"
        registry = Ask::Skills.discover

        if registry.names.empty?
          puts "No skills found."
          return
        end

        puts "Discovered skills:"
        puts ""
        registry.names.sort.each do |name|
          skill = registry[name]
          puts "  #{skill.name}"
          puts "    description: #{skill.description}"
          puts "    tags:        #{skill.tags.join(", ")}" if skill.tags.any?
          siblings = skill.siblings
          if siblings.any?
            summaries = siblings.map { |cat, files| "#{files.length} #{cat}" }.join(", ")
            puts "    files:       #{summaries}"
          end
        end
      end

      def cmd_skills_show(name)
        unless name
          puts "Usage: askr skills show <name>"
          exit 1
        end

        require "ask/skills"
        registry = Ask::Skills.discover
        skill = registry[name]

        unless skill
          puts "Skill not found: #{name}"
          exit 1
        end

        puts "Name:        #{skill.name}"
        puts "Description: #{skill.description}"
        puts "Source:      #{skill.source}"
        puts "Tags:        #{skill.tags.join(", ")}" if skill.tags.any?

        if skill.siblings.any?
          puts ""
          puts "Sibling files:"
          skill.siblings.each do |category, files|
            puts "  #{category}/"
            files.each { |f| puts "    #{f}" }
          end
        end

        puts ""
        puts "--- Instructions ---"
        puts skill.instructions
      end

      def cmd_skills_search(query)
        unless query
          puts "Usage: askr skills search <query>"
          exit 1
        end

        require "ask/skills"
        registry = Ask::Skills.discover
        query_down = query.downcase

        matches = registry.names.select do |name|
          skill = registry[name]
          name.downcase.include?(query_down) ||
            skill.description.downcase.include?(query_down) ||
            skill.tags.any? { |t| t.downcase.include?(query_down) }
        end

        if matches.empty?
          puts "No skills matching \"#{query}\"."
          return
        end

        puts "Skills matching \"#{query}\":"
        matches.sort.each do |name|
          skill = registry[name]
          puts "  #{skill.name} — #{skill.description}"
        end
      end

      SKILL_NAME = "agent.build_agents"
      SKILL_SOURCE_REL = "ask/skills/agent.build_agents/SKILL.md"

      # Keep installed copies in sync after `gem update ask-agent`.
      # Only touches copies created by `askr skills install` (identified
      # by the marker file). Failures are swallowed.
      def auto_sync_skills
        skill_candidates.each do |dest|
          next unless File.file?(dest)
          next unless skill_managed?(dest)
          skill_sync_copy(dest)
        end
      rescue StandardError
        nil
      end

      def cmd_skills_install(args)
        opts = parse_skill_flags(args)
        dest = skill_target_dir(opts)
        source = skill_bundled_path
        unless File.file?(source)
          puts "Bundled skill not found at #{source} — reinstall ask-agent"
          exit 1
        end

        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(source, dest)
        skill_stamp(dest)
        puts "Installed #{SKILL_NAME} skill -> #{dest}"
        0
      end

      def cmd_skills_uninstall(args)
        opts = parse_skill_flags(args)
        dest = skill_target_dir(opts)
        if File.file?(dest)
          FileUtils.rm(dest)
          FileUtils.rm_f(skill_managed_marker(dest))
          puts "Removed #{dest}"
        else
          puts "Not installed at #{dest} (nothing to do)"
        end
        0
      end

      def skill_target_dir(opts)
        if opts[:dir]
          File.expand_path(File.join(opts[:dir], SKILL_NAME, "SKILL.md"))
        elsif opts[:local]
          File.join(Dir.pwd, ".agents", "skills", SKILL_NAME, "SKILL.md")
        else
          File.expand_path("~/.agents/skills/#{SKILL_NAME}/SKILL.md")
        end
      end

      def skill_bundled_path
        File.expand_path("../../#{SKILL_SOURCE_REL}", __dir__)
      end

      def skill_managed_marker(dest)
        File.join(File.dirname(dest), ".ask-agent-managed")
      end

      def skill_managed?(dest)
        File.file?(skill_managed_marker(dest))
      end

      def skill_stamp(dest)
        File.write(skill_managed_marker(dest), "managed by askr skills install; safe to auto-update\n")
      rescue StandardError
        nil
      end

      def skill_candidates
        [
          File.expand_path("~/.agents/skills/#{SKILL_NAME}/SKILL.md"),
          File.join(Dir.pwd, ".agents", "skills", SKILL_NAME, "SKILL.md")
        ]
      end

      def skill_sync_copy(dest)
        source = skill_bundled_path
        FileUtils.cp(source, dest) if File.exist?(source) && File.read(source) != File.read(dest)
        skill_stamp(dest)
      rescue StandardError
        nil
      end

      def parse_skill_flags(args)
        opts = {}
        args.each do |arg|
          case arg
          when "--local" then opts[:local] = true
          when "--global" then nil # default
          when "--dir"
            # next arg is the path; handled by shifting in the caller
          when /\A--dir=(.+)/ then opts[:dir] = $1
          when "--help", "-h"
            puts "Usage: askr skills install [--global] [--local] [--dir <path>]"
            puts "       askr skills uninstall [--global] [--local] [--dir <path>]"
            exit 0
          end
        end
        opts
      end

      def cmd_help
        puts <<~HELP
          Usage: askr <command> [options]

          Commands:
            run <name> [prompt]    Run an agent with an optional prompt
            list                   List all discovered agents
            schedule               Start the scheduler for all scheduled agents
            new <name>             Scaffold a new agent directory
            skills list            List all discovered skills
            skills show <name>     Show skill details and instructions
            skills search <query>  Search skills by name, description, or tags
            help                   Show this help

          Examples:
            askr list
            askr run health_check
            askr schedule
            askr skills list
            askr skills show rails_debug
            askr skills search deploy

          Agent directories are discovered from:
            ./agents/<name>/agent.rb
            ./app/agents/<name>/agent.rb

          Skills are discovered from:
            ./agents/shared/skills/<name>/SKILL.md
            ./app/agents/shared/skills/<name>/SKILL.md
        HELP
      end

      def camelize(str)
        str.split(/[_-]/).map(&:capitalize).join
      end
    end
  end
end
