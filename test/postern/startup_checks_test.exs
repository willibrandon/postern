defmodule Postern.StartupChecksTest do
  use ExUnit.Case, async: true

  alias Postern.Diagnostics
  alias Postern.Files

  @archival_17 ~s(WAL archival cannot be enabled when "wal_level" is "minimal")
  @archival_16 ~s(WAL archival cannot be enabled when wal_level is "minimal")
  @streaming_17 ~s|WAL streaming ("max_wal_senders" > 0) requires "wal_level" to be "replica" or "logical"|
  @streaming_16 ~s|WAL streaming (max_wal_senders > 0) requires wal_level "replica" or "logical"|
  @summarize ~s(WAL cannot be summarized when "wal_level" is "minimal")
  @autovacuum ~s(autovacuum not started because of misconfiguration\nEnable the "track_counts" option.)

  # Each case is a file, the target version, and the findings as a list of
  # the line the finding sits on, its severity and its message; the
  # container logs behind each message are in the issue.
  @cases [
    {"wal_level = minimal\n", 18, [{1, 1, @streaming_17}]},
    {"wal_level = minimal\n", 16, [{1, 1, @streaming_16}]},
    {"wal_level = minimal\nmax_wal_senders = 0\n", 18, []},
    {"wal_level = minimal\nmax_wal_senders = 0\narchive_mode = on\n", 18, [{3, 1, @archival_17}]},
    {"archive_mode = always\nwal_level = minimal\nmax_wal_senders = 0\n", 16,
     [{2, 1, @archival_16}]},
    {"archive_mode = true\nwal_level = minimal\n", 18, [{2, 1, @archival_17}]},
    {"wal_level = minimal\nmax_wal_senders = 0\nsummarize_wal = on\n", 18, [{3, 1, @summarize}]},
    {"wal_level = archive\nmax_wal_senders = 10\n", 18, []},
    {"wal_level = replica\n", 18, []},
    {"wal_level = nope\nmax_wal_senders = 5\n", 18, [{1, 1, :value}]},
    {"recovery_target_time = '2024-01-01'\nrecovery_target_xid = 123\n", 18,
     [{2, 1, "multiple recovery targets specified"}]},
    {"recovery_target_time = '2024-01-01'\nrecovery_target_xid = 123\n", 13,
     [{2, 1, "multiple recovery targets specified"}]},
    {"recovery_target = ''\nrecovery_target_lsn = '0/1'\n", 18, []},
    {"track_counts = off\n", 18, [{1, 2, @autovacuum}]},
    {"autovacuum = off\ntrack_counts = off\n", 18, []},
    {"track_counts = off\nautovacuum = on\n", 18, [{2, 2, @autovacuum}]}
  ]

  for {text, version, expected} <- @cases do
    test "#{inspect(text)} on #{version}" do
      findings =
        Diagnostics.for_document("file:///tmp/postgresql.conf", unquote(text), %{
          "pg" => unquote(version)
        })
        |> Enum.map(fn diagnostic ->
          message = if diagnostic.message =~ "invalid value", do: :value, else: diagnostic.message
          {diagnostic.range.start.line + 1, diagnostic.severity, message}
        end)

      assert findings == unquote(Macro.escape(expected))
    end
  end

  test "a pair completed across the tree is reported on the document's line" do
    files =
      Files.in_memory(%{
        "/pg/postgresql.conf" => "max_wal_senders = 5\ninclude_dir 'conf.d'\n",
        "/pg/conf.d/10-wal.conf" => "wal_level = minimal\n"
      })

    [finding] =
      Diagnostics.for_document(
        "file:///pg/postgresql.conf",
        "max_wal_senders = 5\ninclude_dir 'conf.d'\n",
        %{
          "pg" => 18,
          reader: files
        }
      )

    assert finding.range.start.line == 0
    assert finding.message == @streaming_17

    [finding] =
      Diagnostics.for_document("file:///pg/conf.d/10-wal.conf", "wal_level = minimal\n", %{
        "pg" => 18,
        reader: files,
        kind: :postgresql_conf
      })

    assert finding.range.start.line == 0
  end
end
