defmodule Postern.StringSettings do
  @moduledoc """
  The check hooks of the string settings a reload runs, in their words.

  Most string settings take anything, and the ones that do not are each a
  small vocabulary or a grammar: the DateStyle words and the two of them that
  may not disagree, the log destinations a version has, the resource managers
  that can be masked, the encodings and their aliases, the time zone names
  and the POSIX specification a name can fall back to, the recovery targets,
  the grammar of `synchronous_standby_names`, and the list syntax of
  `search_path` and `temp_tablespaces`, which a file gets wrong where SET
  cannot, since SET quotes a string constant as one name. Each check answers `:ok`,
  `{:invalid, detail}` for the server's `invalid value for parameter` with the
  detail it adds or `nil`, or `{:error, message}` where the server replaces
  the message altogether. The words come from a running 18 and the source of
  13 through 18; the checks that need the running server, such as whether a
  tablespace exists, are left to it.
  """

  @styles %{"iso" => :iso, "sql" => :sql, "german" => :german}
  @orders %{"ymd" => :ymd, "dmy" => :dmy, "mdy" => :mdy, "us" => :mdy}
  @destinations ~w(stderr csvlog syslog eventlog)
  @masked_rmgrs ~w(heap2 heap btree hash gin gist sequence spgist brin generic)
  @io_direct ~w(data wal wal_init)
  @max_hours 24 * 7
  @uint64_max 18_446_744_073_709_551_615

  @type result :: :ok | {:invalid, String.t() | nil} | {:error, String.t()}

  @doc "Checks a string setting's value the way its check hook does."
  @spec check(String.t(), String.t(), map(), pos_integer()) :: result()
  def check(name, value, catalog, version),
    do: hook(String.downcase(name), value, catalog, version)

  defp hook("datestyle", value, _catalog, version), do: datestyle(value, version)
  defp hook("timezone", value, catalog, _version), do: timezone(value, catalog)
  defp hook("log_timezone", value, catalog, _version), do: timezone(value, catalog)

  defp hook("log_destination", value, _catalog, version),
    do: keywords(value, destinations(version))

  defp hook("wal_consistency_checking", value, _catalog, _version),
    do: keywords(value, ["all" | @masked_rmgrs])

  defp hook("client_encoding", value, catalog, _version), do: encoding(value, catalog)
  defp hook("recovery_target", value, _catalog, _version), do: recovery_target(value)
  defp hook("recovery_target_lsn", value, _catalog, _version), do: lsn(value)
  defp hook("recovery_target_xid", value, _catalog, _version), do: number(value, nil)
  defp hook("recovery_target_timeline", value, _catalog, version), do: timeline(value, version)
  defp hook("recovery_target_name", value, _catalog, version), do: target_name(value, version)
  defp hook("recovery_target_time", value, _catalog, _version), do: target_time(value)
  defp hook("synchronous_standby_names", value, _catalog, _version), do: standby_names(value)
  defp hook("debug_io_direct", value, _catalog, version), do: io_direct(value, version)

  defp hook("search_path", value, _catalog, _version),
    do: with({:ok, _names} <- list(value), do: :ok)

  defp hook("temp_tablespaces", value, _catalog, _version),
    do: with({:ok, _names} <- list(value), do: :ok)

  defp hook(_name, _value, _catalog, _version), do: :ok

  @doc "The values worth offering for a string setting, for completion."
  @spec completions(String.t(), map(), pos_integer()) :: [String.t()]
  def completions(name, catalog, version), do: vocabulary(String.downcase(name), catalog, version)

  defp vocabulary("datestyle", _catalog, _version),
    do: ~w(ISO SQL Postgres German YMD DMY MDY Euro US Default)

  defp vocabulary("timezone", catalog, _version), do: Map.get(catalog, :timezones, [])
  defp vocabulary("log_timezone", catalog, _version), do: Map.get(catalog, :timezones, [])
  defp vocabulary("log_destination", _catalog, version), do: destinations(version)

  defp vocabulary("wal_consistency_checking", _catalog, _version),
    do: ~w(all Heap2 Heap Btree Hash Gin Gist Sequence SPGist BRIN Generic)

  defp vocabulary("client_encoding", catalog, _version), do: Map.get(catalog, :encodings, [])
  defp vocabulary("recovery_target", _catalog, _version), do: ["immediate"]
  defp vocabulary("recovery_target_timeline", _catalog, _version), do: ~w(current latest)
  defp vocabulary("debug_io_direct", _catalog, _version), do: @io_direct
  defp vocabulary(_name, _catalog, _version), do: []

  @doc "Whether a string setting is a list, so that a completed value may be followed by another."
  @spec list?(String.t()) :: boolean()
  def list?(name),
    do:
      String.downcase(name) in ~w(datestyle log_destination wal_consistency_checking debug_io_direct)

  @doc """
  Splits a list the way SplitIdentifierString does: names separated by
  commas, white space around them, a double-quoted name taken as written
  with `""` for a quote, an unquoted one lowercased, and no empty name.

  ## Examples

      iex> Postern.StringSettings.split_identifiers(~s( ISO , "Mixed Case",ymd ))
      {:ok, ["iso", "Mixed Case", "ymd"]}

      iex> Postern.StringSettings.split_identifiers("iso,,ymd")
      :error

      iex> Postern.StringSettings.split_identifiers("")
      {:ok, []}

  """
  @spec split_identifiers(String.t(), keyword()) :: {:ok, [String.t()]} | :error
  def split_identifiers(text, opts \\ []) do
    downcase = Keyword.get(opts, :downcase, true)

    case String.trim_leading(text) do
      "" -> {:ok, []}
      rest -> names(rest, downcase, [])
    end
  end

  defp names(<<?", rest::binary>>, downcase, acc) do
    case quoted(rest, "") do
      {:ok, name, rest} -> after_name(rest, downcase, [name | acc])
      :error -> :error
    end
  end

  defp names(rest, downcase, acc) do
    case Regex.run(~r/^[^,\s"]+/, rest) do
      [name] ->
        name = if downcase, do: String.downcase(name), else: name
        rest = binary_part(rest, byte_size(name), byte_size(rest) - byte_size(name))
        after_name(rest, downcase, [name | acc])

      nil ->
        :error
    end
  end

  defp after_name(rest, downcase, acc) do
    case String.trim_leading(rest) do
      "" -> {:ok, Enum.reverse(acc)}
      "," <> rest -> names(String.trim_leading(rest), downcase, acc)
      _other -> :error
    end
  end

  defp quoted(<<?", ?", rest::binary>>, acc), do: quoted(rest, acc <> "\"")
  defp quoted(<<?", rest::binary>>, acc), do: {:ok, acc, rest}
  defp quoted(<<char::utf8, rest::binary>>, acc), do: quoted(rest, acc <> <<char::utf8>>)
  defp quoted("", _acc), do: :error

  # A second style or a second order that differs from the first is a
  # conflict. GERMAN also sets DMY, but not as an order given, so an order
  # after it is no conflict, and DEFAULT takes what the server was built
  # with.
  defp datestyle(value, version) do
    with {:ok, words} <- list(value) do
      words
      |> Enum.reduce_while({:ok, %{style: nil, order: nil, given: false}}, &datestyle_step/2)
      |> case do
        {:ok, _state} -> :ok
        :conflict -> {:invalid, ~s(Conflicting "#{datestyle_name(version)}" specifications.)}
        invalid -> invalid
      end
    end
  end

  # 18 started writing the setting's name in its own case in the detail.
  defp datestyle_name(version) when version >= 18, do: "DateStyle"
  defp datestyle_name(_version), do: "datestyle"

  defp datestyle_step(word, {:ok, state}) do
    case datestyle_word(word) do
      {:style, new} -> style_step(new, state)
      {:order, new} -> order_step(new, state)
      :default -> {:cont, {:ok, state}}
      :unknown -> {:halt, {:invalid, ~s(Unrecognized key word: "#{word}".)}}
    end
  end

  defp style_step(new, %{style: style}) when style not in [nil, new], do: {:halt, :conflict}

  defp style_step(:german, state),
    do: {:cont, {:ok, %{state | style: :german, order: state.order || :dmy}}}

  defp style_step(new, state), do: {:cont, {:ok, %{state | style: new}}}

  defp order_step(new, %{given: true, order: order}) when order != new, do: {:halt, :conflict}
  defp order_step(new, state), do: {:cont, {:ok, %{state | order: new, given: true}}}

  defp datestyle_word(word) do
    cond do
      Map.has_key?(@styles, word) -> {:style, @styles[word]}
      String.starts_with?(word, "postgres") -> {:style, :postgres}
      Map.has_key?(@orders, word) -> {:order, @orders[word]}
      String.starts_with?(word, "euro") -> {:order, :dmy}
      String.starts_with?(word, "noneuro") -> {:order, :mdy}
      word == "default" -> :default
      true -> :unknown
    end
  end

  defp keywords(value, allowed) do
    with {:ok, words} <- list(value) do
      case Enum.find(words, &(&1 not in allowed)) do
        nil -> :ok
        word -> {:invalid, ~s(Unrecognized key word: "#{word}".)}
      end
    end
  end

  defp list(value) do
    case split_identifiers(value) do
      {:ok, words} -> {:ok, words}
      :error -> {:invalid, "List syntax is invalid."}
    end
  end

  defp destinations(version) when version >= 15, do: @destinations ++ ["jsonlog"]
  defp destinations(_version), do: @destinations

  # A number of hours, a name the server knows in any case, or a POSIX
  # specification such as EST5EDT or Foo5Bar,M3.2.0,M11.1.0, which the
  # server tries when the name is not in its files. Without a list of names
  # to check against there is nothing to say.
  defp timezone(value, catalog) do
    names = Map.get(catalog, :timezones, [])

    cond do
      names == [] -> :ok
      String.starts_with?(String.downcase(value), "interval") -> :ok
      match?({hours, ""} when abs(hours) <= @max_hours, Float.parse(value)) -> :ok
      String.downcase(value) in Enum.map(names, &String.downcase/1) -> :ok
      true -> posix(value)
    end
  end

  # tzparse: a standard name and its offset, then a daylight name with an
  # offset of its own and a pair of rules if it wants them. An hour count
  # runs up to a week, and an offset with seconds in it is a zone the
  # server takes for one with leap seconds and refuses as such.
  defp posix(value) do
    with {:ok, rest} <- zone_name(value),
         {:ok, seconds, rest} <- offset(rest, false),
         {:ok, seconds} <- daylight(rest, seconds) do
      if seconds,
        do:
          {:error,
           ~s(time zone "#{value}" appears to use leap seconds\nPostgreSQL does not support leap seconds.)},
        else: :ok
    else
      _error -> {:invalid, nil}
    end
  end

  defp daylight("", seconds), do: {:ok, seconds}

  defp daylight(rest, seconds) do
    with {:ok, rest} <- zone_name(rest),
         {:ok, seconds, rest} <- offset(rest, seconds, optional: true) do
      case rest do
        "" -> {:ok, seconds}
        "," <> rest -> rules(rest, seconds)
        _other -> :error
      end
    end
  end

  defp rules(rest, seconds) do
    with {:ok, seconds, rest} <- rule(rest, seconds),
         "," <> rest <- rest,
         {:ok, seconds, ""} <- rule(rest, seconds) do
      {:ok, seconds}
    else
      _error -> :error
    end
  end

  defp rule(rest, seconds) do
    case Regex.run(~r/^(?:J([0-9]{1,3})|M([0-9]{1,2})\.([0-9])\.([0-9])|([0-9]{1,3}))/, rest) do
      [matched, julian] when julian != "" ->
        rule_time(matched, rest, seconds, String.to_integer(julian) in 1..365)

      [matched, _julian, month, week, day] ->
        {month, week, day} =
          {String.to_integer(month), String.to_integer(week), String.to_integer(day)}

        rule_time(matched, rest, seconds, month in 1..12 and week in 1..5 and day in 0..6)

      [matched, _julian, _month, _week, _day, zero_based] ->
        rule_time(matched, rest, seconds, String.to_integer(zero_based) in 0..365)

      nil ->
        :error
    end
  end

  defp rule_time(_matched, _rest, _seconds, false), do: :error

  defp rule_time(matched, rest, seconds, true) do
    case binary_part(rest, byte_size(matched), byte_size(rest) - byte_size(matched)) do
      "/" <> rest -> offset(rest, seconds)
      rest -> {:ok, seconds, rest}
    end
  end

  defp zone_name(text) do
    case Regex.run(~r/^(?:<[+\-0-9A-Za-z]+>|[A-Za-z]+)/, text) do
      [name] -> {:ok, binary_part(text, byte_size(name), byte_size(text) - byte_size(name))}
      nil -> :error
    end
  end

  defp offset(text, seconds, opts \\ []) do
    optional = Keyword.get(opts, :optional, false)

    case Regex.run(~r/^[+-]?([0-9]{1,3})(?::([0-9]{1,2})(?::([0-9]{1,2}))?)?/, text) do
      [matched | parts] ->
        offset_parts(Enum.map(parts, &String.to_integer/1), matched, text, seconds)

      nil when optional ->
        {:ok, seconds, text}

      nil ->
        :error
    end
  end

  defp offset_parts([hours | rest], matched, text, seconds) do
    minutes = Enum.at(rest, 0, 0)
    secs = Enum.at(rest, 1, 0)

    if hours <= @max_hours and minutes < 60 and secs < 60 do
      remaining = binary_part(text, byte_size(matched), byte_size(text) - byte_size(matched))
      {:ok, seconds or secs != 0, remaining}
    else
      :error
    end
  end

  # pg_char_to_encoding keeps letters and digits, lowercased, and looks the
  # rest up among the canonical names and their aliases.
  defp encoding(value, catalog) do
    known = Map.get(catalog, :encodings, []) ++ Map.get(catalog, :encoding_aliases, [])
    cleaned = value |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

    cond do
      known == [] -> :ok
      cleaned in Enum.map(known, &clean/1) -> :ok
      true -> {:invalid, nil}
    end
  end

  defp clean(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  defp recovery_target(value) when value in ["", "immediate"], do: :ok
  defp recovery_target(_value), do: {:invalid, ~s(The only allowed value is "immediate".)}

  defp lsn(""), do: :ok

  defp lsn(value),
    do:
      if(Regex.match?(~r|^[0-9A-Fa-f]{1,8}/[0-9A-Fa-f]{1,8}$|, value),
        do: :ok,
        else: {:invalid, nil}
      )

  # strtou64 in base 0 says nothing about a value that is not a number at
  # all, so only one too large for 64 bits is refused.
  defp number("", _detail), do: :ok

  defp number(value, detail) do
    magnitude =
      case Regex.run(~r/^\s*[+-]?(0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)/, value) do
        [_all, "0" <> <<x, hex::binary>>] when x in [?x, ?X] -> String.to_integer(hex, 16)
        [_all, "0" <> octal] when octal != "" -> String.to_integer(octal, 8)
        [_all, digits] -> String.to_integer(digits)
        nil -> 0
      end

    if magnitude > @uint64_max, do: {:invalid, detail}, else: :ok
  end

  defp timeline(value, _version) when value in ["current", "latest"], do: :ok

  defp timeline(value, version),
    do: number(value, "#{named(version, "recovery_target_timeline")} is not a valid number.")

  defp target_name(value, version) do
    if byte_size(value) >= 64,
      do:
        {:invalid,
         "#{named(version, "recovery_target_name")} is too long (maximum 63 characters)."},
      else: :ok
  end

  # 17 put quotes around a setting's name in these details.
  defp named(version, name) when version >= 17, do: ~s("#{name}")
  defp named(_version, name), do: name

  # The server parses a timestamp with time zone and refuses the special
  # words; what it would make of every other string is its own, so only a
  # value with no digit in it at all is refused here.
  defp target_time(""), do: :ok

  defp target_time(value) do
    lower = String.downcase(value)

    cond do
      lower in ~w(now today tomorrow yesterday epoch infinity -infinity) -> {:invalid, nil}
      not Regex.match?(~r/\d/, value) -> {:invalid, nil}
      true -> :ok
    end
  end

  # syncrep_gram.y: a list of names, or a count and a parenthesised list,
  # with ANY or FIRST before the count.
  defp standby_names(""), do: :ok

  defp standby_names(value) do
    with {:ok, tokens} <- standby_tokens(value, []),
         {:ok, count} <- standby_config(tokens) do
      if count <= 0,
        do: {:error, "number of synchronous standbys (#{count}) must be greater than zero"},
        else: :ok
    else
      {:unterminated} -> {:invalid, "unterminated quoted identifier at end of input"}
      {:near, text} -> {:invalid, ~s(syntax error at or near "#{text}")}
      :end -> {:invalid, "syntax error at end of input"}
    end
  end

  defp standby_tokens("", acc), do: {:ok, Enum.reverse(acc)}

  defp standby_tokens(<<?", rest::binary>>, acc) do
    case quoted(rest, "") do
      {:ok, name, rest} -> standby_tokens(rest, [{:name, name} | acc])
      :error -> {:unterminated}
    end
  end

  defp standby_tokens(text, acc) do
    cond do
      match = Regex.run(~r/^[ \t\n\r\f\v]+/, text) ->
        standby_tokens(drop(text, match), acc)

      match = Regex.run(~r/^[A-Za-z\x80-\xff_][A-Za-z\x80-\xff_0-9$]*/, text) ->
        standby_tokens(drop(text, match), [standby_word(hd(match)) | acc])

      match = Regex.run(~r/^[0-9]+/, text) ->
        standby_tokens(drop(text, match), [{:num, hd(match)} | acc])

      true ->
        <<char::utf8, rest::binary>> = text
        standby_tokens(rest, [standby_punctuation(<<char::utf8>>) | acc])
    end
  end

  defp standby_word(word) do
    case String.downcase(word) do
      "any" -> {:any, word}
      "first" -> {:first, word}
      _name -> {:name, word}
    end
  end

  defp standby_punctuation("*"), do: {:name, "*"}
  defp standby_punctuation(","), do: {:comma, ","}
  defp standby_punctuation("("), do: {:open, "("}
  defp standby_punctuation(")"), do: {:close, ")"}
  defp standby_punctuation(other), do: {:junk, other}

  defp drop(text, [matched]),
    do: binary_part(text, byte_size(matched), byte_size(text) - byte_size(matched))

  defp standby_config([{keyword, _text}, {:num, count} | rest]) when keyword in [:any, :first],
    do: parenthesised(rest, count)

  defp standby_config([{keyword, _text}, token | _rest]) when keyword in [:any, :first],
    do: {:near, elem(token, 1)}

  defp standby_config([{keyword, _text}]) when keyword in [:any, :first], do: :end

  defp standby_config([{:num, count}, {:open, _text} | rest]),
    do: parenthesised([{:open, "("} | rest], count)

  defp standby_config(tokens), do: with({:ok, []} <- standby_list(tokens), do: {:ok, 1})

  defp parenthesised([{:open, _text} | rest], count) do
    case standby_list(rest) do
      {:ok, [{:close, _text}]} -> {:ok, String.to_integer(count)}
      {:ok, [{:close, _text}, token | _rest]} -> {:near, elem(token, 1)}
      {:ok, [token | _rest]} -> {:near, elem(token, 1)}
      {:ok, []} -> :end
      error -> error
    end
  end

  defp parenthesised([token | _rest], _count), do: {:near, elem(token, 1)}
  defp parenthesised([], _count), do: :end

  # A name, then either the end, or a comma and another name.
  defp standby_list([{type, _text} | rest]) when type in [:name, :num] do
    case rest do
      [{:comma, _text} | after_comma] -> standby_list_after_comma(after_comma)
      [{:close, _text} | _more] -> {:ok, rest}
      [] -> {:ok, []}
      [token | _more] -> {:near, elem(token, 1)}
    end
  end

  defp standby_list([token | _rest]), do: {:near, elem(token, 1)}
  defp standby_list([]), do: :end

  defp standby_list_after_comma([{type, _text} | _rest] = tokens) when type in [:name, :num],
    do: standby_list(tokens)

  defp standby_list_after_comma([token | _rest]), do: {:near, elem(token, 1)}
  defp standby_list_after_comma([]), do: :end

  # 16's details were lower case without a period; 17 gave them a capital
  # and one.
  defp io_direct(value, version) do
    case split_identifiers(value, downcase: false) do
      {:ok, words} ->
        case Enum.find(words, &(String.downcase(&1) not in @io_direct)) do
          nil -> :ok
          word when version >= 17 -> {:invalid, ~s(Invalid option "#{word}".)}
          word -> {:invalid, ~s(invalid option "#{word}")}
        end

      :error when version >= 17 ->
        {:invalid, ~s(Invalid list syntax in parameter "debug_io_direct".)}

      :error ->
        {:invalid, ~s(invalid list syntax in parameter "debug_io_direct")}
    end
  end
end
