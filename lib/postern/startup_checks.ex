defmodule Postern.StartupChecks do
  @moduledoc """
  The checks the postmaster makes across settings when it starts, which a
  reload never makes, so `pg_file_settings` passes them and the failure
  waits for the next restart.

  postmaster.c refuses to start when `wal_level` is `minimal` and WAL
  archiving is on, `max_wal_senders` is above zero, or, from 17, WAL
  summarization is on, and stops at the first of the three. The recovery
  target hooks refuse more than one recovery target. autovacuum.c starts
  with `track_counts` off but
  logs a warning that autovacuum will not run, with the hint to enable it.
  Each check weighs the value that counts across the tree, or the default
  the server assumes without one, and reports on the last of the lines in
  the document that take part, in the version's words.
  """

  alias Postern.Catalog
  alias Postern.ConfigTree
  alias Postern.GucValue

  @recovery_targets ~w(recovery_target recovery_target_lsn recovery_target_name recovery_target_time recovery_target_xid)

  @type finding :: %{entry: map(), severity: 1 | 2, message: String.t()}

  @doc """
  The findings for the document at `path` in `tree`, with the catalog of
  the target version for the defaults and the messages.
  """
  @spec findings(map(), Path.t() | nil, map()) :: [finding()]
  def findings(tree, path, catalog) do
    lookup = &value(tree, path, catalog, &1)
    version = catalog.version

    List.flatten([
      wal_level(lookup, version),
      recovery_targets(lookup, version),
      autovacuum(lookup)
    ])
  end

  # The three checks in the order postmaster.c makes them; it stops at the
  # first that fails, and so does this.
  defp wal_level(lookup, version) do
    {level, level_entry} = lookup.("wal_level")

    if level == "minimal" do
      [
        {"archive_mode", &(&1 != "off"), archival_message(version)},
        {"max_wal_senders", &(&1 > 0), streaming_message(version)},
        {"summarize_wal", &(&1 == true),
         ~s(WAL cannot be summarized when "wal_level" is "minimal")}
      ]
      |> Enum.find_value([], &minimal_with(lookup, level_entry, &1))
    else
      []
    end
  end

  defp minimal_with(lookup, level_entry, {name, fails?, message}) do
    {other, other_entry} = lookup.(name)
    if other != nil and fails?.(other), do: report([level_entry, other_entry], 1, message)
  end

  defp archival_message(version) when version >= 17,
    do: ~s(WAL archival cannot be enabled when "wal_level" is "minimal")

  defp archival_message(_version),
    do: ~s(WAL archival cannot be enabled when wal_level is "minimal")

  defp streaming_message(version) when version >= 17,
    do:
      ~s(WAL streaming \("max_wal_senders" > 0\) requires "wal_level" to be "replica" or "logical")

  defp streaming_message(_version),
    do: ~s(WAL streaming \(max_wal_senders > 0\) requires wal_level "replica" or "logical")

  defp recovery_targets(lookup, _version) do
    set =
      @recovery_targets
      |> Enum.map(lookup)
      |> Enum.filter(fn {value, _entry} -> value not in [nil, ""] end)

    if length(set) > 1,
      do: report(Enum.map(set, &elem(&1, 1)), 1, "multiple recovery targets specified"),
      else: []
  end

  defp autovacuum(lookup) do
    {on, autovacuum_entry} = lookup.("autovacuum")
    {counts, counts_entry} = lookup.("track_counts")

    if on == true and counts == false,
      do:
        report(
          [autovacuum_entry, counts_entry],
          2,
          "autovacuum not started because of misconfiguration\nEnable the \"track_counts\" option."
        ),
      else: []
  end

  # The finding sits on the last of the entries that are in the document,
  # the line that completes the pair; with none there, the defaults alone
  # never fail and there is nothing to mark.
  defp report(entries, severity, message) do
    case Enum.reject(entries, &is_nil/1) do
      [] ->
        []

      present ->
        [%{entry: Enum.max_by(present, & &1.span.line), severity: severity, message: message}]
    end
  end

  # The value that counts for a setting, read the way the server reads it,
  # and the document's entry it comes from when the document holds it. A
  # value the server would refuse counts for nothing here, since its own
  # error is on the line already.
  defp value(tree, path, catalog, name) do
    setting = Catalog.fetch(catalog, name)

    case {setting, ConfigTree.winner(tree, name)} do
      {nil, _winner} ->
        {nil, nil}

      {setting, nil} ->
        {read(setting["boot_val"], setting), nil}

      {setting, %{path: winner_path, entry: entry}} ->
        {read(entry.value, setting), if(winner_path == path, do: entry)}
    end
  end

  defp read(value, %{"vartype" => "bool"}) do
    case GucValue.parse_bool(value) do
      {:ok, boolean} -> boolean
      :error -> nil
    end
  end

  defp read(value, %{"vartype" => "integer"} = setting) do
    case GucValue.parse_int(value, GucValue.base(setting["unit"])) do
      {:ok, number} -> number
      {:error, _hint} -> nil
    end
  end

  # An enum's hidden spelling counts as the visible value it stands for.
  defp read(value, %{"vartype" => "enum"} = setting) do
    lower = String.downcase(value)
    visible = Catalog.array_literal(setting["enumvals"])
    hidden = setting["hidden_enumvals"] || %{}

    cond do
      lower in Enum.map(visible, &String.downcase/1) -> lower
      Map.has_key?(hidden, lower) -> hidden[lower]
      true -> nil
    end
  end

  defp read(value, _setting), do: value
end
