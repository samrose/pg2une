defmodule Pg2une.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :pg2une,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      name: "pg2une",
      description: "PostgreSQL auto-tuner on mxc microVMs"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Pg2une.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:anytune, github: "samrose/anytune"},
      {:mxc, github: "samrose/mxc"},
      {:datalox, github: "samrose/datalox"},
      {:postgrex, ">= 0.0.0"},
      {:ecto_sql, "~> 3.13"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
