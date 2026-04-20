defmodule StressSimulator.Telemetry do
  @moduledoc """
  Telemetry supervisor.

  Attaches handlers for Phoenix and BEAM VM metrics so they appear
  in Logger output and can be forwarded to external APM tools.

  The poller runs every 10 seconds and captures:
  - BEAM memory usage
  - Process count
  - ETS table sizes (proxy for metrics store health)
  """
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Polls VM metrics every 10s
      {:telemetry_poller,
       measurements: [
         {:process_info, event: [:stress_simulator, :vm, :process_count], name: self()},
       ],
       period: 10_000,
       name: :stress_poller}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix endpoint metrics
      summary("phoenix.endpoint.start.system_time", unit: {:native, :millisecond}),
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),

      # LiveView metrics
      summary("phoenix.live_view.mount.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.live_view.handle_event.stop.duration", unit: {:native, :millisecond}),

      # VM metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),

      # Custom simulation metrics (emitted by Aggregator)
      last_value("stress_simulator.simulation.rps"),
      last_value("stress_simulator.simulation.active_workers"),
      last_value("stress_simulator.simulation.failure_rate"),
      last_value("stress_simulator.simulation.p95_latency_ms")
    ]
  end
end
