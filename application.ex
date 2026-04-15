defmodule StressSim.Application do
  @moduledoc """
  OTP Application entry point.

  Supervision tree:
    Application
    ├── StressSim.Metrics.Store          (ETS owner GenServer)
    ├── StressSim.Metrics.Aggregator     (periodic aggregation GenServer)
    ├── StressSim.Simulation.Supervisor  (DynamicSupervisor for worker pools)
    ├── StressSim.Simulation.Registry    (Registry for named simulations)
    ├── StressSim.MockServer             (local mock HTTP target)
    └── StressSimWeb.Endpoint            (Phoenix web server)
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ETS-backed metrics store — must start first
      StressSim.Metrics.Store,

      # Aggregates raw samples into windowed stats
      StressSim.Metrics.Aggregator,

      # Circuit breaker state store
      StressSim.CircuitBreaker,

      # Registry so simulations can be looked up by name
      {Registry, keys: :unique, name: StressSim.Simulation.Registry},

      # Dynamic supervisor — spawns/kills simulation runners
      {DynamicSupervisor,
       name: StressSim.Simulation.Supervisor, strategy: :one_for_one},

      # Finch HTTP connection pool used by workers
      {Finch, name: StressSim.Finch, pools: %{
        :default => [size: 200, count: 8]
      }},

      # Built-in mock target endpoint (no external dependency needed)
      StressSim.MockServer,

      # Phoenix endpoint — always last
      StressSimWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: StressSim.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    StressSimWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
