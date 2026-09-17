defmodule Postern.DocumentStore do
  @moduledoc """
  In-memory document store keyed by URI.

  Documents are stored as maps with keys:

  * `:uri` - document URI
  * `:language_id` - language identifier from the client
  * `:version` - document version
  * `:text` - full document text
  * `:kind` - file kind from the URI and the language identifier via `Postern.FileKind`

  The store lives inside `GenLSP.Assigns` under the key `:documents`.
  """

  alias Postern.FileKind

  @type uri :: String.t()
  @type document :: %{
          uri: uri(),
          language_id: String.t(),
          version: integer(),
          text: String.t(),
          kind: FileKind.t()
        }

  @doc """
  Returns all documents.
  """
  @spec all(GenLSP.LSP.t()) :: %{uri() => document()}
  def all(lsp) do
    Map.get(GenLSP.LSP.assigns(lsp), :documents, %{})
  end

  @doc """
  Fetches a document by URI.
  """
  @spec get(GenLSP.LSP.t(), uri()) :: document() | nil
  def get(lsp, uri) do
    lsp |> all() |> Map.get(uri)
  end

  @doc """
  Stores a document, overwriting any existing entry.
  """
  @spec put(GenLSP.LSP.t(), uri(), String.t(), integer(), String.t()) :: GenLSP.LSP.t()
  def put(lsp, uri, text, version, language_id \\ "") do
    kind = FileKind.detect(uri, language_id)

    doc = %{
      uri: uri,
      language_id: language_id,
      version: version,
      text: text,
      kind: kind
    }

    GenLSP.LSP.assign(lsp, fn current ->
      documents = Map.get(current, :documents, %{})
      [documents: Map.put(documents, uri, doc)]
    end)
  end

  @doc """
  Updates the text (and version) of an existing document. If the document
  does not exist, it is created.
  """
  @spec update(GenLSP.LSP.t(), uri(), String.t(), integer()) :: GenLSP.LSP.t()
  def update(lsp, uri, text, version) do
    case get(lsp, uri) do
      nil ->
        put(lsp, uri, text, version)

      existing ->
        doc = %{existing | text: text, version: version}

        GenLSP.LSP.assign(lsp, fn current ->
          documents = Map.get(current, :documents, %{})
          [documents: Map.put(documents, uri, doc)]
        end)
    end
  end

  @doc """
  Applies `textDocument/didChange` content changes to `text`.

  A change with a `range` replaces that span; one without replaces the whole
  document. Positions count UTF-16 code units from the start of a line, as
  the protocol requires.
  """
  @spec apply_changes(String.t(), [map()]) :: String.t()
  def apply_changes(text, changes) do
    Enum.reduce(changes, text, fn change, current ->
      replacement = field(change, :text) || ""

      case field(change, :range) do
        nil ->
          replacement

        range ->
          from = offset(current, field(range, :start))
          to = offset(current, field(range, :end))

          binary_part(current, 0, from) <>
            replacement <> binary_part(current, to, byte_size(current) - to)
      end
    end)
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp offset(text, position) do
    line = field(position, :line) || 0
    character = field(position, :character) || 0
    lines = String.split(text, "\n")

    if line >= length(lines) do
      byte_size(text)
    else
      before = lines |> Enum.take(line) |> Enum.reduce(0, &(byte_size(&1) + &2 + 1))
      before + column_bytes(Enum.at(lines, line), character)
    end
  end

  # Walks the line while `units` of UTF-16 remain; a code point beyond the
  # basic plane takes two.
  defp column_bytes(line, units) do
    line
    |> String.to_charlist()
    |> Enum.reduce_while({0, units}, fn codepoint, {bytes, remaining} ->
      cost = if codepoint > 0xFFFF, do: 2, else: 1

      if remaining >= cost and remaining > 0,
        do: {:cont, {bytes + byte_size(<<codepoint::utf8>>), remaining - cost}},
        else: {:halt, {bytes, 0}}
    end)
    |> elem(0)
  end

  @doc """
  Deletes a document from the store.
  """
  @spec delete(GenLSP.LSP.t(), uri()) :: GenLSP.LSP.t()
  def delete(lsp, uri) do
    GenLSP.LSP.assign(lsp, fn current ->
      documents = Map.get(current, :documents, %{})
      [documents: Map.delete(documents, uri)]
    end)
  end
end
