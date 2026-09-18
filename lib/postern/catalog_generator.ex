defmodule Postern.CatalogGenerator do
  @moduledoc """
  Generates versioned PostgreSQL setting catalogs from live PostgreSQL servers
  and the source of the same versions.

  The generator deliberately selects the complete `pg_settings` fields required
  by Postern instead of embedding setting metadata in source code. A generated
  catalog is a JSON object containing its PostgreSQL major version and a list of
  setting maps.

  One thing `pg_settings` keeps to itself: each enum setting's table in the
  source carries entries marked hidden, `archive` and `hot_standby` on
  `wal_level` from before `replica` was the name, and `true`, `false`, `yes`,
  `no`, `1` and `0` on the settings that used to be booleans, and the view
  leaves them out of `enumvals` although the server takes them. Those come
  from the tables in a git checkout of PostgreSQL, read at the release branch
  of each version, and are recorded on the row as `hidden_enumvals`, each
  with the visible value it stands for when the table gives it one.
  """

  @select """
  select name, vartype, unit, context, category, short_desc,
         extra_desc, min_val, max_val, enumvals, boot_val, reset_val
    from pg_settings
   order by name
  """

  @default_ports %{13 => 5413, 14 => 5414, 15 => 5415, 16 => 5416, 17 => 5417, 18 => 5418}

  @doc """
  Generates one catalog by querying the PostgreSQL server on `port` and
  reading the enum tables of the same version from the checkout at `:source`.
  """
  @spec generate(pos_integer(), :inet.port_number(), keyword()) :: :ok
  def generate(version, port, opts \\ []) when is_integer(version) and is_integer(port) do
    database = Keyword.get(opts, :database, "postgres")
    username = Keyword.get(opts, :username, "postgres")
    hostname = Keyword.get(opts, :hostname, "127.0.0.1")
    output_dir = Keyword.get(opts, :output_dir, "priv/catalog")
    source = Keyword.get(opts, :source) || raise "a PostgreSQL git checkout is needed as :source"
    hidden = hidden_enums(source, version)

    {:ok, connection} =
      Postgrex.start_link(
        hostname: hostname,
        port: port,
        database: database,
        username: username,
        password: "",
        connect_timeout: 5_000,
        timeout: 15_000
      )

    try do
      case Postgrex.query(connection, @select, [], query_type: :text) do
        {:ok, result} ->
          settings =
            Enum.map(result.rows, fn row ->
              result.columns
              |> Enum.zip(row)
              |> Map.new()
              |> with_enums(hidden)
            end)

          catalog = %{"version" => version, "settings" => settings}
          path = Path.join(output_dir, "pg#{version}.json")

          File.mkdir_p!(output_dir)
          File.write!(path, Jason.encode!(catalog, pretty: true) <> "\n")
          :ok

        {:error, error} ->
          raise "catalog query failed for PostgreSQL #{version} on port #{port}: #{Exception.message(error)}"
      end
    after
      GenServer.stop(connection, :normal)
    end
  end

  @doc """
  Returns the default major-version-to-port mapping used by the Mix task.
  """
  @spec default_ports() :: %{pos_integer() => :inet.port_number()}
  def default_ports, do: @default_ports

  @doc """
  Generates all catalogs using the default ports 5413 through 5418.
  """
  @spec generate_all(keyword()) :: :ok
  def generate_all(opts \\ []) do
    Enum.each(@default_ports, fn {version, port} ->
      generate(version, port, opts)
    end)

    :ok
  end

  @doc """
  The hidden spellings of every enum setting of a version, read from the
  checkout at `source`: a map from the setting's name to a map from each
  hidden spelling to the visible value with the same meaning, or `nil`
  when no visible value shares it.
  """
  @spec hidden_enums(Path.t(), pos_integer()) :: %{
          String.t() => %{String.t() => String.t() | nil}
        }
  def hidden_enums(source, version) do
    ref = release_branch(source, version)

    files =
      git!(source, ["grep", "-l", "config_enum_entry", ref, "--", "src/backend"])
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> line |> String.split(":", parts: 2) |> List.last() end)

    texts = Map.new(files, &{&1, git!(source, ["show", "#{ref}:#{&1}"])})
    tables = texts |> Map.values() |> Enum.map(&enum_tables/1) |> Enum.reduce(%{}, &Map.merge/2)

    settings =
      texts
      |> Map.values()
      |> Enum.map(&enum_settings/1)
      |> Enum.reduce(%{}, &Map.merge/2)

    Map.new(settings, fn {setting, table} ->
      entries = Map.get(tables, table) || raise "no table #{table} for #{setting} in #{ref}"
      {setting, hidden_of(entries)}
    end)
  end

  @doc """
  The `config_enum_entry` tables in a C source text: each table's name to
  its entries as `{spelling, constant, hidden?}`.

  ## Examples

      iex> Postern.CatalogGenerator.enum_tables(~S'''
      ...> const struct config_enum_entry wal_level_options[] = {
      ...>   {"minimal", WAL_LEVEL_MINIMAL, false},
      ...>   {"replica", WAL_LEVEL_REPLICA, false},
      ...>   {"archive", WAL_LEVEL_REPLICA, true},	/* deprecated */
      ...>   {NULL, 0, false}
      ...> };
      ...> ''')
      %{"wal_level_options" => [{"minimal", "WAL_LEVEL_MINIMAL", false}, {"replica", "WAL_LEVEL_REPLICA", false}, {"archive", "WAL_LEVEL_REPLICA", true}]}

  """
  @spec enum_tables(String.t()) :: %{String.t() => [{String.t(), String.t(), boolean()}]}
  def enum_tables(text) do
    ~r/config_enum_entry\s+(\w+)\[\]\s*=\s*\{(.*?)\n\};/s
    |> Regex.scan(text)
    |> Map.new(fn [_all, name, body] ->
      entries =
        ~r/\{\s*"([^"]*)"\s*,\s*(\w+)\s*,\s*(true|false)\s*\}/
        |> Regex.scan(body)
        |> Enum.map(fn [_all, spelling, constant, hidden] ->
          {spelling, constant, hidden == "true"}
        end)

      {name, entries}
    end)
  end

  @doc """
  The enum settings declared in a C source text, as the setting's name to
  the name of its table.

  ## Examples

      iex> Postern.CatalogGenerator.enum_settings(~S'''
      ...> struct config_enum ConfigureNamesEnum[] =
      ...> {
      ...>   {
      ...>     {"wal_level", PGC_POSTMASTER, WAL_SETTINGS,
      ...>       gettext_noop("Sets the level of information written to the WAL."),
      ...>       NULL
      ...>     },
      ...>     &wal_level,
      ...>     WAL_LEVEL_REPLICA, wal_level_options,
      ...>     NULL, NULL, NULL
      ...>   },
      ...> };
      ...> ''')
      %{"wal_level" => "wal_level_options"}

  """
  @spec enum_settings(String.t()) :: %{String.t() => String.t()}
  def enum_settings(text) do
    case Regex.run(~r/ConfigureNamesEnum\[\]\s*=\s*\{(.*?)\n\};/s, text) do
      [_all, body] ->
        ~r/\{\s*"([A-Za-z_]+)"\s*,\s*PGC_\w+\s*,.*?\}\s*,\s*&\w+\s*,\s*\w+\s*,\s*(\w+)\s*,/s
        |> Regex.scan(body)
        |> Map.new(fn [_all, setting, table] -> {setting, table} end)

      nil ->
        %{}
    end
  end

  # A hidden spelling stands for the visible one with the same constant.
  defp hidden_of(entries) do
    visible = for {spelling, constant, false} <- entries, into: %{}, do: {constant, spelling}

    for {spelling, constant, true} <- entries,
        into: %{},
        do: {spelling, Map.get(visible, constant)}
  end

  # A row's enumvals as a list, and its hidden spellings from the source.
  defp with_enums(row, hidden) do
    case row["vartype"] do
      "enum" ->
        row
        |> Map.put("enumvals", Postern.Catalog.array_literal(row["enumvals"]))
        |> Map.put("hidden_enumvals", Map.get(hidden, row["name"], %{}))

      _other ->
        Map.put(row, "hidden_enumvals", nil)
    end
  end

  # The release branch as a local branch, or as the remote's when the
  # checkout only fetched it.
  defp release_branch(source, version) do
    Enum.find(["REL_#{version}_STABLE", "origin/REL_#{version}_STABLE"], fn ref ->
      match?(
        {_out, 0},
        System.cmd("git", ["-C", source, "rev-parse", "--verify", "--quiet", ref])
      )
    end) || raise "no REL_#{version}_STABLE branch in #{source}"
  end

  defp git!(source, args) do
    case System.cmd("git", ["-C", source | args], stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> raise "git #{Enum.join(args, " ")} failed with #{status}: #{out}"
    end
  end
end
