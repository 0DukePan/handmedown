defmodule Handmedown.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :handmedown,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Handmedown.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Every dependency is pure Elixir or pure Erlang on purpose. A SQLite adapter would drag in a C NIF,
  # which needs a compiler on every machine that runs the brain - the opposite of "one command".
  defp deps do
    [
      {:bandit, "~> 1.15"},
      {:plug, "~> 1.20"},
      {:websock_adapter, "~> 0.7.2"},
      {:jason, "~> 1.4"}
    ]
  end
end
