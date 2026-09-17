defmodule Postern.Files do
  @moduledoc """
  Reads the configuration files a check needs besides the one it is about.

  A check on `pg_hba.conf` looks at the `pg_ident.conf` next to it, and the
  other way round. In the editor the copy being edited is the one that
  counts, so a reader built from the open documents answers with the buffer
  for a file that is open and with the disk for one that is not.
  `postern check` has only the disk.
  """

  alias Postern.FileKind

  @type reader :: (Path.t() -> {:ok, String.t()} | :error)

  @doc "A reader that sees only the disk."
  @spec disk() :: reader()
  def disk, do: &read/1

  @doc "A reader that answers with an open document's text before looking at the disk."
  @spec with_documents(%{
          optional(String.t()) => %{:text => String.t(), optional(atom()) => any()}
        }) ::
          reader()
  def with_documents(documents) do
    open =
      Map.new(documents, fn {uri, document} -> {FileKind.uri_to_path(uri), document.text} end)

    fn path ->
      case Map.fetch(open, path) do
        {:ok, text} -> {:ok, text}
        :error -> read(path)
      end
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> :error
    end
  end
end
