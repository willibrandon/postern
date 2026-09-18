defmodule Postern.PostgresqlConfDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Postern.Diagnostics

  @fixtures Path.expand("../fixtures", __DIR__)

  test "reports catalog-backed diagnostics from the fixture" do
    diagnostics =
      Diagnostics.for_document(
        "file:///tmp/postgresql.conf",
        fixture!("postgresql_diagnostics.conf"),
        %{"pg" => 16}
      )

    messages = Enum.map(diagnostics, & &1.message)

    assert ~s(unrecognized configuration parameter "shared_buffrs"\nPerhaps you meant "shared_buffers".) in messages

    assert ~s(parameter "fsync" requires a Boolean value) in messages

    assert ~s(invalid value for parameter "password_encryption": "plaintext"\nAvailable values: md5, scram-sha-256.) in messages

    assert ~s|0 is outside the valid range for parameter "max_connections" (1 .. 262143)| in messages

    assert ~s(invalid value for parameter "port": "5432ms") in messages
    refute Enum.any?(messages, &String.contains?(&1, "requires restart"))

    overrides =
      diagnostics
      |> Enum.filter(&(&1.code == "override"))
      |> Enum.map(&{&1.range.start.line, &1.severity, &1.message})

    assert overrides == [
             {4, 4, "overridden by a later entry on line 9"},
             {5, 4, "overridden by a later entry on line 7"}
           ]
  end

  test "selects the target version from a postern comment" do
    text = "# postern: pg=18\nold_snapshot_threshold = 1\n"
    [diagnostic] = Diagnostics.for_document("file:///tmp/postgresql.conf", text)

    assert diagnostic.message ==
             ~s(unrecognized configuration parameter "old_snapshot_threshold"\nPostgreSQL 17 removed it.)
  end

  # A name the target version does not have refuses the whole file, and the
  # second line says what became of it.
  @history [
    {13, "summarize_wal = on", "It arrives in PostgreSQL 17."},
    {18, "force_parallel_mode = on", ~s(PostgreSQL 16 replaced it with "debug_parallel_query".)},
    {18, "stats_temp_directory = 'x'", "PostgreSQL 15 removed it."},
    {18, "promote_trigger_file = 'x'", "PostgreSQL 16 removed it."},
    {18, "ssl_ecdh_curve = 'x'", ~s(PostgreSQL 18 replaced it with "ssl_groups".)},
    {17, "ssl_ecdh_curve = 'x'", nil},
    {13, "wal_keep_segments = 32", ~s(PostgreSQL 13 replaced it with "wal_keep_size".)},
    {18, "checkpoint_segments = 32", ~s(PostgreSQL 9.5 replaced it with "max_wal_size".)},
    {18, "standby_mode = on",
     "PostgreSQL 12 removed it; a standby.signal file in the data directory takes its place."},
    {18, "silent_mode = on", "PostgreSQL 9.2 removed it."},
    {18, "shared_buffrs = 1", ~s(Perhaps you meant "shared_buffers".)},
    {18, "zzzz = 1", :nothing}
  ]

  for {version, line, note} <- @history do
    test "#{line} on #{version}" do
      [name | _rest] = String.split(unquote(line))

      diagnostics =
        Diagnostics.for_document("file:///tmp/postgresql.conf", unquote(line) <> "\n", %{
          "pg" => unquote(version)
        })
        |> Enum.map(&{&1.severity, &1.message})

      first = ~s(unrecognized configuration parameter "#{name}")

      case unquote(note) do
        nil -> assert diagnostics == []
        :nothing -> assert diagnostics == [{1, first}]
        note -> assert diagnostics == [{1, first <> "\n" <> note}]
      end
    end
  end

  test "unknown settings get a Jaro-based suggestion" do
    [diagnostic] =
      Diagnostics.for_document("file:///tmp/postgresql.conf", "shared_buffrs = 128MB\n", %{
        "pg" => 16
      })

    assert diagnostic.severity == 1

    assert diagnostic.message ==
             ~s(unrecognized configuration parameter "shared_buffrs"\nPerhaps you meant "shared_buffers".)

    assert diagnostic.range.start.line == 0
    assert diagnostic.range.start.character == 0

    [diagnostic] =
      Diagnostics.for_document("file:///tmp/postgresql.conf", "zzzz = 1\n", %{"pg" => 16})

    assert diagnostic.message == ~s(unrecognized configuration parameter "zzzz")
  end

  test "a syntax error is the scanner's, on the token it stopped at" do
    [diagnostic] =
      Diagnostics.for_document("file:///tmp/postgresql.conf", "work_mem = 1.5GB\n", %{
        "pg" => 18
      })

    assert diagnostic.message == ~s(syntax error near token "GB")
    assert diagnostic.range.start.character == 14
    assert diagnostic.range.end.character == 16
  end

  test "an enum value with a space in it is one of the values" do
    text = "default_transaction_isolation = 'read committed'\n"
    assert Diagnostics.for_document("file:///tmp/postgresql.conf", text, %{"pg" => 18}) == []

    [diagnostic] =
      Diagnostics.for_document(
        "file:///tmp/postgresql.conf",
        "default_transaction_isolation = 'read commited'\n",
        %{"pg" => 18}
      )

    assert diagnostic.message ==
             ~s(invalid value for parameter "default_transaction_isolation": "read commited"\n) <>
               "Available values: serializable, repeatable read, read committed, read uncommitted."
  end

  test "a malformed value is one error on its value span" do
    [diagnostic] =
      Diagnostics.for_document("file:///tmp/postgresql.conf", "shared_buffers = 128QB\n", %{
        "pg" => 16
      })

    assert diagnostic.severity == 1

    assert diagnostic.message ==
             ~s(invalid value for parameter "shared_buffers": "128QB"\n) <>
               ~s(Valid units for this parameter are "B", "kB", "MB", "GB", and "TB".)

    assert diagnostic.range.start.character == 17
    assert diagnostic.range.end.character == 22
  end

  # Each line is what a reload on 18 makes of it: nothing, or the message
  # the server logs with its hint on a second line.
  @values [
    {"log_file_mode = 0600", nil},
    {"unix_socket_permissions = 0777", nil},
    {"work_mem = 0x80", nil},
    {"work_mem = 100.7", nil},
    {"work_mem = '64 MB'", nil},
    {"work_mem = '1.5GB'", nil},
    {"enable_seqscan = of", nil},
    {"checkpoint_completion_target = 0.9", nil},
    {"work_mem = 128mb",
     ~s(invalid value for parameter "work_mem": "128mb"\n) <>
       ~s(Valid units for this parameter are "B", "kB", "MB", "GB", and "TB".)},
    {"statement_timeout = 5MB",
     ~s(invalid value for parameter "statement_timeout": "5MB"\n) <>
       ~s(Valid units for this parameter are "us", "ms", "s", "min", "h", and "d".)},
    {"max_parallel_workers = 5MB", ~s(invalid value for parameter "max_parallel_workers": "5MB")},
    {"enable_seqscan = o", ~s(parameter "enable_seqscan" requires a Boolean value)},
    {"log_file_mode = 9999",
     ~s|9999 is outside the valid range for parameter "log_file_mode" (0 .. 511)|},
    {"work_mem = 1kB",
     ~s|1 kB is outside the valid range for parameter "work_mem" (64 kB .. 2147483647 kB)|},
    {"shared_buffers = 1kB",
     ~s|0 8kB is outside the valid range for parameter "shared_buffers" (16 8kB .. 1073741823 8kB)|},
    {"checkpoint_completion_target = 1.5",
     ~s|1.5 is outside the valid range for parameter "checkpoint_completion_target" (0 .. 1)|},
    {"random_page_cost = abc", ~s(invalid value for parameter "random_page_cost": "abc")},
    {"work_mem = 99999999999",
     ~s(invalid value for parameter "work_mem": "99999999999"\nValue exceeds integer range.)}
  ]

  for {line, expected} <- @values do
    test "#{line} on 18" do
      diagnostics =
        Diagnostics.for_document("file:///tmp/postgresql.conf", unquote(line) <> "\n", %{
          "pg" => 18
        })

      assert Enum.map(diagnostics, & &1.message) == List.wrap(unquote(expected))
    end
  end

  # A string setting with a check hook is refused the way the hook refuses
  # it, with the detail on a second line, or with the hook's own message.
  @strings [
    {"datestyle = 'ISO, MDX'",
     ~s(invalid value for parameter "DateStyle": "ISO, MDX"\nUnrecognized key word: "mdx".)},
    {"timezone = 'Mars/Olympus'", ~s(invalid value for parameter "TimeZone": "Mars/Olympus")},
    {"log_destination = 'stderr, csvlogg'",
     ~s(invalid value for parameter "log_destination": "stderr, csvlogg"\nUnrecognized key word: "csvlogg".)},
    {"client_encoding = 'utf-9'", ~s(invalid value for parameter "client_encoding": "utf-9")},
    {"recovery_target = 'nope'",
     ~s(invalid value for parameter "recovery_target": "nope"\nThe only allowed value is "immediate".)},
    {"synchronous_standby_names = 'FIRST 2 (a, b'",
     ~s|invalid value for parameter "synchronous_standby_names": "FIRST 2 (a, b"\nsyntax error at end of input|},
    {"synchronous_standby_names = '0 (a)'",
     "number of synchronous standbys (0) must be greater than zero"},
    {"wal_consistency_checking = 'heap, nope'",
     ~s(invalid value for parameter "wal_consistency_checking": "heap, nope"\nUnrecognized key word: "nope".)},
    {"timezone = 'Europe/Berlin'", nil},
    {"timezone = Europe/Berlin", nil},
    {"timezone = 'Foo5Bar,M3.2.0,M11.1.0'", nil},
    {"log_destination = 'STDERR'", nil},
    {"client_encoding = 'UTF-8'", nil},
    {"synchronous_standby_names = 'any 1 (a, \"b c\", *)'", nil},
    {"shared_preload_libraries = 'anything'", nil}
  ]

  for {line, expected} <- @strings do
    test "#{line} on 18" do
      diagnostics =
        Diagnostics.for_document("file:///tmp/postgresql.conf", unquote(line) <> "\n", %{
          "pg" => 18
        })

      assert Enum.map(diagnostics, & &1.message) == List.wrap(unquote(expected))
    end
  end

  test "an enum takes the spellings the server hides, in any case, and lists the visible ones" do
    for line <- [
          "wal_level = archive",
          "wal_level = ARCHIVE",
          "wal_level = hot_standby",
          "synchronous_commit = true",
          "huge_pages = 1",
          "log_min_messages = debug"
        ] do
      assert Diagnostics.for_document("file:///tmp/postgresql.conf", line <> "\n", %{"pg" => 18}) ==
               []
    end

    [diagnostic] =
      Diagnostics.for_document("file:///tmp/postgresql.conf", "wal_level = nope\n", %{"pg" => 18})

    assert diagnostic.message ==
             ~s(invalid value for parameter "wal_level": "nope"\nAvailable values: minimal, replica, logical.)
  end

  test "a module's setting is a placeholder the server takes as it is" do
    for line <- [
          "pg_stat_statements.max = 5000",
          "auto_explain.log_min_duration = 250ms",
          "auto_explain.log_level = debug",
          "x.y = on",
          "pgcrypto.builtin_crypto_enabled = fips"
        ] do
      assert Diagnostics.for_document("file:///tmp/postgresql.conf", line <> "\n", %{"pg" => 18}) ==
               []
    end
  end

  test "a known module's setting is checked like any other" do
    for {line, expected} <- [
          {"pg_stat_statements.max = 50",
           ~s|50 is outside the valid range for parameter "pg_stat_statements.max" (100 .. 1073741823)|},
          {"auto_explain.log_min_duration = 5MB",
           ~s(invalid value for parameter "auto_explain.log_min_duration": "5MB"\n) <>
             ~s(Valid units for this parameter are "us", "ms", "s", "min", "h", and "d".)},
          {"plpgsql.variable_conflict = nope",
           ~s(invalid value for parameter "plpgsql.variable_conflict": "nope"\n) <>
             "Available values: error, use_variable, use_column."}
        ] do
      [diagnostic] =
        Diagnostics.for_document("file:///tmp/postgresql.conf", line <> "\n", %{"pg" => 18})

      assert diagnostic.message == expected
    end
  end

  test "a placeholder under a known module's prefix is removed with a warning when it loads" do
    [diagnostic] =
      Diagnostics.for_document("file:///tmp/postgresql.conf", "pg_stat_statements.nope = 1\n", %{
        "pg" => 18
      })

    assert diagnostic.severity == 2

    assert diagnostic.message ==
             ~s(invalid configuration parameter name "pg_stat_statements.nope", removing it\n) <>
               ~s("pg_stat_statements" is now a reserved prefix.)

    [diagnostic] =
      Diagnostics.for_document("file:///tmp/postgresql.conf", "pg_stat_statements.nope = 1\n", %{
        "pg" => 14
      })

    assert diagnostic.severity == 2

    assert diagnostic.message ==
             ~s(unrecognized configuration parameter "pg_stat_statements.nope")

    # A module the version's catalog does not know keeps its placeholder.
    assert Diagnostics.for_document("file:///tmp/postgresql.conf", "pgcrypto.nope = 1\n", %{
             "pg" => 17
           }) == []
  end

  test "a setting with the internal context cannot be changed, whatever its value" do
    for line <- ["block_size = 8192", "block_size = abc", "data_checksums = on"] do
      [diagnostic] =
        Diagnostics.for_document("file:///tmp/postgresql.conf", line <> "\n", %{"pg" => 18})

      [name | _] = String.split(line)
      assert diagnostic.message == ~s(parameter "#{name}" cannot be changed)
      assert diagnostic.range.start.character == 0
      assert diagnostic.range.end.character == String.length(name)
    end
  end

  test "the bounds carry no unit before 17" do
    [diagnostic] =
      Diagnostics.for_document("file:///tmp/postgresql.conf", "work_mem = 1kB\n", %{"pg" => 16})

    assert diagnostic.message ==
             ~s|1 kB is outside the valid range for parameter "work_mem" (64 .. 2147483647)|
  end

  defp fixture!(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
  end
end
