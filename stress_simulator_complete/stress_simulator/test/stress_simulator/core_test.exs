defmodule StressSimulator.Simulation.WorkerTest do
  use ExUnit.Case, async: true

  alias StressSimulator.Simulation.Worker

  describe "apply_jitter/1 via execute_request options" do
    test "no jitter: :none is accepted without sleeping" do
      # We can't test the sleep directly, but we can verify the function
      # accepts :none without raising
      start = System.monotonic_time(:millisecond)
      Worker.apply_jitter_test(:none)
      elapsed = System.monotonic_time(:millisecond) - start
      assert elapsed < 50, "Expected near-zero delay for :none jitter"
    end

    test "uniform jitter sleeps within range" do
      cfg = %{distribution: :uniform, min_ms: 10, max_ms: 50}
      start = System.monotonic_time(:millisecond)
      Worker.apply_jitter_test(cfg)
      elapsed = System.monotonic_time(:millisecond) - start
      # Allow some OS scheduling slack
      assert elapsed >= 5,  "Should have slept at least min_ms"
      assert elapsed < 200, "Should not have slept excessively"
    end

    test "gaussian jitter stays within reasonable bounds" do
      cfg = %{distribution: :gaussian, min_ms: 0, max_ms: 100}
      start = System.monotonic_time(:millisecond)
      Worker.apply_jitter_test(cfg)
      elapsed = System.monotonic_time(:millisecond) - start
      # 2*max_ms is the hard cap in the implementation
      assert elapsed < 300, "Gaussian jitter exceeded cap"
    end

    test "exponential jitter produces non-negative delays" do
      cfg = %{distribution: :exponential, min_ms: 0, max_ms: 80}
      # Run multiple times to verify no negative values crash it
      for _ <- 1..5 do
        assert :ok == Worker.apply_jitter_test(cfg)
      end
    end

    test "unknown jitter config is silently ignored" do
      assert :ok == Worker.apply_jitter_test(%{distribution: :unknown, min_ms: 0, max_ms: 100})
    end
  end
end

defmodule StressSimulator.Simulation.RampSchedulerTest do
  use ExUnit.Case, async: true

  # We test the pure concurrency computation functions by calling the
  # private functions via a test-helper facade exposed on the module.
  # In production code we'd use @doc false and test via the public API.

  alias StressSimulator.Simulation.RampScheduler

  describe "ramp profile math" do
    test "linear profile reaches peak at 100% progress" do
      cfg = %{ramp_up_seconds: 10, peak_concurrency: 100, start_concurrency: 0, step_count: 10}
      # At tick=10 (100%), should be at or near peak
      result = RampScheduler.compute_concurrency_test(:linear, 10, cfg)
      assert result == 100
    end

    test "linear profile is at 50% halfway" do
      cfg = %{ramp_up_seconds: 10, peak_concurrency: 100, start_concurrency: 0, step_count: 10}
      result = RampScheduler.compute_concurrency_test(:linear, 5, cfg)
      assert result == 50
    end

    test "step profile jumps in equal intervals" do
      cfg = %{ramp_up_seconds: 10, peak_concurrency: 100, start_concurrency: 0, step_count: 5}
      # step_size = 100/5 = 20; seconds_per_step = 10/5 = 2
      # at tick 0: step 0, concurrency = 0
      assert RampScheduler.compute_concurrency_test(:step, 0, cfg) == 0
      # at tick 2: step 1, concurrency = 20
      assert RampScheduler.compute_concurrency_test(:step, 2, cfg) == 20
      # at tick 4: step 2, concurrency = 40
      assert RampScheduler.compute_concurrency_test(:step, 4, cfg) == 40
    end

    test "exponential profile is slow at start" do
      cfg = %{ramp_up_seconds: 100, peak_concurrency: 1000, start_concurrency: 0, step_count: 10}
      early  = RampScheduler.compute_concurrency_test(:exponential, 10, cfg)
      middle = RampScheduler.compute_concurrency_test(:exponential, 50, cfg)
      late   = RampScheduler.compute_concurrency_test(:exponential, 90, cfg)

      assert early < middle, "Exponential should be lower early on"
      assert middle < late,  "Exponential should accelerate over time"
      # The gap between middle->late should be bigger than early->middle
      assert (late - middle) > (middle - early),
             "Exponential should accelerate (bigger gap in later half)"
    end

    test "sine_wave oscillates between start and peak" do
      cfg = %{ramp_up_seconds: 20, peak_concurrency: 100, start_concurrency: 0, step_count: 10}
      values = for t <- 0..20 do
        RampScheduler.compute_concurrency_test(:sine_wave, t, cfg)
      end

      min_v = Enum.min(values)
      max_v = Enum.max(values)

      assert min_v >= 0,   "Sine wave should not go below start_concurrency"
      assert max_v <= 100, "Sine wave should not exceed peak_concurrency"
      assert max_v > 50,   "Sine wave should actually reach high values"
    end
  end
