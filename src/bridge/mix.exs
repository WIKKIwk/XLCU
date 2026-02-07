defmodule TitanBridge.MixProject do
  use Mix.Project

  def project do
    [
      app: :titan_bridge,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {TitanBridge.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.6"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0"},
      {:finch, "~> 0.18"},
      {:cloak_ecto, "~> 1.3"}
    ]
  end
end
