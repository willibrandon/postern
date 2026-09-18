defmodule Postern.RegexCheck do
  @moduledoc """
  Whether a regular expression the server would compile when a file loads
  compiles, in the words of its engine.

  The server's engine is Henry Spencer's, not PCRE, so a compile through
  Elixir's `Regex` can only stand in for the errors both refuse. The
  common ones are mapped to the messages in regerrs.h: parentheses,
  brackets and braces that do not close, a quantifier with nothing before
  it, a range out of order, a repetition count out of order, a backslash
  at the end, and a backreference to a group that is not there. Anything
  else PCRE refuses is let through, since the server might not.
  """

  @details [
    {"missing closing parenthesis", "parentheses () not balanced"},
    {"unmatched closing parenthesis", "parentheses () not balanced"},
    {"missing terminating ] for character class", "brackets [] not balanced"},
    {"quantifier does not follow a repeatable item", "quantifier operand invalid"},
    {"range out of order in character class", "invalid character range"},
    {"numbers out of order in {} quantifier", "invalid repetition count(s)"},
    {"\\ at end of pattern", "invalid escape \\ sequence"},
    {"reference to non-existent subpattern", "invalid backreference number"}
  ]

  @doc """
  Checks a pattern, without its leading slash.

  ## Examples

      iex> Postern.RegexCheck.check("^(.*")
      {:error, "parentheses () not balanced"}

      iex> Postern.RegexCheck.check("^(.*)@example\\\\.com$")
      :ok

      iex> Postern.RegexCheck.check("a\\\\y")
      :ok

  """
  @spec check(String.t()) :: :ok | {:error, String.t()}
  def check(pattern) do
    case Regex.compile(pattern) do
      {:ok, _regex} -> :ok
      {:error, {reason, _position}} -> detail(to_string(reason))
    end
  end

  defp detail(reason) do
    case Enum.find(@details, fn {pcre, _detail} -> String.starts_with?(reason, pcre) end) do
      {_pcre, detail} -> {:error, detail}
      nil -> :ok
    end
  end

  @doc "The server's message for a pattern that does not compile, or `nil`."
  @spec message(String.t()) :: String.t() | nil
  def message(pattern) do
    case check(pattern) do
      :ok -> nil
      {:error, detail} -> ~s(invalid regular expression "#{pattern}": #{detail})
    end
  end
end
