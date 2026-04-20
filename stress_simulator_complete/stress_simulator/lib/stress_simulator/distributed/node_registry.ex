defmodule StressSimulator.Distributed.NodeRegistry do
  @moduledoc """
  Tracks all connected worker nodes and their health state.

  Each worker node periodically sends a heartbeat. The registry
  marks nodes as :healthy, :degraded, or :disconnected based on
  heartbeat freshness.

  Why ETS + GenServer hybrid?
  - ETS for fast O(1) reads (dashboard polling, coordinator queries)
  - GenServer for serialized writes (heartbeat updates, registration)
  - Monitors for automatic cleanup when nodes crash/disconnect
  """
  use GenServer
  require Logger

  @table :node_registry
  @heartbeat_timeout_ms 10_000
  @check_interval_ms 2_000

  defstruct monitors: %{}   # node -> monitor_ref

  ## Client API

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def register_node(node, capabilities) do
    GenServer.call(__MODULE__, {:register, node, capabilities})
  end

  def heartbeat(node, stats) do
    GenServer.cast(__MODULE__, {:heartbeat, node, stats})
  end

  def list_nodes() do
    :ets.tab2list(@table)
    |> Enum.map(fn {node, info} -> Map.put(info, :node, node) end)
  end

  def healthy_nodes() do
    now = System.monotonic_time(:millisecond)

    :ets.select(@table, [
      {{:"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.filter(fn {_node, info} ->
      info.status == :healthy && (now - info.last_heartbeat_at) < @heartbeat_timeout_ms
    end)
    |> Enum.map(&elem(&1, 0))
  end

  def node_count(), do: length(healthy_nodes())

  def update_node_load(node, assigned_concurrency) do
    GenServer.cast(__MODULE__, {:update_load, node, assigned_concurrency})
  end

  ## Server callbacks

  @impl true
  def init([]) do
    :ets.new(@table, [:named_table, :public, {:read_concurrency, true}])
    Process.send_after(self(), :check_heartbeats, @check_interval_ms)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register, node, capabilities}, _from, state) do
    Logger.info("[NodeRegistry] Registering node: #{node}")

    info = %{
      node: node,
      status: :healthy,
      capabilities: capabilities,
      registered_at: System.monotonic_time(:millisecond),
      last_heartbeat_at: System.monotonic_time(:millisecond),
      assigned_concurrency: 0,
      stats: %{}
    }

    :ets.insert(@table, {node, info})

    # Monitor the node for disconnect detection
    monitor_ref = Node.monitor(node, true)
    new_monitors = Map.put(state.monitors, node, monitor_ref)

    {:reply, :ok, %{state | monitors: new_monitors}}
  end

  @impl true
  def handle_cast({:heartbeat, node, stats}, state) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, node) do
      [{^node, info}] ->
        updated = %{info | last_heartbeat_at: now, status: :healthy, stats: stats}
        :ets.insert(@table, {node, updated})

      [] ->
        Logger.warn("[NodeRegistry] Heartbeat from unknown node: #{node}")
    end

    {:noreply, state}
  end

  def handle_cast({:update_load, node, concurrency}, state) do
    case :ets.lookup(@table, node) do
      [{^node, info}] ->
        :ets.insert(@table, {node, %{info | assigned_concurrency: concurrency}})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:check_heartbeats, state) do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.each(fn {node, info} ->
      age = now - info.last_heartbeat_at

      cond do
        age > @heartbeat_timeout_ms * 3 ->
          Logger.warn("[NodeRegistry] Node #{node} timed out — removing")
          :ets.delete(@table, node)

        age > @heartbeat_timeout_ms ->
          :ets.insert(@table, {node, %{info | status: :disconnected}})

        age > @heartbeat_timeout_ms / 2 ->
          :ets.insert(@table, {node, %{info | status: :degraded}})

        true ->
          :ok
      end
    end)

    Process.send_after(self(), :check_heartbeats, @check_interval_ms)
    {:noreply, state}
  end

  # BEAM nodedown notification
  def handle_info({:nodedown, node}, state) do
    Logger.warn("[NodeRegistry] Node disconnected: #{node}")
    :ets.delete(@table, node)
    {:noreply, %{state | monitors: Map.delete(state.monitors, node)}}
  end

  def handle_info(_, state), do: {:noreply, state}
end
