defmodule Postern.Files do
  @moduledoc """
  Reads the configuration files a check needs besides the one it is about.

  A check follows includes and looks at the file next to the document, so it
  reads files and lists directories through this struct rather than the disk
  directly. In the editor the copy being edited is the one that counts, so a
  reader built from the open documents answers with the buffer for a file that
  is open and with the disk for one that is not. `postern check` has only the
  disk, and a test or a tree read back from a server has files in memory.
  """

  alias Postern.FileKind

  defstruct [:read, :list]

  @type t :: %__MODULE__{
          read: (Path.t() -> {:ok, String.t()} | :error),
          list: (Path.t() -> {:ok, [String.t()]} | :error)
        }

  @doc "A reader that sees only the disk."
  @spec disk() :: t()
  def disk, do: %__MODULE__{read: &read_disk/1, list: &list_disk/1}

  @doc "A reader that answers with an open document's text before looking at the disk."
  @spec with_documents(%{
          optional(String.t()) => %{:text => String.t(), optional(atom()) => any()}
        }) ::
          t()
  def with_documents(documents) do
    open =
      Map.new(documents, fn {uri, document} -> {FileKind.uri_to_path(uri), document.text} end)

    %__MODULE__{
      read: fn path ->
        case Map.fetch(open, path) do
          {:ok, text} -> {:ok, text}
          :error -> read_disk(path)
        end
      end,
      list: &list_disk/1
    }
  end

  @doc "A reader over files held in memory, keyed by absolute path."
  @spec in_memory(%{optional(Path.t()) => String.t()}) :: t()
  def in_memory(files) do
    %__MODULE__{
      read: fn path ->
        case Map.fetch(files, path) do
          {:ok, text} -> {:ok, text}
          :error -> :error
        end
      end,
      list: fn directory ->
        below = Enum.filter(Map.keys(files), &String.starts_with?(&1, directory <> "/"))

        if below == [] do
          :error
        else
          {:ok, for(path <- below, Path.dirname(path) == directory, do: Path.basename(path))}
        end
      end
    }
  end

  defp read_disk(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> :error
    end
  end

  # The plain files in a directory, which is what an include_dir takes.
  defp list_disk(directory) do
    case File.ls(directory) do
      {:ok, names} -> {:ok, Enum.reject(names, &File.dir?(Path.join(directory, &1)))}
      {:error, _reason} -> :error
    end
  end
end
