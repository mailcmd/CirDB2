defmodule CirDB.MixProject do
  use Mix.Project

  def project do
    [
      app: :cir_db,
      version: "0.2.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
  defp deps() do
    [
      {:plug_cowboy, "~> 2.9.0"},
      {:jason, "~> 1.4.5"}
    ]
  end

  def get_mode() do
    (File.cwd! |> Path.dirname() |> Path.basename()) == "deps"
      && :module
      || :service
  end
end
