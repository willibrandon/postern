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
  ordinary character. Comma-separated lists apply.

  Every token carries a span.
  """

  import NimbleParsec

  # Quoted strings for pg_hba — double quotes with "" => "
  dq_quoted_content =
    repeat(
      choice([
        string("\"\"") |> replace("\""),
        utf8_string([not: ?"], min: 1)
      ])
    )
    |> reduce({Enum, :join, [""]})

  dq_quoted =
    ignore(string("\""))
    |> concat(dq_quoted_content)
    |> ignore(string("\""))
    |> unwrap_and_tag(:quoted)

  quoted_token = dq_quoted

  # Unquoted token: up to whitespace, #, comma? Actually comma is separator inside list,
  # but we keep it as part of token; later split. So unquoted token is run of non-space, non-# , non-quote
  unquoted_token =
    ascii_string([not: ?\s, not: ?\t, not: ?#, not: ?"], min: 1)
    |> unwrap_and_tag(:unquoted)

  token = choice([quoted_token, unquoted_token])

  defparsec(:parse_token, token)
  defparsec(:parse_quoted_token, quoted_token)

  @connection_types ~w(local host hostssl hostnossl hostgssenc hostnogssenc)
  @include_directives ~w(include include_if_exists include_dir)
  @address_keywords ~w(all samehost samenet)

  @type span :: %{
          line: pos_integer(),
          col: pos_integer(),
          end_line: pos_integer(),
          end_col: pos_integer()
        }
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
  """
  @spec parse(String.t()) :: {:ok, [entry()]}
  def parse(content) when is_binary(content) do
    lines = String.split(content, "\n", trim: false)

    entries =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {raw_line, line_no} ->
        line = String.trim_trailing(raw_line, "\r")
        parse_line(line, line_no)
      end)

    {:ok, entries}
  end

  @doc """
  Parses a single line.
  """
  @spec parse_line(String.t(), pos_integer()) :: entry()
  def parse_line(line, line_no) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        %{type: :blank, span: span_for(line_no, 1, line), raw: line}

      String.starts_with?(trimmed, "#") ->
        col = column_of(line, "#")
        %{type: :comment, text: line, span: span_for(line_no, col, line), raw: line}

      true ->
        {code_part, _comment} = split_comment(line)
        code_trimmed = String.trim(code_part)

        if code_trimmed == "" do
          %{type: :comment, text: line, span: span_for(line_no, 1, line), raw: line}
        else
          tokens = tokenize(code_trimmed)
          parse_tokens(tokens, line, line_no)
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

  defp parse_tokens([], raw_line, line_no),
    do: %{type: :blank, span: span_for(line_no, 1, raw_line), raw: raw_line}

  defp parse_tokens([first | _rest] = tokens, raw_line, line_no) do
    if first in @include_directives,
      do: parse_include(tokens, raw_line, line_no),
      else: parse_rule(tokens, raw_line, line_no)
  end

  defp parse_include(tokens, raw_line, line_no) do
    case tokens do
      [directive, file | _rest] when directive in @include_directives ->
        %{
          type: :include,
          directive: directive,
          file: unquote_token(file),
          tokens: token_spans(tokens, raw_line, line_no),
          span: span_for(line_no, 1, raw_line),
          raw: raw_line
        }

      [directive] when directive in @include_directives ->
        %{
          type: :error,
          message: "missing file for #{directive}",
          span: span_for(line_no, 1, raw_line),
          raw: raw_line
        }

      _ ->
        %{
          type: :error,
          message: "invalid include directive",
          span: span_for(line_no, 1, raw_line),
          raw: raw_line
        }
    end
  end

  # A rule is read field by field the way parse_hba_line reads it: the
  # connection type, the database list, the user list, then for anything but
  # local an address, which is a keyword, a host name, a CIDR address, or an
  # IP address followed by a netmask, then the method and its options. A
  # field that ends too soon or holds a list where one value belongs is an
  # error in the server's words. Whether the method exists is for the checks,
  # which know the target version.
  defp parse_rule([conn_type | rest] = tokens, raw_line, line_no) do
    with :ok <- single(conn_type, "connection type", raw_line, line_no),
         :ok <- connection_type(conn_type, raw_line, line_no),
         {:ok, database, rest} <- field(rest, "database specification", raw_line, line_no),
         {:ok, user, rest} <- field(rest, "role specification", raw_line, line_no),
         {:ok, address, netmask, rest} <- address(conn_type, rest, raw_line, line_no),
         {:ok, method, options} <- field(rest, "authentication method", raw_line, line_no),
         :ok <- single(method, "authentication type", raw_line, line_no) do
      spans = token_spans(tokens, raw_line, line_no)
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
        options: parse_options(options, raw_line, line_no),
        tokens: spans,
        address_span: address && Enum.at(spans, 3).span,
        method_span: Enum.at(spans, method_index).span,
        span: span_for(line_no, 1, raw_line),
        raw: raw_line
      }
    end
  end

  # The server names the field it ran out of input before.
  defp field([], what, raw_line, line_no),
    do: parse_error("end-of-line before #{what}", raw_line, line_no)

  defp field([token | rest], _what, _raw_line, _line_no), do: {:ok, token, rest}

  # A field that takes one value refuses a list.
  defp single(token, what, raw_line, line_no) do
    if length(split_outside_quotes(token, "", [], false)) > 1,
      do: parse_error("multiple values specified for #{what}", raw_line, line_no),
      else: :ok
  end

  # The keywords count only unquoted, as token_is_keyword has it.
  defp connection_type(token, raw_line, line_no) do
    if token in @connection_types,
      do: :ok,
      else: parse_error(~s(invalid connection type "#{unquote_token(token)}"), raw_line, line_no)
  end

  # The address field: nothing on a local rule; a keyword, a host name or a
  # CIDR address on its own; an IP address followed by its netmask. The
  # server checks the address and the mask as it reads them, before it looks
  # for the method, so those are errors here rather than in the checks.
  defp address("local", rest, _raw_line, _line_no), do: {:ok, nil, nil, rest}

  defp address(_type, [], raw_line, line_no),
    do: parse_error("end-of-line before IP address specification", raw_line, line_no)

  defp address(_type, [address | rest], raw_line, line_no) do
    with :ok <- single(address, "host address", raw_line, line_no),
         :ok <- cidr(address, raw_line, line_no) do
      if address_kind(address) == :ip,
        do: netmask(address, rest, raw_line, line_no),
        else: {:ok, address, nil, rest}
    end
  end

  # A CIDR address has an IP address before the slash and a mask that fits it.
  defp cidr(token, raw_line, line_no) do
    value = unquote_token(token)

    with :cidr <- address_kind(token),
         [host, mask] = String.split(value, "/", parts: 2),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(host)),
         true <- valid_prefix?(mask, ip) do
      :ok
    else
      {:error, _reason} ->
        parse_error(
          ~s(specifying both host name and CIDR mask is invalid: "#{value}"),
          raw_line,
          line_no
        )

      false ->
        parse_error(~s(invalid CIDR mask in address "#{value}"), raw_line, line_no)

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
  defp netmask(_address, [], raw_line, line_no),
    do: parse_error("end-of-line before netmask specification", raw_line, line_no)

  defp netmask(address, [netmask | rest], raw_line, line_no) do
    {:ok, ip} = :inet.parse_strict_address(String.to_charlist(unquote_token(address)))
    mask = unquote_token(netmask)

    with :ok <- single(netmask, "netmask", raw_line, line_no),
         {:ok, parsed} <- :inet.parse_strict_address(String.to_charlist(mask)),
         true <- tuple_size(parsed) == tuple_size(ip) do
      {:ok, address, netmask, rest}
    else
      {:error, _reason} -> parse_error(~s(invalid IP mask "#{mask}"), raw_line, line_no)
      false -> parse_error("IP address and mask do not match", raw_line, line_no)
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

  @doc "Whether the server would take the text for an IP address rather than a host name."
  @spec numeric_ip?(String.t()) :: boolean()
  def numeric_ip?(value),
    do: match?({:ok, _address}, :inet.parse_strict_address(String.to_charlist(value)))

  defp maybe_unquote(nil), do: nil
  defp maybe_unquote(value), do: unquote_token(value)

  defp parse_error(message, raw_line, line_no) do
    %{type: :error, message: message, span: span_for(line_no, 1, raw_line), raw: raw_line}
  end

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
  defp parse_options(opts, _raw_line, _line_no) do
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

  defp span_for(line, col, raw) do
    end_col = col + String.length(raw)
    %{line: line, col: col, end_line: line, end_col: end_col}
  end

  defp column_of(line, substr) do
    case :binary.match(line, substr) do
      {pos, _} -> pos + 1
      :nomatch -> 1
    end
  end

  defp token_spans(tokens, raw_line, line_no) do
    {spans, _offset} =
      Enum.map_reduce(tokens, 0, fn token, offset ->
        token_size = byte_size(token)
        remaining_size = byte_size(raw_line) - offset
        remaining = binary_part(raw_line, offset, max(remaining_size, 0))

        position =
          case :binary.match(remaining, token) do
            {relative, _length} -> offset + relative + 1
            :nomatch -> offset + 1
          end

        span = %{
          value: unquote_token(token),
          raw: token,
          span: %{
            line: line_no,
            col: position,
            end_line: line_no,
            end_col: position + String.length(token)
          }
        }

        {span, position - 1 + token_size}
      end)

    spans
  end
end
