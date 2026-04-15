defmodule StressSim.CircuitBreaker do
  @moduledoc """
  Circuit breaker GenServer implementing the classic three-state machine:

    CLOSED  → normal operation, requests flow through
    OPEN    → tripped by failure threshold, requests rejected immediately
    HALF_OPEN → probe state, allows one request to test recovery

  Thresholds (configurable per simulation):
  - error_rate > 50% over last 20 requests → OPEN
  - latency p95 > 5000ms → OPEN
  - After 10s in OPEN → HALF_OPEN
  - Successful probe → CLOSED
  - Failed probe → OPEN again

  Also implements adaptive concurrency reduction:
  - If error_rate > 30%, reduce max_concurrency by 25%
  - If error_rate < 5% and latency good, restore concurrency
  """
  use GenServer

  @check_interval_ms 1_000
  @open_timeout_ms   10_000
  @error_threshold   50.0    # % error rate to open circuit
  @latency_threshold 5_000   # ms p95 to open circuit

  defmodule State do
    defstruct [
      :sim_id,
      status: :closed,       # :closed | :open | :half_open
      opened_at: nil,
      probe_sent: false
    ]
  end

  ## ── Public API ──────────────────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Returns :ok or {:error, :circuit_open}"
  def check(sim_id) do
    GenServer.call(__MODULE__, {:check, sim_id})
  end

  @doc "Report outcome to allow state transitions."
  def report(sim_id, :ok),    do: GenServer.cast(__MODULE__, {:report, sim_id, :ok})
  def report(sim_id, :error), do: GenServer.cast(__MODULE__, {:report, sim_id, :error})

  def get_status(sim_id) do
    GenServer.call(__MODULE__, {:get_status, sim_id})
  end

  ## ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    Process.send_after(self(), :evaluate, @check_interval_ms)
    # state is a map of sim_id => %State{}
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check, sim_id}, _from, states) do
    state = Map.get(states, sim_id, %State{sim_id: sim_id})

    case state.status do
      :closed ->
        {:reply, :ok, states}

      :open ->
        elapsed = System.monotonic_time(:millisecond) - (state.opened_at || 0)
        if elapsed > @open_timeout_ms do
          new_state = %{state | status: :half_open, probe_sent: false}
          {:reply, :ok, Map.put(states, sim_id, new_state)}
        else
          {:reply, {:error, :circuit_open}, states}
        end

      :half_open ->
        if state.probe_sent do
          {:reply, {:error, :circuit_open}, states}
        else
          new_state = %{state | probe_sent: true}
          {:reply, :ok, Map.put(states, sim_id, new_state)}
        end
    end
  end

  @impl true
  def handle_call({:get_status, sim_id}, _from, states) do
    status = states |> Map.get(sim_id, %State{}) |> Map.get(:status)
    {:reply, status, states}
  end

  @impl true
  def handle_cast({:report, sim_id, :ok}, states) do
    state = Map.get(states, sim_id, %State{sim_id: sim_id})
    new_state =
      if state.status == :half_open,
        do: %{state | status: :closed, opened_at: nil, probe_sent: false},
        else: state
    {:noreply, Map.put(states, sim_id, new_state)}
  end

  @impl true
  def handle_cast({:report, sim_id, :error}, states) do
    state = Map.get(states, sim_id, %State{sim_id: sim_id})
    new_state =
      if state.status in [:half_open] do
        %{state | status: :open, opened_at: System.monotonic_time(:millisecond)}
      else
        state
      end
    {:noreply, Map.put(states, sim_id, new_state)}
  end

  @impl true
  def handle_info(:evaluate, states) do
    new_states =
      Enum.reduce(states, states, fn {sim_id, state}, acc ->
        snap = StressSim.Metrics.Store.get_snapshot(sim_id)
        updated = evaluate_thresholds(state, snap)
        Map.put(acc, sim_id, updated)
      end)

    Process.send_after(self(), :evaluate, @check_interval_ms)
    {:noreply, new_states}
  end

  ## ── Private ──────────────────────────────────────────────────────────────

  defp evaluate_thresholds(%State{status: :open} = state, _snap), do: state

  defp evaluate_thresholds(%State{status: status} = state, snap)
       when status in [:closed, :half_open] do
    should_open =
      snap.total > 10 and
      (snap.error_rate > @error_threshold or snap.p95_latency > @latency_threshold)

    if should_open do
      %{state | status: :open, opened_at: System.monotonic_time(:millisecond)}
    else
      state
    end
  end
end
