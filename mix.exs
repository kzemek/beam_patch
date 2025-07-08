defmodule BeamPatch.MixProject do
  use Mix.Project

  def project do
    [
      app: :beam_patch,
      version: "0.2.0",
      description: "Patch Elixir & Erlang modules at runtime",
      package: package(),
      source_url: "https://github.com/kzemek/beam_patch",
      homepage_url: "https://github.com/kzemek/beam_patch",
      docs: docs(),
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    []
  end

  defp deps do
    [
      {:ex_doc, "~> 0.38.1", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:markdown_doctest, "~> 0.1.0", only: :test, runtime: false}
    ]
  end

  defp docs do
    [
      main: "BeamPatch",
      extras: ["LICENSE", "NOTICE"],
      groups_for_modules: [
        Error: [BeamPatch.Error]
      ]
    ]
  end

  defp package do
    [
      links: %{"GitHub" => "https://github.com/kzemek/beam_patch"},
      licenses: ["Apache-2.0"]
    ]
  end

  defp dialyzer do
    []
  end

  defp aliases do
    [
      credo: "credo --strict",
      lint: ["credo", "dialyzer"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/fixtures"]
  defp elixirc_paths(_), do: ["lib"]
end
