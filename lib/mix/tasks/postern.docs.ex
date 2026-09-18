defmodule Mix.Tasks.Postern.Docs do
  @shortdoc "Generate the hover text for pg_hba.conf and pg_ident.conf from the manual"

  @moduledoc """
  Generates `priv/docs/pg13.json` through `priv/docs/pg18.json` from the
  client authentication chapter of each version's manual, read from a git
  checkout of PostgreSQL that has the release branches:

      mix postern.docs --source ~/src/postgres

  The text is the manual's own, under the PostgreSQL License.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {options, remaining, _invalid} =
      OptionParser.parse(argv, strict: [source: :string, output_dir: :string])

    if remaining != [], do: Mix.raise("unexpected arguments: #{Enum.join(remaining, " ")}")

    source =
      options[:source] || Mix.raise("pass --source with a git checkout of PostgreSQL")

    opts = Enum.filter(options, fn {key, _value} -> key == :output_dir end)

    for version <- Postern.Catalog.versions() do
      Mix.shell().info("Generating the PostgreSQL #{version} hover text")
      Postern.DocsGenerator.generate(source, version, opts)
    end
  end
end
