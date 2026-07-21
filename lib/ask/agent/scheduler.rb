# frozen_string_literal: true

module Ask
  module Agent
    # Schedules recurring agent runs.
    #
    # Configure tasks through {Ask::Agent::Configuration#scheduler}, then
    # start the scheduler loop. Tasks run in background threads managed by
    # +rufus-scheduler+.
    #
    # @example
    #   Ask::Agent.configure do |c|
    #     c.scheduler.every "5 minutes", name: "health-check" do
    #       Ask::Agent::Session.new(model: "gpt-4o").run("Check server health")
    #     end
    #
    #     c.scheduler.cron "0 9 * * 1-5", name: "morning-report" do
    #       Ask::Agent::Session.new(model: "gpt-4o").run("Generate daily report")
    #     end
    #   end
    #
    #   Ask::Agent::Scheduler.start   # background thread loop
    #   Ask::Agent::Scheduler.running? # => true
    #   Ask::Agent::Scheduler.jobs     # => list of rufus jobs
    #   Ask::Agent::Scheduler.stop    # graceful shutdown
    class Scheduler
      @instance = nil
      @mutex = Mutex.new

      class << self
        # @return [Scheduler] the singleton instance
        def instance
          @instance ||= new
        end

        # Start the scheduler background thread.
        # All configured tasks begin running on their schedules.
        # @return [Scheduler] the singleton instance
        def start
          @mutex.synchronize do
            return instance if instance.up?

            instance.start
          end
          instance
        end

        # Gracefully stop the scheduler and wait for running tasks.
        def stop
          @mutex.synchronize do
            instance.stop
            @instance = nil
          end
        end

        # @return [Boolean] whether the scheduler loop is active
        def running?
          instance.up?
        end

        # @return [Array<Rufus::Scheduler::Job>] currently scheduled jobs
        def jobs
          instance.jobs
        end

        # Find a scheduled job by its name.
        # @param name [String] the job name
        # @return [Rufus::Scheduler::Job, nil]
        def job_by_name(name)
          jobs.find { |j| j.name == name }
        end
      end

      def initialize
        @rufus = nil
        @own_mutex = Mutex.new
      end

      # Start the rufus-scheduler loop and register all configured tasks.
      # @return [self]
      def start
        @own_mutex.synchronize do
          return self if @rufus&.up?

          require "rufus-scheduler"

          @rufus = Rufus::Scheduler.new

          config = Ask::Agent.configuration

          # Register tasks that were configured statically
          config.scheduler.each_task do |task|
            schedule_task(task)
          end
        end
        self
      end

      # Stop the scheduler and wait for running jobs to finish.
      def stop
        @own_mutex.synchronize do
          @rufus&.shutdown(:wait)
          @rufus = nil
        end
      end

      # @return [Boolean] true if the rufus scheduler is active
      def up?
        @rufus&.up? || false
      end

      # @return [Array<Rufus::Scheduler::Job>] currently scheduled jobs
      def jobs
        @rufus&.jobs || []
      end

      private

      def schedule_task(task)
        block = task[:block]
        name = task[:name]

        case task[:type]
        when :every
          @rufus.every task[:interval], name: name do
            block&.call
          end
        when :cron
          @rufus.cron task[:cron], name: name do
            block&.call
          end
        else
          raise ArgumentError, "Unknown schedule type: #{task[:type].inspect}"
        end
      end
    end

    # DSL proxy used inside {Ask::Agent::Configuration#scheduler}.
    # Collects task definitions that the {Scheduler} registers on start.
    class SchedulerConfig
      def initialize(config)
        @config = config
        @tasks = []
      end

      # Schedule a block to run on a recurring interval.
      #
      # @param interval [String] human-readable interval (e.g. "5 minutes", "1 hour")
      # @param name [String, nil] optional job name for identification
      # @yield block to execute on each tick
      def every(interval, name: nil, &block)
        @tasks << { type: :every, interval: interval, name: name, block: block }
        self
      end

      # Schedule a block to run on a cron schedule.
      #
      # @param cron_expression [String] standard cron syntax (e.g. "0 9 * * 1-5")
      # @param name [String, nil] optional job name for identification
      # @yield block to execute at each scheduled time
      def cron(cron_expression, name: nil, &block)
        @tasks << { type: :cron, cron: cron_expression, name: name, block: block }
        self
      end

      # Yield each configured task definition.
      def each_task(&block)
        @tasks.each(&block)
      end
    end
  end
end
