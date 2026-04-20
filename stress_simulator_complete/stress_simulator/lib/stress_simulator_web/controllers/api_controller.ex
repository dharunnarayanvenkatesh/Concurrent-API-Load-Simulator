defmodule StressSimulatorWeb.ApiController do
  @moduledoc """
  REST API for headless control of the stress simulator.

  Useful for:
  - CI/CD pipelines that trigger load tests automatically
  - Scripted multi-phase test scenarios
  - Integration with external orchestration tools

  All endpoints return JSON. The simulation runs asynchronously —
  POST /start returns immediately and the simulation runs in the background.
  Poll GET /metrics to stream results.

  ## Example curl usage

      # Start a ramp simulation
      curl -X POST http://localhost:4000/api/simulation/start \\
        -H "Content-Type: application/json" \\
        -d '{
          "url": "https://api.example.com/health",
          "concurrency": 500,
          "timeout_ms": 5000,
          "jitter": {"distribution": "exponential", "min_ms": 0, "max_ms": 200},
          "ramp": {
            "profile": "linear",
            "ramp_up_seconds": 60,
            "sustain_seconds": 120,
            "ramp_down_seconds": 30,
            "peak_concurrency": 500,
            "start_concurrency": 1
          }
        }'

      # Poll metrics
      curl http://localhost:4000/api/metrics

      # Stop
      curl -X POST http://localhost:4000/api/simulation/stop
  """
  use StressSimulatorWeb, :controller

  alias StressSimulator.Metrics.{Store, Aggregator}
  alias StressSimulator.Simulation.{Coordinator, RampScheduler}
  alias StressSimulator.Distributed.{NodeRegistry, MasterOrchestrator}

  @doc "GET /api/status — current simulation status and config"
  def status(conn, _params) do
    status_info = Coordinator.get_status()
    ramp_info   = RampScheduler.get_state()
    nodes       = NodeRegistry.list_nodes()

    json(conn, %{
      status:               status_info.status,
      circuit_state:        status_info.circuit_state,
      effective_concurrency: status_info.effective_concurrency,
      config:               status_info.config,
      ramp: %{
        phase:               ramp_info.phase,
        current_concurrency: ramp_info.current_concurrency,
        config:              ramp_info.config
      },
      nodes: Enum.map(nodes, fn n ->
        %{node: n.node, status: n.status, assigned_concurrency: n.assigned_concurrency}
      end),
      timestamp: System.system_time(:second)
    })
  end

  @doc "GET /api/metrics — current metrics snapshot + recent timeseries"
  def metrics(conn, params) do
    snapshot  = Aggregator.get_latest()
    seconds   = Map.get(params, "seconds", "60") |> parse_int(60)
    timeseries = Store.get_timeseries(seconds)

    json(conn, %{
      snapshot: %{
        total_requests:    snapshot.total_requests,
        success_count:     snapshot.success_count,
        failure_count:     snapshot.failure_count,
        timeout_count:     snapshot.timeout_count,
        active_workers:    snapshot.active_workers,
        rps:               snapshot.rps,
        failure_rate:      snapshot.failure_rate,
        backpressure:      snapshot.backpressure,
        latency: %{
          avg: snapshot.latency.avg,
          p50: snapshot.latency.p50,
          p95: snapshot.latency.p95,
          p99: snapshot.latency.p99,
          min: snapshot.latency.min,
          max: snapshot.latency.max
        }
      },
      timeseries: Enum.map(timeseries, fn b ->
        %{timestamp: b.timestamp, requests: b.requests, errors: b.errors, avg_latency: b.avg_latency}
      end),
      timestamp: System.system_time(:second)
    })
  end

  @doc "POST /api/simulation/start — start a simulation (async)"
  def start_simulation(conn, params) do
    # Normalize string-keyed params from JSON body
    config = normalize_params(params)

    use_distributed = Map.get(params, "distributed", false)

    result =
      if use_distributed do
        MasterOrchestrator.start_distributed(config)
      else
        Coordinator.start_simulation(config)
      end

    case result do
      {:ok, validated_config} ->
        conn
        |> put_status(:ok)
        |> json(%{
          status: "started",
          config: validated_config,
          dashboard_url: "http://localhost:4000",
          metrics_url: "http://localhost:4000/api/metrics"
        })

      {:error, reason} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: reason})
    end
  end

  @doc "POST /api/simulation/stop — stop running simulation"
  def stop_simulation(conn, _params) do
    Coordinator.stop_simulation()
    snapshot = Aggregator.get_latest()

    json(conn, %{
      status: "stopped",
      final_metrics: %{
        total_requests: snapshot.total_requests,
        success_count:  snapshot.success_count,
        failure_count:  snapshot.failure_count,
        rps:            snapshot.rps,
        avg_latency_ms: snapshot.latency.avg,
        p95_latency_ms: snapshot.latency.p95
      }
    })
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  # Convert string-keyed JSON params to the atom-keyed maps our modules expect.
  # We do this safely — no String.to_atom on untrusted input.
  defp normalize_params(params) do
    base = %{
      url:          Map.get(params, "url"),
      concurrency:  parse_int(Map.get(params, "concurrency"), 100),
      timeout_ms:   parse_int(Map.get(params, "timeout_ms"), 5_000),
      request_rate: parse_rate(Map.get(params, "request_rate"))
    }

    base = case Map.get(params, "jitter") do
      nil -> base
      j   -> Map.put(base, :jitter, normalize_jitter(j))
    end

    case Map.get(params, "ramp") do
      nil -> base
      r   -> Map.put(base, :ramp, normalize_ramp(r))
    end
  end

  defp normalize_jitter(%{"distribution" => dist} = j) do
    %{
      distribution: parse_distribution(dist),
      min_ms:       parse_int(Map.get(j, "min_ms"), 0),
      max_ms:       parse_int(Map.get(j, "max_ms"), 500)
    }
  end
  defp normalize_jitter(_), do: :none

  defp normalize_ramp(r) do
    %{
      profile:           Map.get(r, "profile", "linear"),
      ramp_up_seconds:   parse_int(Map.get(r, "ramp_up_seconds"), 30),
      sustain_seconds:   parse_int(Map.get(r, "sustain_seconds"), 0),
      ramp_down_seconds: parse_int(Map.get(r, "ramp_down_seconds"), 0),
      peak_concurrency:  parse_int(Map.get(r, "peak_concurrency"), 100),
      start_concurrency: parse_int(Map.get(r, "start_concurrency"), 1),
      step_count:        parse_int(Map.get(r, "step_count"), 10)
    }
  end

  defp parse_int(nil, default), do: default
  defp parse_int(v, _) when is_integer(v), do: v
  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _      -> default
    end
  end
  defp parse_int(_, default), do: default

  defp parse_rate(nil), do: :unlimited
  defp parse_rate(""), do: :unlimited
  defp parse_rate(v) when is_integer(v) and v > 0, do: v
  defp parse_rate(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} when n > 0 -> n
      _                  -> :unlimited
    end
  end
  defp parse_rate(_), do: :unlimited

  defp parse_distribution("uniform"),     do: :uniform
  defp parse_distribution("gaussian"),    do: :gaussian
  defp parse_distribution("exponential"), do: :exponential
  defp parse_distribution(_),             do: :uniform
end
