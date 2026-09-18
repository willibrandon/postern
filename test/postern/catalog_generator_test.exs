defmodule Postern.CatalogGeneratorTest do
  use ExUnit.Case, async: true

  alias Postern.CatalogGenerator

  doctest CatalogGenerator

  test "reads a module's enum setting from its DefineCustomEnumVariable call" do
    text = """
    	DefineCustomEnumVariable("auto_explain.log_level",
    							 "Log level for the plan.",
    							 NULL,
    							 &auto_explain_log_level,
    							 LOG,
    							 loglevel_options,
    							 PGC_SUSET,
    							 0,
    							 NULL,
    							 NULL,
    							 NULL);
    """

    assert CatalogGenerator.enum_settings(text) == %{
             "auto_explain.log_level" => "loglevel_options"
           }
  end

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
