defmodule StressSimulator.Simulation.Worker do
  @moduledoc """
  Stateless worker that executes a single HTTP request.

  ## Jitter

  Real users don't all arrive simultaneously. Jitter adds a random
  pre-request delay drawn from a configurable distribution:

    :uniform      — flat random between jitter_min_ms and jitter_max_ms
    :gaussian     — bell-curve centered at midpoint (Box-Muller transform)
    :exponential  — models Poisson arrival times (lambda = 1/mean_ms)
    :none         — no delay (original behaviour)

  The key insight: latency measurement starts AFTER the jitter sleep,
  so jitter does not pollute the latency numbers reported to the dashboard.

  ## Why stateless tasks?
  - Simpler lifecycle: spawn -> execute -> die
  - No state cleanup on failure
  - BEAM handles thousands of lightweight processes natively
  - Coordinator tracks refs, not pids
  """
  require Logger

  @doc """
  Execute one HTTP GET request with optional pre-request jitter.

  Options:
    - :jitter — %{distribution: :uniform|:gaussian|:exponential, min_ms: N, max_ms: N}
                or :none (default)

  Returns:
    - {:ok, latency_ms}
    - {:error, :timeout, latency_ms}
    - {:error, reason, latency_ms}
  """
  def execute_request(url, timeout_ms \\ 5_000, opts \\ []) do
    jitter_cfg = Keyword.get(opts, :jitter, :none)
    # Apply jitter BEFORE the clock starts — jitter is simulated think-time,
    # not part of server latency.
    apply_jitter(jitter_cfg)

    start = System.monotonic_time(:millisecond)

    result =
      try do
        request = Finch.build(:get, url)

        case Finch.request(request, StressSimulator.Finch, receive_timeout: timeout_ms) do
          {:ok, %Finch.Response{status: status}} when status in 200..299 ->
            :ok

          {:ok, %Finch.Response{status: status}} when status in 500..599 ->
            {:error, {:server_error, status}}

          {:ok, %Finch.Response{}} ->
            :ok

          {:error, %Mint.TransportError{reason: :timeout}} ->
            {:error, :timeout}

          {:error, %Mint.TransportError{reason: reason}} ->
            {:error, {:transport, reason}}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        e ->
          Logger.debug("[Worker] Rescued: #{inspect(e)}")
          {:error, :exception}
      catch
        kind, reason ->
          Logger.debug("[Worker] Caught #{kind}: #{inspect(reason)}")
          {:error, :caught}
      end

    latency_ms = System.monotonic_time(:millisecond) - start

    case result do
      :ok -> {:ok, latency_ms}
      {:error, :timeout} -> {:error, :timeout, latency_ms}
      {:error, reason} -> {:error, reason, latency_ms}
    end
  end

  def execute_batch(url, count, max_concurrency, timeout_ms \\ 5_000, opts \\ []) do
    1..count
    |> Task.async_stream(
      fn _i -> execute_request(url, timeout_ms, opts) end,
      max_concurrency: max_concurrency,
      timeout: timeout_ms + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce({0, 0, []}, fn
      {:ok, {:ok, lat}}, {ok, err, lats} -> {ok + 1, err, [lat | lats]}
      {:ok, {:error, _, lat}}, {ok, err, lats} -> {ok, err + 1, [lat | lats]}
      {:exit, :timeout}, {ok, err, lats} -> {ok, err + 1, lats}
      _, acc -> acc
    end)
  end

  # ---------------------------------------------------------------------------
  # Jitter implementations
  # ---------------------------------------------------------------------------

  defp apply_jitter(:none), do: :ok
  defp apply_jitter(nil), do: :ok

  # Uniform: flat random between min and max
  # Best for: simple predictable spread across a window
  defp apply_jitter(%{distribution: :uniform, min_ms: min_ms, max_ms: max_ms}) do
    range = max(max_ms - min_ms, 0)
    delay = min_ms + :rand.uniform(max(range, 1))
    if delay > 0, do: Process.sleep(delay)
  end

  # Gaussian (normal): bell curve, Box-Muller transform
  # Best for: realistic user think-time — most near average, outliers rare
  defp apply_jitter(%{distribution: :gaussian, min_ms: min_ms, max_ms: max_ms}) do
    mean = (min_ms + max_ms) / 2
    # std_dev chosen so ~95% of values fall within [min, max]
    std_dev = (max_ms - min_ms) / 4

    u1 = max(:rand.uniform(), 0.0001)
    u2 = :rand.uniform()
    z = :math.sqrt(-2.0 * :math.log(u1)) * :math.cos(2.0 * :math.pi * u2)

    delay = round(mean + std_dev * z)
    delay = max(0, min(delay, max_ms * 2))
    if delay > 0, do: Process.sleep(delay)
  end

  # Exponential: canonical Poisson arrival model
  # P(delay > t) = e^(-lambda*t) where lambda = 1/mean
  # Best for: statistically rigorous load testing
  defp apply_jitter(%{distribution: :exponential, min_ms: _min_ms, max_ms: max_ms}) do
    mean = max_ms / 2
    u = max(:rand.uniform(), 0.0001)
    delay = round(-:math.log(u) * mean)
    delay = max(0, min(delay, max_ms * 2))
    if delay > 0, do: Process.sleep(delay)
  end

  defp apply_jitter(_), do: :ok
end

  # ── Test helpers (not compiled in prod) ─────────────────────────────────────
  if Mix.env() == :test do
    @doc false
    def apply_jitter_test(cfg), do: apply_jitter(cfg)
  end
