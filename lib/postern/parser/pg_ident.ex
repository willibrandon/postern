defmodule Postern.Parser.PgIdent do
  @moduledoc """
  Parser for `pg_ident.conf`.

  Records are `map-name system-username pg-username`, with `/regex`
  system usernames and `\\1` substitution in `pg-username`.

  Include directives `include`, `include_if_exists`, `include_dir` are
  also allowed. A token is quoted with double quotes, the only quote
  character the server's tokenizer knows; a single quote is an ordinary
  character. A line that ends with a backslash goes on with the next one,
  as `Postern.Parser.AuthLines` has it, unless the caller says the target
  version has no continuations.

  Every token carries a span.
  """

  alias Postern.Parser.AuthLines

  @include_directives ~w(include include_if_exists include_dir)

  @type span :: AuthLines.span()
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

  defp parse_tokens(tokens, %{text: text} = record) do
    case tokens do
      [first | _] when first in @include_directives ->
        case tokens do
          [directive, file | _] ->
            %{
              type: :include,
              directive: directive,
              file: unquote_token(file),
              tokens: token_spans(tokens, record),
              span: AuthLines.span(record),
              raw: text
            }

          [_directive] ->
            error("missing file for include directive", record)
        end

      [map, sys, pg] ->
        [map_span, system_span, pg_span] = Enum.map(token_spans(tokens, record), & &1.span)

        %{
          type: :mapping,
          map: unquote_token(map),
          system_user: unquote_token(sys),
          pg_user: unquote_token(pg),
          tokens: token_spans(tokens, record),
          map_span: map_span,
          system_span: system_span,
          pg_span: pg_span,
          span: AuthLines.span(record),
          raw: text
        }

      [_map, _sys, _pg | _rest] ->
        %{
          type: :error,
          message: "too many fields, expected MAPNAME SYSTEM-USERNAME PG-USERNAME",
          span: AuthLines.span(record, Enum.at(token_spans(tokens, record), 3).offset),
          raw: text
        }

      [_ | _] ->
        error("missing entry at end of line", record)

      [] ->
        %{type: :blank, span: AuthLines.span(record), raw: text}
    end
  end

  defp error(message, %{text: text} = record),
    do: %{type: :error, message: message, span: AuthLines.span(record), raw: text}

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
