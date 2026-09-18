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

    assert Enum.any?(messages, &String.contains?(&1, "did you mean \"shared_buffers\""))
    assert ~s(parameter "fsync" requires a Boolean value) in messages
    assert Enum.any?(messages, &String.contains?(&1, "not one of"))

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
    diagnostics = Diagnostics.for_document("file:///tmp/postgresql.conf", text)

    assert Enum.any?(
             diagnostics,
             &String.contains?(&1.message, "may have been removed or renamed")
           )
  end

  test "unknown settings get a Jaro-based suggestion" do
    [diagnostic] =
      Diagnostics.for_document("file:///tmp/postgresql.conf", "shared_buffrs = 128MB\n", %{
        "pg" => 16
      })

    assert diagnostic.severity == 1

    assert diagnostic.message ==
             "unknown setting \"shared_buffrs\"; did you mean \"shared_buffers\"?"

    assert diagnostic.range.start.line == 0
    assert diagnostic.range.start.character == 0
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
             ~s(value "read commited" is not one of: serializable, repeatable read, read committed, read uncommitted)
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
