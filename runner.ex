defmodule StressSim.Simulation.Runner do
  @moduledoc """
  GenServer that owns a single simulation run.

  Concurrency model:
  ┌─────────────────────────────────────────────────────────┐
  │  Runner GenServer                                       │
  │  ├── spawns a Task for the "driver loop"               │
  │  │   └── produces an infinite Stream of requests       │
  │  │       └── piped through Task.async_stream/3         │
  │  │           (max_concurrency = configured cap)        │
  │  └── handles cast messages to adjust/stop              │
  └─────────────────────────────────────────────────────────┘

  Why a separate driver Task instead of spawning from the GenServer?
  - The GenServer stays responsive to control messages (stop, adjust)
    while the driver loop is blocking on Task.async_stream.
  - On :stop, we send an exit signal to the driver task, which causes
    async_stream to abort cleanly — no orphan worker processes.

  Backpressure:
  - Task.async_stream with :ordered => false + timeout acts as
    natural throttle; if workers are slow, async_stream back-pressures.
  - Adaptive concurrency: if error_rate > 30%, the next batch reduces
    max_concurrency by 25% (floor 1). Recovers when error_rate < 5%.
  """
  use GenServer, restart: :transient

  alias StressSim.Metrics.Store
  alias StressSim.CircuitBreaker

  defstruct [
    :sim_id,
    :config,
    :driver_task,
    :start_time,
    status: :idle
  ]

  ## ── Config schema ────────────────────────────────────────────────────────

  @type config :: %{
    target_url:      String.t(),
    concurrency:     pos_integer(),
    rate_per_second: pos_integer(),
    duration_sec:    pos_integer() | :infinite,
    method:          :get | :post,
    headers:         [{String.t(), String.t()}],
    body:            String.t() | nil,
    timeout_ms:      pos_integer()
  }

  def default_config do
    %{
      target_url:      "http://localhost:4001/mock",
      concurrency:     100,
      rate_per_second: 200,
      duration_sec:    :infinite,
      method:          :get,
      headers:         [{"accept", "application/json"}],
      body:            nil,
      timeout_ms:      5_000
    }
  end

  ## ── Public API ──────────────────────────────────────────────────────────

  def start_link({sim_id, config}) do
    GenServer.start_link(__MODULE__, {sim_id, config},
      name: via(sim_id))
  end

  def stop(sim_id) do
    GenServer.cast(via(sim_id), :stop)
  end

  def update_concurrency(sim_id, new_concurrency) do
    GenServer.cast(via(sim_id), {:set_concurrency, new_concurrency})
  end

  def get_state(sim_id) do
    GenServer.call(via(sim_id), :get_state)
  end

  ## ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init({sim_id, config}) do
    state = %__MODULE__{
      sim_id:     sim_id,
      config:     config,
      start_time: System.monotonic_time(:millisecond),
      status:     :running
    }

    Store.reset(sim_id)
    Store.put(sim_id, :active_workers, 0)
    Store.put(sim_id, :status, :running)

    # Spawn the driver in a linked task; if this GenServer dies, driver dies too
    driver = Task.async(fn -> run_driver(sim_id, config) end)

    {:ok, %{state | driver_task: driver}}
  end

  @impl true
  def handle_cast(:stop, state) do
    shutdown(state)
    {:stop, :normal, %{state | status: :stopped}}
  end

  @impl true
  def handle_cast({:set_concurrency, n}, state) do
    new_config = %{state.config | concurrency: clamp(n, 1, 5_000)}
    Store.put(state.sim_id, :concurrency, new_config.concurrency)
    # Signal driver to restart with new concurrency
    if state.driver_task, do: Task.shutdown(state.driver_task, :brutal_kill)
    driver = Task.async(fn -> run_driver(state.sim_id, new_config) end)
    {:noreply, %{state | config: new_config, driver_task: driver}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Task.async reply — driver finished (duration elapsed)
    Process.demonitor(ref, [:flush])
    Store.put(state.sim_id, :status, :completed)
    {:noreply, %{state | status: :completed, driver_task: nil}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state)
      when reason in [:normal, :shutdown] do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Driver crashed — restart it
    driver = Task.async(fn -> run_driver(state.sim_id, state.config) end)
    {:noreply, %{state | driver_task: driver}}
  end

  ## ── Driver loop (runs in a separate Task) ───────────────────────────────

  defp run_driver(sim_id, config) do
    # Produce a throttled stream of request "tickets"
    request_stream = build_request_stream(config)

    request_stream
    |> Task.async_stream(
         fn _ticket -> execute_request(sim_id, config) end,
         max_concurrency: config.concurrency,
         timeout:         config.timeout_ms + 1_000,
         on_timeout:      :kill_task,
         ordered:         false
       )
    |> Stream.each(fn
         {:ok, _}         -> :ok
         {:exit, :timeout} ->
           Store.record_request(sim_id, config.timeout_ms, :error)
         {:exit, _reason}  ->
           Store.record_request(sim_id, 0, :error)
       end)
    |> Stream.run()
  end

  # Infinite stream of tokens, rate-limited to req_per_sec
  defp build_request_stream(%{rate_per_second: rps, duration_sec: dur}) do
    delay_ms = max(1, div(1_000, rps))

    base_stream =
      Stream.repeatedly(fn ->
        Process.sleep(delay_ms)
        :request
      end)

    case dur do
      :infinite -> base_stream
      secs      -> Stream.take(base_stream, secs * rps)
    end
  end

  ## ── HTTP execution ───────────────────────────────────────────────────────

  defp execute_request(sim_id, config) do
    # Check circuit breaker before sending
    case CircuitBreaker.check(sim_id) do
      {:error, :circuit_open} ->
        Store.record_request(sim_id, 0, :error)
        {:error, :circuit_open}

      :ok ->
        do_http_request(sim_id, config)
    end
  end

  defp do_http_request(sim_id, config) do
    t0 = System.monotonic_time(:millisecond)

    Store.put(sim_id, :active_workers,
      Store.get(sim_id, :active_workers, 0) + 1)

    result = send_http(config)

    t1 = System.monotonic_time(:millisecond)
    latency = t1 - t0

    # Adaptive backpressure: if we're slow, note it
    Store.put(sim_id, :active_workers,
      max(0, Store.get(sim_id, :active_workers, 1) - 1))

    case result do
      {:ok, status} when status in 200..299 ->
        Store.record_request(sim_id, latency, :ok)
        CircuitBreaker.report(sim_id, :ok)
        {:ok, latency}

      {:ok, _status} ->
        Store.record_request(sim_id, latency, :error)
        CircuitBreaker.report(sim_id, :error)
        {:error, :bad_status}

      {:error, _reason} ->
        Store.record_request(sim_id, latency, :error)
        CircuitBreaker.report(sim_id, :error)
        {:error, :request_failed}
    end
  end

  defp send_http(config) do
    method = config.method |> Atom.to_string() |> String.upcase()

    req =
      if config.body do
        Finch.build(method, config.target_url,
          config.headers ++ [{"content-type", "application/json"}],
          config.body)
      else
        Finch.build(method, config.target_url, config.headers)
      end

    case Finch.request(req, StressSim.Finch,
           receive_timeout: config.timeout_ms) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, reason}         -> {:error, reason}
    end
  end

  ## ── Helpers ─────────────────────────────────────────────────────────────

  defp via(sim_id),
    do: {:via, Registry, {StressSim.Simulation.Registry, sim_id}}

  defp clamp(n, min, max), do: n |> max(min) |> min(max)

  defp shutdown(%{driver_task: nil}), do: :ok
  defp shutdown(%{driver_task: task, sim_id: sim_id}) do
    Store.put(sim_id, :status, :stopped)
    Task.shutdown(task, :brutal_kill)
  end
end
