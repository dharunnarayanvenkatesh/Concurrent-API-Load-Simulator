defmodule StressSim.Metrics.Store do
  @moduledoc """
  High-performance metrics storage using ETS.

  Design decisions:
  - `:public` + `:write_concurrency` allows worker processes to write
    directly without going through a bottleneck GenServer.
  - `:read_concurrency` optimises the LiveView polling path.
  - Counters use `:ets.update_counter/4` which is atomic — safe for
    thousands of concurrent writers with no locking.
  - Raw latency samples are stored in a separate `:bag` table so we
    can compute percentiles without holding any lock.
  """
  use GenServer

  @table :stress_metrics
  @samples_table :stress_latency_samples
  @rps_table :stress_rps_window

  ## ── Public API ──────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Record a completed request."
  def record_request(sim_id, latency_ms, :ok) do
    :ets.update_counter(@table, {sim_id, :total}, 1, {{sim_id, :total}, 0})
    :ets.update_counter(@table, {sim_id, :success}, 1, {{sim_id, :success}, 0})
    :ets.insert(@samples_table, {sim_id, latency_ms, :os.system_time(:millisecond)})
    bump_rps(sim_id)
  end

  def record_request(sim_id, latency_ms, :error) do
    :ets.update_counter(@table, {sim_id, :total}, 1, {{sim_id, :total}, 0})
    :ets.update_counter(@table, {sim_id, :failure}, 1, {{sim_id, :failure}, 0})
    :ets.insert(@samples_table, {sim_id, latency_ms, :os.system_time(:millisecond)})
    bump_rps(sim_id)
  end

  @doc "Store the snapshot produced by Aggregator."
  def put_snapshot(sim_id, snapshot) do
    :ets.insert(@table, {{sim_id, :snapshot}, snapshot})
  end

  @doc "Retrieve the latest aggregated snapshot."
  def get_snapshot(sim_id) do
    case :ets.lookup(@table, {sim_id, :snapshot}) do
      [{_, snap}] -> snap
      [] -> empty_snapshot()
    end
  end

  @doc "Raw counters for Aggregator to compute deltas."
  def get_counters(sim_id) do
    total   = counter(sim_id, :total)
    success = counter(sim_id, :success)
    failure = counter(sim_id, :failure)
    %{total: total, success: success, failure: failure}
  end

  @doc "Pull latency samples from the last N ms and delete them."
  def drain_samples(sim_id, window_ms \\ 2_000) do
    cutoff = :os.system_time(:millisecond) - window_ms
    # Match samples for this sim_id newer than cutoff
    match = {sim_id, :"$1", :"$2"}
    guard = [{:>=, :"$2", cutoff}]
    samples = :ets.select(@samples_table, [{match, guard, [:"$1"]}])
    # Delete old ones
    old_match = {sim_id, :_, :"$2"}
    old_guard = [{:<, :"$2", cutoff}]
    :ets.select_delete(@samples_table, [{old_match, old_guard, [true]}])
    samples
  end

  @doc "Current RPS computed from sliding window counters."
  def get_rps(sim_id) do
    now_bucket = bucket_key(sim_id)
    prev_bucket = bucket_key(sim_id, -1)
    now_count  = rps_count(now_bucket)
    prev_count = rps_count(prev_bucket)
    # Average of current incomplete second + previous complete second
    (now_count + prev_count) / 2.0
  end

  @doc "Reset all metrics for a simulation."
  def reset(sim_id) do
    for key <- [:total, :success, :failure, :snapshot] do
      :ets.delete(@table, {sim_id, key})
    end
    :ets.match_delete(@samples_table, {sim_id, :_, :_})
  end

  @doc "Store arbitrary key/value for a simulation (e.g. active_workers)."
  def put(sim_id, key, value) do
    :ets.insert(@table, {{sim_id, key}, value})
  end

  def get(sim_id, key, default \\ nil) do
    case :ets.lookup(@table, {sim_id, key}) do
      [{_, v}] -> v
      [] -> default
    end
  end

  ## ── GenServer (table owner) ──────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@table, [
      :named_table, :set, :public,
      read_concurrency: true,
      write_concurrency: true
    ])
    :ets.new(@samples_table, [
      :named_table, :bag, :public,
      write_concurrency: true
    ])
    :ets.new(@rps_table, [
      :named_table, :set, :public,
      write_concurrency: true
    ])
    {:ok, %{}}
  end

  ## ── Private ──────────────────────────────────────────────────────────────

  defp counter(sim_id, key) do
    case :ets.lookup(@table, {sim_id, key}) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  defp bump_rps(sim_id) do
    key = bucket_key(sim_id)
    :ets.update_counter(@rps_table, key, 1, {key, 0})
  end

  defp bucket_key(sim_id, offset \\ 0) do
    sec = div(:os.system_time(:second) + offset, 1)
    {sim_id, :rps, sec}
  end

  defp rps_count(key) do
    case :ets.lookup(@rps_table, key) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  def empty_snapshot do
    %{
      total: 0, success: 0, failure: 0,
      avg_latency: 0.0, p95_latency: 0.0,
      rps: 0.0, active_workers: 0,
      rps_history: [], latency_history: [],
      error_rate: 0.0
    }
  end
end
