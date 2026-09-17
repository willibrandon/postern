defmodule Postern.Parser.AuthLines do
  @moduledoc """
  The records of `pg_hba.conf` and `pg_ident.conf` as the server reads them.

  Since 14 a line that ends with a backslash goes on with the next one.
  `tokenize_auth_file` strips the backslash and appends the next line as it
  is, with nothing in between, before it looks for a comment or a quote, so
  the continuation works inside either, and an empty next line ends the
  record. The record carries the number of the line it starts on, which is
  the line `pg_hba_file_rules` reports, and a token still knows the physical
  line and column it stands on.
  """

  @type segment :: %{offset: non_neg_integer(), line: pos_integer(), raw: String.t()}
  @type t :: %{text: String.t(), line: pos_integer(), segments: [segment()]}
  @type span :: %{
          line: pos_integer(),
          col: pos_integer(),
          end_line: pos_integer(),
          end_col: pos_integer()
        }

  @doc "Splits a file into records, joining continued lines unless told not to."
  @spec records(String.t(), boolean()) :: [t()]
  def records(content, continuations? \\ true) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.with_index(1)
    |> collect(continuations?, [])
  end

  @doc "One physical line as a record of its own."
  @spec single(String.t(), pos_integer()) :: t()
  def single(text, line),
    do: %{text: text, line: line, segments: [%{offset: 0, line: line, raw: text}]}

  @doc "The physical line and column of a byte offset into the record's text."
  @spec position(t(), non_neg_integer()) :: {pos_integer(), pos_integer()}
  def position(%{segments: segments}, offset) do
    segment = Enum.reduce(segments, hd(segments), &if(&1.offset <= offset, do: &1, else: &2))
    {segment.line, offset - segment.offset + 1}
  end

  @doc "The span of the whole record, or of the part from a byte offset on."
  @spec span(t(), non_neg_integer()) :: span()
  def span(%{segments: segments} = record, from \\ 0) do
    {line, col} = position(record, from)
    last = List.last(segments)
    %{line: line, col: col, end_line: last.line, end_col: String.length(last.raw) + 1}
  end

  @doc "The span of a piece of the record, from one byte offset to another."
  @spec span(t(), non_neg_integer(), non_neg_integer()) :: span()
  def span(record, from, to) do
    {line, col} = position(record, from)
    {end_line, end_col} = position(record, to)
    %{line: line, col: col, end_line: end_line, end_col: end_col}
  end

  # A record is the lines up to the first that does not end in a backslash,
  # where the backslash must be past the last one stripped, so that two
  # backslashes followed by an empty line do not read as two continuations.
  defp collect([], _continuations?, acc), do: Enum.reverse(acc)

  defp collect([{raw, line} | rest], continuations?, acc) do
    record = %{text: "", line: line, segments: []}
    {record, rest} = extend(record, raw, line, rest, continuations?, 0)
    collect(rest, continuations?, [record | acc])
  end

  defp extend(record, raw, line, rest, continuations?, last_backslash) do
    segment = %{offset: byte_size(record.text), line: line, raw: raw}
    text = record.text <> raw
    record = %{record | text: text, segments: record.segments ++ [segment]}

    if continuations? and byte_size(text) > last_backslash and String.ends_with?(text, "\\") do
      record = %{record | text: binary_part(text, 0, byte_size(text) - 1)}

      case rest do
        [{next, next_line} | rest] ->
          extend(record, next, next_line, rest, continuations?, byte_size(record.text))

        [] ->
          {record, []}
      end
    else
      {record, rest}
    end
  end
end
