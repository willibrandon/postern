defmodule Postern.ValueOracleLiveTest do
  @moduledoc """
  Compares the value checks with a running server, line by line.

  Each line of the fixture goes two ways. ALTER SYSTEM SET validates a
  value the way the file does, through parse_and_validate_value and the
  setting's check hook, and answers with the message, the detail and the
  hint the log would carry, so a value the server refuses must be refused
  here with the same words, and a value it takes must pass. The file path
  itself then decides what a whole line is, since a syntax error or a name
  the server does not know never reaches a value check: each such line is
  written into a file the server's postgresql.conf includes, and
  pg_file_settings says whether the server read it, refused its value, or
  refused the line. From 16, pg_hba.conf rules go through an included file
  the same way, and pg_hba_file_rules gives each rule's error in full.

  Runs when `PGHOST` names a server, as the CI matrix does for 13 through
  18, and leaves the server as it found it: every ALTER SYSTEM is reset and
  the included files are removed.
  """

  use ExUnit.Case, async: false

  @moduletag :live

  alias Postern.Diagnostics
  alias Postern.LiveOracle

  # Values the file can carry, with what the server does on each version.
  # ALTER SYSTEM cannot carry a setting the auto file may not hold, nor a
  # name it does not know, nor a line the scanner refuses, so those go
  # through the file below.
  @values [
    "log_file_mode = 0600",
    "unix_socket_permissions = 0777",
    "work_mem = 0x80",
    "work_mem = 100.7",
    "work_mem = '64 MB'",
    "work_mem = '1.5GB'",
    "work_mem = 128mb",
    "work_mem = 1kB",
    "work_mem = 99999999999",
    "shared_buffers = 1kB",
    "shared_buffers = 128QB",
    "statement_timeout = 5MB",
    "max_parallel_workers = 5MB",
    "log_file_mode = 9999",
    "checkpoint_completion_target = 1.5",
    "checkpoint_completion_target = 0.9",
    "random_page_cost = abc",
    "enable_seqscan = o",
    "enable_seqscan = of",
    "wal_level = archive",
    "wal_level = ARCHIVE",
    "wal_level = nope",
    "synchronous_commit = true",
    "huge_pages = 1",
    "log_min_messages = debug",
    "default_transaction_isolation = 'read committed'",
    "default_transaction_isolation = 'read commited'",
    "block_size = 8192",
    "pg_stat_statements.max = 5000",
    "pg_stat_statements.max = 50",
    "auto_explain.log_min_duration = 250ms",
    "auto_explain.log_min_duration = 5MB",
    "auto_explain.log_level = debug",
    "plpgsql.variable_conflict = nope",
    "x.y = on",
    "datestyle = 'ISO, MDX'",
    "datestyle = 'ISO, SQL'",
    "datestyle = 'iso,,ymd'",
    "datestyle = 'german, ymd'",
    "timezone = 'Mars/Olympus'",
    "timezone = 'europe/berlin'",
    "timezone = 'Foo5Bar,M3.2.0,M11.1.0'",
    "timezone = 'Foo200'",
    "timezone = 'Foo-5:30:15'",
    "timezone = '+16'",
    "log_timezone = 'PDT'",
    "log_destination = 'stderr, csvlogg'",
    "log_destination = 'STDERR'",
    "log_destination = 'stderr,,syslog'",
    "log_destination = 'jsonlog'",
    "wal_consistency_checking = 'heap, BTREE'",
    "wal_consistency_checking = 'xlog'",
    "wal_consistency_checking = 'all, nope'",
    "client_encoding = 'UTF-8'",
    "client_encoding = 'utf-9'",
    "client_encoding = ''",
    "recovery_target = 'nope'",
    "recovery_target = 'immediate'",
    "recovery_target_lsn = 'ab/123456789'",
    "recovery_target_lsn = 'AB/12345678'",
    "recovery_target_timeline = '99999999999999999999'",
    "recovery_target_time = 'yesterday-ish'",
    "recovery_target_time = '2024-01-15 10:30:00'",
    "synchronous_standby_names = 'FIRST 2 (a, b'",
    "synchronous_standby_names = 'a b'",
    "synchronous_standby_names = '0 (a)'",
    "synchronous_standby_names = 'any 1 (a, \"b c\", *)'",
    "archive_command = 'anything %p'"
  ]

  # Settings SET and ALTER SYSTEM quote as one name, so that only the file
  # can get their list syntax wrong.
  @quoted_lists ~w(search_path temp_tablespaces)

  @values_file "postern_values.conf"
  @rules_directory "postern_rules.d"

  # Lines only the file can judge: the scanner's, the unknown names, and
  # the values ALTER SYSTEM would refuse for reasons of its own.
  @lines [
    "work_mem = 1.5GB",
    "temp_buffers = 1e3",
    "listen_addresses = *",
    "log_directory = /var/log",
    "include_dir conf.d",
    "search_path = \"$user\", public",
    "work_mem = 'unterminated",
    "a.b.c = 1",
    "foo_bar = 1",
    "shared_buffrs = 1",
    "wal_keep_segments = 32",
    "data_directory = '/nowhere'",
    "transaction_isolation = 'read committed'",
    "search_path = 'a,,b'",
    "search_path = '\"$user\", public'",
    "temp_tablespaces = 'a,,b'",
    "work_mem = 64 MB",
    "work_mem=64MB"
  ]

  # pg_hba.conf rules, one per line of an included file, from 16 on.
  @rules [
    "local all all peer",
    "host all all 10.0.0.0/8 scram-sha-256",
    "host all all 10.0.0.0/8 nope",
    "local all all gss",
    "host all all 10.0.0.0/8 peer",
    "host all all 10.0.0.0/8 cert",
    "host all all 10.0.0.0/8 md5 clientcert=verify-ca",
    "host all all 10.0.0.0/8 ldap ldapserver=x ldapprefix=cn= ldapbasedn=dc=x",
    "host all all 10.0.0.0/8 ldap ldapserver=x",
    "host all all 10.0.0.0/8 radius",
    "host all all 10.0.0.0/8 md5 map=x",
    "host all all 10.0.0.0/8 md5 nope=1",
    "host all all 10.0.0.999 md5",
    "host all all example.com/24 md5",
    "host all all 10.0.0.0 255.255.0.0 md5",
    "host all all 10.0.0.0 ::1 md5",
    "host all 10.0.0.0/8 md5",
    "hostx all all 10.0.0.0/8 md5",
    "host all,all all 10.0.0.0/8 md5 md5",
    "host all @admins 10.0.0.0/8 scram-sha-256",
    "host all /^(.* 10.0.0.0/8 scram-sha-256",
    "host /^app_[a-z]+$ all 10.0.0.0/8 scram-sha-256"
  ]

  setup_all do
    {:ok, conn} =
      Postgrex.start_link(LiveOracle.connection_options(%{}) ++ [connect_timeout: 5_000])

    version = div(scalar!(conn, "select current_setting('server_version_num')::int"), 10_000)

    # A module's setting is checked only where the module is loaded: in this
    # session for ALTER SYSTEM, and in the postmaster for the file, which
    # has the preloaded modules alone.
    for library <- ~w(auto_explain pg_trgm plpgsql pg_stat_statements pg_prewarm) do
      Postgrex.query(conn, "load '#{library}'", [])
    end

    preloaded = scalar!(conn, "show shared_preload_libraries")
    %{conn: conn, version: version, preloaded: preloaded}
  end

  test "a value is taken or refused with the server's words", %{conn: conn, version: version} do
    disagreements =
      Enum.flat_map(@values, fn line ->
        [name, value] = String.split(line, ~r/\s*=\s*/, parts: 2)
        value = unquote_value(value)
        server = if skip_sql?(name, version), do: :skip, else: alter_system(conn, name, value)
        postern = messages(line, version)

        case {server, postern} do
          {:skip, _postern} -> []
          {:ok, []} -> []
          {{:error, message}, [only]} when only == message -> []
          {server, postern} -> [{line, server, postern}]
        end
      end)

    assert disagreements == []
  end

  test "a line is read, refused for its value, or refused outright as the file says", %{
    conn: conn,
    version: version,
    preloaded: preloaded
  } do
    data_directory = scalar!(conn, "select current_setting('data_directory')")
    config_file = scalar!(conn, "select current_setting('config_file')")
    path = Path.join(data_directory, @values_file)
    catalog = Postern.Catalog.load(version)

    unless String.contains?(read!(conn, config_file), path) do
      program!(conn, "printf \"include_if_exists '#{path}'\\n\" >> #{config_file}")
    end

    # The include line goes again at the end, so that the other live tests
    # find the server's file as they expect it.
    on_exit(fn -> restore(config_file, @values_file, path) end)

    disagreements =
      Enum.flat_map(@lines ++ @values, fn line ->
        write!(conn, path, [line])
        Postgrex.query!(conn, "select pg_reload_conf()", [])
        Process.sleep(300)

        rows =
          query!(
            conn,
            "select name, applied, error from pg_file_settings where sourcefile = '#{path}'"
          )

        [name | _rest] = String.split(line, ~r/\s*=\s*|\s+/, parts: 2)
        setting = Postern.Catalog.fetch(catalog, name)
        server = verdict(rows)
        postern = verdict_of(messages(line, version))

        cond do
          server == postern -> []
          # The postmaster checks a module's setting only when the module is
          # preloaded; otherwise the value is a placeholder it takes as it is.
          setting["module"] != nil and not String.contains?(preloaded, setting["module"]) -> []
          # A postmaster setting whose value differs from the running one is
          # refused for needing a restart, which the view words the same way.
          server == :refused and postern == :applied and setting["context"] == "postmaster" -> []
          true -> [{line, server, postern, rows}]
        end
      end)

    program!(conn, "rm -f #{path}")
    assert disagreements == []
  end

  test "a pg_hba.conf rule gets the error pg_hba_file_rules gives it", %{
    conn: conn,
    version: version
  } do
    if version >= 16 do
      data_directory = scalar!(conn, "select current_setting('data_directory')")
      hba_file = scalar!(conn, "select current_setting('hba_file')")
      directory = Path.join(data_directory, @rules_directory)
      path = Path.join(directory, "rules.conf")

      program!(conn, "mkdir -p #{directory}")
      write!(conn, path, @rules)

      unless String.contains?(read!(conn, hba_file), directory) do
        program!(conn, "printf \"include_dir #{directory}\\n\" >> #{hba_file}")
      end

      on_exit(fn -> restore(hba_file, @rules_directory, directory) end)

      Postgrex.query!(conn, "select pg_reload_conf()", [])
      Process.sleep(300)

      server =
        conn
        |> query!(
          "select line_number, error from pg_hba_file_rules where file_name = '#{path}' and error is not null"
        )
        |> Map.new(fn [line, error] -> {line, error} end)

      # The rules are read with the reader the editor would have for them,
      # which sees the file and nothing beside it, as the server does.
      text = Enum.join(@rules, "\n") <> "\n"

      diagnostics =
        Diagnostics.for_document("file://#{path}", text, %{
          "pg" => version,
          kind: :pg_hba_conf,
          reportTrust: false,
          reader: Postern.Files.in_memory(%{path => text})
        })

      postern =
        diagnostics
        |> Enum.filter(&(&1.severity == 1))
        |> Enum.group_by(& &1.range.start.line)
        |> Map.new(fn {line, [first | _rest]} -> {line + 1, first.message} end)

      program!(conn, "rm -rf #{directory}")
      assert postern == server
    end
  end

  # ALTER SYSTEM cannot carry what the file can: a setting the auto file may
  # not hold, a list setting it would quote as one name, and a placeholder
  # for a module it does not know, which it refuses as unrecognized while
  # the file creates it.
  defp skip_sql?(name, version) do
    name in @quoted_lists or
      (String.contains?(name, ".") and
         Postern.Catalog.fetch(Postern.Catalog.load(version), name) == nil)
  end

  # Takes the test's line out of the server's file again and reloads, on a
  # connection of its own since the test's is gone by then.
  defp restore(file, marker, path) do
    {:ok, conn} =
      Postgrex.start_link(LiveOracle.connection_options(%{}) ++ [connect_timeout: 5_000])

    program!(conn, "sed -i '/#{marker}/d' #{file}")
    program!(conn, "rm -rf #{path}")
    Postgrex.query!(conn, "select pg_reload_conf()", [])
    GenServer.stop(conn)
  end

  # What a line's messages amount to, in the terms pg_file_settings uses.
  defp verdict_of([]), do: :applied

  defp verdict_of(messages) do
    cond do
      Enum.any?(messages, &String.starts_with?(&1, "syntax error")) ->
        :syntax_error

      Enum.any?(messages, &String.starts_with?(&1, "unrecognized configuration parameter")) ->
        :unrecognized

      true ->
        :refused
    end
  end

  defp verdict([]), do: :syntax_error

  defp verdict(rows) do
    case Enum.find(rows, fn [_name, _applied, error] -> error != nil end) do
      nil -> :applied
      [_name, _applied, "syntax error"] -> :syntax_error
      [_name, _applied, "unrecognized configuration parameter"] -> :unrecognized
      [_name, _applied, "setting could not be applied"] -> :refused
      [_name, _applied, _other] -> :refused
    end
  end

  # The error diagnostics for one line of postgresql.conf, as messages.
  defp messages(line, version) do
    Diagnostics.for_document("file:///tmp/postgresql.conf", line <> "\n", %{"pg" => version})
    |> Enum.filter(&(&1.severity == 1))
    |> Enum.map(& &1.message)
  end

  # ALTER SYSTEM SET, reset again when it took, with the server's message,
  # detail and hint joined the way the diagnostic joins them.
  defp alter_system(conn, name, value) do
    case Postgrex.query(conn, "alter system set #{name} = #{literal(value)}", []) do
      {:ok, _result} ->
        Postgrex.query!(conn, "alter system reset #{name}", [])
        :ok

      {:error, %Postgrex.Error{postgres: postgres}} ->
        {:error,
         [postgres[:message], postgres[:detail], postgres[:hint]]
         |> Enum.reject(&is_nil/1)
         |> Enum.join("\n")}
    end
  end

  defp unquote_value("'" <> rest),
    do: rest |> String.trim_trailing("'") |> String.replace("''", "'")

  defp unquote_value(value), do: value

  defp scalar!(conn, sql), do: hd(hd(Postgrex.query!(conn, sql, []).rows))
  defp query!(conn, sql), do: Postgrex.query!(conn, sql, []).rows

  defp read!(conn, path),
    do: hd(hd(Postgrex.query!(conn, "select pg_read_file($1)", [path]).rows))

  defp program!(conn, command),
    do: Postgrex.query!(conn, "copy (select 1 where false) to program #{literal(command)}", [])

  defp write!(conn, path, lines) do
    values = Enum.map_join(lines, ", ", &literal/1)

    Postgrex.query!(
      conn,
      "copy (select unnest(array[#{values}]::text[])) to #{literal(path)}",
      []
    )
  end

  defp literal(text), do: "'" <> String.replace(text, "'", "''") <> "'"
end
