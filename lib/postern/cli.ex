defmodule Postern.CLI do
  @moduledoc """
  Command-line checks for PostgreSQL configuration files.
  """

  alias Postern.ConfigTree
  alias Postern.Diagnostics
  alias Postern.FileKind
  alias Postern.Files

  @help_flags ~w(--help -h help)
  @version_flags ~w(--version -v version)

  @usage """
  Usage:
    postern                          start the language server on stdio
    postern check [--json] FILE...   report diagnostics and exit 1 on errors
    postern --version
    postern --help

  Files are recognised by name, postgresql.conf, postgresql.auto.conf,
  pg_hba.conf and pg_ident.conf, or by the root that includes them. Checking
  a root checks every file it reads.
  """

  @doc "Arguments that print information and exit instead of starting the server."
  @spec info_flags() :: [String.t()]
  def info_flags, do: @help_flags ++ @version_flags

  @doc "Runs the command-line interface and returns an exit code."
  @spec run([String.t()]) :: non_neg_integer()
  def run([flag | _]) when flag in @help_flags do
    IO.write(@usage)
    0
  end

  def run([flag | _]) when flag in @version_flags do
    IO.puts("postern " <> to_string(Application.spec(:postern, :vsn)))
    0
  end

  def run(["check" | args]) do
    {options, files, invalid} = OptionParser.parse(args, switches: [json: :boolean])

    cond do
      invalid != [] ->
        print_error("invalid options: #{inspect(invalid)}")
        2

      files == [] ->
        IO.write(:stderr, @usage)
        2

      true ->
        results = check_files(files)
        print_results(results, options[:json] == true)

        if Enum.any?(results, &has_errors?/1), do: 1, else: 0
    end
  end

  def run(_args) do
    IO.write(:stderr, @usage)
    2
  end

  # Each file given, then the files a root among them reads that were not
  # given themselves, once each.
  defp check_files(files) do
    given = MapSet.new(files, &Path.expand/1)

    {results, _seen} =
      Enum.flat_map_reduce(files, MapSet.new(), fn file, seen ->
        path = Path.expand(file)
        {result, tree} = check_file(file, path)

        included =
          if tree && tree.root == path,
            do: Enum.reject(tree.files, &(&1 == path or &1 in given or &1 in seen)),
            else: []

        results = [
          result | Enum.map(included, &elem(check_file(Path.relative_to_cwd(&1), &1), 0))
        ]

        {results, seen |> MapSet.put(path) |> MapSet.union(MapSet.new(included))}
      end)

    results
  end

  defp check_file(file, path) do
    with {:ok, text} <- File.read(path),
         kind when kind != :unknown <- kind_of(path) do
      uri = "file://" <> path
      diagnostics = Diagnostics.for_document(uri, text, %{reader: Files.disk(), kind: kind})
      {%{file: file, diagnostics: diagnostics}, ConfigTree.for_document(kind, path, Files.disk())}
    else
      {:error, reason} ->
        {%{file: file, diagnostics: [], error: "#{file}: #{:file.format_error(reason)}"}, nil}

      :unknown ->
        {%{
           file: file,
           diagnostics: [],
           error:
             "#{file}: not one of PostgreSQL's configuration files, and no postgresql.conf, pg_hba.conf or pg_ident.conf includes it"
         }, nil}
    end
  end

  defp kind_of(path) do
    case FileKind.detect(path) do
      :unknown -> ConfigTree.kind_of(path, Files.disk())
      kind -> kind
    end
  end

  defp print_results(results, true) do
    json =
      Enum.map(results, fn result ->
        %{
          "file" => result.file,
          "error" => Map.get(result, :error),
          "diagnostics" => Enum.map(result.diagnostics, &diagnostic_json/1)
        }
      end)

    IO.puts(Jason.encode!(json, pretty: true))
  end

  defp print_results(results, false) do
    Enum.each(results, fn result ->
      if result[:error], do: print_error(result.error)

      Enum.each(result.diagnostics, fn diagnostic ->
        range = diagnostic.range
        severity = severity_name(diagnostic.severity)

        IO.puts(
          "#{result.file}:#{range.start.line + 1}:#{range.start.character + 1}: #{severity}: #{diagnostic.message}"
        )
      end)
    end)
  end

  defp diagnostic_json(diagnostic) do
    %{
      "severity" => diagnostic.severity,
      "message" => diagnostic.message,
      "source" => diagnostic.source,
      "range" => %{
        "start" => %{
          "line" => diagnostic.range.start.line,
          "character" => diagnostic.range.start.character
        },
        "end" => %{
          "line" => diagnostic.range.end.line,
          "character" => diagnostic.range.end.character
        }
      }
    }
  end

  defp has_errors?(%{error: _}), do: true
  defp has_errors?(%{diagnostics: diagnostics}), do: Enum.any?(diagnostics, &(&1.severity == 1))

  defp severity_name(1), do: "error"
  defp severity_name(2), do: "warning"
  defp severity_name(3), do: "info"
  defp severity_name(4), do: "hint"
  defp severity_name(_), do: "diagnostic"

  defp print_error(message), do: IO.puts(:stderr, message)
end
