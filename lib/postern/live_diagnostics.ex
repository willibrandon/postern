defmodule Postern.LiveDiagnostics do
  @moduledoc """
  Maps live PostgreSQL configuration results to source diagnostics.

  The views describe the files the server read from its disk, line by line:
  the setting and its value, the rule's type and method, the mapping's map,
  or the error the line got. A document is taken for one of those files
  when every row of the file describes the document's line, which needs
  neither the same name nor the same path, so a file the server reads
  through a mount is found, and a document with unsaved edits above a line
  is not, and keeps the offline diagnostics alone until it is saved.
  """

  alias GenLSP.Structures.Diagnostic
  alias GenLSP.Structures.Position
  alias GenLSP.Structures.Range
  alias Postern.Parser.PgHba
  alias Postern.Parser.PgIdent
  alias Postern.Parser.PostgresqlConf

  @doc """
  Produces diagnostics from a live snapshot for the open document.
  """
  @spec for_document(String.t(), String.t(), map() | {:error, atom()} | nil, boolean(), atom()) ::
          [Diagnostic.t()]
  def for_document(_uri, _text, nil, _configured, _kind), do: []
  def for_document(_uri, _text, {:error, :disabled}, _configured, _kind), do: []

  def for_document(_uri, _text, {:error, _reason}, true, _kind) do
    [diagnostic(0, "PostgreSQL server is unreachable; using offline diagnostics", 3)]
  end

  def for_document(_uri, _text, {:error, _reason}, false, _kind), do: []

  def for_document(
        uri,
        text,
        %{file_settings: file_settings, settings: settings},
        _configured,
        :postgresql_conf
      ) do
    case matched_file(uri, text, file_settings, "sourcefile", &settings_row?/2) do
      nil ->
        []

      file ->
        rows = Enum.filter(file_settings, &(&1["sourcefile"] == file))

        errors =
          for row <- rows, error?(row), do: diagnostic(row["sourceline"] || 1, row["error"], 1)

        restarts =
          for row <- settings, truthy?(row["pending_restart"]), row["sourcefile"] == file do
            diagnostic(
              row["sourceline"] || 1,
              "setting #{inspect(row["name"])} is pending restart",
              3
            )
          end

        errors ++ restarts ++ override_diagnostics(file_settings, file)
    end
  end

  def for_document(uri, text, %{hba_rules: rows}, _configured, :pg_hba_conf),
    do: file_errors(uri, text, rows, &rule_row?/2)

  def for_document(uri, text, %{ident_mappings: rows}, _configured, :pg_ident_conf),
    do: file_errors(uri, text, rows, &mapping_row?/2)

  def for_document(_uri, _text, _snapshot, _configured, _kind), do: []

  defp file_errors(uri, text, rows, describes?) do
    case matched_file(uri, text, rows, "file_name", describes?) do
      nil ->
        []

      file ->
        for row <- rows,
            row["file_name"] == file,
            error?(row),
            do: diagnostic(row["line_number"] || 1, row["error"], 1)
    end
  end

  # The file whose every row describes the document's line, preferring one
  # named like the document when more than one does; a file with no rows
  # says nothing and cannot be matched.
  defp matched_file(uri, text, rows, file_key, describes?) do
    lines = lines_of(uri, text)
    basename = Path.basename(Postern.FileKind.uri_to_path(uri))

    rows
    |> Enum.reject(&is_nil(&1[file_key]))
    |> Enum.group_by(& &1[file_key])
    |> Enum.filter(fn {_file, file_rows} -> Enum.all?(file_rows, &describes?.(&1, lines)) end)
    |> Enum.map(fn {file, _rows} -> file end)
    |> Enum.sort_by(&{Path.basename(&1) != basename, &1})
    |> List.first()
  end

  # The document's entries by line, parsed as the kind the rows are about.
  defp lines_of(uri, text) do
    {:ok, entries} =
      case Postern.FileKind.detect(uri) do
        :pg_hba_conf -> PgHba.parse(text)
        :pg_ident_conf -> PgIdent.parse(text)
        _kind -> PostgresqlConf.parse(text)
      end

    Map.new(entries, &{&1.span.line, &1})
  end

  # A row with a name is the document's assignment of that name and value on
  # that line; one without, which is what a syntax error leaves, is the
  # document's error there.
  defp settings_row?(row, lines) do
    row_name = row["name"]

    case Map.get(lines, number(row["sourceline"])) do
      %{type: :assignment, name: name, value: value} when is_binary(row_name) ->
        String.downcase(name) == String.downcase(row_name) and value == row["setting"]

      %{type: :error} ->
        row_name == nil

      _other ->
        false
    end
  end

  defp rule_row?(row, lines) do
    row_type = row["type"]

    case Map.get(lines, number(row["line_number"])) do
      %{type: :rule, connection_type: type, auth_method: method} when is_binary(row_type) ->
        type == row_type and method == row["auth_method"]

      %{type: kind} when kind in [:rule, :error, :include] ->
        row_type == nil

      _other ->
        false
    end
  end

  defp mapping_row?(row, lines) do
    row_map = row["map_name"]

    case Map.get(lines, number(row["line_number"])) do
      %{type: :mapping, map: map} when is_binary(row_map) -> map == row_map
      %{type: kind} when kind in [:mapping, :error, :include] -> row_map == nil
      _other -> false
    end
  end

  # A row that is not applied and carries no error lost to a later entry for
  # the same name, as the view's documentation puts it, and the applied row
  # for that name is the one that won. A syntax error anywhere leaves every
  # row unapplied with no winner, and then there is nothing to say.
  defp override_diagnostics(file_settings, file) do
    for row <- file_settings,
        not truthy?(row["applied"]),
        not error?(row),
        row["sourcefile"] == file,
        winner = Enum.find(file_settings, &(&1["name"] == row["name"] and truthy?(&1["applied"]))),
        winner != nil do
      %{diagnostic(row["sourceline"] || 1, override_message(row, winner), 4) | code: "override"}
    end
  end

  defp override_message(row, winner) do
    file = to_string(winner["sourcefile"])
    line = winner["sourceline"]

    if file == to_string(row["sourcefile"]) do
      "overridden by a later entry on line #{line}"
    else
      relative = Path.relative_to(file, Path.dirname(to_string(row["sourcefile"])))
      "overridden by a later entry in #{relative} on line #{line}"
    end
  end

  defp error?(row), do: is_binary(row["error"]) and row["error"] != ""

  # The oracle runs its queries in the text protocol, so a line number
  # arrives as "133".
  defp number(value) when is_integer(value), do: value
  defp number(value) when is_binary(value), do: String.to_integer(value)
  defp number(nil), do: 0

  defp truthy?(value) when value in [true, "t", "true", "on", 1, "1"], do: true
  defp truthy?(_value), do: false

  defp diagnostic(line, message, severity) do
    line = max(number(line) - 1, 0)

    %Diagnostic{
      range: %Range{
        start: %Position{line: line, character: 0},
        end: %Position{line: line, character: 0}
      },
      severity: severity,
      source: "postern",
      message: message
    }
  end
end
