defmodule Postern.SettingHistory do
  @moduledoc """
  What became of a setting name the target version does not have.

  For a name the catalogs know, 13 through 18, the catalogs say whether it
  arrives in a later version or went in an earlier one, and this module adds
  the name that took its place where one did. For a name from before 13 it
  keeps a table of the ones that still turn up in copied configuration
  files, each with the release that dropped it, checked against the guc.c
  of every release tag, and the successor its release notes name.
  """

  alias Postern.Catalog

  # A name the catalogs have, with the version that dropped it and the name
  # that replaced it in that version.
  @replaced_since_13 %{
    "force_parallel_mode" => {16, "debug_parallel_query"},
    "ssl_ecdh_curve" => {18, "ssl_groups"}
  }

  # Names from before 13: the release that dropped each, and its successor or
  # a word on what took its place.
  @before_13 %{
    "preload_libraries" => {"8.2", "shared_preload_libraries"},
    "redirect_stderr" => {"8.3", "logging_collector"},
    "stats_start_collector" => {"8.3", nil},
    "stats_row_level" => {"8.3", "track_counts"},
    "stats_block_level" => {"8.3", "track_counts"},
    "max_fsm_pages" => {"8.4", nil},
    "explain_pretty_print" => {"8.4", nil},
    "regex_flavor" => {"9.0", nil},
    "add_missing_from" => {"9.0", nil},
    "custom_variable_classes" => {"9.2", nil},
    "silent_mode" => {"9.2", nil},
    "wal_sender_delay" => {"9.2", nil},
    "unix_socket_directory" => {"9.3", "unix_socket_directories"},
    "krb_srvname" => {"9.4", nil},
    "checkpoint_segments" => {"9.5", "max_wal_size"},
    "min_parallel_relation_size" => {"10", "min_parallel_table_scan_size"},
    "sql_inheritance" => {"10", nil},
    "replacement_sort_tuples" => {"11", nil},
    "standby_mode" => {"12", "a standby.signal file in the data directory"},
    "trigger_file" => {"12", "promote_trigger_file"},
    "wal_keep_segments" => {"13", "wal_keep_size"}
  }

  @doc """
  A sentence on what became of the name for the target version, phrased the
  way the server phrases a hint, or `nil` when there is nothing to say.

  ## Examples

      iex> Postern.SettingHistory.note("wal_keep_segments", 16)
      ~s(PostgreSQL 13 replaced it with "wal_keep_size".)

      iex> Postern.SettingHistory.note("silent_mode", 16)
      "PostgreSQL 9.2 removed it."

      iex> Postern.SettingHistory.note("nothing_like_this", 16)
      nil

  """
  @spec note(String.t(), pos_integer()) :: String.t() | nil
  def note(name, target) do
    name = String.downcase(name)
    present = Enum.filter(Catalog.versions(), &(Catalog.fetch(Catalog.load(&1), name) != nil))

    cond do
      present == [] -> before_13(name)
      Enum.min(present) > target -> "It arrives in PostgreSQL #{Enum.min(present)}."
      Enum.max(present) < target -> since_13(name, Enum.max(present) + 1)
      true -> nil
    end
  end

  @doc "The name that replaced a setting, for a quick fix, or `nil`."
  @spec successor(String.t(), pos_integer()) :: String.t() | nil
  def successor(name, target) do
    name = String.downcase(name)

    case {Map.get(@replaced_since_13, name), Map.get(@before_13, name)} do
      {{version, successor}, _old} when version <= target -> successor
      {nil, {_release, successor}} when is_binary(successor) -> plain_name(successor)
      _other -> nil
    end
  end

  defp since_13(name, version) do
    case Map.get(@replaced_since_13, name) do
      {^version, successor} -> ~s(PostgreSQL #{version} replaced it with "#{successor}".)
      _other -> "PostgreSQL #{version} removed it."
    end
  end

  defp before_13(name) do
    case Map.get(@before_13, name) do
      nil ->
        nil

      {release, nil} ->
        "PostgreSQL #{release} removed it."

      {release, "a " <> _rest = what} ->
        "PostgreSQL #{release} removed it; #{what} takes its place."

      {release, successor} ->
        ~s(PostgreSQL #{release} replaced it with "#{successor}".)
    end
  end

  # A successor that is a setting name rather than a description.
  defp plain_name("a " <> _rest), do: nil
  defp plain_name(name), do: name
end
