defmodule StressSimulator.Metrics.Aggregator do
  @moduledoc """
  Periodic aggregator that:
  1. Reads raw ETS counters every @flush_interval ms
  2. Computes derived stats (RPS, percentiles, error rate)
  3. Snapshots per-second timeseries buckets for charting
  4. Detects backpressure conditions and signals Coordinator
  5. Broadcasts a full snapshot to LiveView via PubSub

  Runs on a 500ms tick. The sliding-window RPS calculation smooths
  out burst noise by averaging deltas over the last 5 seconds.
  """
  use GenServer
  require Logger

  alias StressSimulator.Metrics.Store
  alias StressSimulator.Simulation.Coordinator

  @pubsub StressSimulator.PubSub
  @metrics_topic "metrics:updates"
  @flush_interval 500

  ## Client API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def subscribe(), do: Phoenix.PubSub.subscribe(@pubsub, @metrics_topic)

  def get_latest() do
    case :ets.lookup(:ss_snapshots, :latest) do
      [{:latest, snap}] -> snap
      []                -> empty_snapshot()
    end
  end

  ## Server callbacks

  @impl true
  def init([]) do
    schedule_flush()
    {:ok, %{
      last_total:      0,
      last_failure:    0,
      last_tick_ms:    System.monotonic_time(:millisecond),
      # Sliding window: queue of {mono_ms, delta} for last 5s
      rps_window:      :queue.new(),
      current_second:  System.system_time(:second)
    }}
  end

  @impl true
  def handle_info(:flush, state) do
    {:noreply, compute_and_broadcast(state)}
  end

  ## Private

  defp compute_and_broadcast(state) do
    now_ms  = System.monotonic_time(:millisecond)
    now_sec = System.system_time(:second)
    elapsed_ms = max(now_ms - state.last_tick_ms, 1)

    counters      = Store.get_counters()
    latency_stats = Store.get_latency_stats()

    total   = counters.total
    delta   = max(total - state.last_total, 0)
    failure_delta = max(counters.failure - state.last_failure, 0)

    # Raw instantaneous RPS
    raw_rps = Float.round(delta / (elapsed_ms / 1_000), 1)

    # Smoothed RPS via 5-second sliding window
    rps_window   = update_rps_window(state.rps_window, now_ms, delta)
    smoothed_rps = compute_smoothed_rps(rps_window, now_ms)

    failure_rate =
      if total > 0, do: Float.round(counters.failure / total, 4), else: 0.0

    backpressure = check_backpressure(latency_stats, failure_rate)
    if backpressure != :none, do: Coordinator.backpressure_signal(backpressure)

    snapshot = %{
      timestamp:      now_sec,
      total_requests: total,
      success_count:  counters.success,
      failure_count:  counters.failure,
      timeout_count:  counters.timeout,
      active_workers: counters.active_workers,
      rps:            smoothed_rps,
      raw_rps:        raw_rps,
      failure_rate:   failure_rate,
      latency:        latency_stats,
      backpressure:   backpressure != :none
    }

    :ets.insert(:ss_snapshots, {:latest, snapshot})

    # Save timeseries bucket when the second rolls over
    if now_sec != state.current_second && delta > 0 do
      Store.save_timeseries_snapshot(
        state.current_second,
        delta,
        failure_delta,
        latency_stats.avg
      )
      # Prune latency ring buffer every 10 seconds
      if rem(now_sec, 10) == 0, do: Store.prune_latency_samples()
    end

    Phoenix.PubSub.broadcast(@pubsub, @metrics_topic, {:metrics_update, snapshot})

    schedule_flush()

    %{state |
      last_total:     total,
      last_failure:   counters.failure,
      last_tick_ms:   now_ms,
      rps_window:     rps_window,
      current_second: now_sec
    }
  end

  # ── Sliding window RPS ───────────────────────────────────────────────────────
  # Keeps (mono_ms, delta) pairs from the last 5 seconds.
  # On each tick we add the new delta and prune stale entries.

  defp update_rps_window(queue, now_ms, delta) do
    cutoff = now_ms - 5_000
    pruned = prune_before(queue, cutoff)
    :queue.in({now_ms, delta}, pruned)
  end

  defp prune_before(queue, cutoff) do
    case :queue.peek(queue) do
      {:value, {ts, _}} when ts < cutoff ->
        {_, rest} = :queue.out(queue)
        prune_before(rest, cutoff)
      _ ->
        queue
    end
  end

  defp compute_smoothed_rps(queue, now_ms) do
    case :queue.to_list(queue) do
      [] ->
        0.0

      items ->
        total_delta = Enum.sum(Enum.map(items, &elem(&1, 1)))
        oldest_ts   = items |> Enum.map(&elem(&1, 0)) |> Enum.min()
        elapsed_ms  = max(now_ms - oldest_ts, 1)
        Float.round(total_delta / (elapsed_ms / 1_000), 1)
    end
  end

  # ── Backpressure detection ───────────────────────────────────────────────────

  defp check_backpressure(latency_stats, failure_rate) do
    lat_threshold     = sim_cfg(:backpressure_latency_threshold_ms,  2_000)
    failure_threshold = sim_cfg(:backpressure_failure_rate_threshold, 0.3)

    cond do
      failure_rate          > failure_threshold    -> :reduce_concurrency
      latency_stats.p95     > lat_threshold * 2   -> :reduce_concurrency
      latency_stats.p95     > lat_threshold        -> :slow_down
      true                                         -> :none
    end
  end

  defp sim_cfg(key, default),
    do: Application.get_env(:stress_simulator, :simulation, [])[key] || default

  defp schedule_flush(),
    do: Process.send_after(self(), :flush, @flush_interval)

  def empty_snapshot() do
    %{
      timestamp:      System.system_time(:second),
      total_requests: 0,
      success_count:  0,
      failure_count:  0,
      timeout_count:  0,
      active_workers: 0,
      rps:            0.0,
      raw_rps:        0.0,
      failure_rate:   0.0,
      latency:        %{avg: 0, p50: 0, p95: 0, p99: 0, min: 0, max: 0, count: 0},
      backpressure:   false
    }
  end
end
