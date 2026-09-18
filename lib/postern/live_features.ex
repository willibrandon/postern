defmodule Postern.LiveFeatures do
  @moduledoc """
  Inlay hints and code actions backed by a live PostgreSQL snapshot, and
  the words for what a live command did.

  The code actions are about the setting under the cursor: one ALTER SYSTEM
  SET for it, with the statement in the title so it is read before it runs,
  and a reload. What the server answers goes back to the editor as a
  message, which every client displays.
  """

  alias GenLSP.Enumerations.CodeActionKind
  alias GenLSP.Enumerations.MessageType
  alias GenLSP.Structures.CodeAction
  alias GenLSP.Structures.Command
  alias GenLSP.Structures.InlayHint
  alias GenLSP.Structures.Position
  alias Postern.Parser.PostgresqlConf

  @apply "postern.applyAlterSystem"
  @reload "postern.reloadConfig"

  @doc "Returns effective-value and pending-restart inlay hints."
  @spec inlay_hints(String.t(), map() | {:error, atom()} | nil) :: [InlayHint.t()]
  def inlay_hints(_text, nil), do: []
  def inlay_hints(_text, {:error, _reason}), do: []

  def inlay_hints(text, %{settings: settings}) do
    {:ok, entries} = PostgresqlConf.parse(text)
    assignments = Map.new(Enum.filter(entries, &(&1.type == :assignment)), &{&1.name, &1})

    Enum.flat_map(settings, fn setting ->
      case Map.get(assignments, setting["name"]) do
        nil -> []
        entry -> effective_hint(entry, setting)
      end
    end)
  end

  @doc """
  The live code actions for a range of the document, when a snapshot is
  there: ALTER SYSTEM SET for the assignment the range starts on, and a
  reload.
  """
  @spec code_actions(String.t(), String.t(), map() | {:error, atom()} | nil, map() | nil) ::
          [CodeAction.t()]
  def code_actions(_uri, _text, nil, _range), do: []
  def code_actions(_uri, _text, {:error, _reason}, _range), do: []

  def code_actions(uri, text, %{settings: _settings}, range) do
    {:ok, entries} = PostgresqlConf.parse(text)
    line = if range, do: range.start.line + 1

    apply =
      case Enum.find(entries, &(&1.type == :assignment and &1.span.line == line)) do
        nil ->
          []

        %{name: name, value: value} ->
          [action(statement(name, value), @apply, [uri, name, value])]
      end

    apply ++ [action("Run pg_reload_conf()", @reload, [uri])]
  end

  @doc "The statement the action runs for a setting."
  @spec statement(String.t(), String.t()) :: String.t()
  def statement(name, value), do: "ALTER SYSTEM SET #{name} = #{literal(value)}"

  @doc "The commands the live code actions carry."
  def commands, do: [@apply, @reload]

  @doc """
  The message the editor shows for what a command did: the statement and
  what applies it, in the words of the setting's context, or the server's
  own error.
  """
  @spec report(String.t(), list(), term(), map() | {:error, atom()} | nil) ::
          {MessageType.t(), String.t()} | nil
  def report(@apply, [_uri, name, value], result, snapshot) do
    case result do
      {:ok, _rows} ->
        {MessageType.info(),
         "#{statement(name, value)} is in postgresql.auto.conf; #{applies(name, snapshot)}."}

      {:error, error} ->
        {MessageType.error(), failure(error)}
    end
  end

  def report(@reload, _arguments, result, _snapshot) do
    case result do
      {:ok, [[true]]} ->
        {MessageType.info(),
         "pg_reload_conf() told the server to read its configuration files again."}

      {:ok, [["t"]]} ->
        {MessageType.info(),
         "pg_reload_conf() told the server to read its configuration files again."}

      {:ok, _other} ->
        {MessageType.error(), "pg_reload_conf() could not signal the server."}

      {:error, error} ->
        {MessageType.error(), failure(error)}
    end
  end

  def report(_command, _arguments, _result, _snapshot), do: nil

  # What brings the new value into effect, from the setting's context in the
  # snapshot: a restart, a reload, or a reload for sessions to come.
  defp applies(name, %{settings: settings}) do
    context = Enum.find_value(settings, fn row -> if row["name"] == name, do: row["context"] end)

    case context do
      "postmaster" -> "a restart applies it"
      "sighup" -> "a reload applies it"
      nil -> "a reload applies it"
      _session -> "a reload applies it to new sessions"
    end
  end

  defp applies(_name, _snapshot), do: "a reload applies it"

  defp failure(:unreachable), do: "No server is reachable, so nothing ran."
  defp failure(:unknown_command), do: "The server does not know that command."

  defp failure(%{postgres: %{message: message} = fields}) do
    [message, fields[:detail], fields[:hint]] |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp failure(other), do: "The server answered: #{inspect(other)}"

  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp effective_hint(entry, setting) do
    effective = setting["setting"]
    pending_restart = setting["pending_restart"] in [true, "t", "true", "on", 1, "1"]

    cond do
      pending_restart -> [hint(entry, " pending restart")]
      is_binary(effective) and effective != entry.value -> [hint(entry, " = #{effective}")]
      true -> []
    end
  end

  defp hint(entry, label) do
    %InlayHint{
      position: %Position{
        line: entry.value_span.line - 1,
        character: entry.value_span.end_col - 1
      },
      label: label,
      padding_left: true
    }
  end

  defp action(title, command, arguments) do
    %CodeAction{
      title: title,
      kind: CodeActionKind.quick_fix(),
      command: %Command{title: title, command: command, arguments: arguments}
    }
  end
end
