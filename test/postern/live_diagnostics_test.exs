defmodule Postern.LiveDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Postern.LiveDiagnostics

  # A document whose lines are the ones the rows describe.
  defp at(lines) do
    last = lines |> Map.keys() |> Enum.max()
    Enum.map_join(1..last, "", fn n -> Map.get(lines, n, "") <> "\n" end)
  end

  test "maps file setting errors and pending restart rows to the document the rows describe" do
    snapshot = %{
      file_settings: [
        %{
          "sourcefile" => "/var/lib/postgresql/postgresql.conf",
          "sourceline" => 12,
          "name" => "shared_buffers",
          "setting" => "1GB",
          "applied" => false,
          "error" => "setting could not be applied"
        }
      ],
      settings: [
        %{
          "name" => "shared_buffers",
          "sourcefile" => "/var/lib/postgresql/postgresql.conf",
          "sourceline" => 12,
          "pending_restart" => "t"
        }
      ]
    }

    text = at(%{12 => "shared_buffers = 1GB"})

    diagnostics =
      LiveDiagnostics.for_document(
        "file:///elsewhere/postgresql.conf",
        text,
        snapshot,
        true,
        :postgresql_conf
      )

    assert Enum.any?(diagnostics, &(&1.message == "setting could not be applied"))
    assert Enum.any?(diagnostics, &String.contains?(&1.message, "pending restart"))
    assert Enum.all?(diagnostics, &(&1.range.start.line == 11))

    # An edit above the line moves it, and the rows no longer describe the document.
    shifted = "# a new comment\n" <> text

    assert LiveDiagnostics.for_document(
             "file:///elsewhere/postgresql.conf",
             shifted,
             snapshot,
             true,
             :postgresql_conf
           ) == []

    # So does another value on the line.
    assert LiveDiagnostics.for_document(
             "file:///elsewhere/postgresql.conf",
             at(%{12 => "shared_buffers = 2GB"}),
             snapshot,
             true,
             :postgresql_conf
           ) == []
  end

  test "of two files with the same lines the one named like the document is taken" do
    snapshot = %{
      settings: [],
      file_settings: [
        %{
          "sourcefile" => "/a/postgresql.conf",
          "sourceline" => 1,
          "name" => "port",
          "setting" => "5433",
          "applied" => true,
          "error" => nil
        },
        %{
          "sourcefile" => "/b/other.conf",
          "sourceline" => 1,
          "name" => "port",
          "setting" => "5433",
          "applied" => false,
          "error" => "setting could not be applied"
        }
      ]
    }

    assert LiveDiagnostics.for_document(
             "file:///x/postgresql.conf",
             "port = 5433\n",
             snapshot,
             true,
             :postgresql_conf
           ) == []

    [diagnostic] =
      LiveDiagnostics.for_document(
        "file:///x/other.conf",
        "port = 5433\n",
        snapshot,
        true,
        :postgresql_conf
      )

    assert diagnostic.message == "setting could not be applied"
  end

  test "reports one informational diagnostic when a configured server is unavailable" do
    [diagnostic] =
      LiveDiagnostics.for_document(
        "file:///tmp/postgresql.conf",
        "",
        {:error, :unreachable},
        true,
        :postgresql_conf
      )

    assert diagnostic.severity == 3
    assert diagnostic.message =~ "offline diagnostics"
  end

  test "a row the view left unapplied without an error lost to the applied one" do
    snapshot = %{
      settings: [],
      file_settings: [
        %{
          "sourcefile" => "/pg/postgresql.conf",
          "sourceline" => 3,
          "name" => "work_mem",
          "setting" => "4MB",
          "applied" => false,
          "error" => nil
        },
        %{
          "sourcefile" => "/pg/conf.d/10-memory.conf",
          "sourceline" => 1,
          "name" => "work_mem",
          "setting" => "8MB",
          "applied" => true,
          "error" => nil
        },
        %{
          "sourcefile" => "/pg/postgresql.conf",
          "sourceline" => 5,
          "name" => "port",
          "setting" => "5432",
          "applied" => false,
          "error" => nil
        },
        %{
          "sourcefile" => "/pg/postgresql.conf",
          "sourceline" => 9,
          "name" => "port",
          "setting" => "5433",
          "applied" => true,
          "error" => nil
        },
        %{
          "sourcefile" => "/pg/postgresql.conf",
          "sourceline" => 7,
          "name" => "shared_buffers",
          "setting" => "1QB",
          "applied" => false,
          "error" => "setting could not be applied"
        }
      ]
    }

    text =
      at(%{
        3 => "work_mem = 4MB",
        5 => "port = 5432",
        7 => "shared_buffers = 1QB",
        9 => "port = 5433"
      })

    diagnostics =
      LiveDiagnostics.for_document(
        "file:///pg/postgresql.conf",
        text,
        snapshot,
        true,
        :postgresql_conf
      )

    overrides =
      for %{code: "override"} = d <- diagnostics, do: {d.range.start.line, d.severity, d.message}

    assert overrides == [
             {2, 4, "overridden by a later entry in conf.d/10-memory.conf on line 1"},
             {4, 4, "overridden by a later entry on line 9"}
           ]

    # A syntax error leaves one row with no name, which is the document's
    # error on that line, and nothing to say about winners.
    broken = %{
      settings: [],
      file_settings: [
        %{
          "sourcefile" => "/pg/postgresql.conf",
          "sourceline" => 2,
          "name" => nil,
          "setting" => nil,
          "applied" => false,
          "error" => "syntax error"
        }
      ]
    }

    [diagnostic] =
      LiveDiagnostics.for_document(
        "file:///pg/postgresql.conf",
        "work_mem = 4MB\nlisten_addresses = *\n",
        broken,
        true,
        :postgresql_conf
      )

    assert diagnostic.message == "syntax error"
    assert diagnostic.range.start.line == 1
  end

  test "reads a line number the way the oracle's text protocol sends it" do
    snapshot = %{
      hba_rules: [
        %{
          "file_name" => "/etc/pg_hba.conf",
          "line_number" => "133",
          "type" => nil,
          "error" => "invalid"
        }
      ],
      ident_mappings: []
    }

    text = at(%{133 => "host all all 10.0.0.0/8 nope"})

    [diagnostic] =
      LiveDiagnostics.for_document("file:///etc/pg_hba.conf", text, snapshot, true, :pg_hba_conf)

    assert diagnostic.range.start.line == 132
  end

  test "maps live HBA and ident rule errors to the lines the rows describe" do
    hba = %{
      hba_rules: [
        %{
          "file_name" => "/etc/pg_hba.conf",
          "line_number" => 2,
          "type" => "local",
          "auth_method" => "peer",
          "error" => nil
        },
        %{
          "file_name" => "/etc/pg_hba.conf",
          "line_number" => 4,
          "type" => nil,
          "error" => "invalid address"
        }
      ],
      ident_mappings: []
    }

    ident = %{
      hba_rules: [],
      ident_mappings: [
        %{
          "file_name" => "/etc/pg_ident.conf",
          "line_number" => 7,
          "map_name" => nil,
          "error" => "invalid map"
        }
      ]
    }

    hba_text = at(%{2 => "local all all peer", 4 => "host all all 10.0.0.999 md5"})

    [hba_diagnostic] =
      LiveDiagnostics.for_document("file:///etc/pg_hba.conf", hba_text, hba, true, :pg_hba_conf)

    ident_text = at(%{7 => "broken /^(.* postgres"})

    [ident_diagnostic] =
      LiveDiagnostics.for_document(
        "file:///etc/pg_ident.conf",
        ident_text,
        ident,
        true,
        :pg_ident_conf
      )

    assert hba_diagnostic.message == "invalid address"
    assert hba_diagnostic.range.start.line == 3
    assert ident_diagnostic.message == "invalid map"
    assert ident_diagnostic.range.start.line == 6

    # A rule with another method on the line is not the server's file.
    assert LiveDiagnostics.for_document(
             "file:///etc/pg_hba.conf",
             at(%{2 => "local all all trust", 4 => "host all all 10.0.0.999 md5"}),
             hba,
             true,
             :pg_hba_conf
           ) == []
  end
end
