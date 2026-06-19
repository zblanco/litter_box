defmodule LitterBox.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/zblanco/litter_box"

  def project do
    [
      app: :litter_box,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Structured sandbox execution contracts and pluggable backends.",
      package: package(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:req, "~> 0.6"},
      {:just_bash, "~> 0.3", optional: true},
      {:lua, "~> 1.0.0-rc.3", optional: true}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      files: ~w(lib mix.exs README.md .formatter.exs),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
