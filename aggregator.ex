defmodule StressSim.Metrics.Aggregator do
  @moduledoc """
  Periodic aggregator that computes windowed statistics from raw ETS data.

  Runs every 500ms, computing:
  - avg / p95 latency from recent samples
  - rolling RPS
  - success/failure rates

  Publishes to Phoenix.PubSub so LiveView subscribers get push updates
  without polling — true real-time streaming.

  History is kept as a fixed-length ring buffer (last 60 data points)
  stored directly in the snapshot so the LiveView needs no extra state.
  """
  use GenServer

  alias StressSim.Metrics.Store

  @interval_ms 500
  @history_size 60

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    aggregate_all_simulations()
    schedule_tick()
    {:noreply, state}
  end

  ## ── Aggregation ──────────────────────────────────────────────────────────

  defp aggregate_all_simulations do
    # Find all active simulation IDs by scanning ETS for active_workers keys
    sim_ids =
      :ets.select(:stress_metrics, [
        {{{:"$1", :active_workers}, :_}, [], [:"$1"]}
      ])

    Enum.each(sim_ids, &aggregate_simulation/1)
  end

  defp aggregate_simulation(sim_id) do
    counters = Store.get_counters(sim_id)
    samples  = Store.drain_samples(sim_id, 2_000)
    rps      = Store.get_rps(sim_id)
    workers  = Store.get(sim_id, :active_workers, 0)

    {avg, p95} = compute_latency_stats(samples)

    # Retrieve previous snapshot to append to history rings
    prev = Store.get_snapshot(sim_id)

    error_rate =
      if counters.total > 0,
        do: counters.failure / counters.total * 100,
        else: 0.0

    snapshot = %{
      total:          counters.total,
      success:        counters.success,
      failure:        counters.failure,
      avg_latency:    avg,
      p95_latency:    p95,
      rps:            Float.round(rps, 1),
      active_workers: workers,
      error_rate:     Float.round(error_rate, 2),
      rps_history:    ring_push(Map.get(prev, :rps_history, []), rps),
      latency_history: ring_push(Map.get(prev, :latency_history, []), avg)
    }

    Store.put_snapshot(sim_id, snapshot)

    # Broadcast to all LiveView subscribers — no polling needed
    Phoenix.PubSub.broadcast(
      StressSim.PubSub,
      "metrics:#{sim_id}",
      {:metrics_update, snapshot}
    )
  end

  ## ── Statistics ───────────────────────────────────────────────────────────

  defp compute_latency_stats([]), do: {0.0, 0.0}

  defp compute_latency_stats(samples) do
    sorted = Enum.sort(samples)
    count  = length(sorted)
    avg    = Enum.sum(sorted) / count

    p95_idx = max(0, round(count * 0.95) - 1)
    p95     = Enum.at(sorted, p95_idx, 0)

    {Float.round(avg, 2), Float.round(p95 * 1.0, 2)}
  end

  ## ── Ring Buffer ──────────────────────────────────────────────────────────

  defp ring_push(list, value) do
    updated = list ++ [value]
    if length(updated) > @history_size,
      do: tl(updated),
      else: updated
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @interval_ms)
  end
end
