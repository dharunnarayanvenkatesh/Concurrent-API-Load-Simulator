defmodule StressSimulator.Distributed.WorkerAgent do
  @moduledoc """
  Runs on each worker node in the distributed cluster.

  Responsibilities:
  1. Receive simulation config + concurrency quota from master via RPC
  2. Run a local simulation engine (mirrors Coordinator logic but lighter)
  3. Periodically report metrics back to master
  4. Respond to quota adjustment messages (rebalancing)
  5. Send heartbeats to master's NodeRegistry

  ## Setup

  Start a worker node with:

    ```bash
    # Terminal 1: Master
    iex --name master@127.0.0.1 --cookie stress_cookie -S mix phx.server

    # Terminal 2: Worker node 1
    iex --name worker1@127.0.0.1 --cookie stress_cookie -S mix run --no-halt

    # Inside worker1 iex:
    Node.connect(:"master@127.0.0.1")
    StressSimulator.Distributed.WorkerAgent.register_with_master(:"master@127.0.0.1")
    ```

  Once registered, the master can push simulation config via RPC and
  the worker runs local Task.async workers.

  ## Why not just run full Phoenix on each worker?

  Worker nodes are pure load-generators. They don't need a web UI,
  LiveView, or PubSub. Running a stripped-down OTP app reduces
  memory overhead and startup time. You can run more worker nodes
  on smaller machines this way.
  """
  use GenServer
  require Logger

  alias StressSimulator.Simulation.Worker
  alias StressSimulator.Metrics.Store

  @heartbeat_interval_ms 2_000
  @metrics_report_interval_ms 1_000

  defstruct [
    :master_node,
    :config,
    :heartbeat_ref,
    :report_ref,
    :scheduler_ref,
    status: :idle,
    effective_concurrency: 0,
    active_refs: %{},
    # Local counters (reported to master)
    local_total: 0,
    local_success: 0,
    local_failure: 0
  ]

  ## Client API (called locally or via RPC from master)

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Register this node with the master orchestrator"
  def register_with_master(master_node) do
    GenServer.call(__MODULE__, {:register, master_node})
  end

  @doc "Called by master via RPC to start local simulation"
  def start_local(config) do
    GenServer.call(__MODULE__, {:start_local, config})
  end

  @doc "Called by master via RPC to stop local simulation"
  def stop_local() do
    GenServer.call(__MODULE__, :stop_local)
  end

  @doc "Called by master via RPC to adjust this node's concurrency quota"
  def adjust_concurrency(new_concurrency) do
    GenServer.cast(__MODULE__, {:adjust_concurrency, new_concurrency})
  end

  def get_local_stats() do
    GenServer.call(__MODULE__, :get_stats)
  end

  ## Server callbacks

  @impl true
  def init([]) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:register, master_node}, _from, state) do
    Logger.info("[WorkerAgent] Registering with master: #{master_node}")

    capabilities = %{
      node: Node.self(),
      cpu_count: System.schedulers_online(),
      max_concurrency: 1000
    }

    # RPC to master's NodeRegistry
    result = :rpc.call(master_node, StressSimulator.Distributed.NodeRegistry,
                       :register_node, [Node.self(), capabilities], 5_000)

    case result do
      :ok ->
        Logger.info("[WorkerAgent] Registered successfully")
        hb_ref = Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
        {:reply, :ok, %{state | master_node: master_node, heartbeat_ref: hb_ref}}

      error ->
        Logger.error("[WorkerAgent] Registration failed: #{inspect(error)}")
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:start_local, config}, _from, %{status: :idle} = state) do
    Logger.info("[WorkerAgent] Starting local simulation with config: #{inspect(config)}")
    concurrency = config[:concurrency] || config["concurrency"] || 10

    report_ref = Process.send_after(self(), :report_metrics, @metrics_report_interval_ms)

    new_state = %{
      state
      | config: config,
        status: :running,
        effective_concurrency: concurrency,
        active_refs: %{},
        local_total: 0,
        local_success: 0,
        local_failure: 0,
        report_ref: report_ref
    }

    new_state = schedule_local_batch(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:start_local, _}, _from, state),
    do: {:reply, {:error, "Already running"}, state}

  def handle_call(:stop_local, _from, state) do
    if state.scheduler_ref, do: Process.cancel_timer(state.scheduler_ref)
    if state.report_ref, do: Process.cancel_timer(state.report_ref)

    new_state = %{
      state
      | status: :idle,
        active_refs: %{},
        scheduler_ref: nil,
        report_ref: nil,
        config: nil
    }

    {:reply, :ok, new_state}
  end

  def handle_call(:get_stats, _from, state) do
    {:reply,
     %{
       total: state.local_total,
       success: state.local_success,
       failure: state.local_failure,
       active_workers: map_size(state.active_refs),
       status: state.status,
       effective_concurrency: state.effective_concurrency
     }, state}
  end

  @impl true
  def handle_cast({:adjust_concurrency, n}, state) do
    Logger.debug("[WorkerAgent] Concurrency adjusted to #{n}")
    {:noreply, %{state | effective_concurrency: n}}
  end

  @impl true
  def handle_info(:dispatch_local_batch, %{status: :running} = state) do
    new_state = dispatch_local_batch(state)
    {:noreply, schedule_local_batch(new_state)}
  end

  def handle_info(:dispatch_local_batch, state), do: {:noreply, state}

  def handle_info(:heartbeat, state) do
    if state.master_node do
      stats = %{
        total: state.local_total,
        success: state.local_success,
        failure: state.local_failure,
        active_workers: map_size(state.active_refs),
        status: state.status
      }

      :rpc.cast(state.master_node, StressSimulator.Distributed.NodeRegistry,
                :heartbeat, [Node.self(), stats])
    end

    ref = Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
    {:noreply, %{state | heartbeat_ref: ref}}
  end

  def handle_info(:report_metrics, %{status: :running, master_node: master} = state)
      when not is_nil(master) do
    metrics = %{
      total: state.local_total,
      success: state.local_success,
      failure: state.local_failure
    }

    # Report metrics to master asynchronously
    :rpc.cast(master, StressSimulator.Distributed.MasterOrchestrator,
              :report_metrics, [Node.self(), metrics])

    ref = Process.send_after(self(), :report_metrics, @metrics_report_interval_ms)
    {:noreply, %{state | report_ref: ref, local_total: 0, local_success: 0, local_failure: 0}}
  end

  def handle_info(:report_metrics, state) do
    ref = Process.send_after(self(), :report_metrics, @metrics_report_interval_ms)
    {:noreply, %{state | report_ref: ref}}
  end

  # Worker task completion
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    new_state = handle_result(ref, result, state)
    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | active_refs: Map.delete(state.active_refs, ref)}}
  end

  def handle_info(_, state), do: {:noreply, state}

  ## Private

  defp dispatch_local_batch(%{config: nil} = state), do: state

  defp dispatch_local_batch(state) do
    %{
      config: %{url: url, timeout_ms: timeout_ms} = config,
      effective_concurrency: eff,
      active_refs: refs
    } = state

    slots = max(eff - map_size(refs), 0)
    batch = min(slots, 20)

    if batch > 0 do
      jitter = Map.get(config, :jitter, :none)

      new_refs =
        for _ <- 1..batch, into: %{} do
          task = Task.async(fn ->
            Worker.execute_request(url, timeout_ms, jitter: jitter)
          end)
          {task.ref, task.pid}
        end

      %{state | active_refs: Map.merge(refs, new_refs)}
    else
      state
    end
  end

  defp handle_result(ref, {:ok, _lat}, state) do
    %{
      state
      | active_refs: Map.delete(state.active_refs, ref),
        local_total: state.local_total + 1,
        local_success: state.local_success + 1
    }
  end

  defp handle_result(ref, {:error, _, _lat}, state) do
    %{
      state
      | active_refs: Map.delete(state.active_refs, ref),
        local_total: state.local_total + 1,
        local_failure: state.local_failure + 1
    }
  end

  defp handle_result(ref, _, state),
    do: %{state | active_refs: Map.delete(state.active_refs, ref)}

  defp schedule_local_batch(state) do
    ref = Process.send_after(self(), :dispatch_local_batch, 100)
    %{state | scheduler_ref: ref}
  end
end
