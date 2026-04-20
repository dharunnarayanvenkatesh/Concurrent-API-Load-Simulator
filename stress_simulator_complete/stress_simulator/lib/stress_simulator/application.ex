defmodule StressSimulator.Application do
  @moduledoc """
  OTP Application and supervision tree.

  All children use :one_for_one — a crash in any single component
  restarts only that component, not the entire tree.

  Start order matters:
  1. PubSub            — must exist before any subscriber
  2. Metrics.Store     — ETS tables created here; must exist before Aggregator
  3. Metrics.Aggregator — reads ETS, broadcasts to PubSub
  4. Finch             — HTTP pool; must exist before any workers
  5. WorkerSupervisor  — DynamicSupervisor that owns task workers
  6. Coordinator       — simulation state machine; reads Store, spawns workers
  7. RampScheduler     — calls Coordinator.adjust_concurrency/1
  8. Distributed.*     — always started; only active when configured
  9. MockServer        — built-in HTTP target on :4001
  10. Endpoint         — last, depends on everything above
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: StressSimulator.PubSub},
      StressSimulator.Metrics.Store,
      StressSimulator.Metrics.Aggregator,
      {Finch,
       name:  StressSimulator.Finch,
       pools: %{
         default: [
           size:  pool_cfg(:default_pool_size,  50),
           count: pool_cfg(:default_pool_count, 10)
         ]
       }},
      {DynamicSupervisor,
       name:         StressSimulator.WorkerSupervisor,
       strategy:     :one_for_one,
       max_children: 5_000},
      StressSimulator.Simulation.Coordinator,
      StressSimulator.Simulation.RampScheduler,
      StressSimulator.Distributed.NodeRegistry,
      StressSimulator.Distributed.MasterOrchestrator,
      StressSimulator.Distributed.WorkerAgent,
      StressSimulator.MockServer,
      StressSimulatorWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: StressSimulator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    StressSimulatorWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp pool_cfg(key, default),
    do: Application.get_env(:stress_simulator, :finch_pools, [])[key] || default
end
