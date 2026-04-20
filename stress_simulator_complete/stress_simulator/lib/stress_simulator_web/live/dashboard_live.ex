defmodule StressSimulatorWeb.DashboardLive do
  @moduledoc """
  Main LiveView dashboard.

  Subscribes to three PubSub topics:
    - "metrics:updates"    — 500ms snapshots from Aggregator
    - "simulation:status"  — state changes from Coordinator/Orchestrator
    - "ramp:updates"       — ramp phase changes from RampScheduler

  Maintains a rolling 60-point timeseries buffer in assigns for charts.
  """
  use StressSimulatorWeb, :live_view
  require Logger

  alias StressSimulator.Metrics.{Store, Aggregator}
  alias StressSimulator.Simulation.{Coordinator, RampScheduler}
  alias StressSimulator.Distributed.{NodeRegistry, MasterOrchestrator}

  @max_chart_points 60

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Aggregator.subscribe()
      Phoenix.PubSub.subscribe(StressSimulator.PubSub, "simulation:status")
      Phoenix.PubSub.subscribe(StressSimulator.PubSub, "ramp:updates")
    end

    snapshot = Aggregator.get_latest()
    status_info = Coordinator.get_status()
    ramp_info = RampScheduler.get_state()
    nodes = NodeRegistry.list_nodes()
    timeseries = Store.get_timeseries(60)

    socket =
      assign(socket,
        url: "http://localhost:4001/api/mock",
        concurrency: "200",
        request_rate: "",
        timeout_ms: "5000",
        jitter_enabled: false,
        jitter_distribution: "uniform",
        jitter_min_ms: "50",
        jitter_max_ms: "300",
        ramp_enabled: false,
        ramp_profile: "linear",
        ramp_up_seconds: "30",
        sustain_seconds: "60",
        ramp_down_seconds: "10",
        ramp_peak_concurrency: "500",
        ramp_start_concurrency: "1",
        ramp_step_count: "10",
        distributed_enabled: false,
        sim_status: status_info.status,
        circuit_state: status_info.circuit_state,
        effective_concurrency: status_info.effective_concurrency,
        metrics: snapshot,
        chart_points: build_initial_chart(timeseries),
        ramp_phase: ramp_info.phase,
        ramp_current: ramp_info.current_concurrency,
        ramp_config: ramp_info.config,
        nodes: nodes,
        active_tab: :simulation,
        flash_msg: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("start_simulation", params, socket) do
    config = build_config(params, socket)

    result =
      if socket.assigns.distributed_enabled do
        MasterOrchestrator.start_distributed(config)
      else
        Coordinator.start_simulation(config)
      end

    case result do
      {:ok, _} -> {:noreply, assign(socket, flash_msg: {:info, "Simulation started"})}
      {:error, msg} -> {:noreply, assign(socket, flash_msg: {:error, msg})}
    end
  end

  def handle_event("stop_simulation", _params, socket) do
    if socket.assigns.distributed_enabled do
      MasterOrchestrator.stop_distributed()
    else
      Coordinator.stop_simulation()
    end
    {:noreply, assign(socket, flash_msg: {:info, "Simulation stopped"})}
  end

  def handle_event("pause_simulation", _params, socket) do
    Coordinator.pause_simulation()
    {:noreply, socket}
  end

  def handle_event("resume_simulation", _params, socket) do
    Coordinator.resume_simulation()
    {:noreply, socket}
  end

  def handle_event("adjust_concurrency", %{"value" => val}, socket) do
    case Integer.parse(val) do
      {n, ""} -> Coordinator.adjust_concurrency(n)
      _ -> :ok
    end
    {:noreply, assign(socket, concurrency: val)}
  end

  def handle_event("update_field", %{"field" => field, "value" => value}, socket) do
    {:noreply, assign(socket, String.to_existing_atom(field), value)}
  end

  def handle_event("toggle_jitter", _params, socket) do
    {:noreply, assign(socket, jitter_enabled: !socket.assigns.jitter_enabled)}
  end

  def handle_event("toggle_ramp", _params, socket) do
    {:noreply, assign(socket, ramp_enabled: !socket.assigns.ramp_enabled)}
  end

  def handle_event("toggle_distributed", _params, socket) do
    {:noreply, assign(socket, distributed_enabled: !socket.assigns.distributed_enabled)}
  end

  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, flash_msg: nil)}
  end

  @impl true
  def handle_info({:metrics_update, snapshot}, socket) do
    new_points = add_chart_point(socket.assigns.chart_points, snapshot)
    {:noreply, assign(socket, metrics: snapshot, chart_points: new_points)}
  end

  def handle_info({:status_update, info}, socket) do
    {:noreply,
     assign(socket,
       sim_status: info.status,
       circuit_state: info.circuit_state,
       effective_concurrency: info.effective_concurrency || 0
     )}
  end

  def handle_info({:distributed_status_update, info}, socket) do
    {:noreply, assign(socket, sim_status: info.status, nodes: NodeRegistry.list_nodes())}
  end

  def handle_info({:ramp_update, info}, socket) do
    {:noreply,
     assign(socket,
       ramp_phase: info.phase,
       ramp_current: info.current_concurrency,
       nodes: NodeRegistry.list_nodes()
     )}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp build_config(params, socket) do
    base = %{
      url: params["url"] || socket.assigns.url,
      concurrency: parse_int(params["concurrency"] || socket.assigns.concurrency, 100),
      timeout_ms: parse_int(params["timeout_ms"] || socket.assigns.timeout_ms, 5000),
      request_rate: parse_rate(params["request_rate"] || socket.assigns.request_rate)
    }

    base =
      if socket.assigns.jitter_enabled do
        Map.put(base, :jitter, %{
          distribution: String.to_existing_atom(socket.assigns.jitter_distribution),
          min_ms: parse_int(socket.assigns.jitter_min_ms, 50),
          max_ms: parse_int(socket.assigns.jitter_max_ms, 300)
        })
      else
        base
      end

    if socket.assigns.ramp_enabled do
      Map.put(base, :ramp, %{
        profile: socket.assigns.ramp_profile,
        ramp_up_seconds: parse_int(socket.assigns.ramp_up_seconds, 30),
        sustain_seconds: parse_int(socket.assigns.sustain_seconds, 60),
        ramp_down_seconds: parse_int(socket.assigns.ramp_down_seconds, 10),
        peak_concurrency: parse_int(socket.assigns.ramp_peak_concurrency, 500),
        start_concurrency: parse_int(socket.assigns.ramp_start_concurrency, 1),
        step_count: parse_int(socket.assigns.ramp_step_count, 10)
      })
    else
      base
    end
  end

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      _ -> default
    end
  end
  defp parse_int(val, _) when is_integer(val), do: val
  defp parse_int(_, d), do: d

  defp parse_rate(""), do: :unlimited
  defp parse_rate(nil), do: :unlimited
  defp parse_rate(:unlimited), do: :unlimited
  defp parse_rate(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> :unlimited
    end
  end

  defp build_initial_chart(timeseries) do
    timeseries
    |> Enum.map(fn b -> %{t: b.timestamp, rps: b.requests, errors: b.errors, latency: b.avg_latency} end)
    |> Enum.take(-@max_chart_points)
  end

  defp add_chart_point(points, snapshot) do
    new_point = %{
      t: snapshot.timestamp,
      rps: snapshot.rps,
      errors: Float.round(snapshot.rps * snapshot.failure_rate, 1),
      latency: snapshot.latency.avg
    }
    ([new_point | Enum.reverse(points)] |> Enum.take(@max_chart_points) |> Enum.reverse())
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: to_string(n)

  defp parse_diagram_int(val, d) when is_binary(val) do
    case Integer.parse(val) do {n, _} -> n; _ -> d end
  end
  defp parse_diagram_int(val, _) when is_integer(val), do: val
  defp parse_diagram_int(_, d), do: d

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <header class="dash-header">
        <div class="header-brand">
          <span class="brand-icon">⚡</span>
          <span class="brand-name">StressKit</span>
          <span class="brand-sub">Concurrent API Simulator</span>
        </div>
        <div class="header-status">
          <span class={"status-badge status-#{@sim_status}"}>
            <%= String.upcase(to_string(@sim_status)) %>
          </span>
          <%= if @circuit_state != :closed do %>
            <span class={"circuit-badge circuit-#{@circuit_state}"}>
              CIRCUIT <%= String.upcase(to_string(@circuit_state)) %>
            </span>
          <% end %>
          <%= if @metrics.backpressure do %>
            <span class="backpressure-badge">⚠ BACKPRESSURE</span>
          <% end %>
        </div>
      </header>

      <%= if @flash_msg do %>
        <div class={"flash flash-#{elem(@flash_msg, 0)}"} phx-click="dismiss_flash">
          <%= elem(@flash_msg, 1) %> <span class="flash-close">×</span>
        </div>
      <% end %>

      <div class="kpi-row">
        <.kpi label="Total Requests" value={format_number(@metrics.total_requests)} />
        <.kpi label="Req/sec" value={"#{@metrics.rps}"} accent />
        <.kpi label="Active Workers" value={to_string(@metrics.active_workers)} />
        <.kpi label="Success Rate"
          value={"#{Float.round((1 - @metrics.failure_rate) * 100, 1)}%"}
          good={@metrics.failure_rate < 0.05}
          warn={@metrics.failure_rate >= 0.05 && @metrics.failure_rate < 0.2}
          bad={@metrics.failure_rate >= 0.2} />
        <.kpi label="Avg Latency" value={"#{@metrics.latency.avg}ms"} />
        <.kpi label="p95 Latency" value={"#{@metrics.latency.p95}ms"}
          warn={@metrics.latency.p95 > 1000} bad={@metrics.latency.p95 > 2000} />
      </div>

      <%= if @ramp_phase not in [:idle, :done, nil] do %>
        <div class="ramp-bar-container">
          <div class="ramp-bar-header">
            <span class="ramp-phase-label">RAMP: <%= String.upcase(to_string(@ramp_phase)) %></span>
            <span class="ramp-concurrency-label"><%= @ramp_current %> / <%= (@ramp_config && @ramp_config.peak_concurrency) || 0 %> workers</span>
          </div>
          <div class="ramp-bar-track">
            <div class="ramp-bar-fill"
              style={"width: #{min(round((@ramp_current || 0) / max((@ramp_config && @ramp_config.peak_concurrency) || 1, 1) * 100), 100)}%"}>
            </div>
          </div>
        </div>
      <% end %>

      <div class="main-tabs">
        <button class={"tab-btn #{if @active_tab == :simulation, do: "active"}"} phx-click="set_tab" phx-value-tab="simulation">Configure</button>
        <button class={"tab-btn #{if @active_tab == :charts, do: "active"}"} phx-click="set_tab" phx-value-tab="charts">Live Charts</button>
        <button class={"tab-btn #{if @active_tab == :nodes, do: "active"}"} phx-click="set_tab" phx-value-tab="nodes">
          Nodes (<%= length(@nodes) %>)
        </button>
      </div>

      <div class="tab-content">
        <%= if @active_tab == :simulation do %>
          <form phx-submit="start_simulation" class="config-form">
            <div class="config-grid">
              <div class="config-section">
                <h3 class="section-title">Target & Load</h3>
                <div class="field-group">
                  <label class="field-label">Target URL</label>
                  <input class="field-input" type="text" name="url" value={@url}
                         placeholder="http://localhost:4001/api/mock" />
                  <span class="field-hint">Built-in mock available at localhost:4001/api/mock</span>
                </div>
                <div class="field-row">
                  <div class="field-group">
                    <label class="field-label">Concurrency</label>
                    <input class="field-input" type="number" name="concurrency" value={@concurrency} min="1" max="2000" />
                    <span class="field-hint">Concurrent workers (max 2000)</span>
                  </div>
                  <div class="field-group">
                    <label class="field-label">Rate Limit (req/s)</label>
                    <input class="field-input" type="number" name="request_rate" value={@request_rate} placeholder="unlimited" />
                  </div>
                  <div class="field-group">
                    <label class="field-label">Timeout (ms)</label>
                    <input class="field-input" type="number" name="timeout_ms" value={@timeout_ms} min="100" />
                  </div>
                </div>
                <%= if @sim_status == :running do %>
                  <div class="live-adjust">
                    <label class="field-label">⚡ Live Concurrency — drag to adjust in real time</label>
                    <div class="slider-row">
                      <input type="range" min="1" max="2000" value={to_string(@effective_concurrency)}
                             phx-change="adjust_concurrency" name="value" class="concurrency-slider" />
                      <span class="slider-val"><%= @effective_concurrency %></span>
                    </div>
                  </div>
                <% end %>
              </div>

              <div class="config-section">
                <div class="section-header-toggle">
                  <h3 class="section-title">Jitter — Randomized Intervals</h3>
                  <button type="button" class={"toggle-btn #{if @jitter_enabled, do: "active"}"} phx-click="toggle_jitter">
                    <%= if @jitter_enabled, do: "ON", else: "OFF" %>
                  </button>
                </div>
                <p class="section-desc">
                  Adds random per-worker delays before each request, spreading arrivals across time rather than synchronized bursts. Makes load patterns statistically realistic.
                </p>
                <%= if @jitter_enabled do %>
                  <div class="field-group">
                    <label class="field-label">Distribution Model</label>
                    <select class="field-input" name="jitter_distribution"
                            phx-change="update_field" phx-value-field="jitter_distribution">
                      <option value="uniform" selected={@jitter_distribution == "uniform"}>Uniform — flat random spread</option>
                      <option value="gaussian" selected={@jitter_distribution == "gaussian"}>Gaussian — bell curve (realistic think-time)</option>
                      <option value="exponential" selected={@jitter_distribution == "exponential"}>Exponential — Poisson arrivals (most rigorous)</option>
                    </select>
                  </div>
                  <div class="field-row">
                    <div class="field-group">
                      <label class="field-label">Min Delay (ms)</label>
                      <input class="field-input" type="number" name="jitter_min_ms" value={@jitter_min_ms} min="0"
                             phx-blur="update_field" phx-value-field="jitter_min_ms" />
                    </div>
                    <div class="field-group">
                      <label class="field-label">Max Delay (ms)</label>
                      <input class="field-input" type="number" name="jitter_max_ms" value={@jitter_max_ms} min="0"
                             phx-blur="update_field" phx-value-field="jitter_max_ms" />
                    </div>
                  </div>
                  <div class="jitter-note">
                    <span class="jitter-note-icon">ℹ</span>
                    Jitter delay occurs before the request clock starts — latency numbers are unaffected.
                  </div>
                <% end %>
              </div>

              <div class="config-section">
                <div class="section-header-toggle">
                  <h3 class="section-title">Ramp-Up Schedule</h3>
                  <button type="button" class={"toggle-btn #{if @ramp_enabled, do: "active"}"} phx-click="toggle_ramp">
                    <%= if @ramp_enabled, do: "ON", else: "OFF" %>
                  </button>
                </div>
                <p class="section-desc">
                  Start at low concurrency and scale up over time. Watch the chart — the server's breaking point appears as an inflection in the error rate and latency curves.
                </p>
                <%= if @ramp_enabled do %>
                  <div class="field-group">
                    <label class="field-label">Ramp Profile</label>
                    <select class="field-input" name="ramp_profile"
                            phx-change="update_field" phx-value-field="ramp_profile">
                      <option value="linear" selected={@ramp_profile == "linear"}>Linear — steady, predictable climb</option>
                      <option value="exponential" selected={@ramp_profile == "exponential"}>Exponential — slow start, fast finish</option>
                      <option value="step" selected={@ramp_profile == "step"}>Step — discrete jumps (reveals step-function failures)</option>
                      <option value="sine_wave" selected={@ramp_profile == "sine_wave"}>Sine Wave — oscillating load (tests elasticity)</option>
                    </select>
                  </div>
                  <div class="field-row">
                    <div class="field-group">
                      <label class="field-label">Start Workers</label>
                      <input class="field-input" type="number" name="ramp_start_concurrency" value={@ramp_start_concurrency}
                             min="1" phx-blur="update_field" phx-value-field="ramp_start_concurrency" />
                    </div>
                    <div class="field-group">
                      <label class="field-label">Peak Workers</label>
                      <input class="field-input" type="number" name="ramp_peak_concurrency" value={@ramp_peak_concurrency}
                             min="1" phx-blur="update_field" phx-value-field="ramp_peak_concurrency" />
                    </div>
                  </div>
                  <div class="field-row">
                    <div class="field-group">
                      <label class="field-label">Ramp Up (sec)</label>
                      <input class="field-input" type="number" name="ramp_up_seconds" value={@ramp_up_seconds}
                             min="1" phx-blur="update_field" phx-value-field="ramp_up_seconds" />
                    </div>
                    <div class="field-group">
                      <label class="field-label">Sustain (sec)</label>
                      <input class="field-input" type="number" name="sustain_seconds" value={@sustain_seconds}
                             min="0" phx-blur="update_field" phx-value-field="sustain_seconds" />
                    </div>
                    <div class="field-group">
                      <label class="field-label">Ramp Down (sec)</label>
                      <input class="field-input" type="number" name="ramp_down_seconds" value={@ramp_down_seconds}
                             min="0" phx-blur="update_field" phx-value-field="ramp_down_seconds" />
                    </div>
                  </div>
                  <%= if @ramp_profile == "step" do %>
                    <div class="field-group">
                      <label class="field-label">Step Count</label>
                      <input class="field-input" type="number" name="ramp_step_count" value={@ramp_step_count}
                             min="2" phx-blur="update_field" phx-value-field="ramp_step_count" />
                    </div>
                  <% end %>
                  <%
                    up = parse_diagram_int(@ramp_up_seconds, 30)
                    sustain = parse_diagram_int(@sustain_seconds, 0)
                    down = parse_diagram_int(@ramp_down_seconds, 0)
                    total = max(up + sustain + down, 1)
                    up_pct = Float.round(up / total * 100, 1)
                    sustain_pct = Float.round(sustain / total * 100, 1)
                    down_pct = Float.round(down / total * 100, 1)
                  %>
                  <div class="ramp-diagram">
                    <div class="ramp-viz">
                      <div class="ramp-seg ramp-seg-up" style={"width: #{up_pct}%"}>
                        <%= if up_pct > 12, do: "↗ #{up}s" %>
                      </div>
                      <%= if sustain > 0 do %>
                        <div class="ramp-seg ramp-seg-sustain" style={"width: #{sustain_pct}%"}>
                          <%= if sustain_pct > 12, do: "— #{sustain}s" %>
                        </div>
                      <% end %>
                      <%= if down > 0 do %>
                        <div class="ramp-seg ramp-seg-down" style={"width: #{down_pct}%"}>
                          <%= if down_pct > 12, do: "↘ #{down}s" %>
                        </div>
                      <% end %>
                    </div>
                    <div class="ramp-labels">
                      <span>0s</span><span><%= total %>s</span>
                    </div>
                  </div>
                <% end %>
              </div>

              <div class="config-section">
                <div class="section-header-toggle">
                  <h3 class="section-title">Distributed Mode</h3>
                  <button type="button" class={"toggle-btn #{if @distributed_enabled, do: "active"}"} phx-click="toggle_distributed">
                    <%= if @distributed_enabled, do: "ON", else: "OFF" %>
                  </button>
                </div>
                <p class="section-desc">
                  Split load across multiple Elixir nodes. The master orchestrator divides the concurrency quota and rebalances automatically if a node fails.
                </p>
                <%= if @distributed_enabled do %>
                  <div class="distributed-setup">
                    <div class="code-block">
                      <span class="code-comment"># Start master node:</span>
                      <code>iex --name master@127.0.0.1 --cookie stress_cookie -S mix phx.server</code>
                    </div>
                    <div class="code-block">
                      <span class="code-comment"># Start worker nodes (separate machines/terminals):</span>
                      <code>iex --name worker1@127.0.0.1 --cookie stress_cookie -S mix run --no-halt</code>
                    </div>
                    <div class="code-block">
                      <span class="code-comment"># Register worker with master (from worker iex):</span>
                      <code>Node.connect(:"master@127.0.0.1")
StressSimulator.Distributed.WorkerAgent.register_with_master(:"master@127.0.0.1")</code>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <div class="action-row">
              <%= if @sim_status == :idle do %>
                <button type="submit" class="btn btn-start">▶ Start Simulation</button>
              <% end %>
              <%= if @sim_status == :running do %>
                <button type="button" class="btn btn-pause" phx-click="pause_simulation">⏸ Pause</button>
                <button type="button" class="btn btn-stop" phx-click="stop_simulation">■ Stop</button>
              <% end %>
              <%= if @sim_status == :paused do %>
                <button type="button" class="btn btn-start" phx-click="resume_simulation">▶ Resume</button>
                <button type="button" class="btn btn-stop" phx-click="stop_simulation">■ Stop</button>
              <% end %>
            </div>
          </form>
        <% end %>

        <%= if @active_tab == :charts do %>
          <div class="charts-container">
            <div class="chart-panel">
              <h3 class="chart-title">Requests / Second</h3>
              <div class="chart-wrapper">
                <canvas id="rps-chart" phx-hook="RpsChart" data-points={Jason.encode!(@chart_points)}></canvas>
              </div>
            </div>
            <div class="chart-panel">
              <h3 class="chart-title">Latency (ms)</h3>
              <div class="chart-wrapper">
                <canvas id="latency-chart" phx-hook="LatencyChart" data-points={Jason.encode!(@chart_points)}></canvas>
              </div>
            </div>
            <div class="latency-breakdown">
              <h3 class="chart-title">Latency Percentiles</h3>
              <div class="percentile-grid">
                <.pct label="Min" value={@metrics.latency.min} />
                <.pct label="P50" value={@metrics.latency.p50} />
                <.pct label="Avg" value={@metrics.latency.avg} accent />
                <.pct label="P95" value={@metrics.latency.p95} warn={@metrics.latency.p95 > 1000} />
                <.pct label="P99" value={@metrics.latency.p99} warn={@metrics.latency.p99 > 2000} />
                <.pct label="Max" value={@metrics.latency.max} />
              </div>
            </div>
            <div class="request-breakdown">
              <h3 class="chart-title">Request Outcomes</h3>
              <div class="breakdown-bars">
                <.outcome_bar label="Success" count={@metrics.success_count} total={max(@metrics.total_requests, 1)} color="success" />
                <.outcome_bar label="Failure" count={@metrics.failure_count} total={max(@metrics.total_requests, 1)} color="failure" />
                <.outcome_bar label="Timeout" count={@metrics.timeout_count} total={max(@metrics.total_requests, 1)} color="timeout" />
              </div>
            </div>
          </div>
        <% end %>

        <%= if @active_tab == :nodes do %>
          <div class="nodes-panel">
            <div class="nodes-header">
              <h3 class="section-title">Connected Nodes (<%= length(@nodes) %>)</h3>
              <span class="nodes-hint">
                <%= if @distributed_enabled, do: "Distributed active — work split across healthy nodes", else: "Single-node mode" %>
              </span>
            </div>
            <%= if @nodes == [] do %>
              <div class="nodes-empty">
                <div class="nodes-empty-icon">🔌</div>
                <p>No worker nodes connected.</p>
                <p class="nodes-empty-sub">Enable Distributed mode and follow the setup instructions to connect worker nodes.</p>
              </div>
            <% else %>
              <div class="nodes-grid">
                <%= for node <- @nodes do %>
                  <div class={"node-card node-#{node.status}"}>
                    <div class="node-header">
                      <span class="node-name"><%= node.node %></span>
                      <span class={"node-status-dot dot-#{node.status}"}></span>
                    </div>
                    <div class="node-stats">
                      <div class="node-stat">
                        <span class="ns-label">Quota</span>
                        <span class="ns-value"><%= node.assigned_concurrency %> workers</span>
                      </div>
                      <div class="node-stat">
                        <span class="ns-label">Status</span>
                        <span class="ns-value"><%= node.status %></span>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :accent, :boolean, default: false
  attr :good, :boolean, default: false
  attr :warn, :boolean, default: false
  attr :bad, :boolean, default: false

  def kpi(assigns) do
    ~H"""
    <div class={"kpi-card #{if @accent, do: "kpi-accent"} #{if @good, do: "kpi-good"} #{if @warn, do: "kpi-warn"} #{if @bad, do: "kpi-bad"}"}>
      <span class="kpi-value"><%= @value %></span>
      <span class="kpi-label"><%= @label %></span>
    </div>
    """
  end

  attr :label, :string; attr :value, :any; attr :accent, :boolean, default: false; attr :warn, :boolean, default: false
  def pct(assigns) do
    ~H"""
    <div class={"pct-cell #{if @accent, do: "pct-accent"} #{if @warn, do: "pct-warn"}"}>
      <span class="pct-value"><%= @value %>ms</span>
      <span class="pct-label"><%= @label %></span>
    </div>
    """
  end

  attr :label, :string; attr :count, :integer; attr :total, :integer; attr :color, :string
  def outcome_bar(assigns) do
    pct = Float.round(assigns.count / assigns.total * 100, 1)
    assigns = assign(assigns, pct: pct)
    ~H"""
    <div class="outcome-row">
      <span class="outcome-label"><%= @label %></span>
      <div class="outcome-track">
        <div class={"outcome-fill outcome-#{@color}"} style={"width: #{@pct}%"}></div>
      </div>
      <span class="outcome-count"><%= format_number(@count) %> (<%= @pct %>%)</span>
    </div>
    """
  end
end
