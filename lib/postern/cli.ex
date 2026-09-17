defmodule Postern.CLI do
  @moduledoc """
  Command-line checks for PostgreSQL configuration files.
  """

  alias Postern.Diagnostics
  alias Postern.Files

  @help_flags ~w(--help -h help)
  @version_flags ~w(--version -v version)

  @usage """
  Usage:
    postern                          start the language server on stdio
    postern check [--json] FILE...   report diagnostics and exit 1 on errors
    postern --version
    postern --help

  Files are recognised by name: postgresql.conf, postgresql.auto.conf,
  pg_hba.conf and pg_ident.conf.
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
        results = Enum.map(files, &check_file/1)
        print_results(results, options[:json] == true)

        if Enum.any?(results, &has_errors?/1), do: 1, else: 0
    end
  end

  def run(_args) do
    IO.write(:stderr, @usage)
    2
  end

  defp check_file(file) do
    path = Path.expand(file)

    case File.read(path) do
      {:ok, text} ->
        uri = "file://" <> path
        %{file: file, diagnostics: Diagnostics.for_document(uri, text, %{reader: Files.disk()})}

      {:error, reason} ->
        %{file: file, diagnostics: [], error: "#{file}: #{:file.format_error(reason)}"}
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
