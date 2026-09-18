defmodule Postern.GucValueTest do
  use ExUnit.Case, async: true

  alias Postern.GucValue

  doctest GucValue

  @memory_hint ~s(Valid units for this parameter are "B", "kB", "MB", "GB", and "TB".)
  @time_hint ~s(Valid units for this parameter are "us", "ms", "s", "min", "h", and "d".)

  # Each case is a value, the base unit of the setting, and what parse_int
  # in guc.c makes of it, checked against a running 18 and, for the number
  # rules, a 13.
  @integers [
    {"0600", nil, {:ok, 384}},
    {"0777", nil, {:ok, 511}},
    {"0x80", nil, {:ok, 128}},
    {"0X1f", nil, {:ok, 31}},
    {"089", nil, {:error, nil}},
    {"100.7", nil, {:ok, 101}},
    {"1.5e3", nil, {:ok, 1500}},
    {"1e3", nil, {:ok, 1000}},
    {".5", nil, {:ok, 0}},
    {"1.", nil, {:ok, 1}},
    {"-1", nil, {:ok, -1}},
    {"+5", nil, {:ok, 5}},
    {"  7  ", nil, {:ok, 7}},
    {"", nil, {:error, nil}},
    {"abc", nil, {:error, nil}},
    {"nan", nil, {:error, nil}},
    {"inf", nil, {:error, "Value exceeds integer range."}},
    {"99999999999", nil, {:error, "Value exceeds integer range."}},
    {"5MB", nil, {:error, nil}},
    {"64MB", {:memory, :kb}, {:ok, 65_536}},
    {"64 MB", {:memory, :kb}, {:ok, 65_536}},
    {"64 MB ", {:memory, :kb}, {:ok, 65_536}},
    {"128mb", {:memory, :kb}, {:error, @memory_hint}},
    {"64MBx", {:memory, :kb}, {:error, @memory_hint}},
    {"64 MB x", {:memory, :kb}, {:error, @memory_hint}},
    {"5xx", {:memory, :kb}, {:error, @memory_hint}},
    {"1.5GB", {:memory, :kb}, {:ok, 1_572_864}},
    {"1.5kB", {:memory, :kb}, {:ok, 2}},
    {"1kB", {:memory, :blocks}, {:ok, 0}},
    {"16MB", {:memory, :blocks}, {:ok, 2048}},
    {"1GB", {:memory, :mb}, {:ok, 1024}},
    {"3B", {:memory, :byte}, {:ok, 3}},
    {"5MB", {:time, :ms}, {:error, @time_hint}},
    {"1h", {:time, :ms}, {:ok, 3_600_000}},
    {"500us", {:time, :ms}, {:ok, 0}},
    {"1500us", {:time, :ms}, {:ok, 2}},
    {"90s", {:time, :min}, {:ok, 2}},
    {"1d", {:time, :s}, {:ok, 86_400}},
    {"MB64", {:memory, :kb}, {:error, nil}}
  ]

  @reals [
    {"0x80", nil, {:ok, 128.0}},
    {"0100", nil, {:ok, 100.0}},
    {"1e-3", nil, {:ok, 0.001}},
    {"2ms", {:time, :ms}, {:ok, 2.0}},
    {"1.5", nil, {:ok, 1.5}},
    {"abc", nil, {:error, nil}},
    {"2min", nil, {:error, nil}},
    {"2mins", {:time, :ms}, {:error, @time_hint}},
    {"inf", nil, {:ok, :infinity}},
    {"-infinity", nil, {:ok, :negative_infinity}}
  ]

  @booleans [
    {"on", {:ok, true}},
    {"of", {:ok, false}},
    {"o", :error},
    {"t", {:ok, true}},
    {"TRUE", {:ok, true}},
    {"tru", {:ok, true}},
    {"truex", :error},
    {"yes", {:ok, true}},
    {"n", {:ok, false}},
    {"1", {:ok, true}},
    {"0", {:ok, false}},
    {"10", :error},
    {"", :error}
  ]

  for {value, base, expected} <- @integers do
    test "parse_int #{inspect(value)} in #{inspect(base)}" do
      assert GucValue.parse_int(unquote(value), unquote(base)) == unquote(Macro.escape(expected))
    end
  end

  for {value, base, expected} <- @reals do
    test "parse_real #{inspect(value)} in #{inspect(base)}" do
      assert GucValue.parse_real(unquote(value), unquote(base)) == unquote(Macro.escape(expected))
    end
  end

  for {value, expected} <- @booleans do
    test "parse_bool #{inspect(value)}" do
      assert GucValue.parse_bool(unquote(value)) == unquote(Macro.escape(expected))
    end
  end

  test "the base a pg_settings unit stands for" do
    assert GucValue.base("8kB") == {:memory, :blocks}
    assert GucValue.base("kB") == {:memory, :kb}
    assert GucValue.base("min") == {:time, :min}
    assert GucValue.base(nil) == nil
  end

  test "format_g prints the way %g does" do
    assert GucValue.format_g(0.0) == "0"
    assert GucValue.format_g(1.0) == "1"
    assert GucValue.format_g(0.9) == "0.9"
    assert GucValue.format_g(100.0) == "100"
    assert GucValue.format_g(123_456.0) == "123456"
    assert GucValue.format_g(1_234_567.0) == "1.23457e+06"
    assert GucValue.format_g(0.0001) == "0.0001"
    assert GucValue.format_g(0.00001) == "1e-05"
    assert GucValue.format_g(String.to_float("1.79769e308")) == "1.79769e+308"
    assert GucValue.format_g(-1.5) == "-1.5"
  end
end
