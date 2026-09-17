defmodule Postern.StdioTest do
  use ExUnit.Case, async: false

  # The server under test is a second VM on the build the suite runs on, so a
  # fresh clone needs nothing but `mix test`. The transport is off in the test
  # environment, since this VM keeps its own stdin, and the child turns it on.
  @boot "Application.put_env(:postern, :stdio, true, persistent: true); " <>
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

  defp start_server do
    Port.open(
      {:spawn_executable, System.find_executable("mix")},
      [
        :binary,
        :exit_status,
        {:args, ["run", "--no-compile", "--no-start", "-e", @boot]},
        {:env, [{~c"MIX_ENV", ~c"test"}]}
      ]
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
