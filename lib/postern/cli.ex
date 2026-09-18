defmodule Postern.CLI do
  @moduledoc """
  Command-line checks for PostgreSQL configuration files.

  `check` takes the files, a target version, a server to compare with, a
  file on stdin, and an output for people, for GitHub Actions or for code
  scanning, and exits 1 when a file has an error, or with `--strict` a
  warning.
  """

  alias Postern.ConfigTree
  alias Postern.Diagnostics
  alias Postern.FileKind
  alias Postern.Files
  alias Postern.LiveOracle

  @help_flags ~w(--help -h help)
  @version_flags ~w(--version -v version)
  @formats ~w(text json github sarif)

  @usage """
  Usage:
    postern                          start the language server on stdio
    postern check [options] FILE...  report diagnostics and exit 1 on errors
    postern --version
    postern --help

  Options of check:
    --pg N                      check against PostgreSQL N, 13 to 18; the newest without it
    --connection-string URL     compare with the server at postgres://user:pass@host:5432/db
    --live                      compare with the server the PG environment variables name
    --stdin-filename PATH       read the file from stdin, as if it were at PATH
    --format FORMAT             text, json, github (workflow commands) or sarif
    --json                      the same as --format json
    --strict                    exit 1 on a warning as well as an error

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
    IO.puts("postern " <> version())
    0
  end

  def run(["check" | args]) do
    {options, files, invalid} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          format: :string,
          pg: :integer,
          connection_string: :string,
          live: :boolean,
          stdin_filename: :string,
          strict: :boolean
        ]
      )

    format = if options[:json], do: "json", else: options[:format] || "text"
    check(options, files, invalid, format)
  end

  def run(_args) do
    IO.write(:stderr, @usage)
    2
  end

  defp check(_options, _files, [_invalid | _rest] = invalid, _format) do
    print_error("invalid options: #{inspect(invalid)}")
    2
  end

  defp check(_options, _files, [], format) when format not in @formats do
    print_error("unknown format #{inspect(format)}; one of #{Enum.join(@formats, ", ")}")
    2
  end

  defp check(options, files, [], format) do
    if files == [] and options[:stdin_filename] == nil do
      IO.write(:stderr, @usage)
      2
    else
      results = check_all(files, options)
      print_results(results, format)
      failing = if options[:strict], do: 2, else: 1
      if Enum.any?(results, &has_findings?(&1, failing)), do: 1, else: 0
    end
  end

  # The file on stdin, when there is one, is read as if it stood at the path
  # given, and the reader answers with it there and with the disk elsewhere.
  defp check_all(files, options) do
    {reader, stdin} =
      case options[:stdin_filename] do
        nil ->
          {Files.disk(), []}

        path ->
          text = IO.read(:stdio, :eof) |> to_string()
          uri = FileKind.path_to_uri(Path.expand(path))
          {Files.with_documents(%{uri => %{text: text}}), [{path, text}]}
      end

    context = %{reader: reader, pg: options[:pg]} |> Map.merge(live_options(options))
    check_files(files, stdin, context)
  end

  # A server to compare with: the one on the command line, or the one the
  # PG environment variables name when asked for. Its snapshot is read once
  # for every file.
  defp live_options(options) do
    connection =
      cond do
        options[:connection_string] ->
          LiveOracle.connection_options(%{connection_string: options[:connection_string]})

        options[:live] ->
          LiveOracle.connection_options(%{})

        true ->
          nil
      end

    case connection do
      nil ->
        %{}

      connection ->
        {:ok, oracle} = LiveOracle.start_link(connection)
        snapshot = LiveOracle.snapshot(oracle)
        GenServer.stop(oracle)
        %{live_snapshot: snapshot, live_configured: true}
    end
  end

  # Each file given, then the files a root among them reads that were not
  # given themselves, once each.
  defp check_files(files, stdin, context) do
    given = MapSet.new(files ++ Enum.map(stdin, &elem(&1, 0)), &Path.expand/1)

    {results, _seen} =
      Enum.flat_map_reduce(stdin_first(stdin) ++ files, MapSet.new(), fn file, seen ->
        path = Path.expand(file)
        {result, tree} = check_file(file, path, context)

        included =
          if tree && tree.root == path,
            do: Enum.reject(tree.files, &(&1 == path or &1 in given or &1 in seen)),
            else: []

        results = [
          result | Enum.map(included, &elem(check_file(Path.relative_to_cwd(&1), &1, context), 0))
        ]

        {results, seen |> MapSet.put(path) |> MapSet.union(MapSet.new(included))}
      end)

    results
  end

  defp stdin_first(stdin), do: Enum.map(stdin, &elem(&1, 0))

  defp check_file(file, path, context) do
    with {:ok, text} <- context.reader.read.(path) |> as_read(),
         kind when kind != :unknown <- kind_of(path, context.reader) do
      uri = FileKind.path_to_uri(path)

      options =
        context |> Map.put(:kind, kind) |> Map.reject(fn {_key, value} -> is_nil(value) end)

      diagnostics = Diagnostics.for_document(uri, text, options)

      {%{file: file, diagnostics: diagnostics},
       ConfigTree.for_document(kind, path, context.reader)}
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

  defp as_read({:ok, text}), do: {:ok, text}
  defp as_read(:error), do: {:error, :enoent}

  defp kind_of(path, reader) do
    case FileKind.detect(path) do
      :unknown -> ConfigTree.kind_of(path, reader)
      kind -> kind
    end
  end

  defp print_results(results, "json") do
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

  # One workflow command per diagnostic, which GitHub Actions turns into an
  # annotation on the line; a newline in the message is written as %0A, as
  # the commands want it.
  defp print_results(results, "github") do
    Enum.each(results, fn result ->
      if result[:error], do: IO.puts("::error title=Postern::#{escape(result.error)}")

      Enum.each(result.diagnostics, fn diagnostic ->
        range = diagnostic.range

        IO.puts(
          "::#{github_level(diagnostic.severity)} file=#{result.file},line=#{range.start.line + 1},col=#{range.start.character + 1},endLine=#{range.end.line + 1},endColumn=#{range.end.character + 1},title=Postern::#{escape(diagnostic.message)}"
        )
      end)
    end)
  end

  # SARIF 2.1.0, which code scanning reads and shows on the pull request.
  defp print_results(results, "sarif") do
    sarif = %{
      "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
      "version" => "2.1.0",
      "runs" => [
        %{
          "tool" => %{
            "driver" => %{
              "name" => "Postern",
              "version" => version(),
              "informationUri" => "https://github.com/willibrandon/postern"
            }
          },
          "results" =>
            Enum.flat_map(results, fn result ->
              Enum.map(result.diagnostics, fn diagnostic ->
                %{
                  "ruleId" => diagnostic.code || "postern",
                  "level" => sarif_level(diagnostic.severity),
                  "message" => %{"text" => diagnostic.message},
                  "locations" => [
                    %{
                      "physicalLocation" => %{
                        "artifactLocation" => %{"uri" => result.file},
                        "region" => %{
                          "startLine" => diagnostic.range.start.line + 1,
                          "startColumn" => diagnostic.range.start.character + 1,
                          "endLine" => diagnostic.range.end.line + 1,
                          "endColumn" => diagnostic.range.end.character + 1
                        }
                      }
                    }
                  ]
                }
              end)
            end)
        }
      ]
    }

    IO.puts(Jason.encode!(sarif, pretty: true))
  end

  defp print_results(results, "text") do
    Enum.each(results, fn result ->
      if result[:error], do: print_error(result.error)

      # A message's first line is the server's message, and any line after it
      # is its hint or detail, printed indented below the way psql prints them.
      Enum.each(result.diagnostics, fn diagnostic ->
        range = diagnostic.range
        severity = severity_name(diagnostic.severity)
        [message | more] = String.split(diagnostic.message, "\n")

        IO.puts(
          "#{result.file}:#{range.start.line + 1}:#{range.start.character + 1}: #{severity}: #{message}"
        )

        Enum.each(more, &IO.puts("  " <> &1))
      end)
    end)
  end

  defp diagnostic_json(diagnostic) do
    %{
      "severity" => diagnostic.severity,
      "message" => diagnostic.message,
      "source" => diagnostic.source,
      "code" => diagnostic.code,
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

  defp has_findings?(%{error: _}, _threshold), do: true

  defp has_findings?(%{diagnostics: diagnostics}, threshold),
    do: Enum.any?(diagnostics, &(&1.severity <= threshold))

  defp severity_name(1), do: "error"
  defp severity_name(2), do: "warning"
  defp severity_name(3), do: "info"
  defp severity_name(4), do: "hint"
  defp severity_name(_), do: "diagnostic"

  defp github_level(1), do: "error"
  defp github_level(2), do: "warning"
  defp github_level(_other), do: "notice"

  defp sarif_level(1), do: "error"
  defp sarif_level(2), do: "warning"
  defp sarif_level(_other), do: "note"

  defp escape(text),
    do:
      text
      |> String.replace("%", "%25")
      |> String.replace("\r", "%0D")
      |> String.replace("\n", "%0A")

  defp print_error(message), do: IO.puts(:stderr, message)

  defp version, do: :postern |> Application.spec(:vsn) |> to_string()
end
