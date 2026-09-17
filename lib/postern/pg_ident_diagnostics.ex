defmodule Postern.PgIdentDiagnostics do
  @moduledoc """
  Offline diagnostics for `pg_ident.conf`, including unused map detection.
  """

  alias GenLSP.Structures.Diagnostic
  alias GenLSP.Structures.Position
  alias GenLSP.Structures.Range
  alias Postern.Parser.PgHba
  alias Postern.Parser.PgIdent
  alias Postern.PgHbaOptions

  @warning 2
  @error 1

  @doc """
  Produces parser diagnostics and warnings for maps never referenced by HBA.

  `hba_text` is the `pg_hba.conf` that goes with the file, when there is one
  to look at; without it no map is called unused. `options` may carry the
  target PostgreSQL major version as `:version`, and, from
  `Postern.ConfigTree`, the file's `:tree` with its `:path` and the
  `:hba_tree` whose rules name the maps.
  """
  @spec diagnostics(String.t(), String.t() | nil, map()) :: [Diagnostic.t()]
  def diagnostics(text, hba_text \\ nil, options \\ %{}) when is_binary(text) do
    version = Map.get(options, :version) || target_version(text, options)
    continuations = [continuations: PgHbaOptions.continuations?(version)]
    {:ok, entries} = PgIdent.parse(text, continuations)
    tree = Map.get(options, :tree)
    path = Map.get(options, :path)

    parser_diagnostics =
      Enum.flat_map(entries, fn
        %{type: :error, message: message, span: span} -> [diagnostic(span, @error, message)]
        _ -> []
      end)

    referenced = referenced_maps(hba_text, Map.get(options, :hba_tree), version, continuations)

    parser_diagnostics ++
      version_diagnostics(entries, version) ++
      unused_diagnostics(entries, referenced) ++ include_diagnostics(tree, path)
  end

  # The three directives and a regular expression as the PostgreSQL user name
  # arrived in 16. An older server reads an include line as a mapping short
  # of its third field, and takes a name that starts with a slash for a name.
  defp version_diagnostics(entries, version) do
    directives =
      if PgHbaOptions.directives?(version),
        do: [],
        else:
          for(
            %{type: :include, span: span} <- entries,
            do: diagnostic(span, @error, "missing entry at end of line")
          )

    regexes =
      if PgHbaOptions.regex?(version),
        do: [],
        else:
          for(
            %{type: :mapping, pg_user: "/" <> _ = name, pg_span: span} <- entries,
            do:
              diagnostic(
                span,
                @warning,
                ~s("#{name}" is a name to PostgreSQL #{version}; a regular expression here needs 16)
              )
          )

    directives ++ regexes
  end

  defp include_diagnostics(nil, _path), do: []

  defp include_diagnostics(tree, path) do
    for %{path: ^path} = problem <- tree.problems,
        do: diagnostic(problem.span, problem.severity, problem.message)
  end

  defp unused_diagnostics(_entries, nil), do: []

  defp unused_diagnostics(entries, referenced) do
    entries
    |> Enum.filter(&(&1.type == :mapping))
    |> Enum.reject(&MapSet.member?(referenced, &1.map))
    |> Enum.map(
      &diagnostic(&1.map_span, @warning, "ident map #{inspect(&1.map)} is never referenced")
    )
  end

  defp target_version(text, options),
    do: Postern.PostgresqlConfDiagnostics.target_version(text, options)

  # The maps the rules name: across the pg_hba.conf tree, or in the text the
  # caller supplied, or nothing to check against.
  defp referenced_maps(_text, %{entries: entries}, version, _continuations) do
    map_methods = PgHbaOptions.map_methods(version)

    MapSet.new(
      for %{entry: %{type: :rule, auth_method: method, options: options}} <- entries,
          method in map_methods,
          is_binary(options["map"]),
          do: options["map"]
    )
  end

  defp referenced_maps(nil, nil, _version, _continuations), do: nil

  defp referenced_maps(text, nil, version, continuations) do
    {:ok, entries} = PgHba.parse(text, continuations)
    map_methods = PgHbaOptions.map_methods(version)

    entries
    |> Enum.filter(&(&1.type == :rule and &1.auth_method in map_methods))
    |> Enum.map(&Map.get(&1.options, "map"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp diagnostic(span, severity, message) do
    %Diagnostic{
      range: %Range{
        start: %Position{line: span.line - 1, character: span.col - 1},
        end: %Position{line: span.end_line - 1, character: span.end_col - 1}
      },
      severity: severity,
      source: "postern",
      message: message
    }
  end
end
