defmodule ExKalshi.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/drdray1/ex_kalshi"

  def project do
    [
      app: :ex_kalshi,
      version: @version,
      test_coverage: [summary: [threshold: 90]],
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Hex
      description: "Elixir client for the Kalshi Trade API v2 (prediction markets)",
      package: package(),

      # Docs
      name: "ExKalshi",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key],
      mod: {ExKalshi.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.0 or ~> 3.0"},
      {:websockex, "~> 0.4"},
      {:plug, "~> 1.14", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mimic, "~> 1.7", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "ExKalshi",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "REST API": [
          ExKalshi.Exchange,
          ExKalshi.Markets,
          ExKalshi.Events,
          ExKalshi.Series,
          ExKalshi.Orders,
          ExKalshi.Portfolio
        ],
        "Prediction Markets": [ExKalshi.Predictions, ExKalshi.Orderbook],
        Authentication: [ExKalshi.Auth, ExKalshi.Signature],
        WebSocket: [
          ExKalshi.WebSocket,
          ExKalshi.WebSocket.Client,
          ExKalshi.WebSocket.Connection
        ],
        Client: [ExKalshi.Client, ExKalshi.Query]
      ]
    ]
  end
end
