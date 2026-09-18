defmodule Postern.Features do
  @moduledoc """
  Implements hover, completion, definition and document links.

  PostgreSQL configuration metadata comes from generated catalogs. HBA
  completion keywords are protocol-level grammar terms, not setting metadata.
  With a `:reader` from `Postern.Files` in the options, hover says where the
  value that counts for a setting is set, definition goes there, and an
  include line links to the file it names.
  """

  alias GenLSP.Enumerations.CodeActionKind
  alias GenLSP.Enumerations.CompletionItemKind
  alias GenLSP.Enumerations.MarkupKind
  alias GenLSP.Structures.CodeAction
  alias GenLSP.Structures.Command
  alias GenLSP.Structures.CompletionItem
  alias GenLSP.Structures.CompletionList
  alias GenLSP.Structures.DocumentLink
  alias GenLSP.Structures.Hover
  alias GenLSP.Structures.Location
  alias GenLSP.Structures.MarkupContent
  alias GenLSP.Structures.Position
  alias GenLSP.Structures.Range
  alias GenLSP.Structures.TextEdit
  alias Postern.Catalog
  alias Postern.ConfigTree
  alias Postern.FileKind
  alias Postern.Files
  alias Postern.Parser.PostgresqlConf
  alias Postern.PgHbaOptions
  alias Postern.StringSettings

  @connection_types ~w(local host hostssl hostnossl hostgssenc hostnogssenc)
  @address_keywords ~w(all samehost samenet)
  @boolean_values ~w(on off true false yes no 1 0)

  @doc """
  Returns hover information for a document position, or `nil`.

  The file kind is `:kind` in the options when the caller knows it, and is
  otherwise detected from the URI.
  """
  @spec hover(String.t(), String.t(), Position.t(), map() | keyword()) :: Hover.t() | nil
  def hover(uri, text, position, options \\ %{}) do
    case option(options, :kind) || FileKind.detect(uri) do
      :postgresql_conf -> postgresql_hover(uri, text, position, options)
      _ -> nil
    end
  end

  @doc """
  Where the value that counts for the setting under the cursor is set, when
  that is another line of the tree, or `nil`.
  """
  @spec definition(String.t(), String.t(), Position.t(), map() | keyword()) :: Location.t() | nil
  def definition(uri, text, position, options \\ %{}) do
    with :postgresql_conf <- option(options, :kind) || FileKind.detect(uri),
         {:ok, entries} = PostgresqlConf.parse(text),
         %{type: :assignment} = entry <- entry_at(entries, position),
         %{path: path, entry: winner} <- elsewhere(uri, entry, options) do
      %Location{uri: FileKind.path_to_uri(path), range: span_to_range(winner.name_span)}
    else
      _ -> nil
    end
  end

  @doc """
  Links from the include lines to the files they name, and from a pg_hba.conf
  field that names a file of names with `@`, for the ones that are there.
  """
  @spec document_links(String.t(), String.t(), map() | keyword()) :: [DocumentLink.t()]
  def document_links(uri, text, options \\ %{}) do
    with kind when kind != :unknown <- option(options, :kind) || FileKind.detect(uri),
         %Files{read: read} <- option(options, :reader) do
      path = path_of(uri)
      {:ok, entries} = ConfigTree.parse(kind, text)

      Enum.flat_map(entries, &entry_links(&1, path, read))
    else
      _ -> []
    end
  end

  defp entry_links(%{type: :include, directive: "include_dir"}, _path, _read), do: []

  defp entry_links(%{type: :include, file: file} = entry, path, read),
    do: link(ConfigTree.include_span(entry), ConfigTree.absolute(file, path), read)

  # The database and user fields of a rule, when they name a file.
  defp entry_links(%{type: :rule, tokens: tokens}, path, read) do
    for %{value: "@" <> file, span: span} <- Enum.slice(tokens, 1, 2),
        link <- link(span, ConfigTree.absolute(file, path), read),
        do: link
  end

  defp entry_links(_entry, _path, _read), do: []

  defp link(span, target, read) do
    if match?({:ok, _text}, read.(target)),
      do: [%DocumentLink{range: span_to_range(span), target: FileKind.path_to_uri(target)}],
      else: []
  end

  @doc "Quick fixes for diagnostics in the request context that carry one."
  @spec code_actions([map()]) :: [CodeAction.t()]
  def code_actions(diagnostics) do
    if Enum.any?(diagnostics, &trust_diagnostic?/1) do
      [
        %CodeAction{
          title: "Stop reporting trust on non-local rules",
          kind: CodeActionKind.quick_fix(),
          diagnostics: Enum.filter(diagnostics, &trust_diagnostic?/1),
          command: %Command{
            title: "Stop reporting trust on non-local rules",
            command: "postern.disableTrustHints",
            arguments: []
          }
        }
      ]
    else
      []
    end
  end

  @doc "Whether a diagnostic is the hint about trust on a non-local rule."
  def trust_diagnostic?(%{source: "postern", code: "trust"}), do: true
  def trust_diagnostic?(_diagnostic), do: false

  @doc """
  Every command a code action can carry. Advertised at initialize, because
  Zed and Neovim run only commands the server lists.
  """
  def commands, do: ["postern.disableTrustHints" | Postern.LiveFeatures.commands()]

  @doc "Returns completion items for a document position."
  @spec completion(String.t(), String.t(), Position.t(), map() | keyword()) :: CompletionList.t()
  def completion(uri, text, position, options \\ %{}) do
    items =
      case option(options, :kind) || FileKind.detect(uri) do
        :postgresql_conf -> postgresql_completion(text, position, options)
        :pg_hba_conf -> hba_completion(text, position, options)
        _ -> []
      end

    %CompletionList{is_incomplete: false, items: items}
  end

  defp postgresql_hover(uri, text, position, options) do
    {:ok, entries} = PostgresqlConf.parse(text)

    with %{type: :assignment, name: name} = entry <- entry_at(entries, position),
         version <-
           Postern.PostgresqlConfDiagnostics.target_version(text, options, Catalog.versions()),
         catalog <- Catalog.load(version),
         setting when not is_nil(setting) <- Catalog.fetch(catalog, name) do
      first_version = first_version(name)

      contents =
        hover_markdown(setting, version, first_version) <> override_note(uri, entry, options)

      %Hover{
        contents: %MarkupContent{kind: MarkupKind.markdown(), value: contents},
        range: span_to_range(entry.name_span)
      }
    else
      _ -> nil
    end
  end

  defp hover_markdown(setting, version, first_version) do
    description =
      [setting["short_desc"], setting["extra_desc"]]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("\n\n")

    details =
      [
        "**Type:** `#{setting["vartype"]}`",
        optional_detail("Module", setting["module"]),
        optional_detail("Unit", setting["unit"]),
        optional_detail("Default", setting["boot_val"]),
        range_detail(setting),
        hidden_detail(setting),
        optional_detail("Context", setting["context"]),
        "**PostgreSQL:** #{version} (first appeared in #{first_version})"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("  \n")

    note =
      case setting["context"] do
        "postmaster" ->
          "\n\nA change takes effect after a server restart."

        "internal" ->
          "\n\nA configuration file cannot change it: the build, initdb or the server itself fixed it."

        _other ->
          ""
      end

    "### `#{setting["name"]}`\n\n#{description}\n\n#{details}#{note}"
  end

  # Where the value that counts is set, when it is not this line.
  defp override_note(uri, entry, options) do
    case elsewhere(uri, entry, options) do
      nil ->
        ""

      %{path: path, entry: winner} ->
        where =
          if path == path_of(uri),
            do: "line #{winner.span.line}",
            else: "`#{ConfigTree.relative(path, path_of(uri))}` line #{winner.span.line}"

        "\n\n**Overridden by:** #{where}, where it is `#{winner.raw_value}`"
    end
  end

  # The assignment the tree keeps for this entry's name, when it is another one.
  defp elsewhere(uri, entry, options) do
    path = path_of(uri)

    with %Files{} = files <- option(options, :reader),
         tree =
           ConfigTree.for_document(:postgresql_conf, path, files,
             workspace: option(options, :workspace)
           ),
         %{path: winner_path, entry: winner} = located <- ConfigTree.winner(tree, entry.name),
         false <- winner_path == path and winner.span.line == entry.span.line do
      located
    else
      _ -> nil
    end
  end

  defp path_of(uri), do: FileKind.canonical(FileKind.uri_to_path(uri))

  defp optional_detail(_label, nil), do: nil
  defp optional_detail(_label, ""), do: nil
  defp optional_detail(label, value), do: "**#{label}:** `#{value}`"

  defp range_detail(setting) do
    enum_values = Catalog.array_literal(setting["enumvals"])

    cond do
      is_list(enum_values) and enum_values != [] ->
        "**Values:** `#{Enum.join(enum_values, "`, `")}`"

      setting["min_val"] || setting["max_val"] ->
        "**Range:** `#{setting["min_val"] || "-∞"}` … `#{setting["max_val"] || "∞"}`"

      true ->
        nil
    end
  end

  # The spellings the server takes but does not list, each with the value it
  # stands for when the table says so.
  defp hidden_detail(%{"hidden_enumvals" => hidden})
       when is_map(hidden) and map_size(hidden) > 0 do
    taken =
      hidden
      |> Enum.sort()
      |> Enum.map_join(", ", fn
        {spelling, nil} -> "`#{spelling}`"
        {spelling, meaning} -> "`#{spelling}` as `#{meaning}`"
      end)

    "**Also taken:** " <> taken
  end

  defp hidden_detail(_setting), do: nil

  defp first_version(name) do
    Enum.find(Catalog.versions(), Catalog.latest(), fn version ->
      Catalog.fetch(Catalog.load(version), name) != nil
    end)
  end

  defp postgresql_completion(text, position, options) do
    line = line_at(text, position.line)
    before = String.slice(line, 0, min(position.character, String.length(line)))
    prefix = word_prefix(before)

    case Regex.run(~r/^\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*(?:=|\s)/, before) do
      [_, name] ->
        version =
          Postern.PostgresqlConfDiagnostics.target_version(text, options, Catalog.versions())

        catalog = Catalog.load(version)
        setting = Catalog.fetch(catalog, name)
        after_cursor = String.slice(line, min(position.character, String.length(line))..-1//1)

        range = %Range{
          start: %Position{
            line: position.line,
            character: position.character - String.length(prefix)
          },
          end: %Position{line: position.line, character: position.character}
        }

        value_completion(setting, prefix, before, after_cursor, catalog, range)

      _ ->
        version =
          Postern.PostgresqlConfDiagnostics.target_version(text, options, Catalog.versions())

        catalog = Catalog.load(version)

        catalog.settings
        |> Enum.reject(fn {_name, setting} -> setting["context"] == "internal" end)
        |> Enum.map(fn {name, _setting} -> name end)
        |> Enum.filter(&String.starts_with?(String.downcase(&1), String.downcase(prefix)))
        |> Enum.sort()
        |> Enum.map(&name_item(&1, Catalog.fetch(catalog, &1)["module"]))
    end
  end

  defp name_item(name, nil),
    do: completion_item(name, CompletionItemKind.keyword(), "PostgreSQL setting")

  defp name_item(name, module),
    do: completion_item(name, CompletionItemKind.keyword(), "#{module} setting")

  defp value_completion(nil, _prefix, _before, _after_cursor, _catalog, _range), do: []

  # The edit replaces the prefix itself, since a value such as a time zone
  # holds characters an editor does not count as part of a word.
  defp value_completion(setting, prefix, before, after_cursor, catalog, range) do
    values =
      case setting["vartype"] do
        "enum" -> Catalog.array_literal(setting["enumvals"])
        "bool" -> @boolean_values
        "string" -> StringSettings.completions(setting["name"], catalog, catalog.version)
        _ -> []
      end

    opened = quote_open?(String.slice(before, 0..-(String.length(prefix) + 1)//1))
    closed = String.starts_with?(after_cursor, "'")
    list? = StringSettings.list?(setting["name"])

    values
    |> Enum.filter(&String.starts_with?(String.downcase(&1), String.downcase(prefix)))
    |> Enum.map(fn value ->
      text = value_text(value, opened, closed, list?)

      %CompletionItem{
        completion_item(value, CompletionItemKind.value(), setting["vartype"])
        | insert_text: text,
          text_edit: %TextEdit{range: range, new_text: text}
      }
    end)
  end

  # A value the file takes bare is a letter followed by letters, digits and a
  # few punctuation marks, or a number; anything else, such as an isolation
  # level with a space in it, is quoted. Inside a quote the editor has left
  # open the closing one is added, unless the setting is a list that may go
  # on after the value.
  defp value_text(value, opened, closed, list?) do
    cond do
      Regex.match?(~r{^[A-Za-z_][A-Za-z0-9_.:/-]*$}, value) -> value
      Regex.match?(~r/^[+-]?[0-9]+$/, value) -> value
      opened and (closed or list?) -> value
      opened -> value <> "'"
      true -> "'" <> value <> "'"
    end
  end

  # Whether a single quote is open at the end of the text, with '' counting
  # as a quote inside quotes rather than a pair.
  defp quote_open?(text) do
    text
    |> String.replace("''", "")
    |> String.graphemes()
    |> Enum.count(&(&1 == "'"))
    |> rem(2) == 1
  end

  defp hba_completion(text, position, options) do
    line = line_at(text, position.line)
    before = String.slice(line, 0, min(position.character, String.length(line)))
    prefix = word_prefix(before)
    fields = String.split(String.trim(before), ~r/\s+/, trim: true)

    complete_fields =
      if String.ends_with?(before, [" ", "\t"]), do: fields, else: Enum.drop(fields, -1)

    version = Postern.PostgresqlConfDiagnostics.target_version(text, options, Catalog.versions())
    candidates = hba_candidates(complete_fields, live_values(options), version)

    candidates
    |> Enum.uniq()
    |> Enum.filter(&String.starts_with?(String.downcase(&1), String.downcase(prefix)))
    |> Enum.map(&completion_item(&1, CompletionItemKind.keyword(), "pg_hba.conf"))
  end

  defp hba_candidates([], _live, _version), do: @connection_types

  defp hba_candidates([_type], live, _version),
    do: ~w(all sameuser samerole replication) ++ live.databases

  defp hba_candidates([type, _database], live, _version) when type in @connection_types,
    do: ~w(all +group) ++ live.roles

  defp hba_candidates(["local", _database, _user], _live, version),
    do: PgHbaOptions.methods(version)

  defp hba_candidates(["local", _database, _user, method | _options], _live, version),
    do: PgHbaOptions.for_rule("local", method, version)

  defp hba_candidates([type, _database, _user], _live, _version) when type in @connection_types,
    do: @address_keywords

  defp hba_candidates([type, _database, _user, _address], _live, version)
       when type in @connection_types,
       do: PgHbaOptions.methods(version)

  defp hba_candidates([type, _database, _user, _address, method | _options], _live, version)
       when type in @connection_types,
       do: PgHbaOptions.for_rule(type, method, version)

  defp hba_candidates(_fields, _live, version) do
    @connection_types ++
      PgHbaOptions.methods(version) ++ @address_keywords ++ PgHbaOptions.all(version)
  end

  defp live_values(options) do
    case option(options, :live_snapshot) do
      %{} = snapshot ->
        %{
          databases: Enum.map(snapshot[:databases] || [], & &1["datname"]),
          roles: Enum.map(snapshot[:roles] || [], & &1["rolname"])
        }

      _ ->
        %{databases: [], roles: []}
    end
  end

  defp option(options, key) when is_map(options), do: options[key] || options[Atom.to_string(key)]
  defp option(options, key) when is_list(options), do: Keyword.get(options, key)
  defp option(_options, _key), do: nil

  defp completion_item(label, kind, detail) do
    %CompletionItem{label: label, kind: kind, detail: detail}
  end

  defp entry_at(entries, position) do
    Enum.find(entries, fn
      %{type: :assignment, name_span: span} ->
        span.line == position.line + 1 and position.character + 1 >= span.col and
          position.character + 1 <= span.end_col

      _ ->
        false
    end)
  end

  defp line_at(text, line_number) do
    text |> String.split("\n", trim: false) |> Enum.at(line_number, "")
  end

  defp word_prefix(before) do
    case Regex.run(~r{([A-Za-z_][A-Za-z0-9_.:/-]*)$}, before, capture: :all_but_first) do
      [prefix] -> prefix
      _ -> ""
    end
  end

  defp span_to_range(%{line: line, col: col, end_line: end_line, end_col: end_col}) do
    %Range{
      start: %Position{line: line - 1, character: col - 1},
      end: %Position{line: end_line - 1, character: end_col - 1}
    }
  end
end
