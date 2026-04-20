defmodule StressSimulator.MixProject do
  use Mix.Project

  def project do
    [
      app: :stress_simulator,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {StressSimulator.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix,             "~> 1.7"},
      {:phoenix_live_view,   "~> 0.20"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_html,        "~> 4.0"},
      {:phoenix_pubsub,      "~> 2.1"},
      {:plug_cowboy,         "~> 2.7"},
      {:jason,               "~> 1.4"},
      {:finch,               "~> 0.16"},
      {:telemetry_metrics,   "~> 0.6"},
      {:telemetry_poller,    "~> 1.0"},
      {:esbuild,             "~> 0.8", runtime: Mix.env() == :dev},
      {:floki,               ">= 0.30.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup:           ["deps.get", "assets.setup", "assets.build"],
      "assets.setup":  ["esbuild.install --if-missing"],
      "assets.build":  ["esbuild default"],
      "assets.deploy": ["esbuild default --minify"]
    ]
  end
end
