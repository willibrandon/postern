defmodule Postern.Features do
  @moduledoc """
  Implements hover and completion features.

  PostgreSQL configuration metadata comes from generated catalogs. HBA
  completion keywords are protocol-level grammar terms, not setting metadata.
  """

  alias GenLSP.Enumerations.CodeActionKind
  alias GenLSP.Enumerations.CompletionItemKind
  alias GenLSP.Enumerations.MarkupKind
  alias GenLSP.Structures.CodeAction
  alias GenLSP.Structures.Command
  alias GenLSP.Structures.CompletionItem
  alias GenLSP.Structures.CompletionList
  alias GenLSP.Structures.Hover
  alias GenLSP.Structures.MarkupContent
  alias GenLSP.Structures.Position
  alias GenLSP.Structures.Range
  alias Postern.Catalog
  alias Postern.FileKind
  alias Postern.Parser.PostgresqlConf
  alias Postern.PgHbaOptions

  @connection_types ~w(local host hostssl hostnossl hostgssenc hostnogssenc)
  @auth_methods ~w(trust reject scram-sha-256 md5 password gss sspi ident peer ldap radius cert pam bsd oauth)
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
      :postgresql_conf -> postgresql_hover(text, position, options)
      _ -> nil
    end
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

  defp postgresql_hover(text, position, options) do
    {:ok, entries} = PostgresqlConf.parse(text)

    with %{type: :assignment, name: name} = entry <- entry_at(entries, position),
         version <-
           Postern.PostgresqlConfDiagnostics.target_version(text, options, Catalog.versions()),
         catalog <- Catalog.load(version),
         setting when not is_nil(setting) <- Catalog.fetch(catalog, name) do
      first_version = first_version(name)
      contents = hover_markdown(setting, version, first_version)

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
        optional_detail("Unit", setting["unit"]),
        optional_detail("Default", setting["reset_val"] || setting["boot_val"]),
        range_detail(setting),
        optional_detail("Context", setting["context"]),
        "**PostgreSQL:** #{version} (first appeared in #{first_version})"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("  \n")

    note =
      if setting["context"] == "postmaster",
        do: "\n\nA change takes effect after a server restart.",
        else: ""

    "### `#{setting["name"]}`\n\n#{description}\n\n#{details}#{note}"
  end

  defp optional_detail(_label, nil), do: nil
  defp optional_detail(_label, ""), do: nil
  defp optional_detail(label, value), do: "**#{label}:** `#{value}`"

  defp range_detail(setting) do
    enum_values = setting["enumvals"]

    cond do
      is_list(enum_values) and enum_values != [] ->
        "**Values:** `#{Enum.join(enum_values, "`, `")}`"

      setting["min_val"] || setting["max_val"] ->
        "**Range:** `#{setting["min_val"] || "-∞"}` … `#{setting["max_val"] || "∞"}`"

      true ->
        nil
    end
  end

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

        setting = Catalog.fetch(Catalog.load(version), name)
        value_completion(setting, prefix)

      _ ->
        version =
          Postern.PostgresqlConfDiagnostics.target_version(text, options, Catalog.versions())

        Catalog.load(version).settings
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(String.downcase(&1), String.downcase(prefix)))
        |> Enum.map(&completion_item(&1, CompletionItemKind.keyword(), "PostgreSQL setting"))
    end
  end

  defp value_completion(nil, _prefix), do: []

  defp value_completion(setting, prefix) do
    values =
      case setting["vartype"] do
        "enum" -> enum_values(setting["enumvals"])
        "bool" -> @boolean_values
        _ -> []
      end

    values
    |> Enum.filter(&String.starts_with?(String.downcase(&1), String.downcase(prefix)))
    |> Enum.map(&completion_item(&1, CompletionItemKind.value(), setting["vartype"]))
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

  defp hba_candidates(["local", _database, _user], _live, _version), do: @auth_methods

  defp hba_candidates(["local", _database, _user, method | _options], _live, version),
    do: PgHbaOptions.for_rule("local", method, version)

  defp hba_candidates([type, _database, _user], _live, _version) when type in @connection_types,
    do: @address_keywords

  defp hba_candidates([type, _database, _user, _address], _live, _version)
       when type in @connection_types,
       do: @auth_methods

  defp hba_candidates([type, _database, _user, _address, method | _options], _live, version)
       when type in @connection_types,
       do: PgHbaOptions.for_rule(type, method, version)

  defp hba_candidates(_fields, _live, version),
    do: @connection_types ++ @auth_methods ++ @address_keywords ++ PgHbaOptions.all(version)

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

  defp enum_values(values) when is_list(values), do: values
  defp enum_values(nil), do: []

  defp enum_values(values) when is_binary(values) do
    values
    |> String.trim_leading("{")
    |> String.trim_trailing("}")
    |> String.split(",", trim: true)
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
    case Regex.run(~r/([A-Za-z_][A-Za-z0-9_.-]*)$/, before, capture: :all_but_first) do
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
