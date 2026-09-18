defmodule Postern.StdioTest do
  use ExUnit.Case, async: false

  # The server under test is a second VM on the build the suite runs on, so a
  # fresh clone needs nothing but `mix test`. The transport is off in the test
  # environment, since this VM keeps its own stdin, and the child turns it on.
  # Mix starts the logger before it loads the configuration, on stdout at
  # debug, so the child starts it again the way a release does, on stderr at
  # warning, and stdout carries the protocol alone.
  @boot "Application.stop(:logger); {:ok, _} = Application.ensure_all_started(:logger); " <>
          "Application.put_env(:postern, :stdio, true, persistent: true); " <>
          "{:ok, _} = Application.ensure_all_started(:postern); Process.sleep(:infinity)"

  test "speaks initialize and shutdown over stdio, then halts on exit" do
    port = start_server()

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
    end)

    Port.command(
      port,
      packet(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })
    )

    {response, buffer} = read_response(port, "")
    assert %{"id" => 1, "result" => %{"capabilities" => capabilities}} = response
    assert capabilities["textDocumentSync"]["openClose"]

    Port.command(port, packet(%{"jsonrpc" => "2.0", "id" => 2, "method" => "shutdown"}))
    {response, _buffer} = read_response(port, buffer)
    assert %{"id" => 2, "result" => nil} = response

    Port.command(port, packet(%{"jsonrpc" => "2.0", "method" => "exit"}))
    assert_receive {^port, {:exit_status, 0}}, 10_000
  end

  test "halts as soon as the editor closes the pipe" do
    port = start_server()
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    Port.command(
      port,
      packet(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })
    )

    {%{"id" => 1}, _buffer} = read_response(port, "")

    # Closing the port closes the server's stdin without sending exit.
    Port.close(port)

    assert gone_within?(os_pid, 5_000),
           "server kept running after its stdin closed (pid #{os_pid})"
  end

  # An editor that dies mid-reply closes its end of the server's stdout first.
  # The failed write stops OTP's tty driver, and with it the process that
  # answers reads, so no end of file ever reaches the reader waiting on stdin.
  # The child's stdin is a named pipe this VM writes into, so it stays open
  # while the port that carries its stdout closes.
  @tag :unix
  test "halts when a reply cannot be written, though stdin stays open" do
    fifo = Path.join(System.tmp_dir!(), "postern-stdin-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("mkfifo", [fifo])
    on_exit(fn -> File.rm(fifo) end)

    port = start_server(stdin: fifo)
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      if alive?(os_pid), do: System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    end)

    {:ok, stdin} = File.open(fifo, [:write, :binary])

    IO.binwrite(
      stdin,
      packet(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })
    )

    {%{"id" => 1}, _buffer} = read_response(port, "")

    Port.close(port)
    IO.binwrite(stdin, packet(%{"jsonrpc" => "2.0", "id" => 2, "method" => "shutdown"}))

    assert gone_within?(os_pid, 5_000),
           "server kept running after its stdout closed (pid #{os_pid})"
  end

  defp start_server(opts \\ []) do
    mix = System.find_executable("mix")
    args = ["run", "--no-compile", "--no-start", "-e", @boot]

    {executable, args} =
      case opts[:stdin] do
        nil ->
          {mix, args}

        fifo ->
          {"/bin/sh", ["-c", ~s(fifo="$1"; shift; exec "$@" < "$fifo"), "sh", fifo, mix | args]}
      end

    Port.open(
      {:spawn_executable, executable},
      [:binary, :exit_status, {:args, args}, {:env, [{~c"MIX_ENV", ~c"test"}]}]
    )
  end

  defp gone_within?(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      not alive?(os_pid) or (System.monotonic_time(:millisecond) > deadline and :timeout)
    end)
    |> Stream.each(fn done -> unless done, do: Process.sleep(100) end)
    |> Enum.find(&(&1 != false)) == true
  end

  # Whether an operating system process is still there, asked the way each
  # system answers it.
  defp alive?(os_pid) do
    case :os.type() do
      {:win32, _} ->
        filter = "PID eq #{os_pid}"
        {output, 0} = System.cmd("tasklist", ["/FI", filter, "/NH", "/FO", "CSV"])
        String.contains?(output, ~s("#{os_pid}"))

      _unix ->
        {_, status} =
          System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

        status == 0
    end
  end

  defp packet(payload) do
    body = Jason.encode!(payload)
    ["Content-Length: ", Integer.to_string(byte_size(body)), "\r\n\r\n", body]
  end

  # Skips server notifications such as window/logMessage until a response arrives.
  defp read_response(port, buffer) do
    case read_packet(port, buffer) do
      {%{"id" => _} = response, rest} -> {response, rest}
      {_notification, rest} -> read_response(port, rest)
    end
  end

  defp read_packet(port, buffer) do
    case parse_packet(buffer) do
      {:ok, packet, rest} ->
        {Jason.decode!(packet), rest}

      :more ->
        receive do
          {^port, {:data, data}} -> read_packet(port, buffer <> data)
          {^port, {:exit_status, status}} -> flunk("stdio server exited with status #{status}")
        after
          10_000 -> flunk("timed out waiting for stdio response")
        end
    end
  end

  defp parse_packet(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        :more

      {header_end, 4} ->
        header = binary_part(buffer, 0, header_end)
        body_start = header_end + 4
        [_, length] = Regex.run(~r/Content-Length:\s*(\d+)/i, header)
        length = String.to_integer(length)

        if byte_size(buffer) >= body_start + length do
          body = binary_part(buffer, body_start, length)
          rest = binary_part(buffer, body_start + length, byte_size(buffer) - body_start - length)
          {:ok, body, rest}
        else
          :more
        end
    end
  end
end
