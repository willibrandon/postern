defmodule Postern.Parser.PgHba do
  @moduledoc """
  Parser for `pg_hba.conf`.

  Fields are `type` (local, host, hostssl, hostnossl, hostgssenc,
  hostnogssenc), `database` list, `user` list, `address` (CIDR, IP
  plus netmask, hostname, all, samehost, samenet), `auth method`
  and method options as `name=value`.

  PostgreSQL 16 added `include`, `include_if_exists` and
  `include_dir` here too, and regexes prefixed with `/` in database
  and user fields. A token is quoted with double quotes, the only
  quote character the server's tokenizer knows; a single quote is an
  ordinary character. Comma-separated lists apply. A line that ends
  with a backslash goes on with the next one, as
  `Postern.Parser.AuthLines` has it, unless the caller says the target
  version has no continuations.

  Every token carries a span.
  """

  alias Postern.Parser.AuthLines

  @connection_types ~w(local host hostssl hostnossl hostgssenc hostnogssenc)
  @include_directives ~w(include include_if_exists include_dir)
  @address_keywords ~w(all samehost samenet)

  @type span :: AuthLines.span()
  @type entry ::
          %{
            type: :rule,
            connection_type: String.t(),
            databases: [String.t()],
            users: [String.t()],
            address: String.t() | nil,
            netmask: String.t() | nil,
            auth_method: String.t(),
            options: map(),
            tokens: [map()],
            address_kind: :keyword | :cidr | :ip | :host | nil,
            address_span: span() | nil,
            method_span: span(),
            span: span(),
            raw: String.t()
          }
          | %{
              type: :include,
              directive: String.t(),
              file: String.t(),
              tokens: [map()],
              span: span(),
              raw: String.t()
            }
          | %{type: :blank, span: span(), raw: String.t()}
          | %{type: :comment, text: String.t(), span: span(), raw: String.t()}
          | %{type: :error, message: String.t(), span: span(), raw: String.t()}

  @doc """
  Parses a `pg_hba.conf` file content.

  `continuations: false` reads every line on its own, as a server older
  than 14 does.
  """
  @spec parse(String.t(), keyword()) :: {:ok, [entry()]}
  def parse(content, opts \\ []) when is_binary(content) do
    records = AuthLines.records(content, Keyword.get(opts, :continuations, true))
    {:ok, Enum.map(records, &parse_record/1)}
  end

  @doc "Parses one physical line."
  @spec parse_line(String.t(), pos_integer()) :: entry()
  def parse_line(line, line_no), do: parse_record(AuthLines.single(line, line_no))

  @doc "Whether the server would take the text for an IP address rather than a host name."
  @spec numeric_ip?(String.t()) :: boolean()
  def numeric_ip?(value),
    do: match?({:ok, _address}, :inet.parse_strict_address(String.to_charlist(value)))

  defp parse_record(%{text: text} = record) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        %{type: :blank, span: AuthLines.span(record), raw: text}

      String.starts_with?(trimmed, "#") ->
        %{
          type: :comment,
          text: text,
          span: AuthLines.span(record, offset_of(text, "#")),
          raw: text
        }

      true ->
        {code_part, _comment} = split_comment(text)
        code_trimmed = String.trim(code_part)

        if code_trimmed == "" do
          %{type: :comment, text: text, span: AuthLines.span(record), raw: text}
        else
          parse_tokens(tokenize(code_trimmed), record)
        end
    end
  end

  defp tokenize(code) do
    # Split by whitespace respecting quotes
    do_tokenize(code, [], "", false, nil)
    |> Enum.reverse()
  end

  defp do_tokenize("", acc, current, _in_quote, _quote_char) do
    if current != "", do: [current | acc], else: acc
  end

  defp do_tokenize(<<c::utf8, rest::binary>>, acc, current, false, nil) when c in [?\s, ?\t] do
    if current == "" do
      do_tokenize(rest, acc, "", false, nil)
    else
      do_tokenize(rest, [current | acc], "", false, nil)
    end
  end

  defp do_tokenize(<<c::utf8, rest::binary>>, acc, current, false, nil) when c == ?" do
    # start quote
    do_tokenize(rest, acc, current <> <<c::utf8>>, true, c)
  end

  defp do_tokenize(<<c::utf8, rest::binary>>, acc, current, true, quote_char) do
    if c == quote_char do
      case rest do
        <<next::utf8, rest2::binary>> when next == quote_char ->
          # escaped quote
          do_tokenize(rest2, acc, current <> <<c::utf8, next::utf8>>, true, quote_char)

        _ ->
          # end quote
          do_tokenize(rest, acc, current <> <<c::utf8>>, false, nil)
      end
    else
      do_tokenize(rest, acc, current <> <<c::utf8>>, true, quote_char)
    end
  end

  defp do_tokenize(<<c::utf8, rest::binary>>, acc, current, false, nil) do
    do_tokenize(rest, acc, current <> <<c::utf8>>, false, nil)
  end

  defp parse_tokens([], %{text: text} = record),
    do: %{type: :blank, span: AuthLines.span(record), raw: text}

  defp parse_tokens([first | _rest] = tokens, record) do
    if first in @include_directives,
      do: parse_include(tokens, record),
      else: parse_rule(tokens, record)
  end

  defp parse_include(tokens, %{text: text} = record) do
    case tokens do
      [directive, file | _rest] ->
        %{
          type: :include,
          directive: directive,
          file: unquote_token(file),
          tokens: token_spans(tokens, record),
          span: AuthLines.span(record),
          raw: text
        }

      [directive] ->
        parse_error("missing file for #{directive}", record)
    end
  end

  # A rule is read field by field the way parse_hba_line reads it: the
  # connection type, the database list, the user list, then for anything but
  # local an address, which is a keyword, a host name, a CIDR address, or an
  # IP address followed by a netmask, then the method and its options. A
  # field that ends too soon or holds a list where one value belongs is an
  # error in the server's words. Whether the method exists is for the checks,
  # which know the target version.
  defp parse_rule([conn_type | rest] = tokens, %{text: text} = record) do
    with :ok <- single(conn_type, "connection type", record),
         :ok <- connection_type(conn_type, record),
         {:ok, database, rest} <- field(rest, "database specification", record),
         {:ok, user, rest} <- field(rest, "role specification", record),
         {:ok, address, netmask, rest} <- address(conn_type, rest, record),
         {:ok, method, options} <- field(rest, "authentication method", record),
         :ok <- single(method, "authentication type", record) do
      spans = token_spans(tokens, record)
      method_index = length(tokens) - length(options) - 1

      %{
        type: :rule,
        connection_type: conn_type,
        databases: split_list(database),
        users: split_list(user),
        address: maybe_unquote(address),
        address_kind: address_kind(address),
        netmask: maybe_unquote(netmask),
        auth_method: unquote_token(method),
        options: parse_options(options),
        tokens: spans,
        address_span: address && Enum.at(spans, 3).span,
        method_span: Enum.at(spans, method_index).span,
        span: AuthLines.span(record),
        raw: text
      }
    end
  end

  # The server names the field it ran out of input before.
  defp field([], what, record), do: parse_error("end-of-line before #{what}", record)
  defp field([token | rest], _what, _record), do: {:ok, token, rest}

  # A field that takes one value refuses a list.
  defp single(token, what, record) do
    if length(split_outside_quotes(token, "", [], false)) > 1,
      do: parse_error("multiple values specified for #{what}", record),
      else: :ok
  end

  # The keywords count only unquoted, as token_is_keyword has it.
  defp connection_type(token, record) do
    if token in @connection_types,
      do: :ok,
      else: parse_error(~s(invalid connection type "#{unquote_token(token)}"), record)
  end

  # The address field: nothing on a local rule; a keyword, a host name or a
  # CIDR address on its own; an IP address followed by its netmask. The
  # server checks the address and the mask as it reads them, before it looks
  # for the method, so those are errors here rather than in the checks.
  defp address("local", rest, _record), do: {:ok, nil, nil, rest}

  defp address(_type, [], record),
    do: parse_error("end-of-line before IP address specification", record)

  defp address(_type, [address | rest], record) do
    with :ok <- single(address, "host address", record),
         :ok <- cidr(address, record) do
      if address_kind(address) == :ip,
        do: netmask(address, rest, record),
        else: {:ok, address, nil, rest}
    end
  end

  # A CIDR address has an IP address before the slash and a mask that fits it.
  defp cidr(token, record) do
    value = unquote_token(token)

    with :cidr <- address_kind(token),
         [host, mask] = String.split(value, "/", parts: 2),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(host)),
         true <- valid_prefix?(mask, ip) do
      :ok
    else
      {:error, _reason} ->
        parse_error(~s(specifying both host name and CIDR mask is invalid: "#{value}"), record)

      false ->
        parse_error(~s(invalid CIDR mask in address "#{value}"), record)

      _other_kind ->
        :ok
    end
  end

  defp valid_prefix?(mask, ip) do
    case Integer.parse(mask) do
      {prefix, ""} -> prefix >= 0 and prefix <= if(tuple_size(ip) == 4, do: 32, else: 128)
      _other -> false
    end
  end

  # A bare IP address takes the next field as its netmask, an address of the
  # same family; whether the mask is contiguous is not the server's concern.
  defp netmask(_address, [], record),
    do: parse_error("end-of-line before netmask specification", record)

  defp netmask(address, [netmask | rest], record) do
    {:ok, ip} = :inet.parse_strict_address(String.to_charlist(unquote_token(address)))
    mask = unquote_token(netmask)

    with :ok <- single(netmask, "netmask", record),
         {:ok, parsed} <- :inet.parse_strict_address(String.to_charlist(mask)),
         true <- tuple_size(parsed) == tuple_size(ip) do
      {:ok, address, netmask, rest}
    else
      {:error, _reason} -> parse_error(~s(invalid IP mask "#{mask}"), record)
      false -> parse_error("IP address and mask do not match", record)
      error -> error
    end
  end

  # What the server makes of an address token: an unquoted keyword, a CIDR
  # address, a bare IP address that takes a netmask, or else a host name,
  # which is what anything it cannot parse as an address becomes.
  defp address_kind(nil), do: nil

  defp address_kind(token) do
    value = unquote_token(token)

    cond do
      not String.starts_with?(token, "\"") and value in @address_keywords -> :keyword
      String.contains?(value, "/") -> :cidr
      numeric_ip?(value) -> :ip
      true -> :host
    end
  end

  defp maybe_unquote(nil), do: nil
  defp maybe_unquote(value), do: unquote_token(value)

  defp parse_error(message, %{text: text} = record),
    do: %{type: :error, message: message, span: AuthLines.span(record), raw: text}

  # A comma separates the names in a field, unless it is inside double
  # quotes, where it is part of the name, as in the server's tokenizer.
  defp split_list(raw) do
    raw
    |> split_outside_quotes("", [], false)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&unquote_token/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_outside_quotes("", current, acc, _in_quote), do: Enum.reverse([current | acc])

  defp split_outside_quotes(<<?,, rest::binary>>, current, acc, false),
    do: split_outside_quotes(rest, "", [current | acc], false)

  defp split_outside_quotes(<<?", rest::binary>>, current, acc, in_quote),
    do: split_outside_quotes(rest, current <> "\"", acc, not in_quote)

  defp split_outside_quotes(<<c::utf8, rest::binary>>, current, acc, in_quote),
    do: split_outside_quotes(rest, current <> <<c::utf8>>, acc, in_quote)

  # An option field is a list like any other, so a comma outside quotes
  # starts another option, which then has to be name=value on its own; a
  # list meant as one value, such as radiusservers, is quoted. An option
  # without a value is kept as `true` for the checks to refuse.
  defp parse_options(opts) do
    opts
    |> Enum.flat_map(&split_outside_quotes(&1, "", [], false))
    |> Enum.reduce(%{}, fn opt, acc ->
      case String.split(opt, "=", parts: 2) do
        [k, v] -> Map.put(acc, k, unquote_token(v))
        [k] -> Map.put(acc, k, true)
      end
    end)
  end

  defp unquote_token(token) when is_binary(token) do
    if String.starts_with?(token, "\"") and String.ends_with?(token, "\"") and
         String.length(token) >= 2 do
      token
      |> String.slice(1..-2//1)
      |> String.replace("\"\"", "\"")
    else
      token
    end
  end

  defp split_comment(line) do
    do_split(line, "", false, nil)
  end

  defp do_split("", acc, _in_quote, _quote_char), do: {acc, nil}

  defp do_split(<<c::utf8, rest::binary>>, acc, false, nil) when c == ?# do
    {acc, "#" <> rest}
  end

  defp do_split(<<c::utf8, rest::binary>>, acc, false, nil) when c == ?" do
    do_split(rest, acc <> <<c::utf8>>, true, c)
  end

  defp do_split(<<c::utf8, rest::binary>>, acc, true, quote_char) when c == quote_char do
    case rest do
      <<next::utf8, rest2::binary>> when next == quote_char ->
        do_split(rest2, acc <> <<c::utf8, next::utf8>>, true, quote_char)

      _ ->
        do_split(rest, acc <> <<c::utf8>>, false, nil)
    end
  end

  defp do_split(<<c::utf8, rest::binary>>, acc, in_quote, quote_char) do
    do_split(rest, acc <> <<c::utf8>>, in_quote, quote_char)
  end

  defp offset_of(text, substr) do
    case :binary.match(text, substr) do
      {pos, _length} -> pos
      :nomatch -> 0
    end
  end

  # Each token found in the record from where the last one ended, with the
  # physical line and column it starts and ends on.
  defp token_spans(tokens, %{text: text} = record) do
    {spans, _offset} =
      Enum.map_reduce(tokens, 0, fn token, offset ->
        remaining = binary_part(text, offset, byte_size(text) - offset)

        start =
          case :binary.match(remaining, token) do
            {relative, _length} -> offset + relative
            :nomatch -> offset
          end

        finish = start + byte_size(token)

        {%{
           value: unquote_token(token),
           raw: token,
           offset: start,
           span: AuthLines.span(record, start, finish)
         }, finish}
      end)

    spans
  end
end
