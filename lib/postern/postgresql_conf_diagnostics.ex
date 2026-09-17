defmodule Postern.PostgresqlConfDiagnostics do
  @moduledoc """
  Offline diagnostics for PostgreSQL configuration assignments.

  All setting metadata comes from `Postern.Catalog`; this module contains only
  validation mechanics. The target major version is selected from
  initialization options, a `# postern: pg=N` comment, or the newest catalog.

  With a `:tree` from `Postern.ConfigTree` and the document's `:path` in the
  options, a setting a later file overrides gets its hint and an include the
  server could not follow gets its error, the way `pg_file_settings` reports
  them. Without one, only the document's own lines are weighed against each
  other.
  """

  alias GenLSP.Structures.Diagnostic
  alias GenLSP.Structures.Position
  alias GenLSP.Structures.Range
  alias Postern.Catalog
  alias Postern.ConfigTree
  alias Postern.Parser.PostgresqlConf

  @error 1
  @warning 2
  @hint 4

  @boolean_values ~w(on off true false yes no 1 0 t f y n)
  @unit_factors %{
    "b" => 1.0,
    "kb" => 1024.0,
    "mb" => 1_048_576.0,
    "gb" => 1_073_741_824.0,
    "tb" => 1_099_511_627_776.0,
    "8kb" => 8192.0,
    "us" => 1.0,
    "ms" => 1000.0,
    "s" => 1_000_000.0,
    "min" => 60_000_000.0,
    "h" => 3_600_000_000.0,
    "d" => 86_400_000_000.0
  }

  @doc """
  Produces parser and catalog diagnostics for a `postgresql.conf` document.
  """
  @spec diagnostics(String.t(), map() | keyword()) :: [Diagnostic.t()]
  def diagnostics(text, options \\ %{}) when is_binary(text) do
    versions = Catalog.versions()
    version = target_version(text, options, versions)
    catalog = Catalog.load(version)
    {:ok, entries} = PostgresqlConf.parse(text)
    tree = option(options, :tree)
    path = option(options, :path)

    parse_diagnostics(entries) ++
      value_diagnostics(entries, catalog, versions) ++
      override_diagnostics(tree, entries, path) ++
      include_diagnostics(tree, path)
  end

  @doc "Returns the selected PostgreSQL major version for a document."
  @spec target_version(String.t(), map() | keyword(), [pos_integer()]) :: pos_integer()
  def target_version(text, initialization_options, versions \\ Catalog.versions()) do
    configured = option_version(initialization_options)
    from_comment = comment_version(text)

    cond do
      configured in versions -> configured
      from_comment in versions -> from_comment
      versions == [] -> raise "no PostgreSQL catalogs are available"
      true -> List.last(versions)
    end
  end

  defp parse_diagnostics(entries) do
    entries
    |> Enum.filter(&(&1.type == :error))
    |> Enum.map(&diagnostic(&1.span, @error, &1.message))
  end

  defp value_diagnostics(entries, catalog, versions) do
    for %{type: :assignment, name: name} = entry <- entries,
        diagnostic <-
          setting_diagnostics(entry, Catalog.fetch(catalog, name), name, versions, catalog),
        do: diagnostic
  end

  # The last assignment of a name is the one PostgreSQL keeps, whether it is
  # further down this file or in a file the tree reads later. The line that
  # loses gets the hint and says where, as pg_file_settings marks that line
  # applied = false.
  defp override_diagnostics(nil, entries, _path) do
    %{entries: Enum.map(entries, &%{path: nil, entry: &1})}
    |> ConfigTree.overridden()
    |> Enum.map(fn {loser, winner} -> override_hint(loser, winner) end)
  end

  defp override_diagnostics(tree, _entries, path) do
    for {%{path: ^path} = loser, winner} <- ConfigTree.overridden(tree),
        do: override_hint(loser, winner)
  end

  defp override_hint(loser, winner) do
    line = winner.entry.span.line

    where =
      if winner.path == loser.path,
        do: "on line #{line}",
        else: "in #{ConfigTree.relative(winner.path, loser.path)} on line #{line}"

    %{
      diagnostic(loser.entry.name_span, @hint, "overridden by a later entry #{where}")
      | code: "override"
    }
  end

  defp include_diagnostics(nil, _path), do: []

  defp include_diagnostics(tree, path) do
    for %{path: ^path} = problem <- tree.problems,
        do: diagnostic(problem.span, problem.severity, problem.message)
  end

  defp setting_diagnostics(entry, nil, name, versions, catalog) do
    if setting_available_elsewhere?(name, catalog.version, versions) do
      [
        diagnostic(
          entry.name_span,
          @warning,
          "setting #{inspect(name)} is not available in PostgreSQL #{catalog.version}; it may have been removed or renamed"
        )
      ]
    else
      unknown_setting_diagnostic(entry, name, versions)
    end
  end

  defp setting_diagnostics(entry, setting, _name, _versions, _catalog) do
    case validate_value(entry.value, setting) do
      :ok -> []
      {:error, message} -> [diagnostic(entry.value_span, @error, message)]
    end
  end

  defp unknown_setting_diagnostic(entry, name, versions) do
    suggestions =
      versions
      |> Enum.flat_map(fn version -> Catalog.load(version).settings |> Map.keys() end)
      |> Enum.uniq()
      |> Enum.map(&{jaro(String.downcase(name), String.downcase(&1)), &1})
      |> Enum.sort_by(fn {score, candidate} -> {-score, candidate} end)

    message =
      case Enum.find(suggestions, fn {score, _candidate} -> score >= 0.80 end) do
        {_score, candidate} ->
          "unknown setting #{inspect(name)}; did you mean #{inspect(candidate)}?"

        nil ->
          "unknown setting #{inspect(name)}"
      end

    [diagnostic(entry.name_span, @error, message)]
  end

  defp setting_available_elsewhere?(name, version, versions) do
    Enum.any?(versions -- [version], fn other_version ->
      Catalog.fetch(Catalog.load(other_version), name) != nil
    end)
  end

  defp validate_value(value, setting) do
    vartype = setting["vartype"]
    unit = setting["unit"]

    case vartype do
      "bool" -> validate_boolean(value, setting)
      "enum" -> validate_enum(value, setting)
      type when type in ["integer", "real"] -> validate_numeric(value, setting, unit)
      _ -> :ok
    end
  end

  defp validate_boolean(value, setting) do
    normalized = String.downcase(value)

    if normalized in @boolean_values or
         Enum.any?(~w(on off true false yes no), &String.starts_with?(&1, normalized)) do
      :ok
    else
      {:error, "invalid value #{inspect(value)} for boolean setting #{inspect(setting["name"])}"}
    end
  end

  defp validate_enum(value, setting) do
    enum_values = enum_values(setting["enumvals"])

    if value in enum_values do
      :ok
    else
      {:error, "value #{inspect(value)} is not one of: #{Enum.join(enum_values, ", ")}"}
    end
  end

  defp validate_numeric(value, setting, catalog_unit) do
    case parse_number(value) do
      {:ok, number, input_unit} ->
        case validate_input_unit(input_unit, catalog_unit, setting) do
          :ok -> compare_numeric(number, input_unit, setting, catalog_unit)
          {:error, message} -> {:error, message}
        end

      :error ->
        {:error,
         "invalid value #{inspect(value)} for #{setting["vartype"]} setting #{inspect(setting["name"])}"}
    end
  end

  defp validate_input_unit(nil, _catalog_unit, _setting), do: :ok

  defp validate_input_unit(input_unit, nil, setting) do
    {:error, "unit #{inspect(input_unit)} is not allowed for setting #{inspect(setting["name"])}"}
  end

  defp validate_input_unit(input_unit, catalog_unit, setting) do
    cond do
      not Map.has_key?(@unit_factors, String.downcase(input_unit)) ->
        {:error, "setting could not be applied"}

      unit_dimension(input_unit) != unit_dimension(catalog_unit) ->
        {:error,
         "unit #{inspect(input_unit)} is not allowed for setting #{inspect(setting["name"])}"}

      true ->
        :ok
    end
  end

  defp compare_numeric(number, input_unit, setting, catalog_unit) do
    converted = convert_unit(number, input_unit, catalog_unit)
    min_value = numeric(setting["min_val"])
    max_value = numeric(setting["max_val"])
    integer_value? = setting["vartype"] == "integer" and converted == trunc(converted)

    cond do
      not integer_value? and setting["vartype"] == "integer" ->
        {:error, "invalid value #{inspect(setting["name"])}: expected an integer"}

      min_value != nil and converted < min_value ->
        {:error,
         "value #{inspect(converted)} is below the minimum #{inspect(setting["min_val"])}"}

      max_value != nil and converted > max_value ->
        {:error,
         "value #{inspect(converted)} is above the maximum #{inspect(setting["max_val"])}"}

      true ->
        :ok
    end
  end

  defp parse_number(value) do
    case Regex.run(~r/^([+-]?(?:\d+(?:\.\d*)?|\.\d+))([A-Za-z]+)?$/, value,
           capture: :all_but_first
         ) do
      [number] ->
        case parsed_number(number) do
          {:ok, parsed} -> {:ok, parsed, nil}
          :error -> :error
        end

      [number, unit] ->
        case parsed_number(number) do
          {:ok, parsed} -> {:ok, parsed, unit}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp parsed_number(number) do
    case Float.parse(number) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end

  defp convert_unit(number, nil, _catalog_unit), do: number

  defp convert_unit(number, input_unit, catalog_unit) do
    input_factor = Map.get(@unit_factors, String.downcase(input_unit), 1.0)
    catalog_factor = Map.get(@unit_factors, String.downcase(catalog_unit), 1.0)
    number * input_factor / catalog_factor
  end

  defp unit_dimension(unit) when is_binary(unit) do
    normalized = String.downcase(unit)

    cond do
      normalized in ~w(b kb mb gb tb 8kb) -> :memory
      normalized in ~w(us ms s min h d) -> :time
      true -> :unknown
    end
  end

  defp unit_dimension(nil), do: :none

  defp numeric(nil), do: nil

  defp numeric(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp enum_values(values) when is_list(values), do: values
  defp enum_values(nil), do: []

  defp enum_values(values) when is_binary(values) do
    values
    |> String.trim_leading("{")
    |> String.trim_trailing("}")
    |> String.split(",", trim: true)
  end

  defp option(options, key) when is_map(options), do: options[key] || options[Atom.to_string(key)]
  defp option(options, key) when is_list(options), do: Keyword.get(options, key)
  defp option(_options, _key), do: nil

  defp option_version(options) when is_list(options), do: options[:pg] || options[:version]

  defp option_version(options) when is_map(options),
    do: options[:pg] || options["pg"] || options[:version] || options["version"]

  defp option_version(_options), do: nil

  defp comment_version(text) do
    case Regex.run(~r/#\s*postern:\s*pg\s*=\s*(\d+)/i, text, capture: :all_but_first) do
      [version] -> String.to_integer(version)
      _ -> nil
    end
  end

  defp diagnostic(span, severity, message) do
    %Diagnostic{
      range: span_to_range(span),
      severity: severity,
      source: "postern",
      message: message
    }
  end

  defp span_to_range(%{line: line, col: col, end_line: end_line, end_col: end_col}) do
    %Range{
      start: %Position{line: line - 1, character: col - 1},
      end: %Position{line: end_line - 1, character: end_col - 1}
    }
  end

  defp jaro(left, right) when left == right, do: 1.0

  defp jaro(left, right) do
    left = String.graphemes(left)
    right = String.graphemes(right)
    left_length = length(left)
    right_length = length(right)
    distance = max(div(max(left_length, right_length), 2) - 1, 0)
    left_matches = matching_flags(left, right, distance)
    right_matches = matching_flags(right, left, distance)
    matches = Enum.count(left_matches, & &1)

    if matches == 0 do
      0.0
    else
      transpositions =
        left_matches
        |> Enum.zip(right_matches)
        |> Enum.count(fn {left_match, right_match} -> left_match != right_match end)

      (matches / left_length + matches / right_length +
         (matches - transpositions / 2) / matches) / 3
    end
  end

  defp matching_flags(source, target, distance) do
    source
    |> Enum.with_index()
    |> Enum.map(fn {character, index} ->
      first = max(index - distance, 0)
      last = min(index + distance, length(target) - 1)
      character in Enum.slice(target, first, max(last - first + 1, 0))
    end)
  end
end
