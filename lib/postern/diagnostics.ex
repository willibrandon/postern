defmodule Postern.Diagnostics do
  @moduledoc """
  Produces LSP diagnostics from file contents.

  Parse errors are handled for all three file formats. PostgreSQL configuration
  assignments additionally use generated catalogs for offline validation.

  A `pg_hba.conf` check needs the `pg_ident.conf` next to it and the other way
  round. The caller can pass their text as `:pg_ident_text` and `:pg_hba_text`,
  or a `:reader` from `Postern.Files` that fetches the file beside the document.
  """

  alias GenLSP.Structures.Diagnostic
  alias Postern.FileKind
  alias Postern.LiveDiagnostics
  alias Postern.PgHbaDiagnostics
  alias Postern.PgIdentDiagnostics
  alias Postern.PostgresqlConfDiagnostics

  @doc """
  Returns diagnostics for the given `uri` and `text`.

  The file kind is detected from the URI via `Postern.FileKind`.
  """
  @spec for_document(String.t(), String.t(), map() | keyword()) :: [Diagnostic.t()]
  def for_document(uri, text, options \\ %{}) when is_binary(uri) and is_binary(text) do
    case FileKind.detect(uri) do
      :unknown -> []
      kind -> offline(kind, uri, text, options) ++ live(kind, uri, options)
    end
  end

  defp offline(:postgresql_conf, _uri, text, options),
    do: PostgresqlConfDiagnostics.diagnostics(text, options)

  defp offline(:pg_hba_conf, uri, text, options) do
    PgHbaDiagnostics.diagnostics(
      text,
      option(options, :pg_ident_text) || sibling_text(uri, "pg_ident.conf", options),
      %{
        report_trust: option(options, :reportTrust) != false,
        version: target_version(text, options)
      }
    )
  end

  defp offline(:pg_ident_conf, uri, text, options) do
    PgIdentDiagnostics.diagnostics(
      text,
      option(options, :pg_hba_text) || sibling_text(uri, "pg_hba.conf", options),
      %{version: target_version(text, options)}
    )
  end

  defp live(kind, uri, options) do
    LiveDiagnostics.for_document(
      uri,
      option(options, :live_snapshot),
      option(options, :live_configured) || false,
      kind
    )
  end

  # The file next to the document, through the reader. Without one there is
  # nothing to look at, and the checks that need the file stay quiet.
  defp sibling_text(uri, name, options) do
    with reader when is_function(reader, 1) <- option(options, :reader),
         path = uri |> FileKind.uri_to_path() |> Path.dirname() |> Path.join(name),
         {:ok, text} <- reader.(path) do
      text
    else
      _ -> nil
    end
  end

  # The version comes from the `pg` option or a `# postern: pg=N` comment in
  # any of the files, the same way it does for postgresql.conf.
  defp target_version(text, options), do: PostgresqlConfDiagnostics.target_version(text, options)

  defp option(options, key) when is_map(options), do: options[key] || options[Atom.to_string(key)]
  defp option(options, key) when is_list(options), do: Keyword.get(options, key)
  defp option(_options, _key), do: nil
end
