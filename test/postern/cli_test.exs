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
    assert output =~ ~s(10-memory.conf:2:1: error: unknown setting "shared_buffrs")

    # The included file on its own is checked through its root, and once
    # when it is given with the root.
    output = capture_io(fn -> assert CLI.run(["check", included]) == 1 end)
    assert output =~ ~s(10-memory.conf:2:1: error: unknown setting "shared_buffrs")

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
end
