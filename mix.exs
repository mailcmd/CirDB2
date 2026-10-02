defmodule CirDB.MixProject do
  use Mix.Project

  def project do
    [
      app: :cir_db,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: get_mode() |> deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {CirDB.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps(:service) do
    [
      {:plug_cowboy, "~> 2.9.0"},
      {:jason, "~> 1.4.5"}
    ]
  end
  defp deps(:client) do
    [
    ]
  end

  def get_mode() do
    (File.cwd! |> Path.dirname() |> Path.basename()) == "deps"
      && :client
      || :service
  end
end