end

defmodule StressSimulator.Metrics.StoreTest do
  use ExUnit.Case

  alias StressSimulator.Metrics.Store

  setup do
    # Reset between tests — Store must be running (started by Application)
    # In test env, we start it manually if needed
    case Process.whereis(Store) do
      nil ->
        {:ok, _} = Store.start_link([])
        :ok
      _pid ->
        Store.reset()
        :ok
    end
  end

  test "counters start at zero after reset" do
    counters = Store.get_counters()
    assert counters.total   == 0
    assert counters.success == 0
    assert counters.failure == 0
    assert counters.timeout == 0
  end

  test "record_request increments total and success" do
    Store.record_request(50, :ok)
    Store.record_request(80, :ok)
    counters = Store.get_counters()
    assert counters.total   == 2
    assert counters.success == 2
    assert counters.failure == 0
  end

  test "record_request increments failure for errors" do
    Store.record_request(200, :error)
    counters = Store.get_counters()
    assert counters.total   == 1
    assert counters.failure == 1
    assert counters.success == 0
  end

  test "record_request counts timeouts as failures" do
    Store.record_request(5000, :timeout)
    counters = Store.get_counters()
    assert counters.total   == 1
    assert counters.timeout == 1
    assert counters.failure == 1
  end

  test "latency stats compute avg correctly" do
    Store.record_request(100, :ok)
    Store.record_request(200, :ok)
    Store.record_request(300, :ok)
    stats = Store.get_latency_stats()
    assert stats.avg == 200.0
    assert stats.min == 100
    assert stats.max == 300
    assert stats.count == 3
  end

  test "latency percentiles are monotonic" do
    # Insert 100 samples
    for i <- 1..100 do
      Store.record_request(i * 10, :ok)
    end

    stats = Store.get_latency_stats()
    assert stats.p50 <= stats.p95, "p50 must be <= p95"
    assert stats.p95 <= stats.p99, "p95 must be <= p99"
    assert stats.p99 <= stats.max, "p99 must be <= max"
  end

  test "set_active_workers is reflected in counters" do
    Store.set_active_workers(42)
    assert Store.get_counters().active_workers == 42
  end

  test "reset clears all counters" do
    Store.record_request(100, :ok)
    Store.record_request(200, :error)
    Store.set_active_workers(10)
    Store.reset()
    counters = Store.get_counters()
    assert counters.total   == 0
    assert counters.success == 0
    assert counters.failure == 0
    assert counters.active_workers == 0
  end

  test "concurrent writes are safe" do
    # Spawn 100 tasks all writing simultaneously — should not crash or corrupt
    tasks = for i <- 1..100 do
      Task.async(fn ->
        status = if rem(i, 5) == 0, do: :error, else: :ok
        Store.record_request(i, status)
      end)
    end

    Enum.each(tasks, &Task.await/1)

    counters = Store.get_counters()
    assert counters.total == 100
    assert counters.success + counters.failure == 100
  end
end
