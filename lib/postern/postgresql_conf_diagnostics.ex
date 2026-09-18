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
  alias Postern.GucValue
  alias Postern.Parser.PostgresqlConf
  alias Postern.SettingHistory
  alias Postern.StringSettings

  @error 1
  @warning 2
  @hint 4

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

  # A name the server does not know refuses the whole file, whatever the
  # name's story. The story goes on a second line: a dotted name is a
  # module's placeholder, and any other is looked up in the catalogs of the
  # other versions and in the history of the names from before them.
  defp setting_diagnostics(entry, nil, name, versions, catalog) do
    if String.contains?(name, "."),
      do: placeholder_diagnostic(entry, name, catalog),
      else: unknown_setting_diagnostic(entry, name, versions, catalog.version)
  end

  # A setting with the internal context, fixed by the build, by initdb or by
  # the server itself, is refused whatever its value, and the value is not
  # looked at, as set_config_option does not look at it.
  defp setting_diagnostics(
         entry,
         %{"context" => "internal"} = setting,
         _name,
         _versions,
         _catalog
       ),
       do: [
         diagnostic(entry.name_span, @error, ~s(parameter "#{setting["name"]}" cannot be changed))
       ]

  defp setting_diagnostics(entry, setting, _name, _versions, catalog) do
    case validate_value(entry.value, setting, catalog) do
      :ok -> []
      {:error, message} -> [diagnostic(entry.value_span, @error, message)]
    end
  end

  defp placeholder_diagnostic(entry, name, catalog) do
    [module | _rest] = String.split(name, ".", parts: 2)

    cond do
      module not in Catalog.modules(catalog) ->
        []

      catalog.version >= 15 ->
        [
          diagnostic(
            entry.name_span,
            @warning,
            ~s(invalid configuration parameter name "#{name}", removing it\n"#{module}" is now a reserved prefix.)
          )
        ]

      true ->
        [
          diagnostic(
            entry.name_span,
            @warning,
            ~s(unrecognized configuration parameter "#{name}")
          )
        ]
    end
  end

  # The server's message, and below it what became of the name, or the
  # closest catalog name, phrased the way the server phrases a hint.
  defp unknown_setting_diagnostic(entry, name, versions, target) do
    message = ~s(unrecognized configuration parameter "#{name}")

    message =
      case SettingHistory.note(name, target) || suggestion(name, versions) do
        nil -> message
        note -> message <> "\n" <> note
      end

    [diagnostic(entry.name_span, @error, message)]
  end

  defp suggestion(name, versions) do
    versions
    |> Enum.flat_map(fn version -> Catalog.load(version).settings |> Map.keys() end)
    |> Enum.uniq()
    |> Enum.map(&{jaro(String.downcase(name), String.downcase(&1)), &1})
    |> Enum.sort_by(fn {score, candidate} -> {-score, candidate} end)
    |> Enum.find(fn {score, _candidate} -> score >= 0.80 end)
    |> case do
      {_score, candidate} -> ~s(Perhaps you meant "#{candidate}".)
      nil -> nil
    end
  end

  # A value is read the way parse_and_validate_value reads it, and refused in
  # the server's words: the message it logs, and on a second line the hint
  # it adds, when it adds one.
  defp validate_value(value, setting, catalog) do
    case setting["vartype"] do
      "bool" -> validate_boolean(value, setting)
      "enum" -> validate_enum(value, setting)
      "integer" -> validate_integer(value, setting, catalog.version)
      "real" -> validate_real(value, setting, catalog.version)
      "string" -> validate_string(value, setting, catalog)
      _ -> :ok
    end
  end

  defp validate_string(value, setting, catalog) do
    case StringSettings.check(setting["name"], value, catalog, catalog.version) do
      :ok -> :ok
      {:invalid, detail} -> {:error, invalid(setting, value, detail)}
      {:error, message} -> {:error, message}
    end
  end

  defp validate_boolean(value, setting) do
    case GucValue.parse_bool(value) do
      {:ok, _boolean} -> :ok
      :error -> {:error, ~s(parameter "#{setting["name"]}" requires a Boolean value)}
    end
  end

  defp validate_integer(value, setting, version) do
    case GucValue.parse_int(value, GucValue.base(setting["unit"])) do
      {:ok, number} -> in_range(number, setting, version, &Integer.to_string/1, &integer/1)
      {:error, hint} -> {:error, invalid(setting, value, hint)}
    end
  end

  defp validate_real(value, setting, version) do
    case GucValue.parse_real(value, GucValue.base(setting["unit"])) do
      {:ok, number} -> in_range(number, setting, version, &GucValue.format_g/1, &real/1)
      {:error, hint} -> {:error, invalid(setting, value, hint)}
    end
  end

  # The value is printed in the setting's base unit with the unit's name,
  # and the bounds carry the name too from 17 on.
  defp in_range(number, setting, version, print, bound) do
    min = bound.(setting["min_val"])
    max = bound.(setting["max_val"])

    if (min != nil and less?(number, min)) or (max != nil and less?(max, number)) do
      unit = if setting["unit"], do: " " <> setting["unit"], else: ""
      bounds_unit = if version >= 17, do: unit, else: ""

      {:error,
       "#{print.(number)}#{unit} is outside the valid range for parameter " <>
         ~s|"#{setting["name"]}" (#{print.(min)}#{bounds_unit} .. #{print.(max)}#{bounds_unit})|}
    else
      :ok
    end
  end

  defp less?(:negative_infinity, _right), do: true
  defp less?(_left, :infinity), do: true
  defp less?(left, right) when is_atom(left) or is_atom(right), do: false
  defp less?(left, right), do: left < right

  defp invalid(setting, value, hint) do
    message = ~s(invalid value for parameter "#{setting["name"]}": "#{value}")
    if hint, do: message <> "\n" <> hint, else: message
  end

  defp integer(nil), do: nil

  defp integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp real(nil), do: nil

  defp real(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  # config_enum_lookup_by_name compares without regard to case and takes the
  # hidden spellings too, while the hint lists the visible values the way
  # config_enum_get_options prints them.
  defp validate_enum(value, setting) do
    enum_values = Catalog.array_literal(setting["enumvals"])
    hidden = Map.keys(setting["hidden_enumvals"] || %{})

    if String.downcase(value) in Enum.map(enum_values ++ hidden, &String.downcase/1) do
      :ok
    else
      {:error, invalid(setting, value, "Available values: #{Enum.join(enum_values, ", ")}.")}
    end
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
