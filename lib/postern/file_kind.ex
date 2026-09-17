defmodule Postern.FileKind do
  @moduledoc """
  Detects the kind of PostgreSQL configuration file based on its basename.

  Known kinds:

  * `:postgresql_conf` - `postgresql.conf`, `postgresql.auto.conf`, or the
    `postgresql.base.conf` Patroni keeps the original file as
  * `:pg_hba_conf` - `pg_hba.conf`
  * `:pg_ident_conf` - `pg_ident.conf`
  * `:unknown` - anything else

  A file with another name, such as one under `conf.d`, is known by the
  language the editor gives it, when the editor sends one.
  """

  @type t :: :postgresql_conf | :pg_hba_conf | :pg_ident_conf | :unknown

  @doc """
  Detects the file kind from a URI or file path, falling back to the
  language identifier the editor sent with the document.

  The name wins when it is one of PostgreSQL's. Otherwise the identifier
  decides: `postgresql-conf`, `pg-hba` and `pg-ident` are the ones the
  editor packages use, and an editor with one language for all four files
  sends `postgresql-conf` for any of them, which is the right guess for a
  file it was told to hand over.

  ## Examples

      iex> Postern.FileKind.detect("file:///etc/postgresql/postgresql.conf")
      :postgresql_conf

      iex> Postern.FileKind.detect("/var/lib/pg_hba.conf")
      :pg_hba_conf

      iex> Postern.FileKind.detect("file:///etc/postgresql/16/main/conf.d/10-memory.conf", "postgresql-conf")
      :postgresql_conf

  """
  @spec detect(String.t(), String.t() | nil) :: t()
  def detect(uri_or_path, language_id \\ nil) when is_binary(uri_or_path) do
    basename =
      uri_or_path
      |> uri_to_path()
      |> Path.basename()

    case basename do
      "postgresql.conf" -> :postgresql_conf
      "postgresql.auto.conf" -> :postgresql_conf
      "postgresql.base.conf" -> :postgresql_conf
      "pg_hba.conf" -> :pg_hba_conf
      "pg_ident.conf" -> :pg_ident_conf
      _ -> from_language_id(language_id)
    end
  end

  # Zed sends the language's name lowercased unless the extension maps it, so
  # "postgresql config" is accepted next to the id the packages use.
  defp from_language_id(nil), do: :unknown

  defp from_language_id(language_id) do
    case language_id |> String.downcase() |> String.replace([" ", "_"], "-") do
      "postgresql-conf" -> :postgresql_conf
      "postgresql-config" -> :postgresql_conf
      "pg-hba" -> :pg_hba_conf
      "pg-ident" -> :pg_ident_conf
      _ -> :unknown
    end
  end

  @doc """
  Converts a `file://` URI to a filesystem path. A Windows drive comes back
  as `c:/Users/...`, without the slash the URI puts before it, and a UNC
  share keeps its host. Anything that is not a URI is returned unchanged.
  """
  @spec uri_to_path(String.t()) :: String.t()
  def uri_to_path("file://" <> _rest = uri) do
    %URI{path: path, host: host} = URI.parse(uri)
    path = URI.decode(path || "")
    path = if host in [nil, ""], do: path, else: "//" <> host <> path

    if Regex.match?(~r{^/[A-Za-z]:(/|$)}, path),
      do: String.slice(path, 1..-1//1),
      else: path
  end

  def uri_to_path(path), do: path

  @doc """
  The `file://` URI for a path, with the slash a Windows drive needs before
  it, as editors write it.
  """
  @spec path_to_uri(String.t()) :: String.t()
  def path_to_uri(path) do
    path = Path.expand(path)
    encoded = URI.encode(path)
    if String.starts_with?(path, "/"), do: "file://" <> encoded, else: "file:///" <> encoded
  end

  @doc """
  One form for a path wherever it came from: absolute, with forward slashes
  and one case for a Windows drive letter, so that a path from an editor's
  URI and one the resolver built from an include line compare equal.
  """
  @spec canonical(String.t()) :: String.t()
  def canonical(path), do: Path.expand(path)
end
