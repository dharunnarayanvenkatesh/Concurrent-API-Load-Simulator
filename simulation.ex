defmodule StressSim.Simulation do
  @moduledoc """
  Public facade for managing simulations.
  LiveView and controllers should only call this module.
  """

  alias StressSim.Simulation.Runner
  alias StressSim.Metrics.Store

  @doc """
  Start a new simulation. Returns {:ok, sim_id} or {:error, reason}.
  Generates a unique sim_id so multiple simulations can run concurrently.
  """
  def start(config \\ %{}) do
    sim_id = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    full_config = Map.merge(Runner.default_config(), config)

    child_spec = {Runner, {sim_id, full_config}}

    case DynamicSupervisor.start_child(StressSim.Simulation.Supervisor, child_spec) do
      {:ok, _pid}      -> {:ok, sim_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stop a running simulation."
  def stop(sim_id) do
    Runner.stop(sim_id)
    Store.put(sim_id, :status, :stopped)
    :ok
  end

  @doc "Dynamically adjust worker concurrency mid-run."
  def update_concurrency(sim_id, new_concurrency) do
    Runner.update_concurrency(sim_id, new_concurrency)
  end

  @doc "Get current snapshot (reads ETS directly — very fast)."
  def get_metrics(sim_id), do: Store.get_snapshot(sim_id)

  @doc "List all active simulation IDs."
  def list_active do
    DynamicSupervisor.which_children(StressSim.Simulation.Supervisor)
    |> Enum.map(fn {_, pid, _, _} ->
      Registry.keys(StressSim.Simulation.Registry, pid) |> List.first()
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Is a simulation still running?"
  def running?(sim_id) do
    sim_id in list_active()
  end

  @doc "Get circuit breaker status for a sim."
  def circuit_status(sim_id) do
    StressSim.CircuitBreaker.get_status(sim_id)
  end
end
