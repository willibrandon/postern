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
    assert Enum.any?(messages, &String.contains?(&1, "boolean setting \"fsync\""))
    assert Enum.any?(messages, &String.contains?(&1, "not one of"))
    assert Enum.any?(messages, &String.contains?(&1, "below the minimum"))
    assert Enum.any?(messages, &String.contains?(&1, "unit \"ms\" is not allowed"))
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

  test "a malformed value is one error on its value span" do
    [diagnostic] =
      Diagnostics.for_document("file:///tmp/postgresql.conf", "shared_buffers = 128QB\n", %{
        "pg" => 16
      })

    assert diagnostic.severity == 1
    assert diagnostic.message == "setting could not be applied"
    assert diagnostic.range.start.character == 17
    assert diagnostic.range.end.character == 22
  end

  defp fixture!(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
  end
end
