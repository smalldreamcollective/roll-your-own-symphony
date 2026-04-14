defmodule Symphony.Orchestrator do
  @moduledoc """
  The central GenServer. Owns all scheduling state.

  Responsibilities:
  - Poll tick: reconcile → validate → fetch candidates → dispatch
  - Claim/running/retry maps
  - Worker monitoring (via Process.monitor)
  - Retry scheduling with exponential backoff
  - Workflow hot-reload
  - Runtime snapshot for observability

  All state mutations happen inside this process — no concurrent writes.
  """

  use GenServer
  require Logger

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

  defmodule RunningEntry do
    defstruct [
      :issue_id,
      :identifier,
      :issue,
      :worker_pid,
      :monitor_ref,
      :session_id,
      :codex_app_server_pid,
      :last_codex_event,
      :last_codex_timestamp,
      :last_codex_message,
      :started_at,
      :retry_attempt,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      last_reported_input_tokens: 0,
      last_reported_output_tokens: 0,
      last_reported_total_tokens: 0,
      turn_count: 0,
      event_log: []
    ]
  end

  defmodule RetryEntry do
    defstruct [
      :issue_id,
      :identifier,
      :attempt,
      :due_at_ms,
      :timer_ref,
      :error
    ]
  end

  defmodule State do
    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :poll_timer_ref,
      running: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      completed: %{},
      pending_completion: %{},
      codex_totals: %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        seconds_running: 0.0
      },
      codex_rate_limits: nil
    ]
  end

  # ---------------------------------------------------------------------------
  # API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns a runtime snapshot for the status surface."
  def snapshot do
    GenServer.call(__MODULE__, :snapshot, 5_000)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc "Trigger an immediate poll + reconcile cycle."
  def trigger_refresh do
    send(__MODULE__, :tick)
    :ok
  end

  # ---------------------------------------------------------------------------
  # init
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    cfg = effective_cfg()

    state = %State{
      poll_interval_ms: Symphony.Config.poll_interval_ms(cfg),
      max_concurrent_agents: Symphony.Config.max_concurrent_agents(cfg)
    }

    case Symphony.Config.validate_for_dispatch(Symphony.WorkflowLoader.get()) do
      {:error, reason} ->
        # Log the error but don't crash the supervisor. The tick loop will
        # re-validate and skip dispatch until config becomes valid.
        Logger.error(
          "startup validation failed reason=#{inspect(reason)}, will retry on first tick"
        )

        state = schedule_tick(state, 0)
        {:ok, state}

      :ok ->
        startup_terminal_cleanup(cfg)
        state = schedule_tick(state, 0)
        {:ok, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call(:snapshot, _from, state) do
    active_seconds =
      state.running
      |> Enum.map(fn {_id, entry} ->
        started_ms = DateTime.to_unix(entry.started_at, :millisecond)
        max(0, (:erlang.system_time(:millisecond) - started_ms) / 1000)
      end)
      |> Enum.sum()

    totals = Map.update!(state.codex_totals, :seconds_running, &(&1 + active_seconds))

    running_rows =
      Enum.map(state.running, fn {_id, entry} ->
        %{
          issue_id: entry.issue_id,
          issue_identifier: entry.identifier,
          state: entry.issue.state,
          session_id: entry.session_id,
          turn_count: entry.turn_count,
          last_event: entry.last_codex_event,
          last_message: entry.last_codex_message,
          started_at: DateTime.to_iso8601(entry.started_at),
          last_event_at: entry.last_codex_timestamp,
          tokens: %{
            input_tokens: entry.codex_input_tokens,
            output_tokens: entry.codex_output_tokens,
            total_tokens: entry.codex_total_tokens
          },
          event_log: Enum.reverse(entry.event_log)
        }
      end)

    retrying_rows =
      Enum.map(state.retry_attempts, fn {_id, entry} ->
        due_at =
          entry.due_at_ms
          |> DateTime.from_unix!(:millisecond)
          |> DateTime.to_iso8601()

        %{
          issue_id: entry.issue_id,
          issue_identifier: entry.identifier,
          attempt: entry.attempt,
          due_at: due_at,
          error: entry.error
        }
      end)

    completed_rows =
      state.completed
      |> Map.values()
      |> Enum.sort_by(& &1.completed_at, :desc)

    snapshot = %{
      running: running_rows,
      retrying: retrying_rows,
      completed: completed_rows,
      codex_totals: totals,
      rate_limits: state.codex_rate_limits
    }

    {:reply, {:ok, snapshot}, state}
  end

  @impl true
  def handle_info(:tick, state) do
    cfg = effective_cfg()
    state = %{state | poll_timer_ref: nil}

    state = reconcile_running_issues(state, cfg)

    state =
      case Symphony.Config.validate_for_dispatch(Symphony.WorkflowLoader.get()) do
        {:error, reason} ->
          Logger.error("dispatch validation failed reason=#{inspect(reason)}, skipping dispatch")
          state

        :ok ->
          run_dispatch_cycle(state, cfg)
      end

    interval = Symphony.Config.poll_interval_ms(cfg)
    state = schedule_tick(%{state | poll_interval_ms: interval}, interval)
    {:noreply, state}
  end

  # Worker exited
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_running_by_monitor(state, ref) do
      nil ->
        {:noreply, state}

      {issue_id, entry} ->
        Logger.info(
          "worker exited issue_id=#{issue_id} issue_identifier=#{entry.identifier} reason=#{inspect(reason)}"
        )

        state = remove_running(state, issue_id, entry)

        state =
          case reason do
            :normal ->
              # Normal exit — stash stats for completion recording after retry confirms done
              Logger.debug("worker normal exit event_log_size=#{length(entry.event_log)}")
              pending = %{
                identifier: entry.identifier,
                turn_count: entry.turn_count,
                tokens: %{
                  input: entry.codex_input_tokens,
                  output: entry.codex_output_tokens,
                  total: entry.codex_total_tokens
                },
                event_log: Enum.reverse(entry.event_log)
              }

              state = Map.update!(state, :pending_completion, &Map.put(&1, issue_id, pending))

              schedule_retry(state, issue_id, 1, %{
                identifier: entry.identifier,
                delay_type: :continuation,
                error: nil
              })

            _ ->
              next_attempt = next_attempt_from(entry.retry_attempt)

              schedule_retry(state, issue_id, next_attempt, %{
                identifier: entry.identifier,
                error: "worker exited: #{inspect(reason)}"
              })
          end

        {:noreply, state}
    end
  end

  # Retry timer fired
  @impl true
  def handle_info({:retry_timer, issue_id}, state) do
    case Map.get(state.retry_attempts, issue_id) do
      nil ->
        {:noreply, state}

      retry_entry ->
        state = %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
        cfg = effective_cfg()
        state = handle_retry(state, retry_entry, cfg)
        {:noreply, state}
    end
  end

  # Codex event from worker
  @impl true
  def handle_info({:codex_event, issue_id, event}, state) do
    state = apply_codex_event(state, issue_id, event)
    {:noreply, state}
  end

  # Workflow hot-reload
  @impl true
  def handle_info({:workflow_reloaded, workflow_result}, state) do
    cfg =
      case workflow_result do
        {:ok, %{config: c}} -> c
        _ -> %{}
      end

    interval = Symphony.Config.poll_interval_ms(cfg)
    max_agents = Symphony.Config.max_concurrent_agents(cfg)

    Logger.info("workflow reloaded poll_interval_ms=#{interval} max_concurrent_agents=#{max_agents}")

    {:noreply, %{state | poll_interval_ms: interval, max_concurrent_agents: max_agents}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Reconciliation (spec §8.5)
  # ---------------------------------------------------------------------------

  defp reconcile_running_issues(state, cfg) do
    state = reconcile_stalled_runs(state, cfg)

    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Symphony.Tracker.fetch_issue_states_by_ids(cfg, running_ids) do
        {:error, reason} ->
          Logger.debug(
            "state refresh failed reason=#{inspect(reason)}, keeping workers running"
          )

          state

        {:ok, refreshed} ->
          terminal = Symphony.Config.tracker_terminal_states(cfg)
          active = Symphony.Config.tracker_active_states(cfg)

          Enum.reduce(refreshed, state, fn issue, acc ->
            state_lower = String.downcase(issue.state)

            cond do
              Enum.any?(terminal, &(String.downcase(&1) == state_lower)) ->
                terminate_running_issue(acc, issue.id, true, cfg)

              Enum.any?(active, &(String.downcase(&1) == state_lower)) ->
                update_running_issue(acc, issue.id, issue)

              true ->
                terminate_running_issue(acc, issue.id, false, cfg)
            end
          end)
      end
    end
  end

  defp reconcile_stalled_runs(state, cfg) do
    stall_timeout = Symphony.Config.stall_timeout_ms(cfg)

    if stall_timeout <= 0 do
      state
    else
      now_ms = :erlang.system_time(:millisecond)

      Enum.reduce(state.running, state, fn {issue_id, entry}, acc ->
        last_ts =
          if entry.last_codex_timestamp do
            parse_ts_ms(entry.last_codex_timestamp)
          else
            DateTime.to_unix(entry.started_at, :millisecond)
          end

        elapsed = now_ms - last_ts

        if elapsed > stall_timeout do
          Logger.warning(
            "stall detected issue_id=#{issue_id} issue_identifier=#{entry.identifier} elapsed_ms=#{elapsed}"
          )

          kill_worker(entry)

          schedule_retry(
            Map.update!(acc, :running, &Map.delete(&1, issue_id)),
            issue_id,
            next_attempt_from(entry.retry_attempt),
            %{identifier: entry.identifier, error: "stall timeout"}
          )
        else
          acc
        end
      end)
    end
  end

  defp terminate_running_issue(state, issue_id, cleanup_workspace, cfg) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      entry ->
        Logger.info(
          "terminating issue_id=#{issue_id} issue_identifier=#{entry.identifier} cleanup=#{cleanup_workspace}"
        )

        kill_worker(entry)

        if cleanup_workspace do
          workspace_path = Symphony.WorkspaceManager.path_for(entry.identifier, cfg)
          Symphony.WorkspaceManager.archive(workspace_path, cfg)
          Symphony.WorkspaceManager.remove(workspace_path, cfg)
        end

        completed_entry = %{
          issue_id: issue_id,
          identifier: entry.identifier,
          completed_at: DateTime.to_iso8601(DateTime.utc_now()),
          turn_count: entry.turn_count,
          tokens: %{
            input: entry.codex_input_tokens,
            output: entry.codex_output_tokens,
            total: entry.codex_total_tokens
          }
        }

        state
        |> remove_running(issue_id, entry)
        |> Map.update!(:claimed, &MapSet.delete(&1, issue_id))
        |> Map.update!(:completed, &Map.put(&1, entry.identifier, completed_entry))
    end
  end

  defp update_running_issue(state, issue_id, issue) do
    Map.update!(state, :running, fn running ->
      Map.update(running, issue_id, nil, fn entry ->
        %{entry | issue: issue}
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Dispatch (spec §8.2, §16.4)
  # ---------------------------------------------------------------------------

  defp run_dispatch_cycle(state, cfg) do
    case Symphony.Tracker.fetch_candidate_issues(cfg) do
      {:error, reason} ->
        Logger.error("candidate fetch failed reason=#{inspect(reason)}, skipping dispatch")
        state

      {:ok, issues} ->
        sorted = sort_for_dispatch(issues)

        Enum.reduce_while(sorted, state, fn issue, acc ->
          if available_slots(acc, cfg) == 0 do
            {:halt, acc}
          else
            if should_dispatch?(issue, acc, cfg) do
              {:cont, dispatch_issue(acc, issue, nil, cfg)}
            else
              {:cont, acc}
            end
          end
        end)
    end
  end

  defp sort_for_dispatch(issues) do
    Enum.sort(issues, fn a, b ->
      pa = priority_rank(a.priority)
      pb = priority_rank(b.priority)

      cond do
        pa != pb -> pa < pb
        a.created_at != b.created_at -> compare_dt(a.created_at, b.created_at)
        true -> a.identifier <= b.identifier
      end
    end)
  end

  defp priority_rank(nil), do: 999
  defp priority_rank(n) when is_integer(n), do: n

  defp compare_dt(nil, nil), do: true
  defp compare_dt(nil, _), do: false
  defp compare_dt(_, nil), do: true
  defp compare_dt(a, b), do: DateTime.compare(a, b) != :gt

  defp should_dispatch?(issue, state, cfg) do
    has_required = issue.id && issue.identifier && issue.title && issue.state

    active_states = Symphony.Config.tracker_active_states(cfg)
    terminal_states = Symphony.Config.tracker_terminal_states(cfg)
    state_lower = String.downcase(issue.state)

    is_active = Enum.any?(active_states, &(String.downcase(&1) == state_lower))
    is_terminal = Enum.any?(terminal_states, &(String.downcase(&1) == state_lower))

    not_running = not Map.has_key?(state.running, issue.id)
    not_claimed = not MapSet.member?(state.claimed, issue.id)

    blocker_ok = check_blockers(issue, terminal_states)

    has_required && is_active && not is_terminal && not_running && not_claimed && blocker_ok
  end

  defp check_blockers(issue, terminal_states) do
    if String.downcase(issue.state) == "todo" do
      Enum.all?(issue.blocked_by, fn b ->
        is_nil(b.state) or
          Enum.any?(terminal_states, &(String.downcase(&1) == String.downcase(b.state || "")))
      end)
    else
      true
    end
  end

  defp available_slots(state, cfg) do
    max_agents = Symphony.Config.max_concurrent_agents(cfg)
    max(max_agents - map_size(state.running), 0)
  end

  defp dispatch_issue(state, issue, attempt, cfg) do
    orchestrator = self()

    notify_fn = fn event ->
      send(orchestrator, {:codex_event, issue.id, event})
    end

    worker_pid =
      spawn(fn ->
        Symphony.Worker.run(issue, attempt, cfg, notify_fn)
      end)

    ref = Process.monitor(worker_pid)

    entry = %RunningEntry{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      worker_pid: worker_pid,
      monitor_ref: ref,
      session_id: nil,
      codex_app_server_pid: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil,
      last_codex_message: nil,
      started_at: DateTime.utc_now(),
      retry_attempt: normalize_attempt(attempt)
    }

    Logger.info(
      "dispatched issue_id=#{issue.id} issue_identifier=#{issue.identifier} attempt=#{inspect(attempt)} worker_pid=#{inspect(worker_pid)}"
    )

    state
    |> Map.update!(:running, &Map.put(&1, issue.id, entry))
    |> Map.update!(:claimed, &MapSet.put(&1, issue.id))
    |> Map.update!(:retry_attempts, &Map.delete(&1, issue.id))
  end

  # ---------------------------------------------------------------------------
  # Retry scheduling (spec §8.4)
  # ---------------------------------------------------------------------------

  defp schedule_retry(state, issue_id, attempt, opts) do
    # Cancel existing timer
    state =
      case Map.get(state.retry_attempts, issue_id) do
        nil -> state
        existing -> cancel_retry_timer(state, existing)
      end

    cfg = effective_cfg()
    delay_ms = compute_retry_delay(attempt, opts[:delay_type], cfg)
    due_at_ms = :erlang.system_time(:millisecond) + delay_ms

    timer_ref =
      Process.send_after(self(), {:retry_timer, issue_id}, delay_ms)

    entry = %RetryEntry{
      issue_id: issue_id,
      identifier: opts[:identifier] || issue_id,
      attempt: attempt,
      due_at_ms: due_at_ms,
      timer_ref: timer_ref,
      error: opts[:error]
    }

    Logger.info(
      "retry scheduled issue_id=#{issue_id} attempt=#{attempt} delay_ms=#{delay_ms} error=#{inspect(opts[:error])}"
    )

    Map.update!(state, :retry_attempts, &Map.put(&1, issue_id, entry))
  end

  defp compute_retry_delay(1, :continuation, _cfg), do: 1_000
  defp compute_retry_delay(_attempt, :continuation, _cfg), do: 1_000

  defp compute_retry_delay(attempt, _type, cfg) do
    max_backoff = Symphony.Config.max_retry_backoff_ms(cfg)
    delay = 10_000 * :math.pow(2, attempt - 1) |> round()
    min(delay, max_backoff)
  end

  defp cancel_retry_timer(state, entry) do
    Process.cancel_timer(entry.timer_ref)
    Map.update!(state, :retry_attempts, &Map.delete(&1, entry.issue_id))
  end

  defp handle_retry(state, retry_entry, cfg) do
    case Symphony.Tracker.fetch_candidate_issues(cfg) do
      {:error, reason} ->
        Logger.error(
          "retry poll failed issue_id=#{retry_entry.issue_id} reason=#{inspect(reason)}"
        )

        schedule_retry(state, retry_entry.issue_id, retry_entry.attempt + 1, %{
          identifier: retry_entry.identifier,
          error: "retry poll failed: #{inspect(reason)}"
        })

      {:ok, candidates} ->
        issue = Enum.find(candidates, &(&1.id == retry_entry.issue_id))

        if is_nil(issue) do
          Logger.info(
            "releasing claim issue_id=#{retry_entry.issue_id} reason=not_found_in_candidates"
          )

          pending = Map.get(state.pending_completion, retry_entry.issue_id) || %{}

          completed_entry = %{
            issue_id: retry_entry.issue_id,
            identifier: retry_entry.identifier,
            completed_at: DateTime.to_iso8601(DateTime.utc_now()),
            turn_count: pending[:turn_count] || 0,
            tokens: pending[:tokens] || %{input: 0, output: 0, total: 0},
            event_log: pending[:event_log] || []
          }

          workspace_path = Symphony.WorkspaceManager.path_for(retry_entry.identifier, cfg)
          Symphony.WorkspaceManager.archive(workspace_path, cfg)
          Symphony.WorkspaceManager.remove(workspace_path, cfg)

          state
          |> Map.update!(:claimed, &MapSet.delete(&1, retry_entry.issue_id))
          |> Map.update!(:pending_completion, &Map.delete(&1, retry_entry.issue_id))
          |> Map.update!(:completed, &Map.put(&1, retry_entry.identifier, completed_entry))
        else
          if available_slots(state, cfg) == 0 do
            schedule_retry(state, retry_entry.issue_id, retry_entry.attempt + 1, %{
              identifier: retry_entry.identifier,
              error: "no available orchestrator slots"
            })
          else
            dispatch_issue(state, issue, retry_entry.attempt, cfg)
          end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Codex event application
  # ---------------------------------------------------------------------------

  defp apply_codex_event(state, issue_id, event) do
    case Map.get(state.running, issue_id) do
      nil ->
        state

      entry ->
        entry = %{
          entry
          | last_codex_event: event[:event] || event["event"],
            last_codex_timestamp: event[:timestamp] || event["timestamp"],
            last_codex_message: event[:message] || event["message"],
            codex_app_server_pid: event[:codex_app_server_pid] || entry.codex_app_server_pid
        }

        entry =
          if (event[:event] || event["event"]) == "session_started" do
            if event[:session_id] || event["session_id"] do
              %{entry | session_id: event[:session_id] || event["session_id"]}
            else
              entry
            end
          else
            entry
          end

        entry =
          if (event[:event] || event["event"]) in ["turn_completed", "session_started"] do
            %{entry | turn_count: entry.turn_count + 1}
          else
            entry
          end

        entry = update_token_counts(entry, event)

        log_entry = Map.take(event, [:event, :timestamp, :message, :tool, :command, :output, :elapsed_ms, :turn, :error, "event", "timestamp", "message", "tool", "command", "output", "elapsed_ms", "turn", "error"])
        event_log = Enum.take([log_entry | entry.event_log], 200)
        entry = %{entry | event_log: event_log}

        state = Map.update!(state, :running, &Map.put(&1, issue_id, entry))

        # Update aggregate rate limits if present
        if rl = event[:rate_limits] || event["rate_limits"] do
          %{state | codex_rate_limits: rl}
        else
          state
        end
    end
  end

  defp update_token_counts(entry, event) do
    usage = event[:usage] || event["usage"]

    if is_map(usage) do
      input = usage["input_tokens"] || usage[:input_tokens] || 0
      output = usage["output_tokens"] || usage[:output_tokens] || 0
      total = usage["total_tokens"] || usage[:total_tokens] || 0

      # Use delta relative to last reported to avoid double-counting
      delta_in = max(input - entry.last_reported_input_tokens, 0)
      delta_out = max(output - entry.last_reported_output_tokens, 0)
      delta_total = max(total - entry.last_reported_total_tokens, 0)

      %{
        entry
        | codex_input_tokens: entry.codex_input_tokens + delta_in,
          codex_output_tokens: entry.codex_output_tokens + delta_out,
          codex_total_tokens: entry.codex_total_tokens + delta_total,
          last_reported_input_tokens: input,
          last_reported_output_tokens: output,
          last_reported_total_tokens: total
      }
    else
      entry
    end
  end

  # ---------------------------------------------------------------------------
  # Startup terminal cleanup (spec §8.6)
  # ---------------------------------------------------------------------------

  defp startup_terminal_cleanup(cfg) do
    terminal_states = Symphony.Config.tracker_terminal_states(cfg)

    case Symphony.Tracker.fetch_issues_by_states(cfg, terminal_states) do
      {:error, reason} ->
        Logger.warning("startup terminal cleanup fetch failed reason=#{inspect(reason)}, continuing")

      {:ok, issues} ->
        Enum.each(issues, fn issue ->
          path = Symphony.WorkspaceManager.path_for(issue.identifier, cfg)

          if File.dir?(path) do
            Logger.info(
              "startup cleanup removing terminal workspace issue_identifier=#{issue.identifier} path=#{path}"
            )

            Symphony.WorkspaceManager.remove(path, cfg)
          end
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp schedule_tick(state, delay_ms) do
    if state.poll_timer_ref do
      Process.cancel_timer(state.poll_timer_ref)
    end

    ref = Process.send_after(self(), :tick, delay_ms)
    %{state | poll_timer_ref: ref}
  end

  defp find_running_by_monitor(state, ref) do
    Enum.find(state.running, fn {_id, entry} -> entry.monitor_ref == ref end)
  end

  defp remove_running(state, issue_id, entry) do
    started_ms = DateTime.to_unix(entry.started_at, :millisecond)
    elapsed_s = max(0, (:erlang.system_time(:millisecond) - started_ms) / 1000)

    state
    |> Map.update!(:running, &Map.delete(&1, issue_id))
    |> Map.update!(:codex_totals, fn totals ->
      %{
        totals
        | input_tokens: totals.input_tokens + entry.codex_input_tokens,
          output_tokens: totals.output_tokens + entry.codex_output_tokens,
          total_tokens: totals.total_tokens + entry.codex_total_tokens,
          seconds_running: totals.seconds_running + elapsed_s
      }
    end)
  end

  defp kill_worker(entry) do
    if Process.alive?(entry.worker_pid) do
      Process.exit(entry.worker_pid, :kill)
    end
  end

  defp normalize_attempt(nil), do: 0
  defp normalize_attempt(n) when is_integer(n), do: n

  defp next_attempt_from(0), do: 1
  defp next_attempt_from(n), do: n + 1

  defp effective_cfg do
    case Symphony.WorkflowLoader.get() do
      {:ok, %{config: cfg}} -> cfg
      _ -> %{}
    end
  end

  defp parse_ts_ms(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> :erlang.system_time(:millisecond)
    end
  end
end
