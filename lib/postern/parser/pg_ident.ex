defmodule Postern.Parser.PgIdent do
  @moduledoc """
  Parser for `pg_ident.conf`.

  Records are `map-name system-username pg-username`, with `/regex`
  system usernames and `\\1` substitution in `pg-username`.

  Include directives `include`, `include_if_exists`, `include_dir` are
  also allowed. A token is quoted with double quotes, the only quote
  character the server's tokenizer knows; a single quote is an ordinary
  character.

  Every token carries a span.
  """

  import NimbleParsec

  dq_quoted =
    ignore(string("\""))
    |> repeat(
      choice([
        string("\"\"") |> replace("\""),
        utf8_string([not: ?"], min: 1)
      ])
    )
    |> reduce({Enum, :join, [""]})
    |> ignore(string("\""))
    |> unwrap_and_tag(:quoted)

  quoted_token = dq_quoted

  unquoted_token =
    ascii_string([not: ?\s, not: ?\t, not: ?#, not: ?"], min: 1)
    |> unwrap_and_tag(:unquoted)

  token = choice([quoted_token, unquoted_token])

  defparsec(:parse_token, token)

  @include_directives ~w(include include_if_exists include_dir)

  @type span :: %{
          line: pos_integer(),
          col: pos_integer(),
          end_line: pos_integer(),
          end_col: pos_integer()
        }
  @type entry ::
          %{
            type: :mapping,
            map: String.t(),
            system_user: String.t(),
            pg_user: String.t(),
            map_span: span(),
            system_span: span(),
            pg_span: span(),
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
  Parses a `pg_ident.conf` file content.
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
    do_tokenize(rest, acc, current <> <<c::utf8>>, true, c)
  end

  defp do_tokenize(<<c::utf8, rest::binary>>, acc, current, true, quote_char) do
    if c == quote_char do
      case rest do
        <<next::utf8, rest2::binary>> when next == quote_char ->
          do_tokenize(rest2, acc, current <> <<c::utf8, next::utf8>>, true, quote_char)

        _ ->
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
      [first | _] when first in @include_directives ->
        case tokens do
          [directive, file | _] ->
            %{
              type: :include,
              directive: directive,
              file: unquote_token(file),
              tokens: token_spans(tokens, raw_line, line_no),
              span: span_for(line_no, 1, raw_line),
              raw: raw_line
            }

          [_directive] ->
            %{
              type: :error,
              message: "missing file for include directive",
              span: span_for(line_no, 1, raw_line),
              raw: raw_line
            }
        end

      [map, sys, pg] ->
        %{
          type: :mapping,
          map: unquote_token(map),
          system_user: unquote_token(sys),
          pg_user: unquote_token(pg),
          tokens: token_spans(tokens, raw_line, line_no),
          map_span: span_for_token(raw_line, map, line_no),
          system_span: span_for_token(raw_line, sys, line_no),
          pg_span: span_for_token(raw_line, pg, line_no),
          span: span_for(line_no, 1, raw_line),
          raw: raw_line
        }

      [_map, _sys, _pg | _rest] ->
        # Extra tokens — treat as error but keep first three
        %{
          type: :error,
          message: "too many fields, expected MAPNAME SYSTEM-USERNAME PG-USERNAME",
          span: span_for(line_no, column_of(raw_line, Enum.at(tokens, 3)), raw_line),
          raw: raw_line
        }

      [_ | _] ->
        %{
          type: :error,
          message: "expected MAPNAME SYSTEM-USERNAME PG-USERNAME",
          span: span_for(line_no, 1, raw_line),
          raw: raw_line
        }

      [] ->
        %{type: :blank, span: span_for(line_no, 1, raw_line), raw: raw_line}
    end
  end

  defp unquote_token(token) when is_binary(token) do
    if String.starts_with?(token, "\"") and String.ends_with?(token, "\"") and
         String.length(token) >= 2 do
      token |> String.slice(1..-2//1) |> String.replace("\"\"", "\"")
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

  defp span_for_token(raw_line, token, line_no) do
    col = column_of(raw_line, token)
    end_col = col + String.length(token)
    %{line: line_no, col: col, end_line: line_no, end_col: end_col}
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
