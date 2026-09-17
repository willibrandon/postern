defmodule Postern.ConfigTree do
  @moduledoc """
  The files PostgreSQL reads for one of its configuration files, in the
  order it reads them.

  An `include`, `include_if_exists` or `include_dir` line splices another
  file in where it stands, and a relative path counts from the directory of
  the file that names it. An `include_dir` takes the plain files whose names
  end in `.conf` and do not start with a dot, in C locale order. The whole
  `postgresql.conf` tree is followed by `postgresql.auto.conf`, the file
  `ALTER SYSTEM` writes in the data directory, so the last assignment of a
  name across all of them is the one that counts. `pg_hba.conf` and
  `pg_ident.conf` take the same three directives from PostgreSQL 16 on.
  Nesting stops at ten levels, where the server stops too, and the messages
  are the ones `pg_file_settings` and `pg_hba_file_rules` report.
  """

  alias Postern.Catalog
  alias Postern.Files
  alias Postern.Parser.PgHba
  alias Postern.Parser.PgIdent
  alias Postern.Parser.PostgresqlConf
  alias Postern.PgHbaOptions

  @max_depth 10

  @roots %{
    postgresql_conf: "postgresql.conf",
    pg_hba_conf: "pg_hba.conf",
    pg_ident_conf: "pg_ident.conf"
  }

  # How far down a workspace a root is looked for when no directory above the
  # file holds one.
  @workspace_depths ["", "*/", "*/*/", "*/*/*/"]

  @type kind :: :postgresql_conf | :pg_hba_conf | :pg_ident_conf
  @type located :: %{path: Path.t(), entry: map()}
  @type problem :: %{path: Path.t(), span: map(), severity: 1 | 4, message: String.t()}
  @type t :: %{
          kind: kind(),
          root: Path.t(),
          files: [Path.t()],
          entries: [located()],
          problems: [problem()]
        }

  @doc "The name of the file a tree of this kind starts from."
  @spec root_name(kind()) :: String.t()
  def root_name(kind), do: Map.fetch!(@roots, kind)

  @doc """
  The tree a document belongs to.

  A document named like a root is one. Any other file belongs to the nearest
  root above it that reaches it, or to one at most three directories down the
  `:workspace`; a file no root reaches is a tree of its own. The `:version`
  decides whether pg_hba.conf and pg_ident.conf includes are followed, since
  those directives arrived in 16.
  """
  @spec for_document(kind(), Path.t(), Files.t(), keyword()) :: t()
  def for_document(kind, path, files, opts \\ []) do
    resolve(kind, root(kind, path, files, opts) || path, files, opts)
  end

  @doc "The kind of a file its name does not give away: that of the root reaching it."
  @spec kind_of(Path.t(), Files.t(), keyword()) :: kind() | :unknown
  def kind_of(path, files, opts \\ []) do
    Enum.find(Map.keys(@roots), :unknown, fn kind -> root(kind, path, files, opts) != nil end)
  end

  @doc "The root of the tree a document belongs to, or `nil` when no root reaches it."
  @spec root(kind(), Path.t(), Files.t(), keyword()) :: Path.t() | nil
  def root(kind, path, files, opts \\ []) do
    if Path.basename(path) == root_name(kind) do
      path
    else
      kind |> candidates(path, opts) |> Enum.find(&reaches?(kind, &1, path, files, opts))
    end
  end

  @doc "Resolves the tree under a root."
  @spec resolve(kind(), Path.t(), Files.t(), keyword()) :: t()
  def resolve(kind, root, files, opts \\ []) do
    follow =
      kind == :postgresql_conf or PgHbaOptions.directives?(opts[:version] || Catalog.latest())

    state = %{kind: kind, files: files, follow: follow, visited: [], entries: [], problems: []}

    state =
      case files.read.(root) do
        {:ok, text} -> state |> walk(root, text, 0) |> auto_conf(root)
        :error -> state
      end

    %{
      kind: kind,
      root: root,
      files: Enum.reverse(state.visited),
      entries: Enum.reverse(state.entries),
      problems: Enum.reverse(state.problems)
    }
  end

  @doc "Parses a file of the kind with the parser for it."
  @spec parse(kind(), String.t()) :: {:ok, [map()]}
  def parse(kind, text), do: parser(kind).parse(text)

  @doc "The absolute path an include names, from the file that names it."
  @spec absolute(String.t(), Path.t()) :: Path.t()
  def absolute(location, from), do: Path.expand(location, Path.dirname(from))

  @doc "A path the way the file at `from` would name it: relative when it is below the same directory."
  @spec relative(Path.t(), Path.t()) :: String.t()
  def relative(path, from), do: Path.relative_to(path, Path.dirname(from))

  @doc "The span of the file name on an include line, for any of the three parsers."
  @spec include_span(map()) :: map()
  def include_span(%{file_span: span}), do: span
  def include_span(%{tokens: [_directive, %{span: span} | _]}), do: span
  def include_span(%{span: span}), do: span

  @doc "Each assignment a later one of the same name overrides, with the one that counts."
  @spec overridden(%{entries: [located()]}) :: [{located(), located()}]
  def overridden(%{entries: entries}) do
    entries
    |> Enum.filter(&match?(%{entry: %{type: :assignment}}, &1))
    |> Enum.group_by(&String.downcase(&1.entry.name))
    |> Enum.flat_map(fn {_name, same} ->
      {losers, [winner]} = Enum.split(same, -1)
      Enum.map(losers, &{&1, winner})
    end)
  end

  @doc "The assignment that counts for a name, or `nil` when the tree has none."
  @spec winner(%{entries: [located()]}, String.t()) :: located() | nil
  def winner(%{entries: entries}, name) do
    name = String.downcase(name)

    Enum.find(Enum.reverse(entries), fn
      %{entry: %{type: :assignment, name: candidate}} -> String.downcase(candidate) == name
      _ -> false
    end)
  end

  defp walk(state, path, text, depth) do
    {:ok, entries} = parser(state.kind).parse(text)
    state = %{state | visited: [path | state.visited]}
    Enum.reduce(entries, state, &visit(&2, path, depth, &1))
  end

  defp visit(state, path, depth, %{type: :include} = entry) do
    state = %{state | entries: [%{path: path, entry: entry} | state.entries]}
    if state.follow, do: include(state, path, depth, entry), else: state
  end

  defp visit(state, path, _depth, entry),
    do: %{state | entries: [%{path: path, entry: entry} | state.entries]}

  defp include(state, path, depth, %{directive: "include_dir", file: name} = entry) do
    directory = absolute(name, path)

    case state.files.list.(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(&conf_name?/1)
        |> Enum.sort()
        |> Enum.reduce(state, &nested(&2, path, depth, entry, Path.join(directory, &1), true))

      :error ->
        problem(state, path, entry, 1, ~s(could not open directory "#{directory}"))
    end
  end

  defp include(state, path, depth, %{directive: directive, file: name} = entry),
    do: nested(state, path, depth, entry, absolute(name, path), directive == "include")

  defp nested(state, path, depth, entry, target, strict) do
    cond do
      depth + 1 > @max_depth ->
        problem(state, path, entry, 1, depth_message(state.kind, target))

      state.kind == :postgresql_conf and target == path ->
        problem(state, path, entry, 1, "configuration file recursion")

      true ->
        case state.files.read.(target) do
          {:ok, text} ->
            walk(state, target, text, depth + 1)

          :error when strict ->
            problem(state, path, entry, 1, missing_message(state.kind, target))

          :error ->
            problem(state, path, entry, 4, skipped_message(state.kind, target))
        end
    end
  end

  # postgresql.auto.conf lives in the data directory, which is the root's
  # unless the tree says otherwise, as Debian's does. The server reads it
  # last, and it is fine for it to be missing.
  defp auto_conf(%{kind: :postgresql_conf} = state, root) do
    directory =
      Enum.find_value(state.entries, Path.dirname(root), fn
        %{entry: %{type: :assignment, name: name, value: value}} ->
          if String.downcase(name) == "data_directory", do: absolute(value, root)

        _entry ->
          nil
      end)

    path = Path.join(directory, "postgresql.auto.conf")

    case state.files.read.(path) do
      {:ok, text} -> walk(state, path, text, 0)
      :error -> state
    end
  end

  defp auto_conf(state, _root), do: state

  # What GetConfFilesInDir keeps: at least "x.conf", not hidden, ending in .conf.
  defp conf_name?(name) do
    byte_size(name) >= 6 and not String.starts_with?(name, ".") and
      String.ends_with?(name, ".conf")
  end

  defp problem(state, path, entry, severity, message) do
    problem = %{path: path, span: include_span(entry), severity: severity, message: message}
    %{state | problems: [problem | state.problems]}
  end

  defp depth_message(:postgresql_conf, _target), do: "nesting depth exceeded"

  defp depth_message(_kind, target),
    do: ~s(could not open file "#{target}": maximum nesting depth exceeded)

  defp missing_message(:postgresql_conf, target), do: ~s(could not open file "#{target}")

  defp missing_message(_kind, target),
    do: ~s(could not open file "#{target}": No such file or directory)

  defp skipped_message(:postgresql_conf, target),
    do: ~s(skipping missing configuration file "#{target}")

  defp skipped_message(_kind, target),
    do: ~s(skipping missing authentication file "#{target}")

  defp candidates(kind, path, opts) do
    name = root_name(kind)
    above = path |> Path.dirname() |> ancestors() |> Enum.map(&Path.join(&1, name))

    below =
      case Keyword.get(opts, :workspace) do
        nil ->
          []

        workspace ->
          Enum.flat_map(@workspace_depths, &Path.wildcard(Path.join(workspace, &1 <> name)))
      end

    Enum.uniq(above ++ below)
  end

  defp ancestors(directory) do
    parent = Path.dirname(directory)
    if parent == directory, do: [directory], else: [directory | ancestors(parent)]
  end

  defp reaches?(kind, root, path, files, opts) do
    match?({:ok, _text}, files.read.(root)) and path in resolve(kind, root, files, opts).files
  end

  defp parser(:postgresql_conf), do: PostgresqlConf
  defp parser(:pg_hba_conf), do: PgHba
  defp parser(:pg_ident_conf), do: PgIdent
end
