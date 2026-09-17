defmodule Postern.PgIdentDiagnostics do
  @moduledoc """
  Offline diagnostics for `pg_ident.conf`, including unused map detection.
  """

  alias GenLSP.Structures.Diagnostic
  alias GenLSP.Structures.Position
  alias GenLSP.Structures.Range
  alias Postern.Parser.PgHba
  alias Postern.Parser.PgIdent

  @warning 2
  @error 1

  @doc """
  Produces parser diagnostics and warnings for maps never referenced by HBA.

  `hba_text` is the `pg_hba.conf` that goes with the file, when there is one
  to look at; without it no map is called unused. `options` may carry the
  target PostgreSQL major version as `:version`.
  """
  @spec diagnostics(String.t(), String.t() | nil, map()) :: [Diagnostic.t()]
  def diagnostics(text, hba_text \\ nil, options \\ %{}) when is_binary(text) do
    {:ok, entries} = PgIdent.parse(text)
    version = Map.get(options, :version) || target_version(text, options)

    parser_diagnostics =
      Enum.flat_map(entries, fn
        %{type: :error, message: message, span: span} -> [diagnostic(span, @error, message)]
        _ -> []
      end)

    parser_diagnostics ++ unused_diagnostics(entries, referenced_maps(hba_text, version))
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

  defp referenced_maps(nil, _version), do: nil

  defp referenced_maps(text, version) do
    {:ok, entries} = PgHba.parse(text)
    map_methods = Postern.PgHbaOptions.map_methods(version)

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
