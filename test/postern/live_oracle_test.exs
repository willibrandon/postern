defmodule Postern.LiveOracleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Postern.LiveOracle

  test "is disabled without connection configuration and never raises" do
    {:ok, oracle} = LiveOracle.start_link(nil)

    assert LiveOracle.status(oracle) == :disabled
    assert LiveOracle.snapshot(oracle) == {:error, :disabled}
  end

  test "a server that refuses the connection is unreachable, at once after the first check" do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)

    capture_log(fn ->
      # Started from a task that ends at once, as the initialize request's
      # does, and the oracle has to outlive it.
      {:ok, oracle} =
        Task.async(fn ->
          LiveOracle.start_link(
            hostname: "127.0.0.1",
            port: port,
            username: "postgres",
            database: "postgres",
            password: ""
          )
        end)
        |> Task.await()

      assert LiveOracle.snapshot(oracle) == {:error, :unreachable}
      assert LiveOracle.status(oracle) == :unreachable
      assert Process.alive?(oracle)

      {elapsed, snapshot} = :timer.tc(fn -> LiveOracle.snapshot(oracle) end, :millisecond)
      assert snapshot == {:error, :unreachable}
      assert elapsed < 500

      assert LiveOracle.execute(oracle, "postern.reloadConfig") == {:error, :unreachable}
      GenServer.stop(oracle)
    end)
  end

  @tag :live
  test "a server that answers is live from the first check" do
    {:ok, oracle} = LiveOracle.start_link(LiveOracle.connection_options(%{}))

    assert %{settings: [_ | _], file_settings: _} = LiveOracle.snapshot(oracle)
    assert LiveOracle.status(oracle) == :connected
  end

  defmodule SnapshotStub do
    use GenServer

    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, {:ok, snapshot}, snapshot}
  end

  test "snapshot unwraps the oracle's reply into the map the features expect" do
    snapshot = %{settings: [], file_settings: [], hba_rules: [], ident_mappings: []}
    {:ok, stub} = GenServer.start_link(SnapshotStub, snapshot)

    assert LiveOracle.snapshot(stub) == snapshot
  end

  test "parses a connection string without exposing credentials" do
    options =
      LiveOracle.connection_options(%{
        "connectionString" => "postgres://alice:secret@db.example.test:5433/app"
      })

    assert options[:hostname] == "db.example.test"
    assert options[:port] == 5433
    assert options[:database] == "app"
    assert options[:username] == "alice"
    assert options[:password] == "secret"
  end
end
