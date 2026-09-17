defmodule Postern.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Postern.Diagnostics

  @fixtures Path.expand("../fixtures", __DIR__)

  test "parser errors become diagnostics with the exact source line span" do
    cases = [
      {"invalid_postgresql.conf", "file:///tmp/postgresql.conf", 0, 0, 6},
      {"invalid_pg_hba.conf", "file:///tmp/pg_hba.conf", 0, 0, 12},
      {"invalid_pg_ident.conf", "file:///tmp/pg_ident.conf", 0, 0, 21}
    ]

    for {fixture, uri, line, start_character, end_character} <- cases do
      text = fixture!(fixture)

      assert [%{range: range, severity: 1, source: "postern"}] =
               Diagnostics.for_document(uri, text)

      assert range.start.line == line
      assert range.start.character == start_character
      assert range.end.line == line
      assert range.end.character == end_character
    end
  end

  test "reads the file next to the document through a reader" do
    directory =
      Path.join(System.tmp_dir!(), "postern-files-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    hba_path = Path.join(directory, "pg_hba.conf")
    ident_path = Path.join(directory, "pg_ident.conf")
    File.write!(hba_path, "local all all peer map=known\nlocal all all ident map=missing\n")
    File.write!(ident_path, "known root postgres\nspare root postgres\n")
    hba_uri = Postern.FileKind.path_to_uri(hba_path)
    ident_uri = Postern.FileKind.path_to_uri(ident_path)

    messages = fn uri, path, reader ->
      Diagnostics.for_document(uri, File.read!(path), %{reader: reader})
      |> Enum.map(& &1.message)
      |> Enum.filter(&String.contains?(&1, "ident map"))
    end

    assert messages.(hba_uri, hba_path, Postern.Files.disk()) ==
             [~s(ident map "missing" does not exist in pg_ident.conf)]

    assert messages.(ident_uri, ident_path, Postern.Files.disk()) ==
             [~s(ident map "spare" is never referenced)]

    # An open document counts before the copy on the disk.
    open = %{ident_uri => %{text: "known root postgres\nmissing root postgres\n"}}
    assert messages.(hba_uri, hba_path, Postern.Files.with_documents(open)) == []

    # Without the reader, or without the file, there is nothing to look at.
    assert Diagnostics.for_document(hba_uri, File.read!(hba_path))
           |> Enum.map(& &1.message)
           |> Enum.filter(&String.contains?(&1, "ident map")) == []

    File.rm!(ident_path)
    assert messages.(hba_uri, hba_path, Postern.Files.disk()) == []
  end

  defp fixture!(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
  end
end
