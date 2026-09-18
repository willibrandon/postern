defmodule Postern.Parser.PostgresqlConf do
  @moduledoc """
  Parser for `postgresql.conf` and `postgresql.auto.conf`, line by line the
  way guc-file.l scans one.

  The scanner takes the longest token at each point and, on a tie, the rule
  that comes first: a name is an identifier or one identifier, a dot and
  another; a value is an identifier, a quoted string, an integer with unit
  letters after its digits, a real, or an unquoted string, which starts with
  a letter and may hold dots, dashes, colons and slashes. `=` between the
  name and the value is optional, a `#` starts a comment, and anything else
  is a syntax error reported near the token the scanner stopped at, or near
  the end of the line when it ran out of tokens, in the server's words. A
  quoted string takes the escapes GUC_scanstr takes: `\\n`, `\\t`, `\\b`,
  `\\f`, `\\r`, an octal code of up to three digits, `''` for a quote, and a
  backslash before any other character stands for that character.

  So `work_mem = 1.5GB` is a syntax error near token `GB`, since a real
  takes no unit letters and `1.5` is the longest token, while `'1.5GB'` is a
  value; `1e3` is the integer `1e` followed by the token `3`; a path or a
  `*` has to be quoted; and so has `conf.d`, which is a qualified name to
  the scanner and not a value, while `a.b.c`, being longer as an unquoted
  string, is one. Every entry carries its spans, and an include directive is
  recognised in any case, as the server compares it.
  """

  @type span :: %{
          line: pos_integer(),
          col: pos_integer(),
          end_line: pos_integer(),
          end_col: pos_integer()
        }
  @type entry ::
          %{
            type: :assignment,
            name: String.t(),
            value: String.t(),
            raw_value: String.t(),
            quoted: boolean(),
            span: span(),
            name_span: span(),
            value_span: span(),
            raw: String.t()
          }
          | %{
              type: :include,
              directive: String.t(),
              file: String.t(),
              quoted: boolean(),
              span: span(),
              file_span: span(),
              raw: String.t()
            }
          | %{type: :blank, span: span(), raw: String.t()}
          | %{type: :comment, text: String.t(), span: span(), raw: String.t()}
          | %{type: :error, message: String.t(), span: span(), raw: String.t()}

  @include_directives ~w(include include_if_exists include_dir)

  # The rules of guc-file.l in their order, each anchored at the point the
  # scanner has reached. Bytes above 127 count as letters, as they do there.
  @rules [
    space: ~r/^[ \t\r]+/,
    comment: ~r/^#.*/,
    id: ~r/^[A-Za-z_\x80-\xff][A-Za-z_0-9\x80-\xff]*/,
    qualified_id:
      ~r/^[A-Za-z_\x80-\xff][A-Za-z_0-9\x80-\xff]*\.[A-Za-z_\x80-\xff][A-Za-z_0-9\x80-\xff]*/,
    string: ~r/^'(?:[^'\\\n]|\\.|'')*'/,
    unquoted_string: ~r{^[A-Za-z_\x80-\xff](?:[A-Za-z_0-9\x80-\xff]|[-._:/])*},
    integer: ~r/^[+-]?(?:0x[0-9a-fA-F]+|[0-9]+)[A-Za-z]*/,
    real: ~r/^[+-]?[0-9]*\.[0-9]*(?:[eE][+-]?[0-9]+)?/,
    equals: ~r/^=/
  ]

  @values [:id, :string, :integer, :real, :unquoted_string]

  @doc """
  Parses a `postgresql.conf` file content.

  Returns `{:ok, entries}` with one entry per line. A syntax error is an
  entry of its own, not a failure, so the file always parses.
  """
  @spec parse(String.t()) :: {:ok, [entry()]}
  def parse(content) when is_binary(content) do
    entries =
      content
      |> String.split("\n", trim: false)
      |> Enum.with_index(1)
      |> Enum.map(fn {raw_line, line_no} ->
        parse_line(String.trim_trailing(raw_line, "\r"), line_no)
      end)

    {:ok, entries}
  end

  @doc "Parses a single line with known line number."
  @spec parse_line(String.t(), pos_integer()) :: entry()
  def parse_line(line, line_no) when is_binary(line) and is_integer(line_no) do
    tokens = scan(line, 0, [])
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> %{type: :blank, span: line_span(line, line_no), raw: line}
      tokens == [] -> %{type: :comment, text: line, span: line_span(line, line_no), raw: line}
      true -> parse_tokens(tokens, line, line_no)
    end
  end

  @doc "The directives that splice another file in."
  def include_directives, do: @include_directives

  # The tokens of a line, comments and white space left out; a byte no rule
  # takes is an error token, as the catch-all rule makes it.
  defp scan("", _offset, acc), do: Enum.reverse(acc)

  defp scan(rest, offset, acc) do
    {type, text} = longest(rest)
    token = %{type: type, text: text, offset: offset, size: byte_size(text)}
    remaining = binary_part(rest, byte_size(text), byte_size(rest) - byte_size(text))

    if type in [:space, :comment],
      do: scan(remaining, offset + byte_size(text), acc),
      else: scan(remaining, offset + byte_size(text), [token | acc])
  end

  defp longest(rest) do
    @rules
    |> Enum.flat_map(fn {type, regex} ->
      case Regex.run(regex, rest) do
        [text] when text != "" -> [{type, text}]
        _none -> []
      end
    end)
    |> Enum.max_by(fn {_type, text} -> byte_size(text) end, fn -> {:error, first_char(rest)} end)
  end

  defp first_char(<<char::utf8, _rest::binary>>), do: <<char::utf8>>
  defp first_char(<<byte, _rest::binary>>), do: <<byte>>

  # ParseConfigFp: a name, an optional equals sign, a value, and nothing
  # else before the end of the line.
  defp parse_tokens([%{type: type} = name | rest], line, line_no)
       when type in [:id, :qualified_id] do
    rest =
      case rest do
        [%{type: :equals} | after_equals] -> after_equals
        _other -> rest
      end

    case rest do
      [%{type: value_type} = value] when value_type in @values ->
        entry(name, value, line, line_no)

      [%{type: value_type}, extra | _rest] when value_type in @values ->
        near_token(extra, line, line_no)

      [] ->
        end_of_line(line, line_no)

      [extra | _rest] ->
        near_token(extra, line, line_no)
    end
  end

  defp parse_tokens([extra | _rest], line, line_no), do: near_token(extra, line, line_no)

  defp entry(name, value, line, line_no) do
    quoted = value.type == :string
    text = if quoted, do: scanstr(value.text), else: value.text
    directive = String.downcase(name.text)

    if directive in @include_directives do
      %{
        type: :include,
        directive: directive,
        file: text,
        quoted: quoted,
        span: line_span(line, line_no),
        file_span: token_span(value, line, line_no),
        raw: line
      }
    else
      %{
        type: :assignment,
        name: name.text,
        value: text,
        raw_value: value.text,
        quoted: quoted,
        span: line_span(line, line_no),
        name_span: token_span(name, line, line_no),
        value_span: token_span(value, line, line_no),
        raw: line
      }
    end
  end

  defp near_token(token, line, line_no) do
    %{
      type: :error,
      message: ~s(syntax error near token "#{token.text}"),
      span: token_span(token, line, line_no),
      raw: line
    }
  end

  defp end_of_line(line, line_no) do
    %{
      type: :error,
      message: "syntax error near end of line",
      span: line_span(line, line_no),
      raw: line
    }
  end

  # GUC_scanstr: the quotes come off, and the escapes inside are read.
  defp scanstr(text) do
    text
    |> binary_part(1, byte_size(text) - 2)
    |> unescape("")
  end

  defp unescape("", acc), do: acc
  defp unescape(<<?', ?', rest::binary>>, acc), do: unescape(rest, acc <> "'")
  defp unescape(<<?\\, ?b, rest::binary>>, acc), do: unescape(rest, acc <> "\b")
  defp unescape(<<?\\, ?f, rest::binary>>, acc), do: unescape(rest, acc <> "\f")
  defp unescape(<<?\\, ?n, rest::binary>>, acc), do: unescape(rest, acc <> "\n")
  defp unescape(<<?\\, ?r, rest::binary>>, acc), do: unescape(rest, acc <> "\r")
  defp unescape(<<?\\, ?t, rest::binary>>, acc), do: unescape(rest, acc <> "\t")

  defp unescape(<<?\\, digit, rest::binary>>, acc) when digit in ?0..?7 do
    {digits, rest} = octal(rest, <<digit>>, 2)
    unescape(rest, acc <> <<String.to_integer(digits, 8)::utf8>>)
  end

  defp unescape(<<?\\, char::utf8, rest::binary>>, acc), do: unescape(rest, acc <> <<char::utf8>>)
  defp unescape(<<char::utf8, rest::binary>>, acc), do: unescape(rest, acc <> <<char::utf8>>)

  defp octal(<<digit, rest::binary>>, acc, more) when digit in ?0..?7 and more > 0,
    do: octal(rest, acc <> <<digit>>, more - 1)

  defp octal(rest, acc, _more), do: {acc, rest}

  # Columns count characters, as the editor does, from a byte offset.
  defp token_span(token, line, line_no) do
    col = String.length(binary_part(line, 0, token.offset)) + 1
    end_col = col + String.length(token.text)
    %{line: line_no, col: col, end_line: line_no, end_col: end_col}
  end

  defp line_span(line, line_no),
    do: %{line: line_no, col: 1, end_line: line_no, end_col: String.length(line) + 1}
end
