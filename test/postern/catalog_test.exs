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
end
