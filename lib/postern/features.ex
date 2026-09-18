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
  alias GenLSP.Structures.WorkspaceEdit
  alias Postern.Catalog
  alias Postern.ConfigTree
  alias Postern.Diagnostics
  alias Postern.Docs
  alias Postern.FileKind
  alias Postern.Files
  alias Postern.Parser.PgHba
  alias Postern.Parser.PgIdent
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
      :pg_hba_conf -> hba_hover(text, position, options)
      :pg_ident_conf -> ident_hover(text, position, options)
      _ -> nil
    end
  end

  # The token under the cursor and what it is to the rule: the connection
  # type, one of the fields, the method, or an option, each with the words
  # the manual has for it.
  defp hba_hover(text, position, options) do
    version = Postern.PostgresqlConfDiagnostics.target_version(text, options, Catalog.versions())
    docs = Docs.load(version)
    {:ok, entries} = PgHba.parse(text, continuations: PgHbaOptions.continuations?(version))

    with %{tokens: tokens} = entry <-
           Enum.find(entries, &(&1.type in [:rule, :include] and covers?(&1, position))),
         {token, index} <-
           Enum.find(Enum.with_index(tokens), fn {token, _index} ->
             within?(token.span, position)
           end),
         {title, body} when is_binary(body) <- hba_words(entry, token, index, docs) do
      %Hover{
        contents: %MarkupContent{kind: MarkupKind.markdown(), value: "### #{title}\n\n#{body}"},
        range: span_to_range(token.span)
      }
    else
      _ -> nil
    end
  end

  defp hba_words(%{type: :include, directive: directive}, _token, 0, docs),
    do: {"`#{directive}`", Docs.hba(docs, directive)}

  defp hba_words(%{type: :include}, _token, _index, _docs), do: {nil, nil}

  defp hba_words(%{type: :rule}, token, 0, docs),
    do: {"`#{token.value}`", Docs.hba(docs, token.value)}

  defp hba_words(%{type: :rule}, _token, 1, docs), do: {"database", Docs.hba(docs, "database")}
  defp hba_words(%{type: :rule}, _token, 2, docs), do: {"user", Docs.hba(docs, "user")}

  defp hba_words(%{type: :rule, connection_type: type, netmask: mask} = rule, token, index, docs) do
    cond do
      token.span == rule.method_span ->
        {"`#{token.value}`", method_words(docs, token.value)}

      type != "local" and index == 3 ->
        if mask,
          do: {"IP-address", Docs.hba(docs, "IP-address")},
          else: {"address", Docs.hba(docs, "address")}

      type != "local" and index == 4 and mask != nil ->
        {"IP-mask", Docs.hba(docs, "IP-mask")}

      true ->
        name = token.value |> String.split("=", parts: 2) |> hd()
        {"`#{name}`", Docs.option(docs, rule.auth_method, name)}
    end
  end

  # The method's own entry, and the title of the section that treats it.
  defp method_words(docs, method) do
    case {Docs.hba(docs, method), Docs.method_section(docs, method)} do
      {nil, _section} -> nil
      {text, nil} -> text
      {text, section} -> text <> "\n\nThe manual treats it under \"#{section}\"."
    end
  end

  # A pg_ident.conf token gets the field it stands in and the section's
  # opening, which says how the three fields are read.
  defp ident_hover(text, position, options) do
    version = Postern.PostgresqlConfDiagnostics.target_version(text, options, Catalog.versions())
    docs = Docs.load(version)
    {:ok, entries} = PgIdent.parse(text, continuations: PgHbaOptions.continuations?(version))

    with %{type: :mapping, tokens: tokens} <-
           Enum.find(entries, &(&1.type == :mapping and covers?(&1, position))),
         {token, index} <-
           Enum.find(Enum.with_index(tokens), fn {token, _index} ->
             within?(token.span, position)
           end),
         body when is_binary(body) <- Docs.maps(docs) do
      title = Enum.at(["map name", "system user name", "PostgreSQL user name"], index)

      %Hover{
        contents: %MarkupContent{
          kind: MarkupKind.markdown(),
          value: "### #{title} `#{token.value}`\n\n#{body}"
        },
        range: span_to_range(token.span)
      }
    else
      _ -> nil
    end
  end

  defp covers?(%{span: span}, position),
    do: span.line - 1 <= position.line and position.line <= span.end_line - 1

  defp within?(span, position) do
    line = position.line + 1
    col = position.character + 1

    (span.line < line or (span.line == line and span.col <= col)) and
      (line < span.end_line or (line == span.end_line and col <= span.end_col))
  end

  @doc """
  Where the value that counts for the setting under the cursor is set, when
  that is another line of the tree; from a `map=` option or a map name, the
  first line of the map in pg_ident.conf; or `nil`.
  """
  @spec definition(String.t(), String.t(), Position.t(), map() | keyword()) :: Location.t() | nil
  def definition(uri, text, position, options \\ %{}) do
    case option(options, :kind) || FileKind.detect(uri) do
      :postgresql_conf ->
        setting_definition(uri, text, position, options)

      kind when kind in [:pg_hba_conf, :pg_ident_conf] ->
        map_definition(uri, text, position, options)

      _ ->
        nil
    end
  end

  defp setting_definition(uri, text, position, options) do
    {:ok, entries} = PostgresqlConf.parse(text)

    with %{type: :assignment} = entry <- entry_at(entries, position),
         %{path: path, entry: winner} <- elsewhere(uri, entry, options) do
      %Location{uri: FileKind.path_to_uri(path), range: span_to_range(winner.name_span)}
    else
      _ -> nil
    end
  end

  defp map_definition(uri, text, position, options) do
    with {:ok, name, _span} <- map_at(uri, text, position, options),
         [location | _rest] <- map_definitions(uri, text, name, options) do
      location
    else
      _ -> nil
    end
  end

  @doc """
  Every place a map name stands: the lines that define it in pg_ident.conf
  first, then the rules that name it with `map=` in pg_hba.conf, across both
  trees.
  """
  @spec references(String.t(), String.t(), Position.t(), map() | keyword()) :: [Location.t()]
  def references(uri, text, position, options \\ %{}) do
    case map_at(uri, text, position, options) do
      {:ok, name, _span} ->
        map_definitions(uri, text, name, options) ++ map_uses(uri, text, name, options)

      _ ->
        []
    end
  end

  @doc "The range of the map name under the cursor, when there is one to rename."
  @spec prepare_rename(String.t(), String.t(), Position.t(), map() | keyword()) :: Range.t() | nil
  def prepare_rename(uri, text, position, options \\ %{}) do
    case map_at(uri, text, position, options) do
      {:ok, _name, span} -> span_to_range(span)
      _ -> nil
    end
  end

  @doc """
  The edits that rename the map under the cursor everywhere it stands, or
  `nil` for a name the files could not carry as one token.
  """
  @spec rename(String.t(), String.t(), Position.t(), String.t(), map() | keyword()) ::
          WorkspaceEdit.t() | nil
  def rename(uri, text, position, new_name, options \\ %{}) do
    with true <- Regex.match?(~r/^[^\s,"#]+$/, new_name),
         [_location | _rest] = locations <- references(uri, text, position, options) do
      changes =
        locations
        |> Enum.group_by(& &1.uri, &%TextEdit{range: &1.range, new_text: new_name})
        |> Map.new()

      %WorkspaceEdit{changes: changes}
    else
      _ -> nil
    end
  end

  # The map name under the cursor: the value of a map= option on a
  # pg_hba.conf rule, or the first field of a pg_ident.conf mapping.
  defp map_at(uri, text, position, options) do
    version = Postern.PostgresqlConfDiagnostics.target_version(text, options, Catalog.versions())
    continuations = [continuations: PgHbaOptions.continuations?(version)]

    case option(options, :kind) || FileKind.detect(uri) do
      :pg_hba_conf -> hba_map_at(PgHba.parse(text, continuations), position)
      :pg_ident_conf -> ident_map_at(PgIdent.parse(text, continuations), position)
      _kind -> :none
    end
  end

  defp hba_map_at({:ok, entries}, position) do
    with %{type: :rule, tokens: tokens} <-
           Enum.find(entries, &(&1.type == :rule and covers?(&1, position))),
         %{} = token <- Enum.find(tokens, &(map_option?(&1) and within?(&1.span, position))) do
      {:ok, map_value(token), map_value_span(token)}
    else
      _ -> :none
    end
  end

  defp ident_map_at({:ok, entries}, position) do
    case Enum.find(entries, &(&1.type == :mapping and within?(&1.map_span, position))) do
      %{map: name, map_span: span} -> {:ok, name, span}
      nil -> :none
    end
  end

  defp map_option?(%{raw: raw}),
    do: String.starts_with?(raw, "map=") or String.starts_with?(raw, ~s("map=))

  defp map_value(%{value: value}),
    do: value |> String.split("=", parts: 2) |> List.last() |> String.trim("\"")

  # The value's own span inside the map=value token, quotes left out.
  defp map_value_span(%{raw: raw, span: span}) do
    {prefix, suffix} =
      cond do
        String.starts_with?(raw, ~s(map=")) -> {5, 1}
        String.starts_with?(raw, ~s("map=)) -> {5, 1}
        true -> {4, 0}
      end

    %{span | col: span.col + prefix, end_col: span.end_col - suffix}
  end

  defp map_definitions(uri, text, name, options) do
    {ident_tree, hba_tree} = map_trees(uri, text, options)
    _ = hba_tree

    for %{path: path, entry: %{type: :mapping, map: ^name, map_span: span}} <- entries(ident_tree),
        do: %Location{uri: FileKind.path_to_uri(path), range: span_to_range(span)}
  end

  defp map_uses(uri, text, name, options) do
    {_ident_tree, hba_tree} = map_trees(uri, text, options)

    for %{path: path, entry: %{type: :rule, tokens: tokens}} <- entries(hba_tree),
        token <- tokens,
        map_option?(token) and map_value(token) == name,
        do: %Location{
          uri: FileKind.path_to_uri(path),
          range: span_to_range(map_value_span(token))
        }
  end

  # The pg_ident.conf and pg_hba.conf trees, whichever file the document is,
  # or the document alone when there is no reader to find the other with.
  defp map_trees(uri, text, options) do
    kind = option(options, :kind) || FileKind.detect(uri)
    path = path_of(uri)

    case Diagnostics.related_trees(kind, path, text, options) do
      {nil, nil} ->
        version =
          Postern.PostgresqlConfDiagnostics.target_version(text, options, Catalog.versions())

        {:ok, entries} =
          ConfigTree.parse(kind, text, continuations: PgHbaOptions.continuations?(version))

        own = %{entries: Enum.map(entries, &%{path: path, entry: &1})}
        if kind == :pg_ident_conf, do: {own, nil}, else: {nil, own}

      {tree, other} ->
        if kind == :pg_ident_conf, do: {tree, other}, else: {other, tree}
    end
  end

  defp entries(nil), do: []
  defp entries(%{entries: entries}), do: entries

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
        :pg_hba_conf -> hba_completion(uri, text, position, options)
        :pg_ident_conf -> ident_completion(uri, text, position, options)
        _ -> []
      end

    %CompletionList{is_incomplete: false, items: items}
  end

  # Every map name the two trees know: the ones pg_ident.conf defines and
  # the ones pg_hba.conf names, so a map used but not yet defined is offered
  # where it would be defined.
  defp map_names(uri, text, options) do
    {ident_tree, hba_tree} = map_trees(uri, text, options)

    defined = for %{entry: %{type: :mapping, map: name}} <- entries(ident_tree), do: name

    used =
      for %{entry: %{type: :rule, tokens: tokens}} <- entries(hba_tree),
          token <- tokens,
          map_option?(token),
          do: map_value(token)

    Enum.uniq(defined ++ used)
  end

  # A map name on a new line, and with a live connection the PostgreSQL user
  # names in the third field.
  defp ident_completion(uri, text, position, options) do
    line = line_at(text, position.line)
    before = String.slice(line, 0, min(position.character, String.length(line)))
    prefix = word_prefix(before)
    fields = String.split(String.trim(before), ~r/\s+/, trim: true)

    complete_fields =
      if String.ends_with?(before, [" ", "\t"]), do: fields, else: Enum.drop(fields, -1)

    candidates =
      case length(complete_fields) do
        0 -> map_names(uri, text, options)
        2 -> live_values(options).roles
        _other -> []
      end

    candidates
    |> Enum.uniq()
    |> Enum.filter(&String.starts_with?(String.downcase(&1), String.downcase(prefix)))
    |> Enum.map(&completion_item(&1, CompletionItemKind.value(), "pg_ident.conf"))
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

  defp hba_completion(uri, text, position, options) do
    line = line_at(text, position.line)
    before = String.slice(line, 0, min(position.character, String.length(line)))
    prefix = word_prefix(before)
    fields = String.split(String.trim(before), ~r/\s+/, trim: true)

    complete_fields =
      if String.ends_with?(before, [" ", "\t"]), do: fields, else: Enum.drop(fields, -1)

    version = Postern.PostgresqlConfDiagnostics.target_version(text, options, Catalog.versions())

    # After map= the names come from pg_ident.conf rather than the grammar.
    {candidates, kind} =
      if Regex.match?(~r/(?:^|\s)"?map=[^\s]*$/, before),
        do: {map_names(uri, text, options), CompletionItemKind.value()},
        else:
          {hba_candidates(complete_fields, live_values(options), version),
           CompletionItemKind.keyword()}

    candidates
    |> Enum.uniq()
    |> Enum.filter(&String.starts_with?(String.downcase(&1), String.downcase(prefix)))
    |> Enum.map(&completion_item(&1, kind, "pg_hba.conf"))
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
