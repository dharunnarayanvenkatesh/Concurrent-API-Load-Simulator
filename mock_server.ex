defmodule StressSim.MockServer do
  @moduledoc """
  Lightweight Plug-based HTTP server that acts as the default stress target.

  Runs on port 4001 (separate from the Phoenix app on 4000).

  Simulates realistic server behavior:
  - Variable latency (normal distribution 20-200ms)
  - Configurable error rate (default 2%)
  - Gradual slowdown under "load" (tracked via ETS counter)
  - Returns JSON with request metadata

  This lets you demo the stress tester without any external services.
  """
  use GenServer

  require Logger

  @port 4001
  @base_latency_ms 30
  @latency_jitter_ms 80
  @base_error_rate 0.02

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    children = [
      {Bandit, plug: StressSim.MockServer.Plug, port: @port, scheme: :http}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
    Logger.info("MockServer listening on http://localhost:#{@port}/mock")
    {:ok, %{}}
  end
end

defmodule StressSim.MockServer.Plug do
  @moduledoc "Plug router for the mock target server."
  import Plug.Conn

  @base_latency_ms 30
  @latency_jitter_ms 80
  @base_error_rate 0.02

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/mock"} = conn, _opts) do
    simulate_work()

    if :rand.uniform() < error_rate() do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(500, ~s({"error": "simulated server error"}))
    else
      body = Jason.encode!(%{
        status: "ok",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        server: "stress_sim_mock"
      })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end

  def call(%Plug.Conn{request_path: "/mock/slow"} = conn, _opts) do
    # Always slow — useful for testing p95 divergence
    Process.sleep(Enum.random(200..800))
    body = Jason.encode!(%{status: "ok", slow: true})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  def call(%Plug.Conn{request_path: "/mock/error"} = conn, _opts) do
    conn |> send_resp(503, "service unavailable")
  end

  def call(%Plug.Conn{request_path: "/health"} = conn, _opts) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"ok": true}))
  end

  def call(conn, _opts) do
    conn |> send_resp(404, "not found")
  end

  defp simulate_work do
    jitter = :rand.uniform(@latency_jitter_ms)
    Process.sleep(@base_latency_ms + jitter)
  end

  defp error_rate, do: @base_error_rate
end
