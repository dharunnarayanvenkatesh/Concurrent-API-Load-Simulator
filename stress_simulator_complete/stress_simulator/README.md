# StressKit — Concurrent API Stress Simulator

A production-grade, high-concurrency load testing tool built in Elixir with Phoenix LiveView.
Simulates thousands of concurrent API requests with real-time metrics, ramp-up scheduling,
statistical jitter models, and distributed multi-node load generation.

---

## Features

- **1000+ concurrent workers** via BEAM lightweight processes + Task.async
- **4 ramp-up profiles**: linear, exponential, step, sine wave — pinpoints server failure thresholds
- **3 jitter distributions**: uniform, gaussian (Box-Muller), exponential (Poisson) — realistic traffic shaping
- **Circuit breaker** with closed → open → half-open probe state machine
- **Adaptive backpressure**: auto-reduces concurrency when latency or error rate spikes
- **Distributed mode**: master orchestrator splits load across N worker nodes via Erlang distribution
- **Live dashboard**: Phoenix LiveView, no page reloads, 500ms metric streaming
- **Built-in mock server** on `:4001` — works out of the box, no external API needed
- **REST API** for CI/CD pipeline integration
- **ETS metrics store**: sub-microsecond concurrent reads/writes, p50/p95/p99 latencies

---

## Quick Start

### Prerequisites
- Elixir 1.15+ and Erlang/OTP 26+
- Install: https://elixir-lang.org/install.html

### Run

```bash
git clone https://github.com/dharunnarayanvenkatesh/Concurrent-API-Load-Simulator
cd Concurrent-API-Load-Simulator
mix deps.get
mix assets.setup
mix assets.build
mix phx.server
```

Open **http://localhost:4000**

The built-in mock server starts automatically on **http://localhost:4001/api/mock**.
No external API needed — just hit Start.

---

## Project Structure

```
stress_simulator/
├── lib/
│   ├── stress_simulator/
│   │   ├── application.ex                  # OTP supervisor tree
│   │   ├── mock_server.ex                  # Built-in HTTP target (port 4001)
│   │   ├── telemetry.ex                    # Phoenix telemetry setup
│   │   ├── simulation/
│   │   │   ├── coordinator.ex              # State machine + circuit breaker
│   │   │   ├── ramp_scheduler.ex           # Ramp-up policy engine
│   │   │   └── worker.ex                   # HTTP worker + jitter
│   │   ├── metrics/
│   │   │   ├── store.ex                    # ETS ring buffer + percentiles
│   │   │   └── aggregator.ex               # Sliding-window RPS + PubSub
│   │   └── distributed/
│   │       ├── node_registry.ex            # Heartbeat tracking
│   │       ├── master_orchestrator.ex      # Quota distribution
│   │       └── worker_agent.ex             # Per-node runner
│   └── stress_simulator_web/
│       ├── live/dashboard_live.ex          # LiveView dashboard
│       ├── controllers/
│       │   ├── api_controller.ex           # REST API
│       │   ├── error_html.ex
│       │   └── error_json.ex
│       ├── components/
│       │   ├── core_components.ex
│       │   ├── layouts.ex
│       │   └── layouts/
│       │       ├── root.html.heex
│       │       └── app.html.heex
│       ├── endpoint.ex
│       └── router.ex
├── assets/
│   ├── js/app.js                           # LiveSocket + Chart.js hooks
│   └── css/app.css                         # Industrial dark terminal UI
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── test.exs
│   └── runtime.exs
└── mix.exs
```

---

## Demo Scenarios

### 1. Basic load test (default)
- URL: `http://localhost:4001/api/mock`
- Concurrency: 200
- Click **▶ Start**

### 2. Find the failure point (ramp)
- Enable **Ramp-Up Schedule**
- Profile: Linear
- Start: 1 worker, Peak: 1000 workers, Ramp: 60s, Sustain: 120s
- Watch the latency chart — error rate inflects at the breaking point

### 3. Realistic traffic (ramp + jitter)
- Enable **Jitter** → Exponential, 0–200ms
- Enable **Ramp** → Linear, 0→500 over 45s
- This models real Poisson-distributed user arrivals

