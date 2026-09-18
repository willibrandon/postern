defmodule Postern.MixProject do
  use Mix.Project

  @source_url "https://github.com/willibrandon/postern"

  def project do
    [
      app: :postern,
      version: "0.2.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      usage_rules: usage_rules(),
      name: "Postern",
      source_url: @source_url,
      homepage_url: "https://willibrandon.github.io/postern",
      docs: docs()
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
      {:gen_lsp, "~> 0.11.3"},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.22.4"},
      {:burrito, "~> 1.6", only: :prod},
      {:usage_rules, "~> 1.2", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  # The site at willibrandon.github.io/postern: the README and the editor
  # notes as the pages for users, the modules grouped as the pages for
  # developers, built by `mix docs` and published by the docs workflow.
  defp docs do
    [
      main: "readme",
      logo: "editors/vscode/media/icon.png",
      extras: [
        "README.md",
        {"editors/vscode/README.md", filename: "vscode", title: "Visual Studio Code"},
        {"editors/nvim/README.md", filename: "neovim", title: "Neovim"},
        {"editors/fresh/README.md", filename: "fresh", title: "Fresh"},
        {"editors/helix/README.md", filename: "helix", title: "Helix"},
        {"editors/emacs/README.md", filename: "emacs", title: "Emacs"},
        {"editors/zed/README.md", filename: "zed", title: "Zed"},
        "CHANGELOG.md",
        "SECURITY.md"
      ],
      groups_for_extras: [Editors: ~r"editors/"],
      groups_for_modules: [
        Server: [
          Postern.Application,
          Postern.Server,
          Postern.Stdio,
          Postern.RuntimeArgs,
          Postern.DocumentStore,
          Postern.Features,
          Postern.Symbols
        ],
        Parsers: [
          Postern.Parser.PostgresqlConf,
          Postern.Parser.PgHba,
          Postern.Parser.PgIdent,
          Postern.Parser.AuthLines
        ],
        Checks: [
          Postern.Diagnostics,
          Postern.PostgresqlConfDiagnostics,
          Postern.PgHbaDiagnostics,
          Postern.PgIdentDiagnostics,
          Postern.PgHbaOptions,
          Postern.GucValue,
          Postern.StringSettings,
          Postern.SettingHistory,
          Postern.StartupChecks,
          Postern.RegexCheck,
          Postern.ConfigTree,
          Postern.Files,
          Postern.FileKind
        ],
        "Live server": [
          Postern.LiveFeatures,
          Postern.LiveDiagnostics,
          Postern.LiveOracle
        ],
        "Catalogs and documentation": [
          Postern.Catalog,
          Postern.CatalogGenerator,
          Postern.Docs,
          Postern.DocsGenerator
        ],
        "Command line": [
          Postern.CLI,
          Mix.Tasks.Postern.Check,
          Mix.Tasks.Postern.Catalog,
          Mix.Tasks.Postern.Docs
        ]
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp releases do
    [
      postern: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
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
