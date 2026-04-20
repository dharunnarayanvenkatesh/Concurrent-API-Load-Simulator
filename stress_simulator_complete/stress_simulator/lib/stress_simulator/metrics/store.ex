defmodule StressSimulator.Metrics.Store do
  @moduledoc """
  High-performance ETS-backed metrics storage.

  Uses multiple ETS tables for different access patterns:
  - :counters table — atomic increment-friendly counters
  - :latencies table — raw latency samples (ring buffer semantics via limited size)
  - :timeseries table — per-second bucketed snapshots for charting

  ETS is chosen over Agent/GenServer state because:
  1. Reads are truly concurrent (no GenServer bottleneck)
  2. Thousands of workers can write simultaneously
  3. Sub-microsecond reads for dashboard queries
  """
  use GenServer
  require Logger

  @table_counters :ss_counters
  @table_latencies :ss_latencies
  @table_timeseries :ss_timeseries
  @table_snapshots :ss_snapshots

  # Keep last 10,000 latency samples for percentile calculation
  @max_latency_samples 10_000

  # Keep 120 seconds of timeseries data
  @max_timeseries_seconds 120

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Reset all metrics (called at simulation start)"
  def reset() do
    GenServer.call(__MODULE__, :reset)
  end

  @doc "Record a completed request result"
  def record_request(latency_ms, :ok) do
    now = System.system_time(:millisecond)
    :ets.update_counter(@table_counters, :total, 1, {:total, 0})
    :ets.update_counter(@table_counters, :success, 1, {:success, 0})
    insert_latency_sample(now, latency_ms, :success)
  end

  def record_request(latency_ms, :error) do
    now = System.system_time(:millisecond)
    :ets.update_counter(@table_counters, :total, 1, {:total, 0})
    :ets.update_counter(@table_counters, :failure, 1, {:failure, 0})
    insert_latency_sample(now, latency_ms, :error)
  end

  def record_request(_latency_ms, :timeout) do
    :ets.update_counter(@table_counters, :total, 1, {:total, 0})
    :ets.update_counter(@table_counters, :timeout, 1, {:timeout, 0})
    :ets.update_counter(@table_counters, :failure, 1, {:failure, 0})
  end

  @doc "Update active worker count"
  def set_active_workers(count) do
    :ets.insert(@table_counters, {:active_workers, count})
  end

  @doc "Read all current counters atomically"
  def get_counters() do
    keys = [:total, :success, :failure, :timeout, :active_workers]

    Enum.reduce(keys, %{}, fn key, acc ->
      val =
        case :ets.lookup(@table_counters, key) do
          [{^key, v}] -> v
          [] -> 0
        end

      Map.put(acc, key, val)
    end)
  end

  @doc "Compute latency percentiles from recent samples"
  def get_latency_stats() do
    samples =
      :ets.select(@table_latencies, [
        {{:_, :"$1", :success}, [], [:"$1"]}
      ])

    case samples do
      [] ->
        %{avg: 0, p50: 0, p95: 0, p99: 0, min: 0, max: 0, count: 0}

      latencies ->
        sorted = Enum.sort(latencies)
        count = length(sorted)
        avg = Enum.sum(sorted) / count

        %{
          avg: Float.round(avg, 2),
          p50: percentile(sorted, 50),
          p95: percentile(sorted, 95),
          p99: percentile(sorted, 99),
          min: List.first(sorted),
          max: List.last(sorted),
          count: count
        }
    end
  end

  @doc "Get timeseries data for the chart (last N seconds)"
  def get_timeseries(seconds \\ 60) do
    now_bucket = current_second_bucket()
    from_bucket = now_bucket - seconds

    :ets.select(@table_timeseries, [
      {{:"$1", :_, :_, :_}, [{:>=, :"$1", from_bucket}], [:"$_"]}
    ])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {ts, req_count, err_count, avg_lat} ->
      %{
        timestamp: ts,
        requests: req_count,
        errors: err_count,
        avg_latency: avg_lat
      }
    end)
  end

  @doc "Save a per-second snapshot (called by Aggregator)"
  def save_timeseries_snapshot(bucket, req_count, err_count, avg_latency) do
    :ets.insert(@table_timeseries, {bucket, req_count, err_count, avg_latency})
    # Prune old entries to prevent unbounded growth
    prune_old_timeseries(bucket - @max_timeseries_seconds)
  end

  ## Server callbacks

  @impl true
  def init([]) do
    create_tables()
    Logger.info("[MetricsStore] ETS tables initialized")
    {:ok, %{latency_counter: 0}}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    reset_tables()
    {:reply, :ok, %{latency_counter: 0}}
  end

  ## Private helpers

  defp create_tables() do
    # :public so workers can write directly without going through GenServer
    # :set for counters (unique keys), :bag would cause issues
    table_opts = [:named_table, :public, {:write_concurrency, true}, {:read_concurrency, true}]

    :ets.new(@table_counters, [:set | table_opts])
    # ordered_set gives us sorted latencies for percentile calculation
    :ets.new(@table_latencies, [:ordered_set | table_opts])
    :ets.new(@table_timeseries, [:ordered_set | table_opts])
    :ets.new(@table_snapshots, [:set | table_opts])

    # Initialize counters to 0
    for key <- [:total, :success, :failure, :timeout, :active_workers] do
      :ets.insert_new(@table_counters, {key, 0})
    end
  end

  defp reset_tables() do
    :ets.delete_all_objects(@table_counters)
    :ets.delete_all_objects(@table_latencies)
    :ets.delete_all_objects(@table_timeseries)

    for key <- [:total, :success, :failure, :timeout, :active_workers] do
      :ets.insert(@table_counters, {key, 0})
    end
  end

  defp insert_latency_sample(now, latency_ms, status) do
    # Use {timestamp, random} as key for uniqueness in ordered_set
    key = {now, :erlang.unique_integer([:monotonic])}
    :ets.insert(@table_latencies, {key, latency_ms, status})

    # Trim old samples if we exceed the ring buffer size
    # This is done probabilistically to avoid doing it on every write
    # Actual cleanup happens in Aggregator on each tick
  end

  defp prune_old_timeseries(cutoff_bucket) do
    # Delete all entries older than cutoff
    :ets.select_delete(@table_timeseries, [
      {{:"$1", :_, :_, :_}, [{:<, :"$1", cutoff_bucket}], [true]}
    ])
  end

  defp prune_old_latencies() do
    count = :ets.info(@table_latencies, :size)

    if count > @max_latency_samples do
      # Delete oldest entries (ordered_set, so first key = oldest)
      to_delete = count - @max_latency_samples

      :ets.first(@table_latencies)
      |> Stream.iterate(fn key -> :ets.next(@table_latencies, key) end)
      |> Enum.take(to_delete)
      |> Enum.each(&:ets.delete(@table_latencies, &1))
    end
  end

  # Called from Aggregator periodically
  def prune_latency_samples(), do: prune_old_latencies()

  defp percentile(sorted_list, p) when is_list(sorted_list) do
    count = length(sorted_list)
    idx = round(p / 100 * count) - 1
    idx = max(0, min(idx, count - 1))
    Enum.at(sorted_list, idx) || 0
  end

  defp current_second_bucket() do
    System.system_time(:second)
  end
end
