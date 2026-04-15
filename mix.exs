defmodule StressSim.MixProject do
  use Mix.Project

  def project do
    [
      app: :stress_sim,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {StressSim.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix core
      {:phoenix, "~> 1.7.10"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 0.20.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},

      # HTTP client for stress testing
      {:finch, "~> 0.16"},

      # JSON
      {:jason, "~> 1.2"},

      # Plug adapter
      {:bandit, "~> 1.2"},

      # Telemetry
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # Dev/test
      {:floki, ">= 0.30.0", only: :test}
    ]
  end
end
