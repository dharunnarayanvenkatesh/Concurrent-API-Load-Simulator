defmodule StressSimulatorWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :stress_simulator

  # LiveView socket
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {:_unused, store: :cookie, key: "_stress_session", signing_salt: "stress_sign"}]]

  # Serve static files
  plug Plug.Static,
    at: "/",
    from: :stress_simulator,
    gzip: false,
    only: StressSimulatorWeb.static_paths()

  # Code reloader
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session,
    store: :cookie,
    key: "_stress_session",
    signing_salt: "stress_sign",
    same_site: "Lax"

  plug StressSimulatorWeb.Router
end
