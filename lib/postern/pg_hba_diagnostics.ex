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
          load_errors(rule, version) ++
            ident_on_local_hint(rule) ++
            unsafe_method_diagnostics(rule, report_trust) ++
            ident_reference_diagnostics(rule, maps, version) ++
            shadow_diagnostics(rule, path, previous) ++
            regex_diagnostics(rule, version)

        invalid_method ->
          invalid_method
      end
  end

  # What the server refuses when it loads the rule, in the order it looks:
  # the method against the connection type, then each option, then the
  # arguments the method needs. It stops at the first, and so does this.
  defp load_errors(rule, version) do
    [
      combination_diagnostics(rule),
      option_diagnostics(rule, version),
      argument_diagnostics(rule, version)
    ]
    |> Enum.find([], &(&1 != []))
  end

  # gssapi cannot serve a local socket, peer serves nothing else, and cert
  # needs a connection with a client certificate to look at.
  defp combination_diagnostics(%{connection_type: type, auth_method: method, method_span: span}) do
    cond do
      type == "local" and method == "gss" ->
        [diagnostic(span, @error, "gssapi authentication is not supported on local sockets")]

      type != "local" and method == "peer" ->
        [diagnostic(span, @error, "peer authentication is only supported on local sockets")]

      type != "hostssl" and method == "cert" ->
        [diagnostic(span, @error, "cert authentication is only supported on hostssl connections")]

      true ->
        []
    end
  end

  # ident on a local socket has meant peer for a long time, and the server
  # swaps it in without a word.
  defp ident_on_local_hint(%{connection_type: "local", auth_method: "ident", method_span: span}),
    do: [diagnostic(span, @hint, ~s(on a local socket the server reads "ident" as "peer"))]

  defp ident_on_local_hint(_rule), do: []

  # The arguments a method needs, checked once the options are all valid.
  defp argument_diagnostics(%{auth_method: "ldap", options: options, span: span}, version),
    do: ldap_arguments(options, span, version)

  defp argument_diagnostics(%{auth_method: "radius", options: options, span: span}, _version),
    do: radius_arguments(options, span)

  defp argument_diagnostics(%{auth_method: "oauth", options: options, span: span}, _version),
    do: oauth_arguments(options, span)

  defp argument_diagnostics(_rule, _version), do: []

  # ldap binds simply, with ldapprefix or ldapsuffix, or searches first,
  # with ldapbasedn, never both, and searches by an attribute or a filter,
  # never both. ldapserver is left alone: a build with OpenLDAP can find the
  # server through DNS and does not insist on it.
  defp ldap_arguments(options, span, version) do
    case ldap_shape(options) do
      :mixed ->
        [diagnostic(span, @error, ldap_mix_message(version))]

      :unbound ->
        [
          diagnostic(
            span,
            @error,
            ~s(authentication method "ldap" requires argument "ldapbasedn", "ldapprefix", or "ldapsuffix" to be set)
          )
        ]

      :two_searches ->
        [
          diagnostic(
            span,
            @error,
            "cannot use ldapsearchattribute together with ldapsearchfilter"
          )
        ]

      :fine ->
        []
    end
  end

  defp ldap_shape(options) do
    {url_basedn?, url_attribute?} = ldapurl_parts(options["ldapurl"])
    simple? = any?(options, ~w(ldapprefix ldapsuffix))

    search? =
      any?(options, ~w(ldapbasedn ldapbinddn ldapbindpasswd ldapsearchattribute ldapsearchfilter))

    basedn? = url_basedn? or any?(options, ~w(ldapbasedn))
    attribute? = url_attribute? or any?(options, ~w(ldapsearchattribute))

    case {simple?, search?, basedn?, attribute? and any?(options, ~w(ldapsearchfilter))} do
      {true, true, _basedn?, _both?} -> :mixed
      {false, _search?, false, _both?} -> :unbound
      {_simple?, _search?, _basedn?, true} -> :two_searches
      _shape -> :fine
    end
  end

  defp any?(options, names), do: Enum.any?(names, &Map.has_key?(options, &1))

  # radius needs its servers and secrets, and the secrets, ports and
  # identifiers are one each or one per server.
  defp radius_arguments(options, span) do
    cond do
      not Map.has_key?(options, "radiusservers") -> [requires("radius", "radiusservers", span)]
      not Map.has_key?(options, "radiussecrets") -> [requires("radius", "radiussecrets", span)]
      true -> radius_lists(options, length(list(options["radiusservers"])), span)
    end
  end

  defp radius_lists(options, servers, span) do
    Enum.find_value(~w(secrets ports identifiers), [], fn what ->
      count = length(list(options["radius" <> what]))

      if Map.has_key?(options, "radius" <> what) and count != 1 and count != servers do
        [
          diagnostic(
            span,
            @error,
            "the number of RADIUS #{what} (#{count}) must be 1 or the same as the number of RADIUS servers (#{servers})"
          )
        ]
      end
    end)
  end

  defp oauth_arguments(options, span) do
    cond do
      not Map.has_key?(options, "scope") ->
        [requires("oauth", "scope", span)]

      not Map.has_key?(options, "issuer") ->
        [requires("oauth", "issuer", span)]

      options["delegate_ident_mapping"] == "1" and Map.has_key?(options, "map") ->
        [
          diagnostic(
            span,
            @error,
            "map cannot be used in combination with delegate_ident_mapping"
          )
        ]

      true ->
        []
    end
  end

  defp requires(method, argument, span) do
    diagnostic(
      span,
      @error,
      ~s(authentication method "#{method}" requires argument "#{argument}" to be set)
    )
  end

  # 18 reworded the message; the rule is the same.
  defp ldap_mix_message(version) when version >= 18,
    do: "cannot mix options for simple bind and search+bind modes"

  defp ldap_mix_message(_version),
    do:
      "cannot use ldapbasedn, ldapbinddn, ldapbindpasswd, ldapsearchattribute, ldapsearchfilter, or ldapurl together with ldapprefix"

  # An ldapurl sets the base DN, even to nothing, and the attribute after
  # its first question mark, ldap://host/dc=x?uid?sub, counts as
  # ldapsearchattribute.
  defp ldapurl_parts(url) when is_binary(url) do
    case Regex.run(~r{^ldaps?://[^/]*/[^?]*\?([^?]*)}, url) do
      [_, attribute] -> {true, attribute != ""}
      nil -> {true, false}
    end
  end

  defp ldapurl_parts(_other), do: {false, false}

  # A comma-separated list the way SplitGUCList reads one.
  defp list(value) when is_binary(value),
    do: value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp list(_other), do: []

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
      if token.raw == name or String.starts_with?(token.raw, name <> "=") or
           String.contains?(token.raw, "," <> name),
         do: token.span
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
