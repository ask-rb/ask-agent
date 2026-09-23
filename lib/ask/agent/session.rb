# frozen_string_literal: true

require "securerandom"
require "time"

module Ask
  module Agent
    class Session
      # Max ids remembered as "recently completed" to guard against late
      # loop registrations resurrecting ghost pending calls.
      RECENTLY_COMPLETED_MAX = 200

      attr_reader :id, :chat, :tools, :turn_count, :created_at, :messages
      attr_reader :tool_calls_made, :total_input_tokens, :total_output_tokens, :total_cost

      def reflection_count
        @reflector&.reflection_count || 0
      end

      attr_reader :meta_agent_results
      # @return [Ask::Skills::Registry, nil] auto-discovered skills registry
      attr_reader :skills_registry
      # @return [Ask::Decisions::AgentAdapter, nil] decision adapter (when decision_provider is set)
      attr_reader :decision_adapter

      # Build a Session from a discovered Definition class and directory.
      #
      # This is the shared implementation used by both Ask::Agent.new(name)
      # and Session.new(name:). It resolves the definition's config, tools,
      # and instructions, then applies any caller-supplied overrides.
      #
      # @param klass [Class] the Definition subclass
      # @param dir [String] the agent directory path
      # @param opts [Hash] runtime overrides (model, provider, tools, system_prompt, etc.)
      # @return [Session]
      def self.build_from_definition(klass, dir, opts = {})
        config = klass._config
        session_opts = { model: config[:model] || Ask::Agent.configuration.default_model }

        # Pass optional config
        session_opts[:provider] = config[:provider] if config[:provider]
        session_opts[:max_turns] = config[:max_turns] if config[:max_turns]
        session_opts[:parallel_tools] = config[:parallel_tools] if config.key?(:parallel_tools)
        session_opts[:skills_disclosure] = config[:skills_disclosure] if config.key?(:skills_disclosure)

        # Pass arbitrary session options
        if config[:options]
          session_opts.merge!(config[:options])
        end

        # Pass agent directory for per-agent skills discovery
        session_opts[:agent_dir] = dir

        # Resolve tools
        tools = resolve_definition_tools(config[:tools], dir)
        session_opts[:tools] = tools if tools.any?

        # Load instructions
        prompt = klass.instructions_content
        session_opts[:system_prompt] = prompt if prompt

        # Apply schedule if defined
        schedule = config[:schedule]
        if schedule
          task_block = ->(_sess = nil) {
            agent = build_from_definition(klass, dir)
            agent.run("")
          }
          Ask::Agent.configuration.scheduler.every(schedule, name: File.basename(dir), &task_block)
        end

        # Caller-supplied runtime options win over the definition's config.
        session_opts.merge!(opts) unless opts.empty?

        new(**session_opts)
      end

      def initialize(model:, tools: [], max_turns: 25, max_tool_retries: 3,
                     compactor: nil, hooks: {}, state: nil, persistence: nil,
                     id: nil, system_prompt: nil, parallel_tools: true,
                     reflector: nil, telemetry: true, meta_agent: nil,
                     agent_dir: nil, evaluator: nil, audit_log: nil,
                     skills_disclosure: true, approval: nil,
                     tool_call_repair: nil, checkpoints: false,
                     todos: false, plan_mode: false, memory: nil,
                     memory_learning: false, offload_large_outputs: false,
                     artifacts: false, artifact_uploader: nil,
                     **chat_options)
        @id = id || SecureRandom.uuid
        @agent_dir = agent_dir
        @max_turns = max_turns
        @max_tool_retries = max_tool_retries
        @parallel_tools = parallel_tools
        @skills_disclosure = skills_disclosure
        @event_handlers = { all: [] }
        @running = false
        @deleted = false
        @abort_requested = false
        @pending_tools = {}
        @recently_completed = []
        @pending_mutex = Mutex.new
        @followup_pending = false
        @turn_count = 0
        # Concurrency-safe steering: turn id bumped at every
        # TurnStart; steers arriving mid-turn are queued and dispatched at
        # the next turn boundary.
        @turn_id = 0
        @queued_steers = []
        @steer_mutex = Mutex.new
        on(Events::TurnStart) do
          @turn_id += 1
          @turn_count += 1
        end
        @created_at = Time.now
        @_no_tools_instructed = false

        @total_input_tokens = 0
        @total_output_tokens = 0
        @total_cost = 0.0

        @telemetry = telemetry.is_a?(Telemetry) ? telemetry : Telemetry.new(enabled: !!telemetry)

        # Task list (todo_write tool) — built before resolve_tools so the
        # tool can be injected with a reference to it.
        @todos_enabled = !!todos
        @todo_list = TodoList.new if @todos_enabled
        @todo_list&.subscribe { |entries| emit(Events::TodoUpdated.new(todos: entries)) }
        # Durable memory (memory_write / memory_search tools). An instance
        # with its own namespace and state adapter; nil disables memory.
        @memory = memory
        # Learning: extract durable facts from the transcript when the
        # session ends (requires memory).
        if memory_learning && !@memory
          raise ArgumentError, "memory_learning: requires a memory: instance"
        end
        @memory_learning = !!memory_learning

        # Large-output offloading: tool results above a size threshold are
        # stored in a ToolOutputStore (state adapter when present, else
        # in-process) and the transcript keeps a preview + reference.
        @offload_threshold = case offload_large_outputs
        when true then 4000
        when Integer then offload_large_outputs
        else nil
        end
        @output_store = if @offload_threshold
          ToolOutputStore.new(state: state || persistence || Ask::State::Memory.new)
        end

        # Tool deliverables (artifacts): metadata[:artifact] on tool results
        # is collected into the store — inline content for small text,
        # external URIs for large binaries (uploader lifts content to a URI
        # when provided).
        @artifact_store = if artifacts
          ArtifactStore.new(
            state: state || persistence || Ask::State::Memory.new,
            uploader: artifact_uploader
          )
        end

        # Plan mode — research phase gated to read-only tools until a human
        # approves the model's plan (submitted via the exit_plan_mode tool).
        @plan_mode = plan_mode.is_a?(Hash) ? true : !!plan_mode
        @plan_mode_read_only_tools = if plan_mode.is_a?(Hash) && plan_mode[:read_only_tools]
          Array(plan_mode[:read_only_tools]).map(&:to_s)
        else
          %w[read glob grep web_search]
        end
        @plan_queue = Ask::Permissions::ApprovalQueue.new(
          on_approve: ->(action) { approve_plan(action) },
          on_reject: ->(action) { reject_plan(action) },
          # Same race closure as the tool approval queue: register the
          # pending call at submit time so plan approvals land even when
          # the executor is still in flight.
          on_submit: ->(action) {
            register_pending_tool(action.tool_call_id, {
              tool_name: action.tool_name,
              message: action.message || "Plan awaiting approval",
              status: "pending",
              tool_call_id: action.tool_call_id,
              action_id: action.id
            })
          }
        ) if @plan_mode

        @tools = resolve_tools(tools)
        @chat = build_chat(model, system_prompt, @tools, **chat_options)
        @loop = Loop.new(max_turns: max_turns)
        @tool_executor = ToolExecutor.new(
          max_retries: max_tool_retries,
          parallel: parallel_tools,
          output_offload_threshold: @offload_threshold,
          output_store: @output_store,
          artifact_store: @artifact_store
        )
        @compactor = compactor ? build_compactor(compactor) : nil
        @hooks = Hooks.new(hooks)
        @audit_log = build_audit_log(audit_log)
        @approval_queue = build_approval(approval)
        @tool_call_repair = tool_call_repair

        # Plan gate runs before user hooks and the approval policy: in plan
        # mode, non-read-only tools are blocked outright (never queued).
        # The allowed-tool decision lives in one shared PlanModePolicy;
        # its #before_tool_call is hooked in only while plan mode is on.
        if @plan_mode
          @plan_mode_policy = Ask::Permissions::PlanModePolicy.new(
            allowed_tools: @plan_mode_read_only_tools,
            exit_tool: "exit_plan_mode"
          )
          @hooks = Hooks.new(
            before_tool: [method(:plan_mode_gate)] + Array(@hooks.instance_variable_get(:@before_tool)),
            after_tool: @hooks.instance_variable_get(:@after_tool)
          )
        end

        # Decision provider integration: wire Gate, OutputJudge, and
        # other decision components when a decision_provider is configured.
        # This is opt-in — when not set, everything works as before.
        decision_provider_name = chat_options.delete(:decision_provider) || Ask::Agent.configuration.decision_provider
        decision_config = chat_options.delete(:decision_config) || {}
        @decision_adapter = nil
        if decision_provider_name && defined?(Ask::Decisions)
          require "ask/decisions/agent_adapter" unless defined?(Ask::Decisions::AgentAdapter)
          @decision_adapter = Ask::Decisions::AgentAdapter.new(decision_provider_name, decision_config)

          # Wire Gate (before_tool) and OutputJudge (after_tool) into hooks.
          existing_before = Array(@hooks.instance_variable_get(:@before_tool))
          existing_after = Array(@hooks.instance_variable_get(:@after_tool))
          @hooks = Hooks.new(
            before_tool: @decision_adapter.before_tool_hooks + existing_before,
            after_tool: existing_after + @decision_adapter.after_tool_hooks
          )
        end

        @system_context = build_system_context(system_prompt)
        apply_system_context

        @state = state || persistence
        if checkpoints && !@state
          raise ArgumentError, "checkpoints: requires a state: adapter"
        end
        @checkpoints = !!checkpoints
        @checkpoint_store = CheckpointStore.new(@state) if @checkpoints

        reflector_opts = reflector.is_a?(Hash) ? reflector : {}
        @reflector = if reflector
          Reflector.new(
            model: @chat,
            max_reflections: reflector_opts[:max_reflections] || 1
          )
        end

        @meta_agent_config = meta_agent
        @meta_agent_results = nil

        @compactor&.chat = @chat

        # Parse evaluator configuration
        @evaluator = nil
        @evaluator_config = {}

        if evaluator
          eval_model = if evaluator.is_a?(Hash)
                         @evaluator_config = evaluator
                         evaluator[:model] || Ask::Agent.configuration.default_evaluator_model || model_id_from(@chat)
                       else
                         Ask::Agent.configuration.default_evaluator_model || model_id_from(@chat)
                       end

          @evaluator = Evaluator.new(model: eval_model)
        end
      end

      # The approval queue backing this session, or nil when the session was
      # created without approval support. Use it to inspect pending actions
      # and approve/reject them.
      #
      # @return [Ask::Permissions::ApprovalQueue, nil]
      attr_reader :approval_queue
      # @return [Ask::Permissions::ApprovalQueue, nil] queue carrying plan
      #   approvals (only when plan mode is enabled)
      attr_reader :plan_queue
      # @return [Ask::Permissions::PlanModePolicy, nil] the shared policy
      #   deciding which tools may run in plan mode (only when plan mode
      #   is enabled)
      attr_reader :plan_mode_policy
      # @return [Ask::Agent::TodoList, nil] session task list (only when
      #   todos are enabled)
      attr_reader :todo_list
      # @return [Ask::Agent::Memory, nil] durable memory (only when passed
      #   via the +memory:+ option)
      attr_reader :memory
      # @return [Ask::Agent::ToolOutputStore, nil] store for offloaded large
      #   tool outputs (only when large-output offloading is enabled)
      attr_reader :output_store
      # @return [Ask::Agent::ArtifactStore, nil] store for tool deliverables
      #   (only when the +artifacts:+ option is enabled)
      attr_reader :artifact_store

      def run(message, tools: nil, reset: true, attachments: nil, runtime_event_sink: nil)
        raise "Session deleted" if @deleted
        raise "Session already running" if @running

        @running = true
        @abort_requested = false
        Ask::Agent.current_session = self
        if reset
          @turn_count = 0
          @loop.reset!
        end

        emit(Events::SessionStart.new)

        active_tools = @tools

        # Retrieve relevant memories from previous sessions into context.
        inject_memories(message) if reset && @memory

        if active_tools.empty? && !@_no_tools_instructed
          @chat.add_message(role: :system, content: "You have no tools available. Do not claim you can look up information or use tools of any kind. Just respond based on your existing knowledge.")
          @_no_tools_instructed = true
        end

        # Leftover queued steers from a previous run become user messages
        # before this run starts.
        drain_leftover_steers

        begin
          @tool_executor.telemetry = @telemetry

	          response = @loop.run_turn(
	            chat: @chat,
	            message: message,
	            attachments: attachments,
	            tools: active_tools,
	            tool_executor: @tool_executor,
	            compactor: @compactor,
	            hooks: @hooks,
	            event_emitter: self,
	            session_id: @id,
            tool_call_repair: @tool_call_repair,
            steer_source: method(:drain_one_steer),
	            persist: @state ? method(:persist!) : nil,
	            runtime_event_sink: runtime_event_sink
	          )

          @total_input_tokens += @loop.last_input_tokens.to_i
          @total_output_tokens += @loop.last_output_tokens.to_i
          @total_cost += @loop.last_cost.to_f
        rescue MaxTurnsExceeded => e
          emit(Events::MaxTurnsExceeded.new(max_turns: @max_turns))
          @telemetry.log(:max_turns_exceeded, session_id: @id, max_turns: @max_turns)
          response = last_content
        rescue LoopDetected => e
          emit(Events::LoopDetected.new(tool_name: e.message, repeated_count: 3))
          @telemetry.log(:loop_detected, session_id: @id, tool_name: e.message, repeated_count: 3)
          response = last_content
        rescue Ask::ContextLengthExceeded
          if @compactor && !@compactor.overflow_recovered?
            @compactor.recover_from_overflow
            retry
          end
          response = "I'm sorry, the conversation has grown too long. Please start a new session."
        rescue StandardError => e
          emit(Events::Error.new(error: e.message, recoverable: true))
          raise
        ensure
          @running = false
          Ask::Agent.current_session = nil if Ask::Agent.current_session.equal?(self)
          persist! if @state
          # Learn from this session: extract durable facts into memory.
          # Only on the initial run (not follow-ups); best-effort, never
          # raises.
          extract_memories if reset && @memory_learning
          # A pending tool completed while this run was busy: voice the
          # result now that the turn is over (one follow-up per completion).
          follow_up = @pending_mutex.synchronize do
            take = @followup_pending
            @followup_pending = false
            take
          end
          run_follow_up if follow_up
        end

        @tool_calls_made = @tool_executor.total_executions

        # Independent evaluator step (generator/evaluator separation).
        # Runs BEFORE self-reflection so the evaluator gets a fresh, unbiased look
        # at the generator's output using a separate model and isolated context.
        @skip_reflector = false

        if @evaluator && !@abort_requested
          goal = @evaluator_config[:goal] || message

          eval_result = @evaluator.evaluate(
            goal: goal.to_s,
            response: response,
            event_emitter: self
          )

          @telemetry.log(:evaluation_end, session_id: @id,
                         decision: eval_result.decision,
                         feedback: eval_result.feedback,
                         scores: eval_result.scores)

          case eval_result.decision
          when :revise
            @chat.add_message(
              role: :system,
              content: "An independent evaluator has requested revisions:\n\n#{eval_result.feedback}"
            )

            response = @loop.run_turn(
              chat: @chat,
              message: "",
              tools: active_tools,
              tool_executor: @tool_executor,
              compactor: @compactor,
              hooks: @hooks,
              event_emitter: self,
              session_id: @id,
              tool_call_repair: @tool_call_repair,
              runtime_event_sink: runtime_event_sink
            )

            @total_input_tokens += @loop.last_input_tokens.to_i
            @total_output_tokens += @loop.last_output_tokens.to_i
            @total_cost += @loop.last_cost.to_f

            # Skip reflector — we already iterated based on evaluator feedback
            @skip_reflector = true
          when :block
            emit(Events::EvaluationBlocked.new(
              feedback: eval_result.feedback,
              scores: eval_result.scores,
              evidence: eval_result.evidence
            ))
            response = "This response was blocked by the evaluator: #{eval_result.feedback}"
          when :accept
            # Fall through to reflector for backward compatibility
          end
        end

        if @reflector && !@skip_reflector && @reflector.reflect?(@tool_calls_made) && !@abort_requested
          eval_result = @reflector.evaluate(response: response, event_emitter: self)
          @telemetry.log(:reflection_end, session_id: @id, decision: eval_result[:decision], feedback: eval_result[:feedback])

          if eval_result[:decision] == :improve && !@abort_requested
            @chat.add_message(
              role: :system,
              content: "Improve your last response: #{eval_result[:feedback]}"
            )

            response = @loop.run_turn(
              chat: @chat,
              message: "",
              tools: active_tools,
              tool_executor: @tool_executor,
              compactor: @compactor,
              hooks: @hooks,
              event_emitter: self,
              session_id: @id,
              tool_call_repair: @tool_call_repair,
              runtime_event_sink: runtime_event_sink
            )

            @total_input_tokens += @loop.last_input_tokens.to_i
            @total_output_tokens += @loop.last_output_tokens.to_i
            @total_cost += @loop.last_cost.to_f
          end
        end

        if @meta_agent_config
          @telemetry.increment_session_count!
          try_auto_meta_agent
        end

        # Capture messages before emitting SessionEnd so event handlers
        # can access agent.messages during the callback
        @messages = @chat.messages.dup

        emit(Events::SessionEnd.new(
          result: response,
          turn_count: @turn_count,
          tool_calls_made: @tool_calls_made,
          input_tokens: @total_input_tokens,
          output_tokens: @total_output_tokens,
          cost: @total_cost
        ))

        response
      end

      def on_event(&block)
        @event_handlers[:all] << block
        self
      end

      def on(type, &block)
        @event_handlers[type] ||= []
        @event_handlers[type] << block
        self
      end

      def emit(event)
        @event_handlers[:all].each { |h| h.call(event) }
        handlers = @event_handlers[event.class]
        handlers&.each { |h| h.call(event) }
      end

      def running? = @running
      def deleted? = @deleted

      def save
        persist! if @state
      end

      def self.load(id, adapter:)
        data = adapter.get(id)
        return nil unless data

        data = deep_symbolize_keys(data)

        approvals_snapshot = data[:approvals]
        plan_snapshot = data[:plan_approvals]

        session = new(
          id: data[:id],
          model: data.dig(:metadata, :model),
          # Restore saved user tools by class name. Tools that cannot be
          # restored — renamed/removed classes (NameError) or constructors
          # with required args (ArgumentError) — are skipped with a warning
          # instead of failing the whole load; resolve_tools re-adds the
          # framework-injected load_skill tool with a proper registry.
          tools: data.dig(:metadata, :tools).to_a.filter_map do |name|
            begin
              name.constantize.new
            rescue NameError, ArgumentError => e
              warn "[ask-agent] Session.load skipped tool '#{name}': #{e.class}: #{e.message}"
              nil
            end
          end,
          state: adapter,
          # Checkpointing is restored automatically when the session has
          # checkpoints in the store; todos likewise when the snapshot has
          # a task list. Approval / plan queues are re-enabled only when the
          # persisted blob carries pending actions — policy config (rules,
          # require_approval lists) is not persisted, only queue state that
          # the shared Permissions API supports.
          checkpoints: !adapter.get("#{id}#{CheckpointStore::HEAD_KEY}").nil?,
          todos: !data[:todos].nil?,
          approval: approval_snapshot_pending?(approvals_snapshot) ? true : nil,
          plan_mode: approval_snapshot_pending?(plan_snapshot) ? true : false
        )

        data[:messages].each do |msg|
          session.chat.add_message(
            role: msg[:role].to_sym,
            content: deserialize_content(msg[:content]),
            tool_call_id: msg[:tool_call_id]
          )
        end
        session.instance_variable_get(:@todo_list)&.restore(data[:todos])
        session.send(:restore_persisted_approvals, approvals_snapshot, plan_snapshot)

	        session.instance_variable_set(:@messages, session.chat.messages.dup)
	        session
      end

      def delete
        @deleted = true
        @checkpoint_store&.delete(@id)
        @output_store&.delete(@id)
        @artifact_store&.delete(@id)
        @state&.delete(@id)
      end

      def abort
        @abort_requested = true
      end

      def abort_requested? = @abort_requested

      # --- Checkpoints (fork, rollback, resume) ---

      # @return [Array<Integer>] checkpoint seqs, oldest first
      # @raise [RuntimeError] when checkpointing is not enabled
      def checkpoint_history
        require_checkpoints!
        @checkpoint_store.history(@id)
      end

      # Load a checkpoint's snapshot.
      #
      # @param seq [Integer, nil] checkpoint seq; defaults to the head
      # @return [Hash, nil] the snapshot with symbol keys
      # @raise [RuntimeError] when checkpointing is not enabled
      def load_checkpoint(seq: nil)
        require_checkpoints!
        data = @checkpoint_store.load(@id, seq: seq)
        data && self.class.deep_symbolize_keys(data)
      end

      # Rewind the session to an earlier checkpoint: messages and turn count
      # are restored from the snapshot, and the store's head moves back.
      # Later checkpoints are kept, so the session can roll forward again.
      #
      # @param seq [Integer, nil] checkpoint seq (xor +turn:)
      # @param turn [Integer, nil] roll back to the last checkpoint whose
      #   turn count equals +turn+ (xor +seq:)
      # @return [self]
      # @raise [ArgumentError] when the checkpoint does not exist
      # @raise [RuntimeError] when checkpointing is not enabled or the
      #   session is running
      def rollback!(seq: nil, turn: nil)
        require_checkpoints!
        raise "cannot roll back a running session" if @running

        seq = resolve_checkpoint_seq(seq, turn)
        data = load_checkpoint(seq: seq)
        raise ArgumentError, "no checkpoint #{seq}" unless data

        @checkpoint_store.rollback(@id, seq)
        restore_from_snapshot(data)
        emit(Events::SessionRolledBack.new(session_id: @id, seq: seq, turn_count: @turn_count))
        self
      end

      # Fork the session at a checkpoint: a new session (new id, same model
      # and tools) whose history is everything up to that point, backed by
      # its own checkpoint chain. Continue the branch with +run+.
      #
      # @param at_seq [Integer, nil] checkpoint to fork from (xor +at_turn:)
      # @param at_turn [Integer, nil] fork at the last checkpoint whose turn
      #   count equals +at_turn+ (xor +at_seq:)
      # @return [Ask::Agent::Session] the forked session
      # @raise [ArgumentError] when the checkpoint does not exist
      # @raise [RuntimeError] when checkpointing is not enabled
      def fork(at_seq: nil, at_turn: nil)
        require_checkpoints!

        seq = resolve_checkpoint_seq(at_seq, at_turn)
        data = load_checkpoint(seq: seq)
        raise ArgumentError, "no checkpoint #{seq}" unless data

        forked_id = @checkpoint_store.fork(@id, at_seq: seq)
        forked = self.class.new(
          id: forked_id,
          model: data[:metadata][:model],
          tools: @tools,
          state: @state,
          checkpoints: true,
          todos: @todos_enabled,
          plan_mode: @plan_mode
        )
        restore_into(forked, data)
        emit(Events::SessionForked.new(session_id: @id, forked_id: forked_id, seq: seq))
        forked
      end

