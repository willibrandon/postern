defmodule Postern.MixProject do
  use Mix.Project

  def project do
    [
      app: :postern,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      usage_rules: usage_rules()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Postern.Application, []}
    ]
  end

  defp deps do
    [
      # ElixirLS 0.31.x vendors the GenLSP protocol using the schematic/0 API.
      # gen_lsp 0.9 is the matching release; newer releases use schema/0 and
      # collide with ElixirLS when it compiles project dependencies in-process.
      {:gen_lsp, "~> 0.11.3"},
      {:nimble_parsec, "~> 1.4"},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.22.4"},
      {:burrito, "~> 1.6", only: :prod},
      {:usage_rules, "~> 1.2", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      postern: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            macos_arm64: [os: :darwin, cpu: :aarch64],
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: {:all, link: :markdown}
    ]
  end
end
