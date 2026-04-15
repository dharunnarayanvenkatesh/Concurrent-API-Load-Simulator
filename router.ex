defmodule StressSimWeb.Router do
  use StressSimWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {StressSimWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", StressSimWeb do
    pipe_through :browser
    live "/", DashboardLive, :index
  end

  # JSON API for programmatic control
  scope "/api", StressSimWeb do
    pipe_through :api
    post "/simulations", SimulationController, :create
    delete "/simulations/:id", SimulationController, :delete
    get "/simulations/:id/metrics", SimulationController, :metrics
  end
end
