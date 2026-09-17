defmodule Postern.LiveDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Postern.LiveDiagnostics

  test "maps file setting errors and pending restart rows to source diagnostics" do
    snapshot = %{
      file_settings: [
        %{
          "sourcefile" => "/var/lib/postgresql/postgresql.conf",
          "sourceline" => 12,
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

    diagnostics =
      LiveDiagnostics.for_document("file:///var/lib/postgresql/postgresql.conf", snapshot, true)

    assert Enum.any?(diagnostics, &(&1.message == "setting could not be applied"))
    assert Enum.any?(diagnostics, &String.contains?(&1.message, "pending restart"))
    assert Enum.all?(diagnostics, &(&1.range.start.line == 11))
  end

  test "reports one informational diagnostic when a configured server is unavailable" do
    [diagnostic] =
      LiveDiagnostics.for_document("file:///tmp/postgresql.conf", {:error, :unreachable}, true)

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
          "applied" => false,
          "error" => nil
        },
        %{
          "sourcefile" => "/pg/conf.d/10-memory.conf",
          "sourceline" => 1,
          "name" => "work_mem",
          "applied" => true,
          "error" => nil
        },
        %{
          "sourcefile" => "/pg/postgresql.conf",
          "sourceline" => 5,
          "name" => "port",
          "applied" => false,
          "error" => nil
        },
        %{
          "sourcefile" => "/pg/postgresql.conf",
          "sourceline" => 9,
          "name" => "port",
          "applied" => true,
          "error" => nil
        },
        %{
          "sourcefile" => "/pg/postgresql.conf",
          "sourceline" => 7,
          "name" => "shared_buffers",
          "applied" => false,
          "error" => "setting could not be applied"
        }
      ]
    }

    diagnostics = LiveDiagnostics.for_document("file:///pg/postgresql.conf", snapshot, true)

    overrides =
      for %{code: "override"} = d <- diagnostics, do: {d.range.start.line, d.severity, d.message}

    assert overrides == [
             {2, 4, "overridden by a later entry in conf.d/10-memory.conf on line 1"},
             {4, 4, "overridden by a later entry on line 9"}
           ]

    # A syntax error leaves every row unapplied with no winner to point at.
    broken = %{
      settings: [],
      file_settings: [
        %{
          "sourcefile" => "/pg/postgresql.conf",
          "sourceline" => 1,
          "name" => "work_mem",
          "applied" => false,
          "error" => nil
        },
        %{
          "sourcefile" => "/pg/postgresql.conf",
          "sourceline" => 2,
          "name" => "work_mem",
          "applied" => false,
          "error" => nil
        },
        %{
          "sourcefile" => "/pg/postgresql.conf",
          "sourceline" => 3,
          "name" => "bogus",
          "applied" => false,
          "error" => "unrecognized configuration parameter \"bogus\""
        }
      ]
    }

    refute Enum.any?(
             LiveDiagnostics.for_document("file:///pg/postgresql.conf", broken, true),
             &(&1.code == "override")
           )
  end

  test "maps live HBA and ident rule errors" do
    hba = %{
      hba_rules: [
        %{"file_name" => "/etc/pg_hba.conf", "line_number" => 4, "error" => "invalid address"}
      ],
      ident_mappings: []
    }

    ident = %{
      hba_rules: [],
      ident_mappings: [
        %{"file_name" => "/etc/pg_ident.conf", "line_number" => 7, "error" => "invalid map"}
      ]
    }

    [hba_diagnostic] =
      LiveDiagnostics.for_document("file:///etc/pg_hba.conf", hba, true, :pg_hba_conf)

    [ident_diagnostic] =
      LiveDiagnostics.for_document("file:///etc/pg_ident.conf", ident, true, :pg_ident_conf)

    assert hba_diagnostic.message == "invalid address"
    assert hba_diagnostic.range.start.line == 3
    assert ident_diagnostic.message == "invalid map"
    assert ident_diagnostic.range.start.line == 6
  end
end
