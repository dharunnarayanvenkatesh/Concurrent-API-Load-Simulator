defmodule StressSimulator.Simulation.RampScheduler do
  @moduledoc """
  Controls the concurrency ramp-up (and optional ramp-down) lifecycle.

  ## Why a separate process?

  The Coordinator owns the *current* effective concurrency at any instant.
  The RampScheduler is the *policy engine* that decides how concurrency
  changes over time — decoupled so ramp logic can be swapped independently.

  ## Ramp profiles

    :linear       — concurrency climbs at a constant rate per second
    :exponential  — concurrency doubles on each step (aggressive)
    :step         — jumps in discrete equal steps at fixed intervals
    :sine_wave    — oscillates between min and max (stress-test stability)

  ## Why ramp-up matters for finding failure points

  A sudden flood of 1000 concurrent requests masks *where* the server
  breaks because everything fails at once. A linear ramp from 0→1000
  over 60s shows you exactly which concurrency level triggers:
    - First elevated latencies
    - First timeouts
    - First 5xx errors
    - Full collapse

  The Aggregator broadcasts metrics every 500ms, so each ramp tick
  produces an observable data point on the chart — the failure point
  becomes visible as an inflection in the latency/error curve.
  """
  use GenServer
  require Logger

  alias StressSimulator.Simulation.Coordinator

  @pubsub StressSimulator.PubSub
  @ramp_topic "ramp:updates"

  defstruct [
    :config,
    :tick_ref,
    status: :idle,
    # Elapsed ticks since ramp started
    elapsed_ticks: 0,
    # Current concurrency level being applied
    current_concurrency: 0,
    # Track the phase: :ramp_up | :sustain | :ramp_down | :done
    phase: :idle
  ]

  ## Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Start a ramp schedule. Config keys:
    - :profile        — :linear | :exponential | :step | :sine_wave
    - :ramp_up_seconds   — how long to ramp from 0 to :peak_concurrency
    - :sustain_seconds   — how long to hold at peak (0 = no sustain)
    - :ramp_down_seconds — how long to ramp back down (0 = instant stop)
    - :peak_concurrency  — target max concurrency
    - :start_concurrency — starting concurrency (default 0)
    - :step_count        — for :step profile, number of steps (default 10)
  """
  def start_ramp(config) do
    GenServer.call(__MODULE__, {:start_ramp, config})
  end

  def stop_ramp() do
    GenServer.call(__MODULE__, :stop_ramp)
  end

  def get_state() do
    GenServer.call(__MODULE__, :get_state)
  end

  def subscribe() do
    Phoenix.PubSub.subscribe(@pubsub, @ramp_topic)
  end

  ## Server callbacks

  @impl true
  def init([]) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:start_ramp, raw_config}, _from, state) do
    config = normalize_ramp_config(raw_config)
    Logger.info("[RampScheduler] Starting ramp: #{inspect(config)}")

    tick_ms = Application.get_env(:stress_simulator, :simulation, [])[:ramp_tick_interval_ms] || 1_000

    # Schedule first tick immediately
    tick_ref = Process.send_after(self(), :tick, tick_ms)

    new_state = %__MODULE__{
      config: config,
      tick_ref: tick_ref,
      status: :running,
      elapsed_ticks: 0,
      current_concurrency: config.start_concurrency,
      phase: :ramp_up
    }

    # Apply starting concurrency right away
    Coordinator.adjust_concurrency(config.start_concurrency)
    broadcast_ramp_state(new_state)

    {:reply, {:ok, config}, new_state}
  end

  def handle_call(:stop_ramp, _from, state) do
    if state.tick_ref, do: Process.cancel_timer(state.tick_ref)
    new_state = %__MODULE__{status: :idle, phase: :idle}
    broadcast_ramp_state(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:get_state, _from, state) do
    info = %{
      status: state.status,
      phase: state.phase,
      elapsed_ticks: state.elapsed_ticks,
      current_concurrency: state.current_concurrency,
      config: state.config
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info(:tick, %{status: :running} = state) do
    tick_ms = Application.get_env(:stress_simulator, :simulation, [])[:ramp_tick_interval_ms] || 1_000

    new_state = advance_ramp(state)

    # Apply the new concurrency to the Coordinator
    if new_state.current_concurrency != state.current_concurrency do
      Coordinator.adjust_concurrency(new_state.current_concurrency)
      Logger.debug("[RampScheduler] Concurrency → #{new_state.current_concurrency} (phase: #{new_state.phase})")
    end

    broadcast_ramp_state(new_state)

    # Schedule next tick unless we're done
    new_state =
      if new_state.phase == :done do
        Logger.info("[RampScheduler] Ramp sequence complete")
        %{new_state | status: :idle, tick_ref: nil}
      else
        ref = Process.send_after(self(), :tick, tick_ms)
        %{new_state | tick_ref: ref}
      end

    {:noreply, new_state}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  ## Private: ramp advancement state machine

  defp advance_ramp(%{phase: :ramp_up} = state) do
    %{config: cfg, elapsed_ticks: t} = state
    new_ticks = t + 1
    target = compute_concurrency(cfg.profile, new_ticks, cfg)

    cond do
      # Reached peak — enter sustain or finish
      target >= cfg.peak_concurrency ->
        clamped = cfg.peak_concurrency

        if cfg.sustain_seconds > 0 do
          %{state | elapsed_ticks: 0, current_concurrency: clamped, phase: :sustain}
        else
          %{state | elapsed_ticks: 0, current_concurrency: clamped, phase: :ramp_down}
        end

      true ->
        %{state | elapsed_ticks: new_ticks, current_concurrency: target}
    end
  end

  defp advance_ramp(%{phase: :sustain} = state) do
    %{config: cfg, elapsed_ticks: t} = state
    new_ticks = t + 1

    if new_ticks >= cfg.sustain_seconds do
      next_phase = if cfg.ramp_down_seconds > 0, do: :ramp_down, else: :done
      %{state | elapsed_ticks: 0, phase: next_phase}
    else
      %{state | elapsed_ticks: new_ticks}
    end
  end

  defp advance_ramp(%{phase: :ramp_down} = state) do
    %{config: cfg, elapsed_ticks: t} = state
    new_ticks = t + 1

    if cfg.ramp_down_seconds == 0 do
      %{state | current_concurrency: cfg.start_concurrency, phase: :done}
    else
      # Linear ramp-down regardless of original profile
      progress = min(new_ticks / cfg.ramp_down_seconds, 1.0)
      target = round(cfg.peak_concurrency * (1.0 - progress))
      target = max(target, cfg.start_concurrency)

      if target <= cfg.start_concurrency do
        %{state | elapsed_ticks: new_ticks, current_concurrency: cfg.start_concurrency, phase: :done}
      else
        %{state | elapsed_ticks: new_ticks, current_concurrency: target}
      end
    end
  end

  defp advance_ramp(%{phase: :done} = state), do: state

  ## Private: concurrency profiles

  # Linear: concurrency grows proportionally to elapsed time
  defp compute_concurrency(:linear, ticks, cfg) do
    ticks_for_ramp = cfg.ramp_up_seconds
    progress = min(ticks / ticks_for_ramp, 1.0)
    round(cfg.start_concurrency + (cfg.peak_concurrency - cfg.start_concurrency) * progress)
  end

  # Exponential: starts slow, accelerates — good for finding limits quickly
  # Uses 2^(10*progress) - 1 normalized to [start, peak]
  defp compute_concurrency(:exponential, ticks, cfg) do
    progress = min(ticks / cfg.ramp_up_seconds, 1.0)
    # Normalized exponential: 0→1 maps to slow start, fast finish
    exp_progress = (:math.pow(10, progress) - 1) / (:math.pow(10, 1) - 1)
    round(cfg.start_concurrency + (cfg.peak_concurrency - cfg.start_concurrency) * exp_progress)
  end

  # Step: jumps in discrete equal increments
  # e.g. 0→100→200→300... every N seconds
  defp compute_concurrency(:step, ticks, cfg) do
    steps = cfg.step_count
    seconds_per_step = max(div(cfg.ramp_up_seconds, steps), 1)
    current_step = min(div(ticks, seconds_per_step), steps)
    step_size = div(cfg.peak_concurrency - cfg.start_concurrency, steps)
    min(cfg.start_concurrency + current_step * step_size, cfg.peak_concurrency)
  end

  # Sine wave: oscillates between start and peak — tests stability under variable load
  # Full cycle = ramp_up_seconds
  defp compute_concurrency(:sine_wave, ticks, cfg) do
    frequency = 2 * :math.pi / cfg.ramp_up_seconds
    midpoint = (cfg.peak_concurrency + cfg.start_concurrency) / 2
    amplitude = (cfg.peak_concurrency - cfg.start_concurrency) / 2
    round(midpoint + amplitude * :math.sin(frequency * ticks - :math.pi / 2))
  end

  ## Private: config & broadcast

  defp normalize_ramp_config(raw) do
    max_c = Application.get_env(:stress_simulator, :simulation, [])[:max_concurrency] || 2000

    %{
      profile: normalize_profile(raw[:profile] || raw["profile"] || "linear"),
      ramp_up_seconds: raw[:ramp_up_seconds] || raw["ramp_up_seconds"] || 30,
      sustain_seconds: raw[:sustain_seconds] || raw["sustain_seconds"] || 0,
      ramp_down_seconds: raw[:ramp_down_seconds] || raw["ramp_down_seconds"] || 0,
      peak_concurrency: min(raw[:peak_concurrency] || raw["peak_concurrency"] || 500, max_c),
      start_concurrency: raw[:start_concurrency] || raw["start_concurrency"] || 1,
      step_count: raw[:step_count] || raw["step_count"] || 10
    }
  end

  defp normalize_profile(p) when is_atom(p), do: p
  defp normalize_profile("linear"), do: :linear
  defp normalize_profile("exponential"), do: :exponential
  defp normalize_profile("step"), do: :step
  defp normalize_profile("sine_wave"), do: :sine_wave
  defp normalize_profile(_), do: :linear

  defp broadcast_ramp_state(state) do
    info = %{
      status: state.status,
      phase: state.phase,
      elapsed_ticks: state.elapsed_ticks,
      current_concurrency: state.current_concurrency,
      peak_concurrency: state.config && state.config.peak_concurrency,
      ramp_up_seconds: state.config && state.config.ramp_up_seconds,
      profile: state.config && state.config.profile
    }

    Phoenix.PubSub.broadcast(@pubsub, @ramp_topic, {:ramp_update, info})
  end
end
