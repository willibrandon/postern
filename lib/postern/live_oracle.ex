defmodule Postern.LiveOracle do
  @moduledoc """
  The PostgreSQL connection the live features read through.

  Postgrex connects in the background and keeps retrying on its own, and a
  query on a pool whose connection is down waits seconds in the queue before
  it is dropped, which would stall every request the language server makes.
  So the oracle does not ask the pool whether the server is there: it listens
  for the connection's own notifications, and until one arrives, or after the
  connection drops, a snapshot is an availability error at once. The one
  exception is the first check after the oracle starts, which waits a moment
  for the connection to come up, so a server that answers quickly is live
  from the start. Nothing here raises into the language server process.
  """

  use GenServer

  @backoff_start 1_000
  @backoff_max 30_000

  # How long the first check after the oracle starts waits for the connection.
  @connect_grace 2_000

  @settings_query """
  select name, setting, unit, context, source, sourcefile, sourceline,
         pending_restart, vartype, enumvals, min_val, max_val, boot_val, reset_val
    from pg_settings
   order by name
  """

  @file_settings_query """
  select name, setting, applied, error, sourcefile, sourceline
    from pg_file_settings
   order by sourceline
  """

  @hba_query """
  select line_number, file_name, error, type, database, user_name, address,
         netmask, auth_method, options
    from pg_hba_file_rules
   order by line_number
  """

  @ident_query """
  select line_number, file_name, map_name, sys_name, pg_username, error
    from pg_ident_file_mappings
   order by line_number
  """

  @database_query "select datname from pg_database where datallowconn order by datname"
  @role_query "select rolname from pg_roles order by rolname"

  @doc "Starts an oracle from PostgreSQL connection options, or disables it for `nil`."
  @spec start_link(keyword() | nil) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options)
  end

  @doc "Returns options parsed from initialization options or environment variables."
  @spec connection_options(map() | keyword()) :: keyword() | nil
  def connection_options(options) do
    connection_string =
      option(options, :connection_string) || option(options, :connectionString)

    cond do
      is_binary(connection_string) -> parse_connection_string(connection_string)
      env_configured?() -> environment_options()
      true -> nil
    end
  end

  @doc "Returns the current oracle status."
  @spec status(pid()) :: :disabled | :connecting | :connected | :unreachable
  def status(oracle), do: GenServer.call(oracle, :status)

  @doc "Fetches one consistent live snapshot as a map, or an availability error."
  @spec snapshot(pid()) :: map() | {:error, :disabled | :unreachable}
  def snapshot(oracle) do
    case GenServer.call(oracle, :snapshot, 20_000) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Executes one of the live code-action commands."
  @spec execute(pid(), String.t(), list()) :: {:ok, term()} | {:error, atom() | term()}
  def execute(oracle, command, arguments \\ []),
    do: GenServer.call(oracle, {:execute, command, arguments}, 20_000)

  @impl true
  def init(nil), do: {:ok, state(nil, :disabled)}

  def init(options) do
    send(self(), :connect)
    {:ok, state(options, :connecting)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  # Postgrex is still on its first attempt: give it until the deadline.
  def handle_call(:snapshot, _from, %{status: :connecting, conn: conn} = state)
      when is_pid(conn) do
    remaining = max(state.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:connected, _pid} -> {:reply, query_snapshot(conn), %{state | status: :connected}}
    after
      remaining -> {:reply, {:error, :unreachable}, %{state | status: :unreachable}}
    end
  end

  def handle_call(:snapshot, _from, %{status: status} = state)
      when status in [:disabled, :connecting, :unreachable] do
    {:reply, {:error, (status == :disabled && :disabled) || :unreachable}, state}
  end

  def handle_call(:snapshot, _from, %{conn: conn} = state) do
    {:reply, query_snapshot(conn), state}
  end

  def handle_call({:execute, _command, _arguments}, _from, %{status: status} = state)
      when status != :connected do
    {:reply, {:error, :unreachable}, state}
  end

  def handle_call({:execute, "postern.reloadConfig", _arguments}, _from, %{conn: conn} = state) do
    {:reply, query_scalar(conn, "select pg_reload_conf()"), state}
  end

  # One statement for one setting; the server's own refusal, with its
  # detail and hint, is the answer when it refuses.
  def handle_call(
        {:execute, "postern.applyAlterSystem", [_uri, name, value]},
        _from,
        %{conn: conn} = state
      ) do
    {:reply, query_scalar(conn, Postern.LiveFeatures.statement(name, value)), state}
  end

  def handle_call({:execute, _command, _arguments}, _from, state) do
    {:reply, {:error, :unknown_command}, state}
  end

  @impl true
  def handle_info(:connect, %{options: options} = state) do
    case Application.ensure_all_started(:postgrex) do
      {:ok, _started} -> connect(state, options)
      {:error, _reason} -> schedule_retry(state)
    end
  end

  # Postgrex reports each connection it makes and loses, and reconnects on
  # its own after a loss.
  def handle_info({:connected, _pid}, state),
    do: {:noreply, %{state | status: :connected, backoff: @backoff_start}}

  def handle_info({:disconnected, _pid}, state), do: {:noreply, %{state | status: :unreachable}}

  # The pool itself went, which Postgrex does not recover from: start another.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    schedule_retry(%{state | conn: nil, monitor: nil, status: :unreachable})
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when is_pid(conn) do
    GenServer.stop(conn)
  catch
    :exit, _reason -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # The oracle is started from the request that configures it, which GenLSP
  # runs in a task of its own, so it must not trap exits: the task's normal
  # end would be the oracle's end too. The pool is unlinked and watched
  # instead, and stopped with the oracle.
  defp connect(state, options) do
    case Postgrex.start_link(options ++ [connection_listeners: [self()]]) do
      {:ok, conn} ->
        Process.unlink(conn)
        monitor = Process.monitor(conn)
        deadline = System.monotonic_time(:millisecond) + @connect_grace

        {:noreply,
         %{state | conn: conn, monitor: monitor, status: :connecting, deadline: deadline}}

      {:error, _reason} ->
        schedule_retry(state)
    end
  end

  defp state(options, status) do
    %{
      options: options,
      conn: nil,
      monitor: nil,
      status: status,
      deadline: nil,
      backoff: @backoff_start
    }
  end

  defp schedule_retry(%{backoff: backoff} = state) do
    Process.send_after(self(), :connect, backoff)
    {:noreply, %{state | status: :unreachable, backoff: min(backoff * 2, @backoff_max)}}
  end

  defp query_snapshot(conn) do
    with {:ok, settings} <- query_rows(conn, @settings_query),
         {:ok, file_settings} <- query_rows(conn, @file_settings_query) do
      {:ok,
       %{
         settings: settings,
         file_settings: file_settings,
         hba_rules: optional_query(conn, @hba_query),
         ident_mappings: optional_query(conn, @ident_query),
         databases: optional_query(conn, @database_query),
         roles: optional_query(conn, @role_query)
       }}
    else
      {:error, _reason} -> {:error, :unreachable}
    end
  end

  defp optional_query(conn, query) do
    case query_rows(conn, query) do
      {:ok, rows} -> rows
      {:error, _reason} -> []
    end
  end

  defp query_rows(conn, query) do
    case Postgrex.query(conn, query, [], query_type: :text) do
      {:ok, result} ->
        {:ok, Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _error -> {:error, :unreachable}
  catch
    :exit, _reason -> {:error, :unreachable}
  end

  defp query_scalar(conn, query) do
    case Postgrex.query(conn, query, [], query_type: :text) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :unreachable}
  catch
    :exit, _reason -> {:error, :unreachable}
  end

  defp parse_connection_string(string) do
    uri = URI.parse(string)
    {username, password} = parse_userinfo(uri.userinfo)

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      database: String.trim_leading(uri.path || "/postgres", "/"),
      username: username || System.get_env("PGUSER", "postgres"),
      password: password || System.get_env("PGPASSWORD", "")
    ]
  end

  defp parse_userinfo(nil), do: {nil, nil}

  defp parse_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] -> {URI.decode(username), URI.decode(password)}
      [username] -> {URI.decode(username), nil}
    end
  end

  defp environment_options do
    [
      hostname: System.get_env("PGHOST", "localhost"),
      port: String.to_integer(System.get_env("PGPORT", "5432")),
      database: System.get_env("PGDATABASE", "postgres"),
      username: System.get_env("PGUSER", "postgres"),
      password: System.get_env("PGPASSWORD", "")
    ]
  end

  defp env_configured? do
    Enum.any?(~w(PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD), &System.get_env/1)
  end

  defp option(options, key) when is_map(options), do: options[key] || options[Atom.to_string(key)]
  defp option(options, key) when is_list(options), do: Keyword.get(options, key)
  defp option(_options, _key), do: nil
end
