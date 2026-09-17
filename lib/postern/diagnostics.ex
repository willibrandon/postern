defmodule Postern.Diagnostics do
  @moduledoc """
  Produces LSP diagnostics from file contents.

  Parse errors are handled for all three file formats. PostgreSQL configuration
  assignments additionally use generated catalogs for offline validation.
  """

  alias GenLSP.Structures.Diagnostic
  alias Postern.FileKind

  @doc """
  Returns diagnostics for the given `uri` and `text`.

  The file kind is detected from the URI via `Postern.FileKind`.
  """
  @spec for_document(String.t(), String.t(), map() | keyword()) :: [Diagnostic.t()]
  def for_document(uri, text, initialization_options \\ %{})
      when is_binary(uri) and is_binary(text) do
    kind = FileKind.detect(uri)

    case kind do
      :postgresql_conf ->
        offline = Postern.PostgresqlConfDiagnostics.diagnostics(text, initialization_options)

        offline ++
          Postern.LiveDiagnostics.for_document(
            uri,
            option(initialization_options, :live_snapshot),
            option(initialization_options, :live_configured) || false,
            :postgresql_conf
          )

      :pg_hba_conf ->
        offline =
          Postern.PgHbaDiagnostics.diagnostics(
            text,
            option(initialization_options, :pg_ident_text),
            %{
              report_trust: option(initialization_options, :reportTrust) != false,
              version: target_version(text, initialization_options)
            }
          )

        offline ++
          Postern.LiveDiagnostics.for_document(
            uri,
            option(initialization_options, :live_snapshot),
            option(initialization_options, :live_configured) || false,
            :pg_hba_conf
          )

      :pg_ident_conf ->
        offline =
          Postern.PgIdentDiagnostics.diagnostics(
            text,
            option(initialization_options, :pg_hba_text),
            %{version: target_version(text, initialization_options)}
          )

        offline ++
          Postern.LiveDiagnostics.for_document(
            uri,
            option(initialization_options, :live_snapshot),
            option(initialization_options, :live_configured) || false,
            :pg_ident_conf
          )

      :unknown ->
        []
    end
  end

  # The version comes from the `pg` option or a `# postern: pg=N` comment in
  # any of the files, the same way it does for postgresql.conf.
  defp target_version(text, options),
    do: Postern.PostgresqlConfDiagnostics.target_version(text, options)

  defp option(options, key) when is_map(options), do: options[key] || options[Atom.to_string(key)]
  defp option(options, key) when is_list(options), do: Keyword.get(options, key)
  defp option(_options, _key), do: nil
end
