defmodule StressSimulator.Distributed.MasterOrchestrator do
  @moduledoc """
  Master node orchestrator for distributed load generation.

  ## Architecture

  ```
  Master Node
  ├── MasterOrchestrator   ← this module, runs only on master
  │   ├── NodeRegistry     ← tracks all connected workers
  │   └── dispatch loop    ← assigns concurrency quotas to nodes
  │
  Worker Node 1            ← connected via Erlang distribution
  ├── WorkerAgent          ← receives quota, runs local workers
  └── MetricsReporter      ← streams metrics back to master
  │
  Worker Node 2
  └── ...
  ```

  ## How quota distribution works

  Total configured concurrency is split proportionally across
  healthy nodes. If node A goes down mid-run, its quota is
  redistributed to remaining nodes automatically.

  Example: 1000 concurrency across 3 nodes → ~333 each.
  If node 3 dies → master detects via NodeRegistry and
  rebalances: nodes 1 and 2 get 500 each.

  ## Why Erlang distribution instead of HTTP?

  Erlang's built-in distribution protocol gives us:
  - Sub-millisecond RPC between nodes
  - Automatic node monitoring (:nodedown events)
  - Native process linking across nodes
  - No serialization overhead for small messages
  - Transparent message passing (same API as local)

  The tradeoff: nodes must be on the same network and use
  the same Erlang cookie. For cloud deployments, use a VPN
  or Kubernetes pod network.
  """
  use GenServer
  require Logger

  alias StressSimulator.Distributed.NodeRegistry
  alias StressSimulator.Metrics.Store

  @pubsub StressSimulator.PubSub
  @rebalance_interval_ms 3_000

  defstruct [
    :config,
    :rebalance_ref,
    status: :idle,
    # node -> assigned concurrency
    node_quotas: %{},
    # Aggregated remote metrics
    remote_metrics: %{}
  ]

  ## Client API

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Start a distributed simulation. Config is the same as local simulation
  but concurrency is the TOTAL across all nodes.
  """
  def start_distributed(config) do
    GenServer.call(__MODULE__, {:start, config}, 15_000)
  end

  def stop_distributed() do
    GenServer.call(__MODULE__, :stop)
  end

  def get_status() do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc "Called by worker nodes to report their local metrics to master"
  def report_metrics(node, metrics) do
    GenServer.cast(__MODULE__, {:metrics_from_node, node, metrics})
  end

  ## Server callbacks

  @impl true
  def init([]) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:start, config}, _from, %{status: :idle} = state) do
    nodes = NodeRegistry.healthy_nodes()

    case nodes do
      [] ->
        Logger.warn("[MasterOrchestrator] No worker nodes connected — falling back to local")
        # Graceful degradation: run locally if no workers
        StressSimulator.Simulation.Coordinator.start_simulation(config)
        {:reply, {:ok, :local_fallback}, state}

      worker_nodes ->
        Logger.info("[MasterOrchestrator] Distributing to #{length(worker_nodes)} nodes")
        quotas = distribute_concurrency(config[:concurrency] || 100, worker_nodes)

        # Push config + quota to each worker node via RPC
        Enum.each(quotas, fn {node, quota} ->
          worker_config = Map.merge(config, %{concurrency: quota})
          rpc_async(node, StressSimulator.Distributed.WorkerAgent, :start_local, [worker_config])
          NodeRegistry.update_node_load(node, quota)
        end)

        ref = Process.send_after(self(), :rebalance, @rebalance_interval_ms)

        new_state = %{
          state
          | config: config,
            status: :running,
            node_quotas: quotas,
            rebalance_ref: ref
        }

        broadcast_status(new_state)
        {:reply, {:ok, :distributed}, new_state}
    end
  end

  def handle_call({:start, _}, _from, state),
    do: {:reply, {:error, "Already #{state.status}"}, state}

  def handle_call(:stop, _from, state) do
    if state.rebalance_ref, do: Process.cancel_timer(state.rebalance_ref)

    # Stop all remote workers
    Enum.each(NodeRegistry.healthy_nodes(), fn node ->
      rpc_async(node, StressSimulator.Distributed.WorkerAgent, :stop_local, [])
    end)

    new_state = %{state | status: :idle, node_quotas: %{}, rebalance_ref: nil, config: nil}
    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply,
     %{
       status: state.status,
       node_count: NodeRegistry.node_count(),
       nodes: NodeRegistry.list_nodes(),
       node_quotas: state.node_quotas
     }, state}
  end

  @impl true
  def handle_cast({:metrics_from_node, node, metrics}, state) do
    # Merge remote metrics into local ETS store
    # This aggregates distributed results into the same dashboard
    merge_remote_metrics(metrics)
    new_remote = Map.put(state.remote_metrics, node, metrics)
    {:noreply, %{state | remote_metrics: new_remote}}
  end

  @impl true
  def handle_info(:rebalance, %{status: :running} = state) do
    new_state = maybe_rebalance(state)
    ref = Process.send_after(self(), :rebalance, @rebalance_interval_ms)
    {:noreply, %{new_state | rebalance_ref: ref}}
  end

  def handle_info(:rebalance, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  ## Private: load distribution

  @doc """
  Distributes total concurrency across nodes using weighted round-robin.
  Currently equal-weighted; could weight by node CPU/memory in future.
  """
  def distribute_concurrency(total, nodes) do
    count = length(nodes)
    base = div(total, count)
    remainder = rem(total, count)

    nodes
    |> Enum.with_index()
    |> Enum.map(fn {node, i} ->
      # Give remainder to first N nodes
      quota = if i < remainder, do: base + 1, else: base
      {node, quota}
    end)
    |> Map.new()
  end

  defp maybe_rebalance(state) do
    healthy = NodeRegistry.healthy_nodes()
    current_nodes = Map.keys(state.node_quotas)

    newly_dead = current_nodes -- healthy
    newly_joined = healthy -- current_nodes

    cond do
      # No change
      newly_dead == [] && newly_joined == [] ->
        state

      # Nodes died — redistribute their quotas
      newly_dead != [] ->
        Logger.warn("[MasterOrchestrator] #{length(newly_dead)} node(s) lost — rebalancing")
        total = state.config[:concurrency] || 100
        new_quotas = distribute_concurrency(total, healthy)

        # Update still-alive nodes with new quotas
        Enum.each(new_quotas, fn {node, quota} ->
          if node in healthy do
            rpc_async(node, StressSimulator.Distributed.WorkerAgent, :adjust_concurrency, [quota])
            NodeRegistry.update_node_load(node, quota)
          end
        end)

        %{state | node_quotas: new_quotas}

      # New nodes joined — bring them into the pool
      newly_joined != [] ->
        Logger.info("[MasterOrchestrator] #{length(newly_joined)} new node(s) — rebalancing")
        total = state.config[:concurrency] || 100
        new_quotas = distribute_concurrency(total, healthy)

        Enum.each(new_quotas, fn {node, quota} ->
          if node in newly_joined do
            rpc_async(node, StressSimulator.Distributed.WorkerAgent, :start_local, [
              Map.merge(state.config, %{concurrency: quota})
            ])
          else
            rpc_async(node, StressSimulator.Distributed.WorkerAgent, :adjust_concurrency, [quota])
          end

          NodeRegistry.update_node_load(node, quota)
        end)

        %{state | node_quotas: new_quotas}
    end
  end

  # Merge remote node metrics into local ETS so the dashboard shows
  # the combined view across all nodes
  defp merge_remote_metrics(%{total: total, success: success, failure: failure}) do
    if total > 0 do
      # Record aggregated counts — we don't have individual latency samples
      # from remote nodes in this simplified implementation; a production
      # system would stream raw samples or quantile sketches (e.g., DDSketch)
      for _ <- 1..success, do: Store.record_request(0, :ok)
      for _ <- 1..failure, do: Store.record_request(0, :error)
    end
  end

  defp merge_remote_metrics(_), do: :ok

  # Fire-and-forget RPC — we don't block on worker responses
  defp rpc_async(node, module, function, args) do
    Task.start(fn ->
      try do
        :rpc.call(node, module, function, args, 5_000)
      catch
        _, reason ->
          Logger.warn("[MasterOrchestrator] RPC to #{node} failed: #{inspect(reason)}")
      end
    end)
  end

  defp broadcast_status(state) do
    Phoenix.PubSub.broadcast(@pubsub, "simulation:status", {
      :distributed_status_update,
      %{
        status: state.status,
        node_count: NodeRegistry.node_count(),
        node_quotas: state.node_quotas
      }
    })
  end
end
