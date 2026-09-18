defmodule Postern.CatalogGeneratorTest do
  use ExUnit.Case, async: true

  alias Postern.CatalogGenerator

  doctest CatalogGenerator

  test "reads the encoding names out of the table in encnames.c" do
    text = """
    const pg_encname pg_encname_tbl[] =
    {
    \t{
    \t\t"abc", PG_WIN1258
    \t},
    \t{
    \t\t"utf8", PG_UTF8
    \t},
    };
    """

    assert CatalogGenerator.encoding_table(text) == ["abc", "utf8"]
    assert CatalogGenerator.encoding_table("nothing here") == []
  end
end
