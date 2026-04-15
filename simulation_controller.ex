defmodule StressSimWeb.SimulationController do
  use StressSimWeb, :controller

  alias StressSim.Simulation

  def create(conn, params) do
    config = %{
      target_url:      Map.get(params, "target_url", "http://localhost:4001/mock"),
      concurrency:     Map.get(params, "concurrency", 100),
      rate_per_second: Map.get(params, "rate_per_second", 200),
      timeout_ms:      Map.get(params, "timeout_ms", 5_000)
    }

    case Simulation.start(config) do
      {:ok, sim_id} ->
        conn
        |> put_status(201)
        |> json(%{sim_id: sim_id, status: "running"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: inspect(reason)})
    end
  end

  def delete(conn, %{"id" => sim_id}) do
    Simulation.stop(sim_id)
    json(conn, %{status: "stopped"})
  end

  def metrics(conn, %{"id" => sim_id}) do
    snap = Simulation.get_metrics(sim_id)
    json(conn, snap)
  end
end
