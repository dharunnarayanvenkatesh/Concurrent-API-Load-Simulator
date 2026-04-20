defmodule StressSimulator.MockServer do
  @moduledoc """
  Built-in mock HTTP endpoint for load testing without external dependencies.

  Simulates realistic API behavior:
  - Variable latency (configurable distribution)
  - Configurable error rate
  - Occasional slow responses (to trigger backpressure)

  Runs as a Plug.Cowboy server on port 4001.
  Target URL: http://localhost:4001/api/mock
  """
  use GenServer
  require Logger

  @port 4001

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    case Plug.Cowboy.http(StressSimulator.MockServer.Router, [], port: @port) do
      {:ok, _pid} ->
        Logger.info("[MockServer] Listening on http://localhost:#{@port}/api/mock")
        {:ok, %{port: @port}}

      {:error, :eaddrinuse} ->
        Logger.warn("[MockServer] Port #{@port} already in use — skipping")
        {:ok, %{port: nil}}

      {:error, reason} ->
        Logger.warn("[MockServer] Could not start: #{inspect(reason)}")
        {:ok, %{port: nil}}
    end
  end
end

defmodule StressSimulator.MockServer.Router do
  @moduledoc "Plug router for mock endpoints"
  use Plug.Router

  plug :match
  plug :dispatch

  # Primary mock endpoint — simulates a realistic API
  get "/api/mock" do
    # Simulate variable latency: mostly fast, occasionally slow
    latency = simulate_latency()
    Process.sleep(latency)

    # Simulate error rate (~5% by default, configurable)
    case simulate_response() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, code, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(code, body)
    end
  end

  # Configurable mock: accepts query params for error rate and latency
  get "/api/mock/custom" do
    params = fetch_query_params(conn).params
    error_rate = String.to_float(params["error_rate"] || "0.05")
    base_latency = String.to_integer(params["latency_ms"] || "50")

    Process.sleep(base_latency + :rand.uniform(50))

    if :rand.uniform() < error_rate do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(500, ~s({"error": "simulated_failure"}))
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"status": "ok"}))
    end
  end

  # Health check
  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  ## Simulation helpers

  defp simulate_latency() do
    # Bimodal distribution: mostly 10-100ms, occasionally 200-2000ms
    case :rand.uniform(100) do
      n when n <= 80 -> 10 + :rand.uniform(90)     # 80%: fast (10-100ms)
      n when n <= 95 -> 100 + :rand.uniform(200)   # 15%: medium (100-300ms)
      _ -> 500 + :rand.uniform(1500)               # 5%: slow (500-2000ms)
    end
  end

  defp simulate_response() do
    case :rand.uniform(100) do
      n when n <= 3 -> {:error, 500, ~s({"error": "internal_error"})}
      n when n <= 4 -> {:error, 503, ~s({"error": "service_unavailable"})}
      _ ->
        {:ok, Jason.encode!(%{
          status: "ok",
          timestamp: System.system_time(:millisecond),
          data: %{id: :rand.uniform(10_000), value: :rand.uniform()}
        })}
    end
  end
end
