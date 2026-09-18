defmodule Postern.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Postern.CLI

  @fixtures Path.expand("../fixtures", __DIR__)

  test "--help prints usage and returns zero" do
    output = capture_io(fn -> assert CLI.run(["--help"]) == 0 end)
    assert output =~ "Usage:"
    assert output =~ "postern check"
  end

  test "--version prints the version and returns zero" do
    output = capture_io(fn -> assert CLI.run(["--version"]) == 0 end)
    assert output =~ ~r/^postern \d+\.\d+\.\d+/
  end

  test "check returns zero for a valid PostgreSQL configuration" do
    output =
      capture_io(fn ->
        assert CLI.run(["check", Path.join(@fixtures, "postgresql.conf")]) == 0
      end)

    assert output == ""
  end

  test "check returns one for parser errors" do
    path = invalid_config_path()

    output =
      capture_io(fn ->
        assert CLI.run(["check", path]) == 1
      end)

    assert output =~ "error"
  end

  test "check --json emits machine-readable diagnostics" do
    path = invalid_config_path()

    output =
      capture_io(fn ->
        assert CLI.run(["check", "--json", path]) == 1
      end)

    assert [%{"file" => _, "diagnostics" => [%{"message" => _}]}] = Jason.decode!(output)
  end

  test "check reads the file next to the one it is given" do
    directory = Path.join(System.tmp_dir!(), "postern-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    hba_path = Path.join(directory, "pg_hba.conf")
    ident_path = Path.join(directory, "pg_ident.conf")
    File.write!(hba_path, "local all all peer map=missing\n")
    File.write!(ident_path, "known root postgres\n")

    output = capture_io(fn -> assert CLI.run(["check", hba_path]) == 1 end)
    assert output =~ ~s(error: ident map "missing" does not exist in pg_ident.conf)

    output = capture_io(fn -> assert CLI.run(["check", ident_path]) == 0 end)
    assert output =~ ~s(warning: ident map "known" is never referenced)
  end

  test "check follows the includes of a root and knows a file by the root that includes it" do
    directory = Path.join(System.tmp_dir!(), "postern-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(directory, "conf.d"))
    on_exit(fn -> File.rm_rf!(directory) end)
    root = Path.join(directory, "postgresql.conf")
    included = Path.join(directory, "conf.d/10-memory.conf")
    stray = Path.join(directory, "stray.conf")
    File.write!(root, "work_mem = 4MB\ninclude_dir 'conf.d'\ninclude 'gone.conf'\n")
    File.write!(included, "work_mem = 8MB\nshared_buffrs = 1\n")
    File.write!(stray, "port = 5432\n")

    output = capture_io(fn -> assert CLI.run(["check", root]) == 1 end)

    assert output =~
             ~s(postgresql.conf:1:1: hint: overridden by a later entry in conf.d/10-memory.conf on line 1)

    # A message names a file the way the resolver built it, in the one form
    # every path takes, which on Windows is not the form the test joined.
    canonical = Path.expand(directory)
    assert output =~ ~s(postgresql.conf:3:9: error: could not open file "#{canonical}/gone.conf")

    assert output =~
             ~s(10-memory.conf:2:1: error: unrecognized configuration parameter "shared_buffrs"\n) <>
               ~s(  Perhaps you meant "shared_buffers".\n)

    # The included file on its own is checked through its root, and once
    # when it is given with the root.
    output = capture_io(fn -> assert CLI.run(["check", included]) == 1 end)

    assert output =~
             ~s(10-memory.conf:2:1: error: unrecognized configuration parameter "shared_buffrs"\n) <>
               ~s(  Perhaps you meant "shared_buffers".\n)

    output = capture_io(fn -> assert CLI.run(["check", root, included]) == 1 end)
    assert length(String.split(output, "shared_buffrs")) == 2

    errors = capture_io(:stderr, fn -> assert CLI.run(["check", stray]) == 1 end)
    assert errors =~ "no postgresql.conf, pg_hba.conf or pg_ident.conf includes it"
  end

  defp invalid_config_path do
    directory = Path.join(System.tmp_dir!(), "postern-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "postgresql.conf")
    File.write!(path, File.read!(Path.join(@fixtures, "invalid_postgresql.conf")))
    path
  end

  test "--pg checks against that version" do
    directory = Path.join(System.tmp_dir!(), "postern-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "postgresql.conf")
    File.write!(path, "summarize_wal = on\n")

    assert capture_io(fn -> assert CLI.run(["check", "--pg", "18", path]) == 0 end) == ""

    output = capture_io(fn -> assert CLI.run(["check", "--pg", "13", path]) == 1 end)

    assert output =~
             ~s(unrecognized configuration parameter "summarize_wal"\n  It arrives in PostgreSQL 17.)
  end

  test "--stdin-filename reads the file from stdin as if it stood at the path" do
    directory = Path.join(System.tmp_dir!(), "postern-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    File.write!(Path.join(directory, "pg_ident.conf"), "known root postgres\n")
    hba = Path.join(directory, "pg_hba.conf")

    output =
      capture_io([input: "local all all peer map=missing\n"], fn ->
        assert CLI.run(["check", "--stdin-filename", hba]) == 1
      end)

    assert output =~
             ~s(pg_hba.conf:1:20: error: ident map "missing" does not exist in pg_ident.conf)
  end

  test "--format github writes one workflow command per diagnostic" do
    path = invalid_config_path()
    output = capture_io(fn -> assert CLI.run(["check", "--format", "github", path]) == 1 end)

    assert output =~
             ~r/^::error file=.*postgresql\.conf,line=\d+,col=\d+,endLine=\d+,endColumn=\d+,title=Postern::/m

    refute output =~ "\n  "
  end

  test "--format sarif writes a run with one result per diagnostic" do
    path = invalid_config_path()
    output = capture_io(fn -> assert CLI.run(["check", "--format", "sarif", path]) == 1 end)
    sarif = Jason.decode!(output)
    assert sarif["version"] == "2.1.0"

    assert [%{"tool" => %{"driver" => %{"name" => "Postern"}}, "results" => [result]}] =
             sarif["runs"]

    assert result["level"] == "error"
    assert result["locations"] |> hd() |> get_in(["physicalLocation", "region", "startLine"]) == 1
  end

  test "--strict fails on a warning, and an unknown format is a usage error" do
    directory = Path.join(System.tmp_dir!(), "postern-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    ident = Path.join(directory, "pg_ident.conf")
    File.write!(ident, "known root postgres\n")
    File.write!(Path.join(directory, "pg_hba.conf"), "local all all peer\n")

    capture_io(fn -> assert CLI.run(["check", ident]) == 0 end)
    capture_io(fn -> assert CLI.run(["check", "--strict", ident]) == 1 end)
    capture_io(:stderr, fn -> assert CLI.run(["check", "--format", "yaml", ident]) == 2 end)
  end

  @tag :live
  test "--live compares the files with the server the environment names" do
    directory = Path.join(System.tmp_dir!(), "postern-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "postgresql.conf")
    File.write!(path, "port = 5432\n")

    # The file is not the server's, so no live row lands on it, and the
    # server being there means no note about it being away.
    assert capture_io(fn -> assert CLI.run(["check", "--live", path]) == 0 end) == ""

    output =
      capture_io(fn ->
        assert CLI.run([
                 "check",
                 "--connection-string",
                 "postgres://postgres@127.0.0.1:1/postgres",
                 path
               ]) == 0
      end)

    assert output =~ "PostgreSQL server is unreachable"
  end
end
