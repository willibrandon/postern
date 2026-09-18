defmodule Postern.LiveFeaturesTest do
  use ExUnit.Case, async: true

  alias Postern.LiveFeatures

  test "returns effective value and pending restart hints" do
    snapshot = %{
      settings: [
        %{"name" => "port", "setting" => "5433", "pending_restart" => "f"},
        %{"name" => "shared_buffers", "setting" => "16384", "pending_restart" => "t"}
      ]
    }

    hints = LiveFeatures.inlay_hints("port = 5432\nshared_buffers = 128MB\n", snapshot)

    assert Enum.any?(hints, &(&1.label == " = 5433"))
    assert Enum.any?(hints, &(&1.label == " pending restart"))
  end

  @range %{start: %{line: 1, character: 3}, end: %{line: 1, character: 3}}
  @snapshot %{
    settings: [
      %{"name" => "work_mem", "context" => "user"},
      %{"name" => "shared_buffers", "context" => "postmaster"}
    ]
  }

  test "offers one ALTER SYSTEM SET for the setting on the line, with the statement in its title, and a reload" do
    text = "port = 5432\nwork_mem = '64 MB'\n"
    actions = LiveFeatures.code_actions("file:///tmp/postgresql.conf", text, @snapshot, @range)

    assert Enum.map(actions, & &1.title) == [
             "ALTER SYSTEM SET work_mem = '64 MB'",
             "Run pg_reload_conf()"
           ]

    assert hd(actions).command.command == "postern.applyAlterSystem"
    assert hd(actions).command.arguments == ["file:///tmp/postgresql.conf", "work_mem", "64 MB"]

    blank = %{start: %{line: 2, character: 0}, end: %{line: 2, character: 0}}

    assert Enum.map(
             LiveFeatures.code_actions("file:///tmp/postgresql.conf", text, @snapshot, blank),
             & &1.title
           ) == ["Run pg_reload_conf()"]

    assert LiveFeatures.code_actions(
             "file:///tmp/postgresql.conf",
             text,
             {:error, :unreachable},
             @range
           ) == []

    assert LiveFeatures.code_actions("file:///tmp/postgresql.conf", text, nil, @range) == []
  end

  test "a value with a quote in it is a literal with the quote doubled" do
    assert LiveFeatures.statement("log_line_prefix", "it's %m") ==
             "ALTER SYSTEM SET log_line_prefix = 'it''s %m'"
  end

  test "reports what a command did in the words of the setting's context, or the server's refusal" do
    apply = "postern.applyAlterSystem"

    assert LiveFeatures.report(apply, ["u", "work_mem", "64MB"], {:ok, []}, @snapshot) ==
             {3,
              "ALTER SYSTEM SET work_mem = '64MB' is in postgresql.auto.conf; a reload applies it to new sessions."}

    assert LiveFeatures.report(apply, ["u", "shared_buffers", "1GB"], {:ok, []}, @snapshot) ==
             {3,
              "ALTER SYSTEM SET shared_buffers = '1GB' is in postgresql.auto.conf; a restart applies it."}

    refusal = %Postgrex.Error{
      postgres: %{
        message: ~s(invalid value for parameter "work_mem": "128mb"),
        hint: ~s(Valid units for this parameter are "B", "kB", "MB", "GB", and "TB".)
      }
    }

    assert LiveFeatures.report(apply, ["u", "work_mem", "128mb"], {:error, refusal}, @snapshot) ==
             {1,
              ~s(invalid value for parameter "work_mem": "128mb"\nValid units for this parameter are "B", "kB", "MB", "GB", and "TB".)}

    assert LiveFeatures.report(
             apply,
             ["u", "work_mem", "64MB"],
             {:error, :unreachable},
             {:error, :unreachable}
           ) ==
             {1, "No server is reachable, so nothing ran."}

    assert LiveFeatures.report("postern.reloadConfig", ["u"], {:ok, [[true]]}, @snapshot) ==
             {3, "pg_reload_conf() told the server to read its configuration files again."}

    assert LiveFeatures.report(
             "postern.showEffectiveValue",
             ["u"],
             {:error, :unknown_command},
             @snapshot
           ) == nil
  end
end
