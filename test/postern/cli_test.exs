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

  defp invalid_config_path do
    directory = Path.join(System.tmp_dir!(), "postern-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "postgresql.conf")
    File.write!(path, File.read!(Path.join(@fixtures, "invalid_postgresql.conf")))
    path
  end
end
