defmodule Postern.ConfigTreeLiveTest do
  @moduledoc """
  Compares the resolver with `pg_file_settings` on a running server, the
  view in which PostgreSQL reads its own configuration files and says, for
  every line, whether it applied. The tree is written into the server's
  data directory through `COPY TO PROGRAM`, which a superuser may run, and
  read back with `pg_read_file`, so both sides look at the very same files.

  The same is done for `pg_hba.conf` against `pg_hba_file_rules` from 16 on,
  the version that gave that file include directives. Runs when `PGHOST`
  names a server, as the CI matrix does for 13 through 18.
  """

  use ExUnit.Case, async: false

  @moduletag :live

  alias Postern.ConfigTree
  alias Postern.Files
  alias Postern.LiveOracle

  setup do
    {:ok, conn} =
      Postgrex.start_link(LiveOracle.connection_options(%{}) ++ [connect_timeout: 5_000])

    %{conn: conn}
  end

  test "reads the files in the order the server does and marks the same lines overridden", %{
    conn: conn
  } do
    data_directory = scalar!(conn, "select current_setting('data_directory')")
    config_file = scalar!(conn, "select current_setting('config_file')")
    tree = Path.join(data_directory, "postern_tree")

    program!(conn, "mkdir -p #{tree}/conf.d")
    write!(conn, "#{tree}/shared.conf", ["work_mem = 4MB"])

    write!(conn, "#{tree}/conf.d/10-memory.conf", [
      "work_mem = 8MB",
      "maintenance_work_mem = 64MB"
    ])

    write!(conn, "#{tree}/conf.d/B.conf", ["work_mem = 16MB"])
    write!(conn, "#{tree}/conf.d/a.conf", ["maintenance_work_mem = 128MB"])
    write!(conn, "#{tree}/conf.d/.hidden.conf", ["port = 1"])
    write!(conn, "#{tree}/conf.d/notes.txt", ["port = 2"])

    write!(conn, "#{tree}/main.conf", [
      "include 'shared.conf'",
      "include_if_exists 'missing.conf'",
      "include_dir 'conf.d'",
      "work_mem = 32MB",
      "log_min_duration_statement = 250"
    ])

    # The server's own postgresql.conf reads the tree, appended once.
    unless String.contains?(read!(conn, config_file), tree) do
      program!(conn, "printf \"include '#{tree}/main.conf'\\n\" >> #{config_file}")
    end

    rows =
      query!(
        conn,
        "select sourcefile, sourceline, name, applied, error from pg_file_settings order by seqno"
      )

    resolved = ConfigTree.resolve(:postgresql_conf, config_file, server_files(conn))

    assert Enum.map(rows, fn [file, line, name, _applied, _error] -> {file, line, name} end) ==
             for(
               %{path: path, entry: %{type: :assignment, name: name, span: span}} <-
                 resolved.entries,
               do: {path, span.line, name}
             )

    overridden_by_server =
      for [file, line, _name, false, nil] <- rows, do: {file, line}

    overridden_by_postern =
      for {%{path: path, entry: %{span: span}}, _winner} <- ConfigTree.overridden(resolved),
          do: {path, span.line}

    assert Enum.sort(overridden_by_server) == Enum.sort(overridden_by_postern)
    assert {"#{tree}/conf.d/B.conf", 1} in overridden_by_postern
    assert {"#{tree}/conf.d/10-memory.conf", 2} in overridden_by_postern

    main = "#{tree}/main.conf"
    assert [%{path: ^main, severity: 4, message: skipped}] = resolved.problems
    assert skipped == ~s(skipping missing configuration file "#{tree}/missing.conf")
  end

  test "reads pg_hba.conf includes in the order pg_hba_file_rules does", %{conn: conn} do
    # pg_hba.conf took the include directives in 16.
    if scalar!(conn, "select current_setting('server_version_num')::int") >= 160_000 do
      data_directory = scalar!(conn, "select current_setting('data_directory')")
      hba_file = scalar!(conn, "select current_setting('hba_file')")
      tree = Path.join(data_directory, "postern_hba.d")

      program!(conn, "mkdir -p #{tree}")
      write!(conn, "#{tree}/10-app.conf", ["host postern_app postern_user 10.0.0.0/8 reject"])

      # pg_hba.conf quotes with double quotes only; a single quote would be
      # part of the name, and the server would fail to open the file.
      write!(conn, "#{tree}/20-more.conf", [
        "include_if_exists missing.conf",
        "host postern_more postern_user 10.0.0.0/8 reject",
        "host postern_continued postern_user 10.0.0.0/8 \\",
        "  reject"
      ])

      write!(conn, "#{tree}/notes.txt", ["host all all all trust"])

      unless String.contains?(read!(conn, hba_file), tree) do
        program!(conn, "printf \"include_dir #{tree}\\n\" >> #{hba_file}")
      end

      # Every line the server took for a rule, valid or not, in the order it
      # read them; the parser refuses the same lines, as errors.
      rows = query!(conn, "select file_name, line_number from pg_hba_file_rules")

      resolved = ConfigTree.resolve(:pg_hba_conf, hba_file, server_files(conn))

      assert Enum.map(rows, &List.to_tuple/1) ==
               for(
                 %{path: path, entry: %{type: type, span: span}} <- resolved.entries,
                 type in [:rule, :error],
                 do: {path, span.line}
               )

      assert {"#{tree}/20-more.conf", 2} in Enum.map(rows, &List.to_tuple/1)
      # The continued rule carries the number of the line it starts on.
      assert {"#{tree}/20-more.conf", 3} in Enum.map(rows, &List.to_tuple/1)
      refute {"#{tree}/20-more.conf", 4} in Enum.map(rows, &List.to_tuple/1)
      assert [%{severity: 4, message: skipped}] = resolved.problems
      assert skipped == ~s(skipping missing authentication file "#{tree}/missing.conf")
    end
  end

  # The server's own files, read the way the resolver reads a disk.
  defp server_files(conn) do
    %Files{
      read: fn path ->
        case Postgrex.query(conn, "select pg_read_file($1)", [path]) do
          {:ok, %{rows: [[text]]}} -> {:ok, text}
          _error -> :error
        end
      end,
      list: fn directory ->
        case Postgrex.query(
               conn,
               "select name from pg_ls_dir($1) as name where not (pg_stat_file($1 || '/' || name)).isdir",
               [directory]
             ) do
          {:ok, %{rows: names}} -> {:ok, List.flatten(names)}
          _error -> :error
        end
      end
    }
  end

  defp scalar!(conn, sql), do: hd(hd(Postgrex.query!(conn, sql, []).rows))
  defp query!(conn, sql), do: Postgrex.query!(conn, sql, []).rows

  defp read!(conn, path),
    do: hd(hd(Postgrex.query!(conn, "select pg_read_file($1)", [path]).rows))

  # COPY takes no parameters, so the command is a literal. The query has no
  # row: the server writes its rows to the program's pipe and flushes them
  # when it closes it, and a program that never reads its input may have
  # exited by then, which the server reports as a broken pipe.
  defp program!(conn, command),
    do: Postgrex.query!(conn, "copy (select 1 where false) to program #{literal(command)}", [])

  # The lines are written one per row, since COPY's text format would escape
  # a newline.
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
