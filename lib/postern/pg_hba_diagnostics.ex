defmodule Postern.PgHbaDiagnostics do
  @moduledoc """
  Offline diagnostics for `pg_hba.conf` rules.

  The parser supplies the rule AST. This module validates addresses and
  netmasks, authentication options, unsafe methods, rule reachability, and
  ident-map references.

  With a `:tree` from `Postern.ConfigTree` and the document's `:path` in the
  options, a rule is weighed against every rule the server reads before it,
  in this file or one included earlier, and an include the server could not
  follow gets its error. An `:ident_tree` supplies the maps from the whole
  `pg_ident.conf` tree.
  """

  alias GenLSP.Structures.Diagnostic
  alias GenLSP.Structures.Position
  alias GenLSP.Structures.Range
  alias Postern.ConfigTree
  alias Postern.Parser.PgHba
  alias Postern.Parser.PgIdent
  alias Postern.PgHbaOptions

  import Bitwise

  @error 1
  @warning 2
  @hint 4

  @host_types ~w(host hostssl hostnossl hostgssenc hostnogssenc)
  @address_keywords ~w(all samehost samenet)

  @doc """
  Returns diagnostics for a `pg_hba.conf` document.

  `ident_text` is the `pg_ident.conf` that goes with the file, when there is
  one to look at; without it `map=` names are not checked. `options` may carry
  `:report_trust` and the target PostgreSQL major version as `:version`;
  without one, the version comes from a `# postern: pg=N` comment or the
  newest catalog.
  """
  @spec diagnostics(String.t(), String.t() | nil, map()) :: [Diagnostic.t()]
  def diagnostics(text, ident_text \\ nil, options \\ %{}) when is_binary(text) do
    {:ok, entries} = PgHba.parse(text)
    tree = Map.get(options, :tree)
    path = if tree, do: Map.get(options, :path)
    maps = ident_maps(ident_text, Map.get(options, :ident_tree))
    report_trust = Map.get(options, :report_trust, true)
    version = Map.get(options, :version) || target_version(text, options)
    rules = located_rules(tree, entries)

    rule_diagnostics =
      rules
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{path: ^path, entry: rule}, index} ->
          rule_diagnostics(rule, version, maps, report_trust, path, Enum.take(rules, index))

        _elsewhere ->
          []
      end)

    parser_diagnostics(entries) ++
      directive_diagnostics(entries, version) ++
      rule_diagnostics ++ include_diagnostics(tree, path)
  end

  # The server stops at a method it does not know, so that is all it says
  # about the rule; the parser has already refused an address it would.
  defp rule_diagnostics(rule, version, maps, report_trust, path, previous) do
    address_advice(rule) ++
      case method_diagnostics(rule, version) do
        [] ->
          option_diagnostics(rule, version) ++
            unsafe_method_diagnostics(rule, report_trust) ++
            ident_reference_diagnostics(rule, maps, version) ++
            shadow_diagnostics(rule, path, previous) ++
            regex_diagnostics(rule, version)

        invalid_method ->
          invalid_method
      end
  end

  defp method_diagnostics(%{auth_method: method, method_span: span}, version) do
    if method in PgHbaOptions.methods(version),
      do: [],
      else: [diagnostic(span, @error, ~s(invalid authentication method "#{method}"))]
  end

  # The three directives arrived in 16; an older server reads the line as a
  # rule and refuses the first word as its connection type.
  defp directive_diagnostics(entries, version) do
    if PgHbaOptions.directives?(version) do
      []
    else
      for %{type: :include, directive: directive, tokens: [%{span: span} | _]} <- entries,
          do: diagnostic(span, @error, ~s(invalid connection type "#{directive}"))
    end
  end

  # A name that starts with a slash is a regular expression from 16 on; an
  # older server takes it for a name, and no database or role is called that.
  defp regex_diagnostics(%{databases: databases, users: users, span: span}, version) do
    if PgHbaOptions.regex?(version) do
      []
    else
      for name <- databases ++ users, String.starts_with?(name, "/") do
        diagnostic(
          span,
          @warning,
          ~s("#{name}" is a name to PostgreSQL #{version}; a regular expression here needs 16)
        )
      end
    end
  end

  # The rules in the order PostgreSQL reads them: this file's alone, or the
  # whole tree's with the file each one came from.
  defp located_rules(nil, entries),
    do: for(%{type: :rule} = rule <- entries, do: %{path: nil, entry: rule})

  defp located_rules(tree, _entries),
    do: for(%{entry: %{type: :rule}} = located <- tree.entries, do: located)

  defp include_diagnostics(nil, _path), do: []

  defp include_diagnostics(tree, path) do
    for %{path: ^path} = problem <- tree.problems,
        do: diagnostic(problem.span, problem.severity, problem.message)
  end

  defp parser_diagnostics(entries) do
    Enum.flat_map(entries, fn
      %{type: :error, message: message, span: span} -> [diagnostic(span, @error, message)]
      _ -> []
    end)
  end

  # What the server takes for a host name it looks up at connection time, so
  # a token that was meant as an address but does not parse deserves a word.
  defp address_advice(%{address_kind: :host, address: address, address_span: span}) do
    if Regex.match?(~r/^[0-9.]+$/, address) or String.contains?(address, ":") do
      [
        diagnostic(
          span,
          @warning,
          ~s("#{address}" is not an IP address, so PostgreSQL takes it for a host name)
        )
      ]
    else
      []
    end
  end

  defp address_advice(_rule), do: []

  # Each option is checked against the rule's connection type and method the
  # way hba.c checks it, and reported on the option itself.
  defp option_diagnostics(
         %{connection_type: type, auth_method: method, options: options} = rule,
         version
       ) do
    Enum.flat_map(options, fn {name, value} ->
      case PgHbaOptions.check(name, value, type, method, version) do
        :ok -> []
        {:error, message} -> [diagnostic(option_span(rule, name), @error, message)]
      end
    end)
  end

  defp option_span(%{tokens: tokens, span: span}, name) do
    Enum.find_value(tokens, span, fn token ->
      if token.raw == name or String.starts_with?(token.raw, name <> "="), do: token.span
    end)
  end

  # A deliberate choice on many development setups, so this is advice rather
  # than a problem, and loopback rules are left alone entirely.
  defp unsafe_method_diagnostics(_rule, false), do: []

  defp unsafe_method_diagnostics(
         %{connection_type: type, auth_method: method, address: address, span: span},
         _report
       ) do
    if type in @host_types and method in ["trust", "password"] and not loopback?(address) do
      [
        %{
          diagnostic(span, @hint, "#{method} authentication is used on a non-local rule")
          | code: "trust"
        }
      ]
    else
      []
    end
  end

  defp loopback?(nil), do: true

  defp loopback?(address) do
    host = address |> String.split("/") |> hd()
    host in ~w(127.0.0.1 ::1 localhost samehost) or String.starts_with?(host, "127.")
  end

  defp ident_reference_diagnostics(_rule, nil, _version), do: []

  defp ident_reference_diagnostics(
         %{auth_method: method, options: options} = rule,
         maps,
         version
       ) do
    with true <- method in PgHbaOptions.map_methods(version),
         map when is_binary(map) <- Map.get(options, "map"),
         false <- MapSet.member?(maps, map) do
      [
        diagnostic(
          option_span(rule, "map"),
          @error,
          "ident map #{inspect(map)} does not exist in pg_ident.conf"
        )
      ]
    else
      _ -> []
    end
  end

  defp shadow_diagnostics(_rule, _path, []), do: []

  defp shadow_diagnostics(rule, path, previous) do
    case Enum.find(previous, &superset?(&1.entry, rule)) do
      nil ->
        []

      %{path: earlier_path, entry: earlier} ->
        what = if earlier.auth_method == "reject", do: "reject rule", else: "rule"
        line = earlier.span.line

        where =
          if earlier_path == path,
            do: "on line #{line}",
            else: "in #{ConfigTree.relative(earlier_path, path)} on line #{line}"

        [
          diagnostic(
            rule.span,
            @warning,
            "rule can never match because an earlier #{what} #{where} shadows it"
          )
        ]
    end
  end

  defp superset?(earlier, later) do
    type_superset?(earlier.connection_type, later.connection_type) and
      database_superset?(earlier.databases, later.databases) and
      list_superset?(earlier.users, later.users) and
      address_superset?(earlier, later)
  end

  # "all" matches every database but never a replication connection, which
  # only the "replication" keyword covers.
  defp database_superset?(earlier, later) do
    Enum.all?(later, fn database ->
      database in earlier or (database != "replication" and "all" in earlier)
    end)
  end

  defp type_superset?(type, type), do: true
  defp type_superset?("host", type), do: type in @host_types
  defp type_superset?(_earlier, _later), do: false

  defp list_superset?(earlier, later) do
    "all" in earlier or Enum.all?(later, &(&1 in earlier))
  end

  defp address_superset?(%{connection_type: "local"}, %{connection_type: "local"}), do: true

  defp address_superset?(%{address: "all", netmask: nil}, _later), do: true

  defp address_superset?(%{address: earlier}, %{address: later})
       when earlier in @address_keywords or later in @address_keywords,
       do: earlier == later

  defp address_superset?(earlier, later) do
    case {network(earlier), network(later)} do
      {{:ok, earlier_ip, earlier_prefix}, {:ok, later_ip, later_prefix}}
      when earlier_prefix <= later_prefix ->
        same_network?(earlier_ip, later_ip, earlier_prefix)

      _ ->
        earlier.address == later.address and earlier.netmask == later.netmask
    end
  end

  defp network(%{address: address, netmask: nil}) do
    case String.split(address, "/", parts: 2) do
      [ip_text, prefix_text] ->
        with {:ok, ip} <- parse_ip(ip_text), {prefix, ""} <- Integer.parse(prefix_text) do
          {:ok, ip, prefix}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp network(%{address: address, netmask: netmask}) do
    with {:ok, ip} <- parse_ip(address),
         {:ok, mask} <- parse_ip(netmask),
         {:ok, prefix} <- prefix_from_netmask(mask) do
      {:ok, ip, prefix}
    else
      _ -> :error
    end
  end

  defp same_network?(left, right, prefix) do
    mask_match?(left, right, prefix)
  end

  defp mask_match?({a, b, c, d}, {e, f, g, h}, prefix) do
    left = <<a, b, c, d>>
    right = <<e, f, g, h>>
    prefix_match?(left, right, prefix)
  end

  defp mask_match?({a, b, c, d, e, f, g, h}, {i, j, k, l, m, n, o, p}, prefix) do
    left = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    right = <<i::16, j::16, k::16, l::16, m::16, n::16, o::16, p::16>>
    prefix_match?(left, right, prefix)
  end

  defp mask_match?(_, _, _), do: false

  defp prefix_match?(left, right, prefix) do
    bytes = div(prefix, 8)
    remainder = rem(prefix, 8)
    same_bytes = binary_part(left, 0, bytes) == binary_part(right, 0, bytes)

    same_bytes and
      (remainder == 0 or
         (:binary.at(left, bytes) &&& 0xFF <<< (8 - remainder)) ==
           (:binary.at(right, bytes) &&& 0xFF <<< (8 - remainder)))
  end

  defp parse_ip(text), do: :inet.parse_strict_address(String.to_charlist(text))

  defp prefix_from_netmask(mask) do
    width = if tuple_size(mask) == 4, do: 8, else: 16

    bits =
      mask
      |> Tuple.to_list()
      |> Enum.map_join("", &(Integer.to_string(&1, 2) |> String.pad_leading(width, "0")))

    if Regex.match?(~r/^1*0*$/, bits) do
      {:ok, String.length(String.trim_trailing(bits, "0"))}
    else
      :error
    end
  end

  # The version comes from the options or a `# postern: pg=N` comment in the
  # file, the same way it does for postgresql.conf.
  defp target_version(text, options),
    do: Postern.PostgresqlConfDiagnostics.target_version(text, options)

  # The maps the rules can name: every mapping in the pg_ident.conf tree, or
  # in the text the caller supplied, or nothing to check against.
  defp ident_maps(_text, %{entries: entries}),
    do: MapSet.new(for(%{entry: %{type: :mapping, map: map}} <- entries, do: map))

  defp ident_maps(nil, nil), do: nil

  defp ident_maps(text, nil) do
    {:ok, entries} = PgIdent.parse(text)

    entries
    |> Enum.filter(&(&1.type == :mapping))
    |> Enum.map(& &1.map)
    |> MapSet.new()
  end

  defp diagnostic(span, severity, message) do
    %Diagnostic{
      range: %Range{
        start: %Position{line: span.line - 1, character: span.col - 1},
        end: %Position{line: span.end_line - 1, character: span.end_col - 1}
      },
      severity: severity,
      source: "postern",
      message: message
    }
  end
end
