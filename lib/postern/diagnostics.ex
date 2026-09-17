defmodule Postern.Diagnostics do
  @moduledoc """
  Produces LSP diagnostics from file contents.

  Parse errors are handled for all three file formats. PostgreSQL configuration
  assignments additionally use generated catalogs for offline validation.

  With a `:reader` from `Postern.Files`, a check sees what the server sees: the
  whole tree of files the document belongs to, resolved by
  `Postern.ConfigTree`, and for `pg_hba.conf` the `pg_ident.conf` tree next to
  the root, and the other way round. The caller can instead pass that other
  file's text as `:pg_ident_text` or `:pg_hba_text`. Without either, only the
  document itself is weighed.
  """

  alias GenLSP.Structures.Diagnostic
  alias Postern.ConfigTree
  alias Postern.FileKind
  alias Postern.Files
  alias Postern.LiveDiagnostics
  alias Postern.PgHbaDiagnostics
  alias Postern.PgIdentDiagnostics
  alias Postern.PostgresqlConfDiagnostics

  @doc """
  Returns diagnostics for the given `uri` and `text`.

  The file kind is `:kind` in the options when the caller knows it, and is
  otherwise detected from the URI via `Postern.FileKind`.
  """
  @spec for_document(String.t(), String.t(), map() | keyword()) :: [Diagnostic.t()]
  def for_document(uri, text, options \\ %{}) when is_binary(uri) and is_binary(text) do
    case option(options, :kind) || FileKind.detect(uri) do
      :unknown ->
        []

      kind ->
        path = FileKind.canonical(FileKind.uri_to_path(uri))
        {tree, other} = trees(kind, path, text, options)

        one_override_per_line(
          offline(kind, path, text, options, tree, other) ++ live(kind, uri, options)
        )
    end
  end

  defp offline(:postgresql_conf, path, text, options, tree, _other) do
    PostgresqlConfDiagnostics.diagnostics(text, with_tree(options, tree, path))
  end

  defp offline(:pg_hba_conf, path, text, options, tree, ident_tree) do
    PgHbaDiagnostics.diagnostics(text, option(options, :pg_ident_text), %{
      report_trust: option(options, :reportTrust) != false,
      version: target_version(text, options),
      tree: tree,
      path: path,
      ident_tree: ident_tree
    })
  end

  defp offline(:pg_ident_conf, path, text, options, tree, hba_tree) do
    PgIdentDiagnostics.diagnostics(text, option(options, :pg_hba_text), %{
      version: target_version(text, options),
      tree: tree,
      path: path,
      hba_tree: hba_tree
    })
  end

  defp live(kind, uri, options) do
    LiveDiagnostics.for_document(
      uri,
      option(options, :live_snapshot),
      option(options, :live_configured) || false,
      kind
    )
  end

  # The document's tree, and for the two authentication files the other one's
  # tree beside the root. Without a reader there is nothing to look at.
  defp trees(kind, path, text, options) do
    case option(options, :reader) do
      %Files{} = files ->
        opts = [workspace: option(options, :workspace), version: target_version(text, options)]
        tree = ConfigTree.for_document(kind, path, files, opts)
        {tree, other_tree(kind, tree.root, files, opts)}

      _none ->
        {nil, nil}
    end
  end

  defp other_tree(:pg_hba_conf, root, files, opts), do: beside(:pg_ident_conf, root, files, opts)
  defp other_tree(:pg_ident_conf, root, files, opts), do: beside(:pg_hba_conf, root, files, opts)
  defp other_tree(_kind, _root, _files, _opts), do: nil

  defp beside(kind, root, files, opts) do
    path = Path.join(Path.dirname(root), ConfigTree.root_name(kind))

    case files.read.(path) do
      {:ok, _text} -> ConfigTree.resolve(kind, path, files, opts)
      :error -> nil
    end
  end

  defp with_tree(options, tree, path),
    do: options |> Map.new() |> Map.put(:tree, tree) |> Map.put(:path, path)

  # The server reports an override the tree already found. The first hint on
  # a line, which is the offline one, is the one kept.
  defp one_override_per_line(diagnostics) do
    diagnostics
    |> Enum.reduce([], fn diagnostic, kept ->
      if diagnostic.code == "override" and
           Enum.any?(kept, &(&1.code == "override" and same_line?(&1, diagnostic))),
         do: kept,
         else: [diagnostic | kept]
    end)
    |> Enum.reverse()
  end

  defp same_line?(a, b), do: a.range.start.line == b.range.start.line

  # The version comes from the `pg` option or a `# postern: pg=N` comment in
  # any of the files, the same way it does for postgresql.conf.
  defp target_version(text, options), do: PostgresqlConfDiagnostics.target_version(text, options)

  defp option(options, key) when is_map(options), do: options[key] || options[Atom.to_string(key)]
  defp option(options, key) when is_list(options), do: Keyword.get(options, key)
  defp option(_options, _key), do: nil
end
