defmodule StressSimulatorWeb.Router do
  use StressSimulatorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {StressSimulatorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", StressSimulatorWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
  end

  scope "/api", StressSimulatorWeb do
    pipe_through :api

    get "/status", ApiController, :status
    get "/metrics", ApiController, :metrics
    post "/simulation/start", ApiController, :start_simulation
    post "/simulation/stop", ApiController, :stop_simulation
  end
end
