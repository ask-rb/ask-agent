# frozen_string_literal: true

module Ask
  module Agent
    module CLI
      module_function

      def run(argv)
        case argv.first
        when "run"
          cmd_run(argv[1..])
        when "list"
          cmd_list
        when "schedule"
          cmd_schedule
        when "new"
          cmd_new(argv[1..])
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

      def cmd_help
        puts <<~HELP
          Usage: askr <command> [options]

          Commands:
            run <name> [prompt]    Run an agent with an optional prompt
            list                   List all discovered agents
            schedule               Start the scheduler for all scheduled agents
            new <name>             Scaffold a new agent directory
            help                   Show this help

          Examples:
            askr list
            askr run health_check
            askr run health_check "Check the server status"
            askr new deploy_bot
            askr schedule

          Agent directories are discovered from:
            ./agents/<name>/agent.rb
            ./app/agents/<name>/agent.rb
        HELP
      end

      def camelize(str)
        str.split(/[_-]/).map(&:capitalize).join
      end
    end
  end
end
