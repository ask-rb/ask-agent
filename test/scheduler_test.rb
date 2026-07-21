# frozen_string_literal: true

require_relative "test_helper"

class SchedulerTest < Minitest::Test
  def setup
    Ask::ModelCatalog.reset_instance!
    Ask::ModelCatalog.instance.register(Ask::ModelInfo.new(id: "gpt-4o", provider: "openai"))
    @original_tasks = Ask::Agent.configuration.scheduler.each_task.to_a.dup
  end

  def teardown
    Ask::Agent::Scheduler.stop
    # Reset scheduler config
    Ask::Agent.configuration.instance_variable_set(:@scheduler_config, Ask::Agent::SchedulerConfig.new(Ask::Agent.configuration))
  end

  def test_scheduler_config_dsl_every
    task = nil
    Ask::Agent.configure do |c|
      c.scheduler.every "5 minutes", name: "test-task" do
        task = :ran
      end
    end

    tasks = []
    Ask::Agent.configuration.scheduler.each_task { |t| tasks << t }
    assert_equal 1, tasks.length
    assert_equal :every, tasks[0][:type]
    assert_equal "5 minutes", tasks[0][:interval]
    assert_equal "test-task", tasks[0][:name]
    refute_nil tasks[0][:block]
  end

  def test_scheduler_config_dsl_cron
    Ask::Agent.configure do |c|
      c.scheduler.cron "0 9 * * 1-5", name: "weekday-task"
    end

    tasks = []
    Ask::Agent.configuration.scheduler.each_task { |t| tasks << t }
    assert_equal 1, tasks.length
    assert_equal :cron, tasks[0][:type]
    assert_equal "0 9 * * 1-5", tasks[0][:cron]
    assert_equal "weekday-task", tasks[0][:name]
  end

  def test_scheduler_config_multiple_tasks
    Ask::Agent.configure do |c|
      c.scheduler.every "10 minutes", name: "task-1"
      c.scheduler.cron "0 0 * * *", name: "task-2"
    end

    tasks = []
    Ask::Agent.configuration.scheduler.each_task { |t| tasks << t }
    assert_equal 2, tasks.length
    assert_equal [:every, :cron], tasks.map { |t| t[:type] }
  end

  def test_scheduler_start_stop
    Ask::Agent.configure do |c|
      c.scheduler.every "1 hour", name: "test" do
        # no-op
      end
    end

    refute Ask::Agent::Scheduler.running?
    Ask::Agent::Scheduler.start
    assert Ask::Agent::Scheduler.running?
    assert_equal 1, Ask::Agent::Scheduler.jobs.length

    Ask::Agent::Scheduler.stop
    refute Ask::Agent::Scheduler.running?
    assert_equal 0, Ask::Agent::Scheduler.jobs.length
  end

  def test_start_twice_is_idempotent
    Ask::Agent.configure do |c|
      c.scheduler.every "1 hour", name: "test" do
        # no-op
      end
    end

    Ask::Agent::Scheduler.start
    jobs_first = Ask::Agent::Scheduler.jobs.length
    Ask::Agent::Scheduler.start  # second start should be no-op
    assert_equal jobs_first, Ask::Agent::Scheduler.jobs.length
    Ask::Agent::Scheduler.stop
  end

  def test_runs_task_on_schedule
    ran = false
    Ask::Agent.configure do |c|
      c.scheduler.every "1s", name: "quick-task" do
        ran = true
      end
    end

    Ask::Agent::Scheduler.start
    sleep 1.5  # wait enough for the task to fire

    assert ran, "Task should have executed within the polling window"
  ensure
    Ask::Agent::Scheduler.stop
  end

  def test_multiple_tasks_run
    counter = 0
    mutex = Mutex.new

    Ask::Agent.configure do |c|
      c.scheduler.every "1s", name: "counter" do
        mutex.synchronize { counter += 1 }
      end
    end

    Ask::Agent::Scheduler.start
    sleep 2.5  # enough for ~2 ticks

    mutex.synchronize do
      assert_operator counter, :>=, 1, "Task should have run at least once"
    end
  ensure
    Ask::Agent::Scheduler.stop
  end

  def test_job_by_name
    Ask::Agent.configure do |c|
      c.scheduler.every "1 hour", name: "my-job"
    end

    Ask::Agent::Scheduler.start

    job = Ask::Agent::Scheduler.job_by_name("my-job")
    refute_nil job
    assert_equal "my-job", job.name

    assert_nil Ask::Agent::Scheduler.job_by_name("nonexistent")
  ensure
    Ask::Agent::Scheduler.stop
  end

  def test_no_tasks_still_starts
    Ask::Agent::Scheduler.start
    assert Ask::Agent::Scheduler.running?
    assert_equal 0, Ask::Agent::Scheduler.jobs.length
  ensure
    Ask::Agent::Scheduler.stop
  end

  def test_stop_without_start
    Ask::Agent::Scheduler.stop  # should not raise
    refute Ask::Agent::Scheduler.running?
  end

  def test_running_after_stop_start_cycle
    Ask::Agent.configure do |c|
      c.scheduler.every "1 hour", name: "test"
    end

    Ask::Agent::Scheduler.start
    assert Ask::Agent::Scheduler.running?
    Ask::Agent::Scheduler.stop
    refute Ask::Agent::Scheduler.running?
    Ask::Agent::Scheduler.start
    assert Ask::Agent::Scheduler.running?
  ensure
    Ask::Agent::Scheduler.stop
  end

  def test_scheduler_class_methods_available
    assert_respond_to Ask::Agent::Scheduler, :start
    assert_respond_to Ask::Agent::Scheduler, :stop
    assert_respond_to Ask::Agent::Scheduler, :running?
    assert_respond_to Ask::Agent::Scheduler, :jobs
    assert_respond_to Ask::Agent::Scheduler, :job_by_name
  end

  def test_config_dsl_returns_self
    config = Ask::Agent.configuration
    assert_instance_of Ask::Agent::SchedulerConfig, config.scheduler
  end

  def test_cron_task_no_block
    # Should not raise - tasks without blocks are valid (do nothing on tick)
    Ask::Agent.configure do |c|
      c.scheduler.cron "0 0 * * *", name: "silent-task"
    end

    Ask::Agent::Scheduler.start
    assert_equal 1, Ask::Agent::Scheduler.jobs.length
  ensure
    Ask::Agent::Scheduler.stop
  end

  def test_start_without_config
    # No tasks configured - should start with empty schedule
    Ask::Agent::Scheduler.start
    assert Ask::Agent::Scheduler.running?
  ensure
    Ask::Agent::Scheduler.stop
  end
end
