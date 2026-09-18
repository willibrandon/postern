defmodule Postern.CatalogTest do
  use ExUnit.Case, async: true

  alias Postern.Catalog

  doctest Postern.Catalog

  test "loads every generated major-version catalog" do
    assert Catalog.versions() == [13, 14, 15, 16, 17, 18]

    for version <- Catalog.versions() do
      catalog = Catalog.load(version)
      assert catalog.version == version
      assert map_size(catalog.settings) > 300

      assert Enum.all?(catalog.settings, fn {_name, setting} ->
               Enum.all?(Catalog.required_fields(), &Map.has_key?(setting, &1))
             end)
    end
  end

  test "selects the newest catalog and indexes setting rows by name" do
    assert Catalog.latest() == 18
    catalog = Catalog.load(16)
    assert Catalog.fetch(catalog, "shared_buffers")["vartype"] == "integer"
  end

  test "enum values come out of the array literal without their quotes" do
    catalog = Catalog.load(18)

    assert Catalog.fetch(catalog, "default_transaction_isolation")["enumvals"] ==
             ["serializable", "repeatable read", "read committed", "read uncommitted"]

    assert Catalog.fetch(catalog, "wal_level")["enumvals"] == ["minimal", "replica", "logical"]
    assert Catalog.fetch(catalog, "shared_buffers")["enumvals"] == nil
  end

  test "a catalog carries the server's time zone names and encodings" do
    for version <- Catalog.versions() do
      catalog = Catalog.load(version)
      assert "Europe/Berlin" in catalog.timezones
      assert "UTF8" in catalog.encodings
      assert "unicode" in catalog.encoding_aliases
    end
  end

  test "an enum row carries the spellings the server takes without listing them" do
    for version <- [13, 18] do
      catalog = Catalog.load(version)

      assert Catalog.fetch(catalog, "wal_level")["hidden_enumvals"] ==
               %{"archive" => "replica", "hot_standby" => "replica"}

      assert Catalog.fetch(catalog, "synchronous_commit")["hidden_enumvals"]["true"] == "on"
      assert Catalog.fetch(catalog, "shared_buffers")["hidden_enumvals"] == nil
    end

    # A spelling with no visible value of the same meaning stands alone.
    assert Catalog.fetch(Catalog.load(18), "client_min_messages")["hidden_enumvals"]["info"] ==
             nil
  end
end
