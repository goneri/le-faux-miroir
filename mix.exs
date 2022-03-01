defmodule LeFauxMiroir.MixProject do
  use Mix.Project

  def project do
    [
      app: :le_faux_miroir,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {LeFauxMiroir.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug_cowboy, "~> 2.0"},
      {:castore, "~> 0.1.0"},
      {:mint, "~> 1.0"},
      {:timex, "~> 3.0"}
    ]
  end
end
