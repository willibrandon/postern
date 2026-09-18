defmodule Mix.Tasks.Postern.Catalog do
  @shortdoc "Generate PostgreSQL setting catalogs from PostgreSQL 13 through 18"

  @moduledoc """
  Generates `priv/catalog/pg13.json` through `priv/catalog/pg18.json` by
  querying Docker PostgreSQL servers on ports 5413 through 5418 and reading
  the enum tables of each version from a git checkout of PostgreSQL.

  Start the servers before running this task, with the two modules that
  define their settings only when preloaded:

      for v in 13 14 15 16 17 18; do
        docker run -d --name pg$v -e POSTGRES_HOST_AUTH_METHOD=trust -p 54$v:5432 postgres:$v \\
          -c shared_preload_libraries=pg_stat_statements,pg_prewarm
      done

  Then point the task at a checkout that has the release branches:

      mix postern.catalog --source ~/src/postgres

  The task never invents setting metadata; all setting names, types, ranges,
  enum values and descriptions come from `pg_settings`, with the contrib
  modules and plpgsql loaded so that their settings are in it, and the
  spellings the view hides, `wal_level = archive` say, from the source of the
  same version.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {options, remaining, _invalid} =
      OptionParser.parse(argv,
        strict: [
          hostname: :string,
          output_dir: :string,
          source: :string
        ]
      )

    if remaining != [] do
      Mix.raise("unexpected arguments: #{Enum.join(remaining, " ")}")
    end

    if options[:source] == nil do
      Mix.raise(
        "pass --source with a git checkout of PostgreSQL, whose enum tables hold the spellings pg_settings hides"
      )
    end

    Application.ensure_all_started(:postgrex)
    opts = Enum.filter(options, fn {key, _value} -> key in [:hostname, :output_dir, :source] end)

    Enum.each(Postern.CatalogGenerator.default_ports(), fn {version, port} ->
      Mix.shell().info("Generating PostgreSQL #{version} catalog from port #{port}")
      Postern.CatalogGenerator.generate(version, port, opts)
    end)
  end
end
