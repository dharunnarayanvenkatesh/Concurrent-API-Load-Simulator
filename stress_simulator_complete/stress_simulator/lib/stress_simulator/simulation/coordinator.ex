defmodule StressSimulator.Simulation.Coordinator do
  @moduledoc """
  Central simulation state machine.

  State transitions:
    :idle    -> :running  (start)
    :running -> :paused   (pause)
    :paused  -> :running  (resume)
    :running/:paused -> :idle (stop)

  Delegates ramp scheduling to RampScheduler (which calls
  adjust_concurrency/1 on each ramp tick). Passes jitter config
  through to each spawned worker task.

  The dispatch loop fires every @scheduler_interval ms and spawns
  Task.async workers up to (effective_concurrency - active_count).
  Workers report back via normal message passing: {ref, result} on
  success, {:DOWN, ref, ...} on crash.
  """
  use GenServer
  require Logger

  alias StressSimulator.Simulation.{Worker, RampScheduler}
  alias StressSimulator.Metrics.Store

  @pubsub StressSimulator.PubSub
  @status_topic "simulation:status"

  defstruct [
    :config,
    status:               :idle,
    active_refs:          %{},          # ref -> pid
    effective_concurrency: 0,
    backpressure_count:   0,
    circuit_state:        :closed,      # :closed | :open | :half_open
    circuit_failure_count: 0,
    circuit_open_at:      nil,
    scheduler_ref:        nil,
    scheduler_interval:   100           # ms between dispatch ticks
  ]

  ## ── Client API ──────────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def start_simulation(config),      do: GenServer.call(__MODULE__, {:start, config}, 10_000)
  def stop_simulation(),             do: GenServer.call(__MODULE__, :stop)
  def pause_simulation(),            do: GenServer.call(__MODULE__, :pause)
  def resume_simulation(),           do: GenServer.call(__MODULE__, :resume)
  def get_status(),                  do: GenServer.call(__MODULE__, :get_status)
  def adjust_concurrency(n),         do: GenServer.cast(__MODULE__, {:adjust_concurrency, n})
  def backpressure_signal(sig),      do: GenServer.cast(__MODULE__, {:backpressure, sig})

  ## ── Server callbacks ────────────────────────────────────────────────────────

  @impl true
  def init([]), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:start, config}, _from, %{status: :idle} = state) do
    validated = validate_config(config)
    Logger.info("[Coordinator] Starting simulation — #{inspect(validated)}")
    Store.reset()

    # If a ramp is configured the RampScheduler will call adjust_concurrency/1
    # on each tick. Without ramp we start at full concurrency immediately.
    initial_concurrency =
      case Map.get(validated, :ramp) do
        nil  -> validated.concurrency
        ramp ->
          RampScheduler.start_ramp(ramp)
          ramp.start_concurrency
      end

    new_state = %{state |
      config:                validated,
      status:                :running,
      effective_concurrency: initial_concurrency,
      backpressure_count:    0,
      circuit_state:         :closed,
      circuit_failure_count: 0,
      active_refs:           %{}
    }

    new_state = schedule_batch(new_state)
    broadcast_status(new_state)
    {:reply, {:ok, validated}, new_state}
  end

  def handle_call({:start, _}, _from, state),
    do: {:reply, {:error, "Simulation already #{state.status}"}, state}

  def handle_call(:stop, _from, state) do
    try do RampScheduler.stop_ramp() rescue _ -> :ok end
    new_state = do_stop(state)
    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:pause, _from, %{status: :running} = state) do
    if state.scheduler_ref, do: Process.cancel_timer(state.scheduler_ref)
    new_state = %{state | status: :paused, scheduler_ref: nil}
    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:pause, _from, state),
    do: {:reply, {:error, "Not running"}, state}

  def handle_call(:resume, _from, %{status: :paused} = state) do
    new_state = schedule_batch(%{state | status: :running})
    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:resume, _from, state),
    do: {:reply, {:error, "Not paused"}, state}

  def handle_call(:get_status, _from, state) do
    {:reply, %{
      status:                state.status,
      circuit_state:         state.circuit_state,
      effective_concurrency: state.effective_concurrency,
      config:                state.config
    }, state}
  end

  ## ── Casts ───────────────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:adjust_concurrency, n}, state) do
    max_c   = sim_cfg(:max_concurrency, 2000)
    clamped = min(max(n, 0), max_c)
    config  = if state.config, do: %{state.config | concurrency: clamped}, else: state.config
    {:noreply, %{state | effective_concurrency: clamped, config: config}}
  end

  def handle_cast({:backpressure, sig}, %{status: :running} = state),
    do: {:noreply, apply_backpressure(sig, state)}

  def handle_cast({:backpressure, _}, state), do: {:noreply, state}

  ## ── Info ────────────────────────────────────────────────────────────────────

  @impl true
  # Main dispatch loop
  def handle_info(:dispatch_batch, %{status: :running} = state) do
    state     = maybe_reset_circuit_breaker(state)
    new_state = case state.circuit_state do
      :open -> state   # Circuit open — skip this batch
      _     -> dispatch_batch(state)
    end
    {:noreply, schedule_batch(new_state)}
  end

  def handle_info(:dispatch_batch, state), do: {:noreply, state}

  # Task completed normally
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_worker_result(ref, result, state)}
  end

  # Task process died
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    unless reason == :normal,
      do: Logger.debug("[Coordinator] Worker down: #{inspect(reason)}")
    new_refs = Map.delete(state.active_refs, ref)
    Store.set_active_workers(map_size(new_refs))
    {:noreply, %{state | active_refs: new_refs}}
  end

  def handle_info(_, state), do: {:noreply, state}

  ## ── Private: dispatch ───────────────────────────────────────────────────────

  defp dispatch_batch(%{config: nil} = state), do: state

  defp dispatch_batch(%{config: config, effective_concurrency: eff, active_refs: refs} = state) do
    slots = max(eff - map_size(refs), 0)
    batch = min(slots, batch_size(state))

    if batch > 0 do
      jitter   = Map.get(config, :jitter, :none)
      url      = config.url
      timeout  = config.timeout_ms

      # Spawn batch workers as Task.async — BEAM cheaply handles thousands.
      # We capture {ref, pid} so we can track completion and crash separately.
      new_refs =
        for _ <- 1..batch, into: %{} do
          task = Task.async(fn ->
            Worker.execute_request(url, timeout, jitter: jitter)
          end)
          {task.ref, task.pid}
        end

      updated = Map.merge(refs, new_refs)
      Store.set_active_workers(map_size(updated))
      %{state | active_refs: updated}
    else
      state
    end
  end

  # How many new workers to spawn per tick.
  # When request_rate is set we pace spawning to hit the RPS target;
  # otherwise we fill available slots as fast as possible (50/tick max).
  defp batch_size(%{config: %{request_rate: :unlimited}}),     do: 50
  defp batch_size(%{config: %{request_rate: rps}, scheduler_interval: iv})
    when is_integer(rps) and rps > 0,
    do: max(round(rps * (iv / 1_000)), 1)
  defp batch_size(_), do: 20

  ## ── Private: worker results ─────────────────────────────────────────────────

  defp handle_worker_result(ref, {:ok, lat}, state) do
    Store.record_request(lat, :ok)
    %{maybe_heal_circuit(state) | active_refs: Map.delete(state.active_refs, ref)}
  end

  defp handle_worker_result(ref, {:error, :timeout, lat}, state) do
    Store.record_request(lat, :timeout)
    %{trip_circuit(state) | active_refs: Map.delete(state.active_refs, ref)}
  end

  defp handle_worker_result(ref, {:error, _reason, lat}, state) do
    Store.record_request(lat, :error)
    %{trip_circuit(state) | active_refs: Map.delete(state.active_refs, ref)}
  end

  defp handle_worker_result(ref, _other, state),
    do: %{state | active_refs: Map.delete(state.active_refs, ref)}

  ## ── Private: circuit breaker ────────────────────────────────────────────────

  # A success during half-open closes the circuit.
  defp maybe_heal_circuit(%{circuit_state: :half_open} = state) do
    Logger.info("[CircuitBreaker] Probe succeeded → CLOSED")
    %{state | circuit_state: :closed, circuit_failure_count: 0}
  end

  defp maybe_heal_circuit(state),
    do: %{state | circuit_failure_count: max(state.circuit_failure_count - 1, 0)}

  # A failure during half-open re-opens the circuit.
  defp trip_circuit(%{circuit_state: :half_open} = state) do
    Logger.warn("[CircuitBreaker] Probe failed → re-OPEN")
    %{state | circuit_state: :open, circuit_open_at: mono_ms()}
  end

  defp trip_circuit(state) do
    threshold = sim_cfg(:circuit_breaker_threshold, 10)
    count     = state.circuit_failure_count + 1

    if count >= threshold && state.circuit_state == :closed do
      Logger.warn("[CircuitBreaker] #{count} failures → OPEN")
      %{state | circuit_state: :open, circuit_failure_count: count, circuit_open_at: mono_ms()}
    else
      %{state | circuit_failure_count: count}
    end
  end

  defp maybe_reset_circuit_breaker(%{circuit_state: :open, circuit_open_at: at} = state) do
    reset = sim_cfg(:circuit_breaker_reset_ms, 10_000)
    if mono_ms() - at > reset do
      Logger.info("[CircuitBreaker] Timeout elapsed → HALF-OPEN probe")
      %{state | circuit_state: :half_open}
    else
      state
    end
  end

  defp maybe_reset_circuit_breaker(state), do: state

  ## ── Private: backpressure ───────────────────────────────────────────────────

  defp apply_backpressure(:reduce_concurrency, state) do
    count = state.backpressure_count + 1
    if count >= 2 do
      new_c = max(round(state.effective_concurrency * 0.75), 1)
      Logger.warn("[Backpressure] #{state.effective_concurrency} → #{new_c} (reduce)")
      %{state | effective_concurrency: new_c, backpressure_count: 0}
    else
      %{state | backpressure_count: count}
    end
  end

  defp apply_backpressure(:slow_down, state) do
    new_c = max(round(state.effective_concurrency * 0.9), 1)
    Logger.debug("[Backpressure] #{state.effective_concurrency} → #{new_c} (slow down)")
    %{state | effective_concurrency: new_c, backpressure_count: 0}
  end

  ## ── Private: scheduling ─────────────────────────────────────────────────────

  # Pace the dispatch interval to approximately hit the configured RPS.
  defp schedule_batch(%{config: %{request_rate: rps}} = state)
       when is_integer(rps) and rps > 0 do
    # interval = 1000ms / (rps / concurrency) — clamped [10, 1000] ms
    eff = max(state.effective_concurrency, 1)
    iv  = round(1_000 / max(rps / eff, 1)) |> max(10) |> min(1_000)
    ref = Process.send_after(self(), :dispatch_batch, iv)
    %{state | scheduler_ref: ref, scheduler_interval: iv}
  end

  defp schedule_batch(state) do
    ref = Process.send_after(self(), :dispatch_batch, 100)
    %{state | scheduler_ref: ref, scheduler_interval: 100}
  end

  ## ── Private: stop ───────────────────────────────────────────────────────────

  defp do_stop(state) do
    if state.scheduler_ref, do: Process.cancel_timer(state.scheduler_ref)
    Store.set_active_workers(0)
    %{state |
      status:                :idle,
      active_refs:           %{},
      scheduler_ref:         nil,
      config:                nil,
      effective_concurrency: 0
    }
  end

  ## ── Private: config validation ──────────────────────────────────────────────

  defp validate_config(cfg) do
    max_c = sim_cfg(:max_concurrency, 2000)

    concurrency = min(
      cfg[:concurrency] || cfg["concurrency"] || 100,
      max_c
    )

    base = %{
      url:              cfg[:url]          || cfg["url"]          || "http://localhost:4001/api/mock",
      concurrency:      concurrency,
      request_rate:     cfg[:request_rate] || cfg["request_rate"] || :unlimited,
      timeout_ms:       cfg[:timeout_ms]   || cfg["timeout_ms"]   || 5_000,
      duration_seconds: cfg[:duration_seconds] || cfg["duration_seconds"] || nil
    }

    base = case cfg[:jitter] || cfg["jitter"] do
      nil     -> base
      "none"  -> base
      j       -> Map.put(base, :jitter, normalize_jitter(j))
    end

    case cfg[:ramp] || cfg["ramp"] do
      nil -> base
      r   -> Map.put(base, :ramp, normalize_ramp(r, concurrency))
    end
  end

  defp normalize_jitter(%{distribution: _} = j), do: j
  defp normalize_jitter(%{"distribution" => dist} = j) do
    %{
      distribution: String.to_existing_atom(dist),
      min_ms:       j["min_ms"] || 0,
      max_ms:       j["max_ms"] || 500
    }
  end
  defp normalize_jitter(_), do: :none

  defp normalize_ramp(ramp, peak_fallback) do
    %{
      profile:           ramp[:profile]           || ramp["profile"]           || "linear",
      ramp_up_seconds:   ramp[:ramp_up_seconds]   || ramp["ramp_up_seconds"]   || 30,
      sustain_seconds:   ramp[:sustain_seconds]    || ramp["sustain_seconds"]   || 0,
      ramp_down_seconds: ramp[:ramp_down_seconds]  || ramp["ramp_down_seconds"] || 0,
      peak_concurrency:  ramp[:peak_concurrency]   || ramp["peak_concurrency"]  || peak_fallback,
      start_concurrency: ramp[:start_concurrency]  || ramp["start_concurrency"] || 1,
      step_count:        ramp[:step_count]          || ramp["step_count"]        || 10
    }
  end

  defp broadcast_status(state) do
    Phoenix.PubSub.broadcast(@pubsub, @status_topic, {:status_update, %{
      status:                state.status,
      circuit_state:         state.circuit_state,
      effective_concurrency: state.effective_concurrency,
      config:                state.config
    }})
  end

  defp sim_cfg(key, default),
    do: Application.get_env(:stress_simulator, :simulation, [])[key] || default

  defp mono_ms(), do: System.monotonic_time(:millisecond)
end
