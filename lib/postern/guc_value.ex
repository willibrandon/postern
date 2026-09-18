defmodule Postern.GucValue do
  @moduledoc """
  Reads a value the way guc.c reads one.

  `parse_int` tries `strtol` in base 0 first, so a leading `0` is octal and
  `0x` is hex, and falls back to `strtod` when it stops at a decimal point
  or an exponent, so a fraction rounds to the nearest integer. White space
  may separate the number from its unit, the unit is matched as written,
  `MB` and not `mb`, and a fraction of a unit rounds to a multiple of the
  next smaller one. `parse_real` is `strtod` alone. `parse_bool` takes any
  prefix of `true`, `false`, `yes` and `no`, at least two letters of `on`
  and `off`, and `1` or `0` on their own. The hints are the server's.
  """

  @int_min -2_147_483_648
  @int_max 2_147_483_647
  @max_unit_len 3

  @memory_units_hint ~s(Valid units for this parameter are "B", "kB", "MB", "GB", and "TB".)
  @time_units_hint ~s(Valid units for this parameter are "us", "ms", "s", "min", "h", and "d".)
  @range_hint "Value exceeds integer range."

  @kib 1024.0
  @mib 1024.0 * 1024.0
  @gib 1024.0 * 1024.0 * 1024.0
  @tib 1024.0 * 1024.0 * 1024.0 * 1024.0
  @block 8192.0

  # The unit tables in guc.c, one row per unit a base takes, largest first,
  # since a fraction rounds to a multiple of the row below it.
  @memory_table %{
    byte: [{"TB", @tib}, {"GB", @gib}, {"MB", @mib}, {"kB", @kib}, {"B", 1.0}],
    kb: [{"TB", @gib}, {"GB", @mib}, {"MB", @kib}, {"kB", 1.0}, {"B", 1.0 / @kib}],
    mb: [{"TB", @mib}, {"GB", @kib}, {"MB", 1.0}, {"kB", 1.0 / @kib}, {"B", 1.0 / @mib}],
    blocks: [
      {"TB", @gib / (@block / 1024)},
      {"GB", @mib / (@block / 1024)},
      {"MB", @kib / (@block / 1024)},
      {"kB", 1.0 / (@block / 1024)},
      {"B", 1.0 / @block}
    ]
  }

  @time_table %{
    ms: [
      {"d", 1000.0 * 60 * 60 * 24},
      {"h", 1000.0 * 60 * 60},
      {"min", 1000.0 * 60},
      {"s", 1000.0},
      {"ms", 1.0},
      {"us", 1.0 / 1000}
    ],
    s: [
      {"d", 60.0 * 60 * 24},
      {"h", 60.0 * 60},
      {"min", 60.0},
      {"s", 1.0},
      {"ms", 1.0 / 1000},
      {"us", 1.0 / (1000 * 1000)}
    ],
    min: [
      {"d", 60.0 * 24},
      {"h", 60.0},
      {"min", 1.0},
      {"s", 1.0 / 60},
      {"ms", 1.0 / (1000 * 60)},
      {"us", 1.0 / (1000 * 1000 * 60)}
    ]
  }

  @type base :: {:memory, :byte | :kb | :mb | :blocks} | {:time, :ms | :s | :min} | nil

  @doc """
  The base a setting's unit in `pg_settings` stands for, or `nil` for a
  setting that takes no unit. Blocks of WAL and of data are both `8kB`
  and convert the same way.
  """
  @spec base(String.t() | nil) :: base()
  def base("B"), do: {:memory, :byte}
  def base("kB"), do: {:memory, :kb}
  def base("MB"), do: {:memory, :mb}
  def base("8kB"), do: {:memory, :blocks}
  def base("ms"), do: {:time, :ms}
  def base("s"), do: {:time, :s}
  def base("min"), do: {:time, :min}
  def base(_none), do: nil

  @doc """
  Reads an integer setting's value in its base unit, or says why not, with
  the hint the server would give or `nil` where it gives none.

  ## Examples

      iex> Postern.GucValue.parse_int("0600", nil)
      {:ok, 384}

      iex> Postern.GucValue.parse_int("1.5GB", {:memory, :kb})
      {:ok, 1572864}

      iex> Postern.GucValue.parse_int("128mb", {:memory, :kb})
      {:error, ~s(Valid units for this parameter are "B", "kB", "MB", "GB", and "TB".)}

      iex> Postern.GucValue.parse_int("5MB", nil)
      {:error, nil}

  """
  @spec parse_int(String.t(), base()) :: {:ok, integer()} | {:error, String.t() | nil}
  def parse_int(value, base) do
    with {:ok, number, rest} <- integer_or_float(value),
         {:ok, number} <- with_unit(number, rest, base) do
      case rint(number) do
        rounded when is_atom(rounded) -> {:error, @range_hint}
        rounded when rounded > @int_max or rounded < @int_min -> {:error, @range_hint}
        rounded -> {:ok, trunc(rounded)}
      end
    end
  end

  @doc """
  Reads a real setting's value in its base unit, or says why not.

  ## Examples

      iex> Postern.GucValue.parse_real("0x80", nil)
      {:ok, 128.0}

      iex> Postern.GucValue.parse_real("1.5h", {:time, :min})
      {:ok, 90.0}

  """
  @spec parse_real(String.t(), base()) ::
          {:ok, float() | :infinity | :negative_infinity} | {:error, String.t() | nil}
  def parse_real(value, base) do
    with {:ok, number, rest} <- strtod(value), do: with_unit(number, rest, base)
  end

  @doc """
  Reads a boolean the way `parse_bool_with_len` does.

  ## Examples

      iex> Postern.GucValue.parse_bool("of")
      {:ok, false}

      iex> Postern.GucValue.parse_bool("o")
      :error

  """
  @spec parse_bool(String.t()) :: {:ok, boolean()} | :error
  def parse_bool(value) do
    lower = String.downcase(value)

    case lower do
      <<?t, _rest::binary>> -> word(lower, "true", true)
      <<?f, _rest::binary>> -> word(lower, "false", false)
      <<?y, _rest::binary>> -> word(lower, "yes", true)
      <<?n, _rest::binary>> -> word(lower, "no", false)
      <<?o, _, _rest::binary>> -> on_or_off(lower)
      "1" -> {:ok, true}
      "0" -> {:ok, false}
      _other -> :error
    end
  end

  defp word(value, word, result),
    do: if(String.starts_with?(word, value), do: {:ok, result}, else: :error)

  defp on_or_off(value) do
    cond do
      String.starts_with?("on", value) -> {:ok, true}
      String.starts_with?("off", value) -> {:ok, false}
      true -> :error
    end
  end

  @doc """
  The value with its unit spelled the way the server takes it, when the
  unit differs from one of the base's units in case alone, or `nil`.

  ## Examples

      iex> Postern.GucValue.respelled("128mb", {:memory, :kb})
      "128MB"

      iex> Postern.GucValue.respelled("10 Min", {:time, :ms})
      "10 min"

      iex> Postern.GucValue.respelled("128MB", {:memory, :kb})
      nil

  """
  @spec respelled(String.t(), base()) :: String.t() | nil
  def respelled(_value, nil), do: nil

  def respelled(value, {dimension, base}) do
    table = if dimension == :memory, do: @memory_table, else: @time_table

    with [_all, number, space, unit, trailing] <-
           Regex.run(~r/^(\s*[+-]?[0-9A-Fa-fxX.]+)(\s*)([A-Za-z]{1,3})(\s*)$/, value),
         {canonical, _multiplier} <-
           Enum.find(Map.fetch!(table, base), fn {name, _m} ->
             String.downcase(name) == String.downcase(unit)
           end),
         true <- canonical != unit do
      number <> space <> canonical <> trailing
    else
      _ -> nil
    end
  end

  @doc """
  A number the way C's `%g` prints it, which is how the server prints a
  real setting's value and range: six significant digits, no trailing
  zeros, and an exponent once the number is large or small enough.

  ## Examples

      iex> Postern.GucValue.format_g(0.9)
      "0.9"

      iex> Postern.GucValue.format_g(1.79769e308)
      "1.79769e+308"

      iex> Postern.GucValue.format_g(100.0)
      "100"

  """
  @spec format_g(number() | :infinity | :negative_infinity) :: String.t()
  def format_g(:infinity), do: "inf"
  def format_g(:negative_infinity), do: "-inf"
  def format_g(number) when is_integer(number), do: format_g(number / 1)
  def format_g(+0.0), do: "0"
  def format_g(-0.0), do: "-0"

  def format_g(number) do
    [mantissa, exponent] =
      number
      |> :erlang.float_to_binary(scientific: 5)
      |> String.split("e")

    exponent = String.to_integer(exponent)

    if exponent < -4 or exponent >= 6 do
      sign = if exponent < 0, do: "-", else: "+"
      digits = exponent |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
      trim(mantissa) <> "e" <> sign <> digits
    else
      number |> :erlang.float_to_binary(decimals: max(5 - exponent, 0)) |> trim()
    end
  end

  defp trim(text) do
    if String.contains?(text, "."),
      do: text |> String.trim_trailing("0") |> String.trim_trailing("."),
      else: text
  end

  # strtol in base 0, then strtod when it stops at a decimal point or an
  # exponent, or parses nothing at all.
  defp integer_or_float(value) do
    case strtol(value) do
      {:ok, number, <<char, _rest::binary>> = rest} when char in [?., ?e, ?E] ->
        strtod(value)
        |> then(fn
          {:ok, float, rest2} -> {:ok, float, rest2}
          :error -> {:ok, number, rest}
        end)

      {:ok, number, rest} ->
        {:ok, number, rest}

      :error ->
        strtod(value)
    end
  end

  defp strtol(value) do
    {sign, rest} = sign(skip_space(value))

    case rest do
      <<?0, x, digits::binary>> when x in [?x, ?X] ->
        case take(digits, &hex_digit?/1) do
          {"", _digits} -> {:ok, 0, <<x, digits::binary>>}
          {hex, rest} -> {:ok, sign * String.to_integer(hex, 16), rest}
        end

      <<?0, _::binary>> ->
        {octal, rest} = take(rest, &(&1 in ?0..?7))
        {:ok, sign * String.to_integer(octal, 8), rest}

      _ ->
        case take(rest, &(&1 in ?0..?9)) do
          {"", _rest} -> :error
          {digits, rest} -> {:ok, sign * String.to_integer(digits), rest}
        end
    end
  end

  # strtod: a decimal number with an optional fraction and exponent, a hex
  # number, or an infinity; NaN is refused where the server refuses it.
  defp strtod(value) do
    {sign, rest} = sign(skip_space(value))
    lower = String.downcase(rest)

    cond do
      String.starts_with?(lower, "infinity") ->
        {:ok, infinity(sign), binary_part(rest, 8, byte_size(rest) - 8)}

      String.starts_with?(lower, "inf") ->
        {:ok, infinity(sign), binary_part(rest, 3, byte_size(rest) - 3)}

      String.starts_with?(lower, "nan") ->
        {:error, nil}

      match?(<<?0, x, _::binary>> when x in [?x, ?X], rest) ->
        hex_float(sign, binary_part(rest, 2, byte_size(rest) - 2))

      true ->
        case Regex.run(~r/^(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?/, rest) do
          [matched | _] ->
            {:ok, sign * to_float(matched),
             binary_part(rest, byte_size(matched), byte_size(rest) - byte_size(matched))}

          nil ->
            {:error, nil}
        end
    end
  end

  defp infinity(-1), do: :negative_infinity
  defp infinity(_sign), do: :infinity

  defp hex_float(sign, text) do
    case Regex.run(~r/^([0-9a-fA-F]*)(?:\.([0-9a-fA-F]*))?(?:[pP]([+-]?\d+))?/, text) do
      [matched, whole | rest] when whole != "" or rest != [] ->
        fraction = Enum.at(rest, 0) || ""
        exponent = Enum.at(rest, 1) || "0"

        number =
          String.to_integer(if(whole == "", do: "0", else: whole), 16) +
            fraction_value(fraction) * 1.0

        {:ok, sign * number * :math.pow(2, String.to_integer(exponent)),
         binary_part(text, byte_size(matched), byte_size(text) - byte_size(matched))}

      _ ->
        {:error, nil}
    end
  end

  defp fraction_value(""), do: 0.0

  defp fraction_value(hex),
    do: String.to_integer(hex, 16) / :math.pow(16, byte_size(hex))

  defp to_float(text) do
    text = if String.starts_with?(text, "."), do: "0" <> text, else: text
    text = if String.ends_with?(text, "."), do: text <> "0", else: text
    text = Regex.replace(~r/\.([eE])/, text, ".0\\1")
    {number, ""} = Float.parse(text)
    number
  end

  # White space may follow the number, and then a unit, which is the next
  # three characters at most, with nothing but white space after it.
  defp with_unit(number, rest, base) do
    case skip_space(rest) do
      "" ->
        {:ok, number}

      _unit when is_nil(base) ->
        {:error, nil}

      unit ->
        {name, rest} = take(unit, &(not space?(&1)), @max_unit_len)

        if String.trim_leading(rest) == "",
          do: convert(number, name, base),
          else: {:error, hint(base)}
    end
  end

  defp convert(number, name, {dimension, base}) do
    table = if dimension == :memory, do: @memory_table, else: @time_table
    rows = Map.fetch!(table, base)

    case Enum.find_index(rows, fn {unit, _multiplier} -> unit == name end) do
      nil ->
        {:error, hint({dimension, base})}

      _index when is_atom(number) ->
        {:ok, number}

      index ->
        {_unit, multiplier} = Enum.at(rows, index)
        converted = number * multiplier

        case Enum.at(rows, index + 1) do
          {_smaller, next} -> {:ok, rint(converted / next) * next}
          nil -> {:ok, converted}
        end
    end
  end

  defp hint({:memory, _base}), do: @memory_units_hint
  defp hint({:time, _base}), do: @time_units_hint

  # rint rounds a half to the even neighbour.
  defp rint(number) when is_atom(number), do: number

  defp rint(number) when is_float(number) do
    floor = Float.floor(number)
    difference = number - floor

    cond do
      difference < 0.5 -> floor
      difference > 0.5 -> floor + 1
      rem(trunc(floor), 2) == 0 -> floor
      true -> floor + 1
    end
  end

  defp rint(number), do: number

  defp sign(<<?-, rest::binary>>), do: {-1, rest}
  defp sign(<<?+, rest::binary>>), do: {1, rest}
  defp sign(rest), do: {1, rest}

  defp skip_space(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v],
    do: skip_space(rest)

  defp skip_space(rest), do: rest

  defp space?(char), do: char in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v]

  defp hex_digit?(char), do: char in ?0..?9 or char in ?a..?f or char in ?A..?F

  defp take(binary, keep?, limit \\ :infinity), do: take(binary, keep?, limit, "")

  defp take(<<char, rest::binary>>, keep?, limit, acc) when limit != 0 do
    if keep?.(char),
      do: take(rest, keep?, if(limit == :infinity, do: limit, else: limit - 1), acc <> <<char>>),
      else: {acc, <<char, rest::binary>>}
  end

  defp take(rest, _keep?, _limit, acc), do: {acc, rest}
end
