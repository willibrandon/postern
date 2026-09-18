defmodule Postern.Symbols do
  @moduledoc """
  The outline of a file, as document symbols.

  postgresql.conf has the sections the sample file marks with a line of
  dashes above and below the title, and the subsections it marks with a
  dash on either side, with the assignments under each and the value as
  the detail. pg_hba.conf is one symbol per rule, named by its fields and
  detailed by its method. pg_ident.conf is one symbol per map, with its
  mappings as children. An include is a symbol of its own wherever it is.
  """

  alias GenLSP.Enumerations.SymbolKind
  alias GenLSP.Structures.DocumentSymbol
  alias GenLSP.Structures.Position
  alias GenLSP.Structures.Range
  alias Postern.Parser.PgHba
  alias Postern.Parser.PgIdent
  alias Postern.Parser.PostgresqlConf
  alias Postern.PgHbaOptions

  @doc "The symbols of a document of the kind, in order."
  @spec document_symbols(atom(), String.t(), pos_integer()) :: [DocumentSymbol.t()]
  def document_symbols(:postgresql_conf, text, _version) do
    {:ok, entries} = PostgresqlConf.parse(text)
    settings(entries)
  end

  def document_symbols(:pg_hba_conf, text, version) do
    {:ok, entries} = PgHba.parse(text, continuations: PgHbaOptions.continuations?(version))

    Enum.flat_map(entries, fn
      %{type: :rule} = rule -> [rule_symbol(rule)]
      %{type: :include} = include -> [include_symbol(include)]
      _entry -> []
    end)
  end

  def document_symbols(:pg_ident_conf, text, version) do
    {:ok, entries} = PgIdent.parse(text, continuations: PgHbaOptions.continuations?(version))
    maps(entries)
  end

  def document_symbols(_kind, _text, _version), do: []

  # A section opens with a title between two lines of dashes, a subsection
  # with a title between single dashes; each holds what follows until the
  # next of its rank.
  defp settings(entries) do
    entries
    |> Enum.reduce({[], []}, fn entry, {stack, done} -> place(entry, entries, stack, done) end)
    |> close_all()
  end

  defp place(%{type: :comment, span: span, text: text} = entry, entries, stack, done) do
    cond do
      section_title?(entry, entries) ->
        open(stack, done, symbol(title(text), nil, SymbolKind.namespace(), span, span), 1)

      subsection_title?(text) ->
        open(stack, done, symbol(subtitle(text), nil, SymbolKind.namespace(), span, span), 2)

      true ->
        {stack, done}
    end
  end

  defp place(%{type: :assignment} = entry, _entries, stack, done) do
    symbol =
      symbol(entry.name, entry.raw_value, SymbolKind.property(), entry.span, entry.name_span)

    add(stack, done, symbol)
  end

  defp place(%{type: :include} = entry, _entries, stack, done),
    do: add(stack, done, include_symbol(entry))

  defp place(_entry, _entries, stack, done), do: {stack, done}

  # A dashed line, the title, and a dashed line again, as the sample writes them.
  defp section_title?(%{text: text, span: %{line: line}}, entries) do
    before = Enum.at(entries, line - 2)
    after_ = Enum.at(entries, line)

    not dashes?(text) and String.starts_with?(String.trim(text), "#") and
      dashes?(before) and dashes?(after_)
  end

  defp dashes?(%{type: :comment, text: text}), do: Regex.match?(~r/^\s*#-{10,}\s*$/, text)
  defp dashes?(text) when is_binary(text), do: Regex.match?(~r/^\s*#-{10,}\s*$/, text)
  defp dashes?(_other), do: false

  defp subsection_title?(text), do: Regex.match?(~r/^\s*#\s+-\s+.+\s+-\s*$/, text)

  defp title(text), do: text |> String.trim() |> String.trim_leading("#") |> String.trim()

  defp subtitle(text) do
    text
    |> String.trim()
    |> String.trim_leading("#")
    |> String.trim()
    |> String.trim("-")
    |> String.trim()
  end

  # The stack holds the open section and subsection, each with its rank;
  # opening one closes those of the same or a lower rank, top first, each
  # into the one below it or, at the bottom, into the outline.
  defp open(stack, done, symbol, rank) do
    {stack, done} = close(stack, done, rank)
    {[{symbol, rank} | stack], done}
  end

  defp close([{top, top_rank} | rest], done, rank) when top_rank >= rank do
    case rest do
      [] ->
        close([], done ++ [top], rank)

      [{parent, parent_rank} | more] ->
        close([{with_child(parent, top), parent_rank} | more], done, rank)
    end
  end

  defp close(stack, done, _rank), do: {stack, done}

  defp close_all({stack, done}), do: stack |> close(done, 0) |> elem(1)

  defp add([], done, symbol), do: {[], done ++ [symbol]}

  defp add([{parent, rank} | rest], done, symbol),
    do: {[{with_child(parent, symbol), rank} | rest], done}

  defp with_child(parent, child),
    do: %{
      parent
      | children: (parent.children || []) ++ [child],
        range: extend(parent.range, child.range)
    }

  defp extend(range, other), do: %{range | end: max_position(range.end, other.end)}

  defp max_position(a, b), do: if({a.line, a.character} >= {b.line, b.character}, do: a, else: b)

  defp rule_symbol(%{tokens: tokens, auth_method: method, method_span: method_span} = rule) do
    fields =
      tokens |> Enum.take_while(&(&1.span != method_span)) |> Enum.map_join(" ", & &1.value)

    symbol(fields, method, SymbolKind.object(), rule.span, rule.span)
  end

  defp include_symbol(%{directive: directive, file: file, span: span}),
    do: symbol(file, directive, SymbolKind.file(), span, span)

  # A map's symbol spans its first mapping to its last, wherever they are.
  defp maps(entries) do
    Enum.reduce(entries, [], fn
      %{type: :include} = include, acc -> acc ++ [include_symbol(include)]
      %{type: :mapping} = mapping, acc -> place_mapping(mapping, acc)
      _entry, acc -> acc
    end)
  end

  defp place_mapping(mapping, acc) do
    child =
      symbol(
        "#{mapping.system_user} #{mapping.pg_user}",
        nil,
        SymbolKind.property(),
        mapping.span,
        mapping.system_span
      )

    case Enum.find_index(acc, &(&1.kind == SymbolKind.namespace() and &1.name == mapping.map)) do
      nil ->
        map = symbol(mapping.map, nil, SymbolKind.namespace(), mapping.span, mapping.map_span)
        acc ++ [with_child(map, child)]

      index ->
        List.update_at(acc, index, &with_child(&1, child))
    end
  end

  defp symbol(name, detail, kind, span, selection) do
    %DocumentSymbol{
      name: name,
      detail: detail,
      kind: kind,
      range: range(span),
      selection_range: range(selection),
      children: []
    }
  end

  defp range(%{line: line, col: col, end_line: end_line, end_col: end_col}) do
    %Range{
      start: %Position{line: line - 1, character: col - 1},
      end: %Position{line: end_line - 1, character: end_col - 1}
    }
  end
end
