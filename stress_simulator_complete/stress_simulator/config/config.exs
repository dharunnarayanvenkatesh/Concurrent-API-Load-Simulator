import Config

config :stress_simulator, StressSimulatorWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: StressSimulatorWeb.ErrorHTML, json: StressSimulatorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: StressSimulator.PubSub,
  live_view: [signing_salt: "stress_sim_salt_xyz"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :stress_simulator, :finch_pools,
  default_pool_size: 50,
  default_pool_count: 10

config :stress_simulator, :simulation,
  max_concurrency: 2000,
  default_timeout_ms: 10_000,
  metrics_flush_interval_ms: 500,
  backpressure_latency_threshold_ms: 2000,
  backpressure_failure_rate_threshold: 0.3,
  circuit_breaker_threshold: 10,
  circuit_breaker_reset_ms: 10_000,
  ramp_tick_interval_ms: 1_000,
  jitter_min_ms: 0,
  jitter_max_ms: 500

config :stress_simulator, :distributed,
  enabled: false,
  node_role: :master,
  master_node: nil,
  worker_heartbeat_ms: 2_000,
  worker_timeout_ms: 10_000

config :esbuild,
  version: "0.17.11",
  default: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

import_config "#{config_env()}.exs"