# --- Artifacts (tool deliverables) ---

# @return [Array<Hash>] artifact summaries for this session (id,
#   filename, mime_type, size, uri), newest first
# @raise [RuntimeError] when artifacts are not enabled
def artifacts
  require_artifacts!
  @artifact_store.list(@id)
end

# @param id [String] artifact id
# @return [Hash, nil] the full record (content or uri)
# @raise [RuntimeError] when artifacts are not enabled
def fetch_artifact(id)
  require_artifacts!
  @artifact_store.fetch(@id, id)
end

      # --- Plan mode ---

      # Pop the next queued steer (called by the loop at each turn
      # boundary); returns "" when nothing is queued.
      def drain_one_steer
        @steer_mutex.synchronize { @queued_steers.shift }.to_s
      end

      # Move any queued steers left over from a previous run into the
      # conversation (the session was idle, so they are dispatched now).
      def drain_leftover_steers
        while (message = drain_one_steer) != ""
          @chat.add_message(role: :user, content: message)
        end
      end

      # Extract durable facts from this session's transcript into memory
      # (memory_learning: true). Best-effort — extraction never breaks the
      # session; failures are swallowed.
      def extract_memories
        extractor = MemoryExtractor.new(model: model_id_from(@chat), memory: @memory)
        extractor.extract(transcript: @chat.messages, session_id: @id)
      rescue StandardError
        nil
      end

      # Retrieve memories relevant to the incoming message and inject them
      # as a system message, so a new session starts with what earlier
      # sessions learned.
      def inject_memories(message)
        hits = @memory.search(message.to_s, limit: 5)
        return if hits.empty?

        @chat.add_message(
          role: :system,
          content: "Relevant memories from previous sessions:\n" + hits.map { |e| "- #{e.content}" }.join("\n")
        )
      end

      # @return [Boolean] whether the session is in plan mode (research
      #   phase; non-read-only tools are blocked until the plan is approved)
      def plan_mode? = @plan_mode

      # Before-tool gate active while in plan mode: delegates the
      # allowed-tool decision to the PlanModePolicy (read-only tools and
      # exit_plan_mode itself) and proceeds once a human approves the plan.
      def plan_mode_gate(tool_call, context)
        return { action: :proceed } unless @plan_mode

        @plan_mode_policy.before_tool_call(tool_call, context)
      end

      def approve_plan(action)
        @plan_mode = false
        plan = action.args[:plan] || action.args["plan"] || ""
        emit(Events::PlanApproved.new(plan: plan))
        complete_pending_tool(
          tool_call_id: action.tool_call_id,
          result: {
            tool_name: "exit_plan_mode",
            message: "Plan approved — execute it now.",
            status: "success",
            is_error: false
          }
        )
      end

      def reject_plan(action)
        plan = action.args[:plan] || action.args["plan"] || ""
        emit(Events::PlanRejected.new(plan: plan))
        complete_pending_tool(
          tool_call_id: action.tool_call_id,
          result: {
            tool_name: "exit_plan_mode",
            message: "Plan rejected by the user — revise your plan and resubmit.",
            status: "rejected",
            is_error: false
          }
        )
      end

      # --- Steer (concurrency-safe message injection) ---

      # @return [Integer] id of the turn currently running (or the last
      #   completed turn when idle)
      attr_reader :turn_id

      # Inject a message into the session safely, from any thread (web, CLI,
      # another agent):
      #
      # - **:stale** — the caller's `expected_turn_id` does not match the
      #   current turn id (the caller was looking at an older state).
      # - **:queued** — a turn is running; the message is held and dispatched
      #   as the next user message at the next turn boundary.
      # - **:steered** — the session is idle; the message is added to the
      #   conversation and processed by the next run.
      #
      # @param message [String]
      # @param expected_turn_id [Integer, nil] the turn id the caller
      #   believes is current; nil skips the check
      # @param attachments [Array<Ask::Attachment>, nil] files to attach
      #   (applied when the session is idle; queued steers keep the
      #   message text only — the loop resolves queued messages as text)
      # @return [Hash] {status: :stale|:queued|:steered, turn_id: Integer}
      def steer(message, expected_turn_id: nil, attachments: nil)
        @steer_mutex.synchronize do
          if expected_turn_id && expected_turn_id != @turn_id
            return { status: :stale, turn_id: @turn_id }
          end
          if @running
            @queued_steers << message.to_s
            return { status: :queued, turn_id: @turn_id }
          end
        end
        @chat.add_message(role: :user, content: message.to_s, attachments: attachments)
        { status: :steered, turn_id: @turn_id }
      end

      # @return [Integer] steers queued and not yet dispatched
      def queued_steers
        @steer_mutex.synchronize { @queued_steers.size }
      end

      # --- Async (pending) tools ---

      # Registers a pending tool call (called by the loop when a tool
      # returned Ask::Result.pending, or at approval-queue submit time).
      # The background work completes later via #complete_pending_tool.
      #
      # A call can be resolved (approved/rejected) while the executor is
      # still in flight; when the loop then registers the same call, the
      # registration is skipped so no ghost pending entry is left behind.
      def register_pending_tool(tool_call_id, result)
        @pending_mutex.synchronize do
          return if @recently_completed.include?(tool_call_id)
          if (action_id = result[:action_id]) && @approval_queue
            action = @approval_queue[action_id]
            return if action && action.status != :pending
          end
          @pending_tools[tool_call_id] = result
        end
        emit(Events::ToolPending.new(name: result[:tool_name], id: tool_call_id))
        nil
      end

      # @return [Boolean] true while at least one async tool is running
      def pending_tools?
        @pending_mutex.synchronize { !@pending_tools.empty? }
      end

      # Completes a pending (async) tool call from a background thread.
      #
      # Adds the tool result to the conversation and, when the session is
      # idle, runs a follow-up turn so the agent voices the answer. If a
      # turn is running, the follow-up fires as soon as it ends.
      #
      # @param tool_call_id [String] the original tool call id
      # @param result [Hash] tool result hash ({message:, is_error:, ...})
      # @return [Boolean] true if the completion was registered
      def complete_pending_tool(tool_call_id:, result:)
        follow_up = @pending_mutex.synchronize do
          pending = @pending_tools.delete(tool_call_id)
          return false unless pending

          # Remember the id briefly so a late loop registration (from a
          # completion that landed while the executor was in flight) cannot
          # resurrect it as a ghost pending call.
          @recently_completed << tool_call_id
          @recently_completed.shift if @recently_completed.size > RECENTLY_COMPLETED_MAX

          @chat.add_message(
            role: :tool,
            content: result[:message].to_s,
            tool_call_id: tool_call_id
          )
          if @running
            @followup_pending = true
            false
          else
            true
          end
        end
        emit(Events::ToolCompleted.new(name: result[:tool_name], id: tool_call_id, result: result))
        run_follow_up if follow_up
        true
      end

      # A follow-up turn driven by an async completion: runs the loop with
      # the tool message already in the conversation, preserving turn state.
      def run_follow_up
        run("", reset: false)
      rescue => e
        emit(Events::Error.new(error: e.message, recoverable: false))
        raise
      end

      # Load a skill by name or file path.
      # Injects the skill's full instructions into the conversation as a system message.
      #
      # @param name [String] skill name (e.g. "rails.db_debug") or path to a .md file
      # @raise [Ask::Skills::Error] if the skill is not found
      def skill(name)
        if @skills_registry && (s = @skills_registry[name])
          @chat.add_message(
            role: :system,
            content: "## Skill: #{s.name}\n\n#{s.description}\n\n---\n\n#{s.instructions}"
          )
        elsif File.exist?(name.to_s)
          content = File.read(name.to_s)
          @chat.add_message(
            role: :system,
            content: "## Skill: #{name}\n\n---\n\n#{content}"
          )
        else
          raise Ask::Skills::Error, "Skill not found: #{name.inspect}"
        end
      end

      def reset_messages!
        @chat.reset_messages!
        @messages = []
      end

      private

      def build_audit_log(config)
        config ||= Ask::Agent.configuration.audit_log
        return nil unless config
        Ask::Agent::Policies::AuditLog.new(self, adapter: config)
      end

      # Build the approval queue + policy when approval is enabled.
      #
      # `approval` accepts:
      #   - true            → queue with defaults
      #   - a Hash          → { require_approval:, auto_approve: } for the policy
      #   - an ApprovalQueue → uses it, with policy options from
      #                        approval[:policy] if given
      #
      # When enabled, an ApprovalPolicy hook is prepended to the session's
      # before_tool hooks so approval-required tools queue instead of running.
      def build_approval(approval)
        return nil unless approval

        policy_opts = approval.is_a?(Hash) ? approval : {}

        queue = if approval.is_a?(Ask::Permissions::ApprovalQueue)
          approval
        elsif policy_opts[:queue].is_a?(Ask::Permissions::ApprovalQueue)
          policy_opts[:queue]
        else
          Ask::Permissions::ApprovalQueue.new(
            auto_approve: policy_opts[:auto_approve],
            on_approve: ->(action) { apply_approved_action(action) },
            on_reject: ->(action) { reject_pending_action(action) }
          )
        end

        # Custom queues (subclasses, event-emitting wrappers) may come
        # without callbacks — wire the session's defaults so approvals
        # actually execute the tool call.
        queue.on_approve ||= ->(action) { apply_approved_action(action) }
        queue.on_reject ||= ->(action) { reject_pending_action(action) }
        # Register the pending tool call the moment the action is queued —
        # before the auto-approval drain — so completions always match even
        # when an approval lands while the executor is still in flight.
        queue.on_submit ||= ->(action) {
          register_pending_tool(action.tool_call_id, {
            tool_name: action.tool_name,
            message: action.message || "Pending approval",
            status: "pending",
            tool_call_id: action.tool_call_id,
            action_id: action.id
          })
        }

        policy = Ask::Permissions::ApprovalPolicy.new(
          queue: queue,
          require_approval: policy_opts[:require_approval],
          rules: policy_opts[:rules],
          tools: @tools
        )

        # Prepend the approval gate so it runs before user hooks
        @hooks = Hooks.new(
          before_tool: [policy.method(:before_tool_call)] + Array(@hooks.instance_variable_get(:@before_tool)),
          after_tool: @hooks.instance_variable_get(:@after_tool)
        )

        queue
      end

      def build_chat(model, system_prompt, tools, **chat_options)
        if model.respond_to?(:ask)
          model
        else
          chat = Ask::Agent::Chat.new(model: model, tools: tools, **chat_options)
          chat.with_instructions(system_prompt) if system_prompt
          chat
        end
      end

      # Execute an approved action's tool call and complete the pending tool,
      # so the follow-up turn voices the outcome.
      def apply_approved_action(action)
        tool = @tools.find { |t| t.name == action.tool_name }
        if tool
          result = tool.call(action.args)
          status = result.respond_to?(:ok?) ? (result.ok? ? "success" : "error") : "success"
          complete_pending_tool(
            tool_call_id: action.tool_call_id,
            result: {
              tool_name: action.tool_name,
              message: result.to_s,
              status: status,
              is_error: status == "error"
            }
          )
        else
          complete_pending_tool(
            tool_call_id: action.tool_call_id,
            result: {
              tool_name: action.tool_name,
              message: "Tool not found: #{action.tool_name}",
              status: "error",
              is_error: true
            }
          )
        end
      end

      # Notify the conversation that an action was rejected by the user.
      def reject_pending_action(action)
        complete_pending_tool(
          tool_call_id: action.tool_call_id,
          result: {
            tool_name: action.tool_name,
            message: "Action '#{action.tool_name}' was rejected by the user.",
            status: "rejected",
            is_error: false
          }
        )
      end

      def resolve_tools(tools)
        resolved = tools.map do |tool|
          tool.is_a?(Class) ? tool.new : tool
        end
        # Always include the load_skill tool for progressive skill disclosure,
        # unless disabled by the agent (voice agents keep a minimal tool
        # surface) or the test framework is loaded (test mode keeps tools
        # deterministic)
        if skills_disclosure_enabled?
          resolved << Ask::Skills::LoadSkillTool.new(registry: @skills_registry) unless resolved.any? { |t| t.name == "load_skill" }
        end
        if @todo_list
          resolved << TodoWrite.new(todo_list: @todo_list) unless resolved.any? { |t| t.name == "todo_write" }
        end
        if @plan_mode
          resolved << ExitPlanMode.new(
            plan_queue: @plan_queue,
            on_submit: ->(plan) { emit(Events::PlanProposed.new(plan: plan)) }
          ) unless resolved.any? { |t| t.name == "exit_plan_mode" }
        end
        if @memory
          resolved << MemoryWrite.new(memory: @memory, session_id: @id) unless resolved.any? { |t| t.name == "memory_write" }
          resolved << MemorySearch.new(memory: @memory) unless resolved.any? { |t| t.name == "memory_search" }
        end
        if @output_store
          resolved << OutputRead.new(store: @output_store, session_id: @id) unless resolved.any? { |t| t.name == "output_read" }
        end
        resolved
      end

      # Whether progressive skill disclosure is active for this session.
      def skills_disclosure_enabled?
        @skills_disclosure && !(defined?(Ask::Agent::Test) && Ask::Agent::Test)
      end

      def build_compactor(config)
        global = Ask::Agent.configuration
        compactor = Compactor.new(
          threshold: config[:threshold] || global.compactor_threshold,
          strategy: config[:strategy] || :proactive,
          reserve_tokens: config[:reserve_tokens] || global.compactor_reserve_tokens,
          keep_recent_tokens: config[:keep_recent_tokens] || global.compactor_keep_recent_tokens,
          keep_count: config[:keep_count],
          min_messages: config[:min_messages]
        )
        compactor.chat = @chat
        compactor
      end

      def require_artifacts!
        raise "artifacts are not enabled (pass artifacts: true)" unless @artifact_store
      end

      def require_checkpoints!
        raise "checkpointing is not enabled (pass state: and checkpoints: true)" unless @checkpoints
      end

      # Resolve a checkpoint seq from either an explicit seq or a turn
      # count (the last checkpoint whose metadata turn_count matches).
      def resolve_checkpoint_seq(seq, turn)
        raise ArgumentError, "pass either seq: or turn:, not both" if seq && turn

        if seq
          seq
        elsif turn
          found = checkpoint_history.reverse_each.find do |s|
            data = self.class.deep_symbolize_keys(@checkpoint_store.load(@id, seq: s) || {})
            data.dig(:metadata, :turn_count) == turn
          end
          raise ArgumentError, "no checkpoint at turn #{turn}" unless found

          found
        else
          raise ArgumentError, "pass either seq: or turn:"
        end
      end

      # Replace the session's in-memory state with a snapshot (symbol keys)
      # and keep the legacy blob consistent.
      def restore_from_snapshot(data)
        restore_into(self, data)
        @state.set(@id, data)
      end

      def restore_into(target, data)
        target.chat.reset_messages!
        data[:messages].each do |msg|
          target.chat.add_message(
            role: msg[:role].to_sym,
            content: self.class.deserialize_content(msg[:content]),
            tool_call_id: msg[:tool_call_id]
          )
        end
        target.instance_variable_set(:@messages, target.chat.messages.dup)
        target.instance_variable_set(:@turn_count, data.dig(:metadata, :turn_count) || 0)
        target.instance_variable_get(:@todo_list)&.restore(data[:todos])
        # Approval restore for checkpoint rollback/fork: silent (never emits)
        # but loud on malformed state — restore_persisted_approvals raises
        # Ask::Agent::Error instead of stranding pending actions.
        target.send(:restore_persisted_approvals, data[:approvals], data[:plan_approvals])
      end

      # User-supplied tools only. Framework-injected tools (the built-in
      # load_skill tool, todo_write, exit_plan_mode, memory tools,
      # output_read) are re-created by resolve_tools on every session, so
      # persisting them would leak framework internals into user data — and
      # they cannot always be auto-instantiated on load anyway (LoadSkillTool
      # needs a registry, ExitPlanMode needs a plan_queue).
      def persisted_tools
        @tools.reject do |t|
          t.is_a?(Ask::Skills::LoadSkillTool) ||
            (defined?(TodoWrite) && t.is_a?(TodoWrite)) ||
            (defined?(ExitPlanMode) && t.is_a?(ExitPlanMode)) ||
            (defined?(MemoryWrite) && t.is_a?(MemoryWrite)) ||
            (defined?(MemorySearch) && t.is_a?(MemorySearch)) ||
            (defined?(OutputRead) && t.is_a?(OutputRead))
        end
      end

      # JSON-safe v1 snapshot for a queue, or nil when there is no queue or
      # it predates the shared Permissions API (compatibility fallback:
      # nothing durable to persist, so nothing to restore — cannot strand
      # pendings because an unsupported queue never contributed durable
      # state). Raises Ask::Agent::Error with context when the queue
      # supports the API but snapshotting fails.
      def queue_snapshot_for(queue, queue_name = "approval")
        return nil unless queue
        return nil unless queue.respond_to?(:snapshot)

        begin
          queue.snapshot
        rescue StandardError => e
          raise Ask::Agent::Error, "Failed to snapshot #{queue_name} queue (#{queue.class}): #{e.class}: #{e.message}"
        end
      end

      # Restore persisted queue snapshots into this session's queues without
      # firing callbacks or emitting events. Pending-tool registrations are
      # rebuilt silently so a later approve/reject still completes the
      # original tool call exactly once.
      #
      # Compatibility fallback (cannot strand): a nil snapshot (approval off
      # or unsupported queue) and an empty pending_actions list are safe
      # no-ops. Any other state that would prevent a faithful restore —
      # non-Hash snapshot, missing/non-Array pendings, missing queue or
      # queue without restore support while pendings exist, a non-empty
      # target queue, or a restore_pending failure — raises
      # Ask::Agent::Error with queue context instead of silently dropping
      # pending actions.
      def restore_persisted_approvals(approvals_snapshot, plan_snapshot)
        restore_queue_snapshot(@approval_queue, approvals_snapshot, "approval")
        restore_queue_snapshot(@plan_queue, plan_snapshot, "plan")
        nil
      end

      def restore_queue_snapshot(queue, snapshot, queue_name = "approval")
        return nil if snapshot.nil?

        unless snapshot.is_a?(Hash)
          raise Ask::Agent::Error, "Cannot restore #{queue_name} queue: snapshot must be a Hash, got #{snapshot.class}"
        end

        pendings = snapshot[:pending_actions] || snapshot["pending_actions"]
        if pendings.nil?
          raise Ask::Agent::Error, "Cannot restore #{queue_name} queue: snapshot missing pending_actions"
        end
        unless pendings.is_a?(Array)
          raise Ask::Agent::Error, "Cannot restore #{queue_name} queue: pending_actions must be an Array, got #{pendings.class}"
        end
        return nil if pendings.empty?

        unless queue
          raise Ask::Agent::Error, "Cannot restore #{queue_name} queue: session has no #{queue_name} queue but snapshot carries #{pendings.size} pending action(s)"
        end
        unless queue.respond_to?(:restore_pending) && queue.respond_to?(:pending_actions)
          raise Ask::Agent::Error, "Cannot restore #{queue_name} queue: #{queue.class} does not support restore_pending"
        end

        # restore_pending requires an empty queue — a non-empty target means
        # a second restore would duplicate or strand actions, so fail loudly
        # instead of silently dropping either side.
        if queue.respond_to?(:any_pending?) && queue.any_pending?
          raise Ask::Agent::Error, "Cannot restore #{queue_name} queue: target queue already holds pending actions"
        end

        begin
          queue.restore_pending(snapshot)
        rescue StandardError => e
          raise Ask::Agent::Error, "Cannot restore #{queue_name} queue: #{e.class}: #{e.message}"
        end
        queue.pending_actions.each do |action|
          tool_call_id = action.tool_call_id
          next unless tool_call_id

          @pending_mutex.synchronize do
            @pending_tools[tool_call_id] ||= {
              tool_name: action.tool_name,
              message: action.message || "Pending approval",
              status: "pending",
              tool_call_id: tool_call_id,
              action_id: action.id
            }
          end
        end
        nil
      end

      # Persist content blocks as their +to_h+ hashes so attachments
      # survive save/load; plain messages stay strings.
      def self.serialize_content(message)
        message.content_blocks ? message.content_blocks.map(&:to_h) : message.content.to_s
      end

      # Rebuild message content from a persisted value: block hashes are
      # reconstructed via Ask::Content.from_h (deep_symbolize_keys may have
      # symbol keys — from_h normalizes).
      def self.deserialize_content(content)
        content.is_a?(Array) ? content.map { |block| Ask::Content.from_h(block) } : content
      end

      def persist!
        payload = {
          id: @id,
          messages: @chat.messages.map { |m|
            {
              role: m.role,
              content: self.class.serialize_content(m),
              tool_call_id: m.tool_call_id,
              created_at: Time.now.iso8601
            }
          },
          todos: @todo_list&.to_h,
          # Durable permission state: JSON-safe v1 queue snapshots when the
          # queue supports the shared Permissions API (#snapshot). Nil when
          # approval is off or the queue predates the API (compatibility
          # fallback — nothing durable to persist, so nothing to strand).
          # Snapshot failures raise Ask::Agent::Error with queue context.
          approvals: queue_snapshot_for(@approval_queue, "approval"),
          plan_approvals: queue_snapshot_for(@plan_queue, "plan"),
          metadata: {
            model: @chat.model.respond_to?(:id) ? @chat.model.id : @chat.model,
            tools: persisted_tools.map { |t| t.class.name },
            max_turns: @max_turns,
            turn_count: @turn_count,
            created_at: @created_at.iso8601,
            updated_at: Time.now.iso8601
          }
        }
        @state.set(@id, payload)
        # Checkpoint only when the conversation actually changed since the
        # last one: the loop persists after every turn and run() persists
        # again on the way out, so without this check every run would append
        # a duplicate tail checkpoint.
        if @checkpoints
          head = @checkpoint_store.load(@id)
          head_messages = head ? (head["messages"] || head[:messages] || []) : []
          head_turn = head ? (head.dig("metadata", "turn_count") || head.dig(:metadata, :turn_count)) : nil
          unchanged = head_messages.size == payload[:messages].size && head_turn == @turn_count
          @checkpoint_store.checkpoint(@id, payload) unless unchanged
        end
      end

      def try_auto_meta_agent
        return unless @meta_agent_config
        return unless @meta_agent_config[:auto]

        interval = @meta_agent_config[:interval] || 10
        count = @telemetry.session_count
        return unless count >= interval

        agent = MetaAgent.new(
          telemetry: @telemetry,
          model: model_id_from(@chat),
          **@meta_agent_config[:chat_options].to_h
        )

        results = agent.analyze
        @meta_agent_results = results
        emit(Events::MetaAgentAnalysis.new(results: results, count: results.size))
        @telemetry.reset_session_count!
      end

      def model_id_from(chat)
        chat.model.respond_to?(:id) ? chat.model.id : chat.model.to_s
      end

      def last_content
        @chat.messages.reverse_each.lazy
          .select { |m| m.role == :assistant && m.content.to_s.strip.length > 0 }
          .first&.content.to_s
      end

      # Build the system context from typed sources.
      def build_system_context(prompt)
        sources = []
        sources << Ask::Agent::ContextSources::Instructions.new(prompt) if prompt

        # Auto-discover skills (shared + per-agent if agent_dir is given)
        @skills_registry = Ask::Skills.discover(agent_dir: @agent_dir) rescue nil
        if @skills_registry && !@skills_registry.names.empty?
          sources << Ask::Agent::ContextSources::SkillsList.new(@skills_registry)
          if @skills_registry.always_active_skills.any?
            sources << Ask::Agent::ContextSources::AlwaysActiveSkills.new(@skills_registry)
          end
        end

        SystemContext.new(sources)
      end

      # Recursively convert string keys to symbol keys in hashes.
      # Needed when loading session data that was serialized through JSON.
      # Resolve tool specs (symbols, strings, or classes) from a Definition
      # into instantiated tool objects. Symbols are looked up in the agent's
      # per-agent tools/ directory first, then shared tools, then the global
      # Ask::Tools registry.
      def self.resolve_definition_tools(tool_specs, dir)
        tools = []
        tool_specs.each do |spec|
          case spec
          when Symbol, String
            name = spec.to_s
            # Try per-agent tools directory
            agent_tool_path = File.join(dir, "tools", "#{name}.rb")
            if File.exist?(agent_tool_path)
              require agent_tool_path
            end

            resolved = Ask::Agent.resolve_tool_symbol(name)
            if resolved
              tool_class = resolved.is_a?(Class) ? resolved : Ask::Tools[name]
              tools << tool_class if tool_class
            end
          when Class
            tools << spec
          end
        end
        tools
      end

      def self.deep_symbolize_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize_keys(v) }
        when Array
          obj.map { |e| deep_symbolize_keys(e) }
        else
          obj
        end
      end

      # True when a persisted approval snapshot carries at least one pending
      # action. Used to decide whether Session.load should re-enable the
      # approval / plan queue — policy config itself is never persisted.
      def self.approval_snapshot_pending?(snapshot)
        return false unless snapshot.is_a?(Hash)

        pendings = snapshot[:pending_actions] || snapshot["pending_actions"]
        pendings.is_a?(Array) && !pendings.empty?
      end

      # Render the system context and apply it to the chat.
      def apply_system_context
        rendered = @system_context.render
        return if rendered.empty?
        return unless @chat.messages.any? { |m| m.role == :system }

        @chat.with_instructions(rendered)
      end
    end
  end
end
