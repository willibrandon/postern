defmodule Postern.SettingHistoryTest do
  use ExUnit.Case, async: true

  alias Postern.SettingHistory

  doctest SettingHistory

  test "names the successor for a quick fix, and only a name" do
    assert SettingHistory.successor("wal_keep_segments", 13) == "wal_keep_size"
    assert SettingHistory.successor("force_parallel_mode", 18) == "debug_parallel_query"
    assert SettingHistory.successor("force_parallel_mode", 15) == nil
    assert SettingHistory.successor("standby_mode", 18) == nil
    assert SettingHistory.successor("silent_mode", 18) == nil
  end
end
