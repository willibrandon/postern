defmodule Postern.RegexCheckTest do
  use ExUnit.Case, async: true

  alias Postern.Diagnostics
  alias Postern.RegexCheck

  doctest RegexCheck

  # The patterns pg_hba_file_rules and pg_ident_file_mappings on 18 refuse,
  # with the engine's words, and ones they take.
  @patterns [
    {"^(.*", {:error, "parentheses () not balanced"}},
    {"a)", {:error, "parentheses () not balanced"}},
    {"[abc", {:error, "brackets [] not balanced"}},
    {"*a", {:error, "quantifier operand invalid"}},
    {"[z-a]", {:error, "invalid character range"}},
    {"a{2,1}", {:error, "invalid repetition count(s)"}},
    {"^(.*)@example\\.com$", :ok},
    {"^app_[a-z]+$", :ok},
    {"a\\y", :ok}
  ]

  for {pattern, expected} <- @patterns do
    test "#{pattern}" do
      assert RegexCheck.check(unquote(pattern)) == unquote(Macro.escape(expected))
    end
  end

  test "a pg_hba.conf field that does not compile is the rule's error from 16, and a name before" do
    text = "host all /^(.* 10.0.0.0/8 scram-sha-256\n"

    [diagnostic] = Diagnostics.for_document("file:///pg/pg_hba.conf", text, %{"pg" => 18})
    assert diagnostic.severity == 1

    assert diagnostic.message ==
             ~s|invalid regular expression "^(.*": parentheses () not balanced|

    assert diagnostic.range.start.character == 9
    assert diagnostic.range.end.character == 14

    [diagnostic] = Diagnostics.for_document("file:///pg/pg_hba.conf", text, %{"pg" => 15})
    assert diagnostic.severity == 2
  end

  test "a pg_ident.conf system name that does not compile is the line's error on every version" do
    for version <- [13, 18] do
      [diagnostic] =
        Diagnostics.for_document("file:///pg/pg_ident.conf", "broken /^(.* postgres\n", %{
          "pg" => version,
          pg_hba_text: "host all all 10.0.0.0/8 cert map=broken\n"
        })

      assert diagnostic.severity == 1

      assert diagnostic.message ==
               ~s|invalid regular expression "^(.*": parentheses () not balanced|

      assert diagnostic.range.start.character == 7
    end

    # The PostgreSQL user name is a regular expression from 16 only.
    [diagnostic] =
      Diagnostics.for_document("file:///pg/pg_ident.conf", "m /^.*$ /^(.*\n", %{
        "pg" => 18,
        pg_hba_text: "host all all 10.0.0.0/8 cert map=m\n"
      })

    assert diagnostic.message ==
             ~s|invalid regular expression "^(.*": parentheses () not balanced|

    assert diagnostic.range.start.character == 8

    assert [%{severity: 2}] =
             Diagnostics.for_document("file:///pg/pg_ident.conf", "m /^.*$ /^(.*\n", %{
               "pg" => 15,
               pg_hba_text: "host all all 10.0.0.0/8 cert map=m\n"
             })
  end
end
