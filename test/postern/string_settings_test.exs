defmodule Postern.StringSettingsTest do
  use ExUnit.Case, async: true

  alias Postern.Catalog
  alias Postern.StringSettings

  doctest StringSettings

  @catalog Catalog.load(18)

  # Each case is a setting, a value, and what its check hook on 18 made of
  # it through SET or ALTER SYSTEM: taken, refused with the detail the
  # server adds, or refused with a message of its own.
  @cases [
    {"DateStyle", "iso, ymd", :ok},
    {"DateStyle", "sql,european", :ok},
    {"DateStyle", "postgres, us", :ok},
    {"DateStyle", "german", :ok},
    {"DateStyle", "german, ymd", :ok},
    {"DateStyle", "euro", :ok},
    {"DateStyle", "noneuropean", :ok},
    {"DateStyle", "default, iso", :ok},
    {"DateStyle", "ISO, SQL", {:invalid, ~s(Conflicting "DateStyle" specifications.)}},
    {"DateStyle", "ymd, dmy", {:invalid, ~s(Conflicting "DateStyle" specifications.)}},
    {"DateStyle", "iso, ymd, mdy", {:invalid, ~s(Conflicting "DateStyle" specifications.)}},
    {"DateStyle", "postgre", {:invalid, ~s(Unrecognized key word: "postgre".)}},
    {"DateStyle", "ISO, MDX", {:invalid, ~s(Unrecognized key word: "mdx".)}},
    {"DateStyle", "iso,,ymd", {:invalid, "List syntax is invalid."}},
    {"TimeZone", "Europe/Berlin", :ok},
    {"TimeZone", "europe/berlin", :ok},
    {"TimeZone", "America/New_York", :ok},
    {"TimeZone", "EST5EDT", :ok},
    {"TimeZone", "Foo25", :ok},
    {"TimeZone", "Fo5", :ok},
    {"TimeZone", "Foo5:30", :ok},
    {"TimeZone", "Foo+5", :ok},
    {"TimeZone", "Foo5Bar", :ok},
    {"TimeZone", "Foo5Bar4", :ok},
    {"TimeZone", "Foo5Bar,M3.2.0,M11.1.0", :ok},
    {"TimeZone", "Foo5Bar,J60,J300", :ok},
    {"TimeZone", "<+05>-05", :ok},
    {"TimeZone", "UTC+30", :ok},
    {"TimeZone", "+16", :ok},
    {"TimeZone", "-15", :ok},
    {"TimeZone", "12.5", :ok},
    {"TimeZone", "Interval '-08:00'", :ok},
    {"TimeZone", "", {:invalid, nil}},
    {"TimeZone", "Foo", {:invalid, nil}},
    {"TimeZone", "PDT", {:invalid, nil}},
    {"TimeZone", "Foo200", {:invalid, nil}},
    {"TimeZone", "Foo5,M3.2.0", {:invalid, nil}},
    {"TimeZone", "abc/def", {:invalid, nil}},
    {"TimeZone", "Mars/Olympus", {:invalid, nil}},
    {"TimeZone", "Foo-5:30:15",
     {:error,
      ~s(time zone "Foo-5:30:15" appears to use leap seconds\nPostgreSQL does not support leap seconds.)}},
    {"log_timezone", "Mars/Olympus", {:invalid, nil}},
    {"log_destination", "STDERR", :ok},
    {"log_destination", "stderr, csvlog, syslog, eventlog, jsonlog", :ok},
    {"log_destination", "", :ok},
    {"log_destination", "stderr, csvlogg", {:invalid, ~s(Unrecognized key word: "csvlogg".)}},
    {"log_destination", "stderr,,syslog", {:invalid, "List syntax is invalid."}},
    {"wal_consistency_checking", "heap, BTREE", :ok},
    {"wal_consistency_checking", "all", :ok},
    {"wal_consistency_checking", "xlog", {:invalid, ~s(Unrecognized key word: "xlog".)}},
    {"wal_consistency_checking", "Transaction",
     {:invalid, ~s(Unrecognized key word: "transaction".)}},
    {"wal_consistency_checking", "all, nope", {:invalid, ~s(Unrecognized key word: "nope".)}},
    {"wal_consistency_checking", "heap,,gin", {:invalid, "List syntax is invalid."}},
    {"client_encoding", "UTF-8", :ok},
    {"client_encoding", "utf8", :ok},
    {"client_encoding", "Unicode", :ok},
    {"client_encoding", "latin-1", :ok},
    {"client_encoding", "win-1252", :ok},
    {"client_encoding", "sql_ascii", :ok},
    {"client_encoding", "utf-9", {:invalid, nil}},
    {"client_encoding", "", {:invalid, nil}},
    {"recovery_target", "immediate", :ok},
    {"recovery_target", "", :ok},
    {"recovery_target", "nope", {:invalid, ~s(The only allowed value is "immediate".)}},
    {"recovery_target_lsn", "0/1", :ok},
    {"recovery_target_lsn", "AB/12345678", :ok},
    {"recovery_target_lsn", "FFFFFFFF/FFFFFFFF", :ok},
    {"recovery_target_lsn", "", :ok},
    {"recovery_target_lsn", "ab/123456789", {:invalid, nil}},
    {"recovery_target_lsn", "0/", {:invalid, nil}},
    {"recovery_target_lsn", "1", {:invalid, nil}},
    {"recovery_target_lsn", "0/1/2", {:invalid, nil}},
    {"recovery_target_xid", "abc", :ok},
    {"recovery_target_xid", "-1", :ok},
    {"recovery_target_xid", "0x10", :ok},
    {"recovery_target_xid", "99999999999999999999999", {:invalid, nil}},
    {"recovery_target_timeline", "current", :ok},
    {"recovery_target_timeline", "latest", :ok},
    {"recovery_target_timeline", "abc", :ok},
    {"recovery_target_timeline", "0x10", :ok},
    {"recovery_target_timeline", "99999999999999999999",
     {:invalid, ~s("recovery_target_timeline" is not a valid number.)}},
    {"recovery_target_name", String.duplicate("a", 63), :ok},
    {"recovery_target_name", String.duplicate("a", 64),
     {:invalid, ~s|"recovery_target_name" is too long (maximum 63 characters).|}},
    {"recovery_target_time", "2024-01-15 10:30:00", :ok},
    {"recovery_target_time", "January 8, 1999", :ok},
    {"recovery_target_time", "2024-01-15T10:30:00Z", :ok},
    {"recovery_target_time", "", :ok},
    {"recovery_target_time", "now", {:invalid, nil}},
    {"recovery_target_time", "tomorrow", {:invalid, nil}},
    {"recovery_target_time", "epoch", {:invalid, nil}},
    {"recovery_target_time", "infinity", {:invalid, nil}},
    {"recovery_target_time", "yesterday-ish", {:invalid, nil}},
    {"synchronous_standby_names", "", :ok},
    {"synchronous_standby_names", "2", :ok},
    {"synchronous_standby_names", "a, b", :ok},
    {"synchronous_standby_names", "FIRST 2 (a, b)", :ok},
    {"synchronous_standby_names", ~s|any 1 (a, "b c", *)|, :ok},
    {"synchronous_standby_names", ~s|1 ("")|, :ok},
    {"synchronous_standby_names", "0 (a)",
     {:error, "number of synchronous standbys (0) must be greater than zero"}},
    {"synchronous_standby_names", "first", {:invalid, "syntax error at end of input"}},
    {"synchronous_standby_names", "1 (a", {:invalid, "syntax error at end of input"}},
    {"synchronous_standby_names", "a,", {:invalid, "syntax error at end of input"}},
    {"synchronous_standby_names", "FIRST 2 (a, b", {:invalid, "syntax error at end of input"}},
    {"synchronous_standby_names", "a b", {:invalid, ~s(syntax error at or near "b")}},
    {"synchronous_standby_names", "a, , b", {:invalid, ~s(syntax error at or near ",")}},
    {"synchronous_standby_names", "1 (a) b", {:invalid, ~s(syntax error at or near "b")}},
    {"synchronous_standby_names", "(a)", {:invalid, ~s|syntax error at or near "("|}},
    {"synchronous_standby_names", "first 1 (first)",
     {:invalid, ~s(syntax error at or near "first")}},
    {"synchronous_standby_names", "a;b", {:invalid, ~s(syntax error at or near ";")}},
    {"synchronous_standby_names", ~s("unterminated),
     {:invalid, "unterminated quoted identifier at end of input"}},
    {"debug_io_direct", "DATA", :ok},
    {"debug_io_direct", "wal_init", :ok},
    {"debug_io_direct", "", :ok},
    {"debug_io_direct", "data, nope", {:invalid, ~s(Invalid option "nope".)}},
    {"debug_io_direct", "data,,wal",
     {:invalid, ~s(Invalid list syntax in parameter "debug_io_direct".)}},
    {"search_path", "a,,b", :ok},
    {"shared_preload_libraries", "anything at all", :ok}
  ]

  for {name, value, expected} <- @cases do
    test "#{name} = #{inspect(value)}" do
      assert StringSettings.check(unquote(name), unquote(value), @catalog, 18) ==
               unquote(Macro.escape(expected))
    end
  end

  test "jsonlog is a destination from 15" do
    assert StringSettings.check("log_destination", "jsonlog", @catalog, 15) == :ok

    assert StringSettings.check("log_destination", "jsonlog", @catalog, 14) ==
             {:invalid, ~s(Unrecognized key word: "jsonlog".)}
  end

  test "a catalog without the lists says nothing about a name" do
    bare = %{@catalog | timezones: [], encodings: [], encoding_aliases: []}
    assert StringSettings.check("TimeZone", "Mars/Olympus", bare, 18) == :ok
    assert StringSettings.check("client_encoding", "utf-9", bare, 18) == :ok
  end

  test "completion offers each vocabulary" do
    assert "Europe/Berlin" in StringSettings.completions("TimeZone", @catalog, 18)
    assert "UTF8" in StringSettings.completions("client_encoding", @catalog, 18)

    assert StringSettings.completions("log_destination", @catalog, 14) ==
             ~w(stderr csvlog syslog eventlog)

    assert StringSettings.completions("recovery_target", @catalog, 18) == ["immediate"]
    assert StringSettings.completions("shared_preload_libraries", @catalog, 18) == []
  end
end
