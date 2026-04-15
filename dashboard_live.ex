defmodule StressSimWeb.DashboardLive do
  @moduledoc """
  Real-time stress test dashboard using Phoenix LiveView.

  Update strategy:
  - On simulation start, subscribe to "metrics:#{sim_id}" PubSub topic
  - Aggregator broadcasts every 500ms → handle_info updates assigns
  - LiveView diffs only changed parts of DOM (no full page re-renders)
  - Chart history is stored in the metrics snapshot itself (ring buffer)

  No JavaScript framework needed — LiveView + our custom canvas charts
  handle everything reactively.
  """
  use StressSimWeb, :live_view

  alias StressSim.{Simulation, Metrics.Store}

  @defaults %{
    target_url:      "http://localhost:4001/mock",
    concurrency:     100,
    rate_per_second: 200,
    duration_sec:    :infinite,
    method:          "get",
    timeout_ms:      5_000
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
           form_params: @defaults,
           sim_id: nil,
           running: false,
           metrics: Store.empty_snapshot(),
           circuit_status: :closed,
           error: nil,
           duration_str: "infinite"
         )

    {:ok, socket}
  end

  @impl true
  def handle_event("start_simulation", params, socket) do
    with {:ok, config} <- parse_config(params) do
      case Simulation.start(config) do
        {:ok, sim_id} ->
          # Subscribe to real-time metric pushes from Aggregator
          Phoenix.PubSub.subscribe(StressSim.PubSub, "metrics:#{sim_id}")

          socket =
            socket
            |> assign(sim_id: sim_id, running: true, error: nil)
            |> assign(form_params: params_to_form(params))

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, error: inspect(reason))}
      end
    else
      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  @impl true
  def handle_event("stop_simulation", _params, socket) do
    if socket.assigns.sim_id do
      Simulation.stop(socket.assigns.sim_id)
      Phoenix.PubSub.unsubscribe(StressSim.PubSub, "metrics:#{socket.assigns.sim_id}")
    end

    {:noreply, assign(socket, running: false, sim_id: nil)}
  end

  @impl true
  def handle_event("update_concurrency", %{"concurrency" => c}, socket) do
    if socket.assigns.sim_id && socket.assigns.running do
      case Integer.parse(c) do
        {n, ""} when n > 0 ->
          Simulation.update_concurrency(socket.assigns.sim_id, n)
          {:noreply, socket}
        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate", params, socket) do
    # Live validation — just update form display
    {:noreply, assign(socket, form_params: params_to_form(params))}
  end

  @impl true
  def handle_info({:metrics_update, snapshot}, socket) do
    circuit_status = if socket.assigns.sim_id do
      Simulation.circuit_status(socket.assigns.sim_id)
    else
      :closed
    end

    {:noreply, assign(socket, metrics: snapshot, circuit_status: circuit_status)}
  end

  ## ── Render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <!-- Header -->
      <header class="dash-header">
        <div class="header-content">
          <div class="header-brand">
            <div class="brand-icon">⚡</div>
            <div>
              <h1>STRESS SIM</h1>
              <p class="brand-sub">Concurrent API Load Testing</p>
            </div>
          </div>
          <div class="header-status">
            <div class={"status-dot #{if @running, do: "status-running", else: "status-idle"}"}>
            </div>
            <span class={"status-label #{if @running, do: "running", else: ""}"}>
              <%= if @running, do: "RUNNING", else: "IDLE" %>
            </span>
            <%= if @running do %>
              <span class="sim-id">ID: <%= @sim_id %></span>
            <% end %>
          </div>
        </div>
      </header>

      <main class="dash-main">
        <!-- Config Panel -->
        <aside class="config-panel">
          <h2 class="panel-title">SIMULATION CONFIG</h2>

          <%= if @error do %>
            <div class="error-banner">⚠ <%= @error %></div>
          <% end %>

          <form phx-submit="start_simulation" phx-change="validate" class="config-form">
            <div class="field-group">
              <label>TARGET URL</label>
              <input
                type="text"
                name="target_url"
                value={@form_params.target_url}
                placeholder="http://localhost:4001/mock"
                class="input-field"
                disabled={@running}
              />
            </div>

            <div class="field-row">
              <div class="field-group">
                <label>CONCURRENT USERS</label>
                <input
                  type="number"
                  name="concurrency"
                  value={@form_params.concurrency}
                  min="1" max="5000"
                  class="input-field"
                  disabled={@running}
                />
              </div>
              <div class="field-group">
                <label>REQ/SEC</label>
                <input
                  type="number"
                  name="rate_per_second"
                  value={@form_params.rate_per_second}
                  min="1" max="10000"
                  class="input-field"
                  disabled={@running}
                />
              </div>
            </div>

            <div class="field-row">
              <div class="field-group">
                <label>METHOD</label>
                <select name="method" class="input-field" disabled={@running}>
                  <option value="get" selected={@form_params.method == "get"}>GET</option>
                  <option value="post" selected={@form_params.method == "post"}>POST</option>
                </select>
              </div>
              <div class="field-group">
                <label>TIMEOUT (ms)</label>
                <input
                  type="number"
                  name="timeout_ms"
                  value={@form_params.timeout_ms}
                  min="100" max="30000"
                  class="input-field"
                  disabled={@running}
                />
              </div>
            </div>

            <div class="field-group">
              <label>DURATION (sec, or 'infinite')</label>
              <input
                type="text"
                name="duration_str"
                value={@duration_str}
                placeholder="infinite"
                class="input-field"
                disabled={@running}
              />
            </div>

            <div class="form-actions">
              <%= if !@running do %>
                <button type="submit" class="btn-primary">
                  ▶ LAUNCH SIMULATION
                </button>
              <% else %>
                <button type="button" phx-click="stop_simulation" class="btn-stop">
                  ■ STOP
                </button>
              <% end %>
            </div>
          </form>

          <!-- Live concurrency slider -->
          <%= if @running do %>
            <div class="live-controls">
              <h3>LIVE CONTROLS</h3>
              <label>Adjust Concurrency</label>
              <div class="slider-row">
                <input
                  type="range"
                  min="1" max="5000"
                  value={@form_params.concurrency}
                  phx-change="update_concurrency"
                  name="concurrency"
                  class="slider"
                />
                <span class="slider-val"><%= @form_params.concurrency %></span>
              </div>
            </div>
          <% end %>

          <!-- Circuit Breaker Status -->
          <div class="circuit-status">
            <h3>CIRCUIT BREAKER</h3>
            <div class={"circuit-indicator circuit-#{@circuit_status}"}>
              <div class="circuit-dot"></div>
              <span><%= String.upcase(to_string(@circuit_status)) %></span>
            </div>
          </div>

          <!-- Quick presets -->
          <div class="presets">
            <h3>QUICK PRESETS</h3>
            <div class="preset-grid">
              <div class="preset-card" phx-click="load_preset" phx-value-preset="light">
                <div class="preset-name">LIGHT</div>
                <div class="preset-desc">50 users · 100 r/s</div>
              </div>
              <div class="preset-card" phx-click="load_preset" phx-value-preset="medium">
                <div class="preset-name">MEDIUM</div>
                <div class="preset-desc">500 users · 1k r/s</div>
              </div>
              <div class="preset-card" phx-click="load_preset" phx-value-preset="heavy">
                <div class="preset-name">HEAVY</div>
                <div class="preset-desc">2k users · 5k r/s</div>
              </div>
              <div class="preset-card" phx-click="load_preset" phx-value-preset="chaos">
                <div class="preset-name">CHAOS</div>
                <div class="preset-desc">Slow endpoint</div>
              </div>
            </div>
          </div>
        </aside>

        <!-- Metrics Panel -->
        <section class="metrics-panel">
          <!-- KPI Row -->
          <div class="kpi-row">
            <div class="kpi-card kpi-primary">
              <div class="kpi-value"><%= format_number(@metrics.total) %></div>
              <div class="kpi-label">TOTAL REQUESTS</div>
            </div>
            <div class="kpi-card kpi-success">
              <div class="kpi-value"><%= format_rps(@metrics.rps) %></div>
              <div class="kpi-label">REQ / SEC</div>
            </div>
            <div class="kpi-card kpi-latency">
              <div class="kpi-value"><%= format_ms(@metrics.avg_latency) %></div>
              <div class="kpi-label">AVG LATENCY</div>
            </div>
            <div class="kpi-card kpi-p95">
              <div class="kpi-value"><%= format_ms(@metrics.p95_latency) %></div>
              <div class="kpi-label">P95 LATENCY</div>
            </div>
            <div class={"kpi-card #{error_rate_class(@metrics.error_rate)}"}>
              <div class="kpi-value"><%= @metrics.error_rate %>%</div>
              <div class="kpi-label">ERROR RATE</div>
            </div>
            <div class="kpi-card kpi-workers">
              <div class="kpi-value"><%= @metrics.active_workers %></div>
              <div class="kpi-label">ACTIVE WORKERS</div>
            </div>
          </div>

          <!-- Charts Row -->
          <div class="charts-row">
            <div class="chart-card">
              <h3 class="chart-title">REQUESTS / SECOND</h3>
              <div class="chart-container">
                <svg viewBox="0 0 400 120" class="sparkline" preserveAspectRatio="none">
                  <%= if length(@metrics.rps_history) > 1 do %>
                    <polyline
                      points={sparkline_points(@metrics.rps_history, 400, 120)}
                      fill="none"
                      stroke="var(--accent-cyan)"
                      stroke-width="2"
                    />
                    <polyline
                      points={sparkline_fill(@metrics.rps_history, 400, 120)}
                      fill="url(#cyanGrad)"
                      stroke="none"
                    />
                  <% end %>
                  <defs>
                    <linearGradient id="cyanGrad" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="0%" stop-color="var(--accent-cyan)" stop-opacity="0.3"/>
                      <stop offset="100%" stop-color="var(--accent-cyan)" stop-opacity="0.02"/>
                    </linearGradient>
                  </defs>
                </svg>
                <div class="chart-axis-label">
                  <span>← <%= length(@metrics.rps_history) %> samples</span>
                  <span>NOW →</span>
                </div>
              </div>
            </div>

            <div class="chart-card">
              <h3 class="chart-title">AVG LATENCY (ms)</h3>
              <div class="chart-container">
                <svg viewBox="0 0 400 120" class="sparkline" preserveAspectRatio="none">
                  <%= if length(@metrics.latency_history) > 1 do %>
                    <polyline
                      points={sparkline_points(@metrics.latency_history, 400, 120)}
                      fill="none"
                      stroke="var(--accent-amber)"
                      stroke-width="2"
                    />
                    <polyline
                      points={sparkline_fill(@metrics.latency_history, 400, 120)}
                      fill="url(#amberGrad)"
                      stroke="none"
                    />
                  <% end %>
                  <defs>
                    <linearGradient id="amberGrad" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="0%" stop-color="var(--accent-amber)" stop-opacity="0.3"/>
                      <stop offset="100%" stop-color="var(--accent-amber)" stop-opacity="0.02"/>
                    </linearGradient>
                  </defs>
                </svg>
                <div class="chart-axis-label">
                  <span>← history</span>
                  <span>NOW →</span>
                </div>
              </div>
            </div>
          </div>

          <!-- Success vs Failure breakdown -->
          <div class="breakdown-row">
            <div class="breakdown-card">
              <h3 class="chart-title">SUCCESS vs FAILURE</h3>
              <div class="breakdown-body">
                <div class="breakdown-bars">
                  <div class="bar-track">
                    <div class="bar-label">Success</div>
                    <div class="bar-bg">
                      <div
                        class="bar-fill bar-success"
                        style={"width: #{success_pct(@metrics)}%"}
                      ></div>
                    </div>
                    <div class="bar-count"><%= format_number(@metrics.success) %></div>
                  </div>
                  <div class="bar-track">
                    <div class="bar-label">Failure</div>
                    <div class="bar-bg">
                      <div
                        class="bar-fill bar-failure"
                        style={"width: #{failure_pct(@metrics)}%"}
                      ></div>
                    </div>
                    <div class="bar-count"><%= format_number(@metrics.failure) %></div>
                  </div>
                </div>
                <div class="donut-wrap">
                  <%= donut_svg(@metrics) %>
                </div>
              </div>
            </div>

            <div class="breakdown-card">
              <h3 class="chart-title">SYSTEM HEALTH</h3>
              <div class="health-grid">
                <%= health_row("Concurrency", @form_params.concurrency, "workers") %>
                <%= health_row("Total Sent", @metrics.total, "req") %>
                <%= health_row("Avg Latency", "#{@metrics.avg_latency}ms", "") %>
                <%= health_row("P95 Latency", "#{@metrics.p95_latency}ms", "") %>
                <%= health_row("Error Rate", "#{@metrics.error_rate}%", "") %>
                <%= health_row("Circuit", String.upcase(to_string(@circuit_status)), "") %>
              </div>
            </div>
          </div>
        </section>
      </main>
    </div>
    """
  end

  ## ── Event handlers continued ─────────────────────────────────────────────

  @impl true
  def handle_event("load_preset", %{"preset" => preset}, socket) do
    params = case preset do
      "light"  -> %{target_url: "http://localhost:4001/mock", concurrency: 50, rate_per_second: 100}
      "medium" -> %{target_url: "http://localhost:4001/mock", concurrency: 500, rate_per_second: 1000}
      "heavy"  -> %{target_url: "http://localhost:4001/mock", concurrency: 2000, rate_per_second: 5000}
      "chaos"  -> %{target_url: "http://localhost:4001/mock/slow", concurrency: 200, rate_per_second: 500}
      _        -> %{}
    end

    form = Map.merge(@defaults, params) |> Map.new(fn {k,v} -> {k, to_string(v)} end)
    {:noreply, assign(socket, form_params: form)}
  end

  ## ── Helpers ──────────────────────────────────────────────────────────────

  defp parse_config(params) do
    with url    <- Map.get(params, "target_url", "http://localhost:4001/mock"),
         {c,""} <- Integer.parse(Map.get(params, "concurrency", "100")),
         {r,""} <- Integer.parse(Map.get(params, "rate_per_second", "200")),
         {t,""} <- Integer.parse(Map.get(params, "timeout_ms", "5000")),
         dur    <- parse_duration(Map.get(params, "duration_str", "infinite")) do
      {:ok, %{
        target_url:      url,
        concurrency:     clamp(c, 1, 5000),
        rate_per_second: clamp(r, 1, 10_000),
        duration_sec:    dur,
        method:          String.to_atom(Map.get(params, "method", "get")),
        timeout_ms:      clamp(t, 100, 30_000),
        headers:         [{"accept", "application/json"}],
        body:            nil
      }}
    else
      _ -> {:error, "Invalid parameters — check numeric fields"}
    end
  end

  defp parse_duration("infinite"), do: :infinite
  defp parse_duration(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> :infinite
    end
  end

  defp params_to_form(params) do
    %{
      target_url:      Map.get(params, "target_url", @defaults.target_url),
      concurrency:     parse_int(params, "concurrency", @defaults.concurrency),
      rate_per_second: parse_int(params, "rate_per_second", @defaults.rate_per_second),
      method:          Map.get(params, "method", "get"),
      timeout_ms:      parse_int(params, "timeout_ms", @defaults.timeout_ms)
    }
  end

  defp parse_int(params, key, default) do
    case Integer.parse(Map.get(params, key, "#{default}")) do
      {n, _} -> n
      _      -> default
    end
  end

  defp clamp(n, min, max), do: n |> max(min) |> min(max)

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000,     do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n),                      do: to_string(n)

  defp format_rps(rps), do: "#{Float.round(rps * 1.0, 1)}"
  defp format_ms(ms),   do: "#{ms}ms"

  defp error_rate_class(rate) when rate > 10, do: "kpi-error-high"
  defp error_rate_class(rate) when rate > 2,  do: "kpi-error-mid"
  defp error_rate_class(_),                   do: "kpi-error-low"

  defp success_pct(%{total: 0}), do: 0
  defp success_pct(%{success: s, total: t}), do: Float.round(s / t * 100, 1)

  defp failure_pct(%{total: 0}), do: 0
  defp failure_pct(%{failure: f, total: t}), do: Float.round(f / t * 100, 1)

  ## ── SVG chart helpers ────────────────────────────────────────────────────

  defp sparkline_points([], _, _), do: ""
  defp sparkline_points([_], _, _), do: ""
  defp sparkline_points(data, w, h) do
    max_val = Enum.max(data) |> max(1)
    count   = length(data) - 1

    data
    |> Enum.with_index()
    |> Enum.map(fn {val, i} ->
      x = Float.round(i / count * w, 2)
      y = Float.round(h - val / max_val * (h - 10) - 5, 2)
      "#{x},#{y}"
    end)
    |> Enum.join(" ")
  end

  defp sparkline_fill(data, w, h) do
    line_pts = sparkline_points(data, w, h)
    count = length(data) - 1
    last_x = w
    "#{line_pts} #{last_x},#{h} 0,#{h}"
  end

  defp donut_svg(%{total: 0}) do
    Phoenix.HTML.raw(~s(<svg viewBox="0 0 80 80" class="donut-svg">
      <circle cx="40" cy="40" r="30" fill="none" stroke="#333" stroke-width="12"/>
    </svg>))
  end

  defp donut_svg(%{success: s, total: t}) do
    pct = s / t
    circumference = 2 * :math.pi() * 30
    dash = Float.round(pct * circumference, 2)
    gap  = Float.round(circumference - dash, 2)

    Phoenix.HTML.raw("""
    <svg viewBox="0 0 80 80" class="donut-svg">
      <circle cx="40" cy="40" r="30" fill="none" stroke="#1a1a2e" stroke-width="12"/>
      <circle cx="40" cy="40" r="30" fill="none" stroke="#00ff9d" stroke-width="12"
        stroke-dasharray="#{dash} #{gap}"
        stroke-linecap="round"
        transform="rotate(-90 40 40)"/>
      <text x="40" y="44" text-anchor="middle" class="donut-label"
        font-size="14" fill="#00ff9d" font-family="monospace">
        #{Float.round(pct * 100, 1)}%
      </text>
    </svg>
    """)
  end

  defp health_row(label, value, unit) do
    assigns = %{label: label, value: value, unit: unit}
    ~H"""
    <div class="health-row">
      <span class="health-label"><%= @label %></span>
      <span class="health-value"><%= @value %> <span class="health-unit"><%= @unit %></span></span>
    </div>
    """
  end
end
