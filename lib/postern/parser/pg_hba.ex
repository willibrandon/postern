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
  @auth_methods ~w(trust reject scram-sha-256 scram-sha-256-plus md5 password gss sspi ident peer ldap radius cert pam bsd oauth)

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

  defp parse_tokens(tokens, raw_line, line_no) do
    case tokens do
      [] ->
        %{type: :blank, span: span_for(line_no, 1, raw_line), raw: raw_line}

      [first | _] when first in @include_directives ->
        parse_include(tokens, raw_line, line_no)

      [conn_type | _] when conn_type in @connection_types ->
        parse_rule(tokens, raw_line, line_no)

      [maybe_include | _] when maybe_include in ["include", "include_if_exists", "include_dir"] ->
        # also handle without _? already covered
        parse_include(tokens, raw_line, line_no)

      _ ->
        %{
          type: :error,
          message: "unknown connection type #{inspect(hd(tokens))}",
          span: span_for(line_no, 1, raw_line),
          raw: raw_line
        }
    end
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

  defp parse_rule(["local" | rest] = tokens, raw_line, line_no) do
    parse_local_rule(rest, tokens, raw_line, line_no)
  end

  defp parse_rule([conn_type | rest] = tokens, raw_line, line_no) do
    parse_host_rule(conn_type, rest, tokens, raw_line, line_no)
  end

  defp parse_local_rule([db, user, method | opts], tokens, raw_line, line_no) do
    rule_entry(
      tokens,
      %{
        connection_type: "local",
        database: db,
        user: user,
        address: nil,
        netmask: nil,
        method: method,
        options: opts
      },
      raw_line,
      line_no
    )
  end

  defp parse_local_rule(_tokens, _raw_tokens, raw_line, line_no) do
    parse_error("local rule requires DATABASE USER METHOD", raw_line, line_no)
  end

  defp parse_host_rule(conn_type, rest, tokens, raw_line, line_no) do
    case Enum.find_index(rest, &(&1 in @auth_methods)) do
      nil ->
        parse_error("could not find auth method in #{inspect(tokens)}", raw_line, line_no)

      0 ->
        parse_error("missing DATABASE/USER/ADDRESS before METHOD", raw_line, line_no)

      1 ->
        parse_error("missing DATABASE/USER/ADDRESS before METHOD", raw_line, line_no)

      method_index ->
        [db, user | tail] = rest
        {address_tokens, [method | opts]} = Enum.split(tail, method_index - 2)
        {address, netmask} = address_parts(address_tokens)

        rule_entry(
          tokens,
          %{
            connection_type: conn_type,
            database: db,
            user: user,
            address: address,
            netmask: netmask,
            method: method,
            options: opts
          },
          raw_line,
          line_no
        )
    end
  end

  defp address_parts([]), do: {nil, nil}
  defp address_parts([address]), do: {address, nil}
  defp address_parts([address, netmask]), do: {address, netmask}
  defp address_parts(addresses), do: {Enum.join(addresses, " "), nil}

  defp rule_entry(
         tokens,
         %{
           connection_type: conn_type,
           database: db,
           user: user,
           address: address,
           netmask: netmask,
           method: method,
           options: opts
         },
         raw_line,
         line_no
       ) do
    %{
      type: :rule,
      connection_type: conn_type,
      databases: split_list(db),
      users: split_list(user),
      address: maybe_unquote(address),
      netmask: maybe_unquote(netmask),
      auth_method: unquote_token(method),
      options: parse_options(opts, raw_line, line_no),
      tokens: token_spans(tokens, raw_line, line_no),
      span: span_for(line_no, 1, raw_line),
      raw: raw_line
    }
  end

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

  defp parse_options(opts, _raw_line, _line_no) do
    # Options are name=value
    Enum.reduce(opts, %{}, fn opt, acc ->
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