### 4. Stability test (sine wave)
- Enable **Ramp** → Sine Wave, Peak 800, Period 60s
- Tests whether the server recovers between load peaks

---

## Distributed Mode

```bash
# Terminal 1 — Master (runs the dashboard)
iex --name master@127.0.0.1 --cookie stress_cookie -S mix phx.server

# Terminal 2 — Worker node
iex --name worker1@127.0.0.1 --cookie stress_cookie -S mix run --no-halt

# Inside worker iex:
Node.connect(:"master@127.0.0.1")
StressSimulator.Distributed.WorkerAgent.register_with_master(:"master@127.0.0.1")
```

Enable **Distributed Mode** in the dashboard Configure tab. The master splits the
concurrency quota evenly across all healthy nodes and rebalances automatically
if any node crashes or disconnects.

---

## REST API

```bash
# Start a simulation
curl -X POST http://localhost:4000/api/simulation/start \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://your-api.com/health",
    "concurrency": 500,
    "timeout_ms": 5000,
    "jitter": {"distribution": "exponential", "min_ms": 0, "max_ms": 200},
    "ramp": {
      "profile": "linear",
      "ramp_up_seconds": 60,
      "sustain_seconds": 120,
      "ramp_down_seconds": 30,
      "peak_concurrency": 500,
      "start_concurrency": 1
    }
  }'

# Poll metrics
curl http://localhost:4000/api/metrics

# Stop
curl -X POST http://localhost:4000/api/simulation/stop

# Status
curl http://localhost:4000/api/status
```

---

## Architecture

### OTP Supervision Tree
```
StressSimulator.Supervisor (one_for_one)
├── Phoenix.PubSub               # Real-time broadcasting
├── Metrics.Store                # ETS tables (concurrent reads/writes)
├── Metrics.Aggregator           # 500ms tick → computes RPS, percentiles, broadcasts
├── Finch                        # HTTP connection pool (50 conns × 10 pools)
├── WorkerSupervisor             # DynamicSupervisor (max 5000 children)
├── Simulation.Coordinator       # State machine: idle→running→paused→idle
├── Simulation.RampScheduler     # Ramp policy: calls adjust_concurrency/1 each tick
├── Distributed.NodeRegistry     # ETS + GenServer, heartbeat tracking
├── Distributed.MasterOrchestrator  # Quota distribution, rebalancing
├── Distributed.WorkerAgent      # Per-node load runner
├── MockServer                   # Cowboy HTTP server on :4001
└── StressSimulatorWeb.Endpoint  # Phoenix on :4000
```

### Why ETS for metrics?
- Concurrent writes from thousands of workers with zero serialization
- Sub-microsecond reads for dashboard queries
- Ring buffer semantics via ordered_set + prune
- No GenServer bottleneck on the hot path

### Why Task.async instead of GenServer workers?
- Spawn → execute → die lifecycle, no state cleanup
- BEAM handles 100k+ lightweight processes natively
- Coordinator tracks refs (not pids) for completion/crash handling
- Backpressure via slot counting: spawn only when `active < concurrency`

---

## Configuration

All tunable parameters in `config/config.exs`:

| Key | Default | Description |
|-----|---------|-------------|
| `max_concurrency` | 2000 | Hard cap on concurrent workers |
| `backpressure_latency_threshold_ms` | 2000 | p95 threshold to trigger backpressure |
| `backpressure_failure_rate_threshold` | 0.3 | Failure rate to trigger backpressure |
| `circuit_breaker_threshold` | 10 | Consecutive failures to open circuit |
| `circuit_breaker_reset_ms` | 10000 | Time before half-open probe |
| `ramp_tick_interval_ms` | 1000 | How often ramp scheduler ticks |

---

## Tech Stack

- **Elixir / OTP** — actor model concurrency, supervision trees
- **Phoenix Framework** — HTTP server, routing
- **Phoenix LiveView** — real-time UI without JavaScript framework
- **Phoenix PubSub** — metric broadcasting to dashboard
- **Finch** — HTTP/1.1 connection pool for load workers
- **ETS** — in-memory concurrent storage for metrics
- **Chart.js** — live charts via LiveView hooks
