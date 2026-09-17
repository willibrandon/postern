defmodule Postern.FeaturesTest do
  use ExUnit.Case, async: true

  alias GenLSP.Structures.Position
  alias Postern.Features

  test "hover on a setting reads generated catalog documentation" do
    text = "shared_buffers = 128MB\n"
    position = %Position{line: 0, character: 7}

    assert %{contents: %{kind: "markdown", value: value}, range: range} =
             Features.hover("file:///tmp/postgresql.conf", text, position, %{"pg" => 16})

    assert value =~ "shared_buffers"
    assert value =~ "Sets the number of shared memory buffers"
    assert value =~ "integer"
    assert value =~ "postmaster"
    assert range.start.character == 0
    assert value =~ "takes effect after a server restart"
  end

  describe "with the tree of files the server reads" do
    setup do
      files =
        Postern.Files.in_memory(%{
          "/pg/postgresql.conf" =>
            "shared_buffers = 128MB\ninclude 'shared.conf'\ninclude_dir 'conf.d'\ninclude_if_exists 'gone.conf'\n",
          "/pg/shared.conf" => "work_mem = 4MB\n",
          "/pg/conf.d/10-memory.conf" => "shared_buffers = 256MB\n"
        })

      %{files: files, options: %{"pg" => 16, reader: files}}
    end

    test "hover says where the value that counts is set", %{options: options} do
      {:ok, text} = options.reader.read.("/pg/postgresql.conf")

      %{contents: %{value: value}} =
        Features.hover(
          "file:///pg/postgresql.conf",
          text,
          %Position{line: 0, character: 3},
          options
        )

      assert value =~ "**Overridden by:** `conf.d/10-memory.conf` line 1, where it is `256MB`"

      # An included file's kind comes from the server, not its name.
      %{contents: %{value: winner}} =
        Features.hover(
          "file:///pg/conf.d/10-memory.conf",
          "shared_buffers = 256MB\n",
          %Position{line: 0, character: 3},
          Map.put(options, :kind, :postgresql_conf)
        )

      refute winner =~ "Overridden"
    end

    test "definition goes to the assignment that counts", %{options: options} do
      {:ok, text} = options.reader.read.("/pg/postgresql.conf")

      assert %GenLSP.Structures.Location{uri: "file:///pg/conf.d/10-memory.conf", range: range} =
               Features.definition(
                 "file:///pg/postgresql.conf",
                 text,
                 %Position{line: 0, character: 3},
                 options
               )

      assert range.start == %Position{line: 0, character: 0}
      assert range.end == %Position{line: 0, character: 14}

      assert Features.definition(
               "file:///pg/conf.d/10-memory.conf",
               "shared_buffers = 256MB\n",
               %Position{line: 0, character: 3},
               Map.put(options, :kind, :postgresql_conf)
             ) == nil
    end

    test "include lines link to the files that are there", %{options: options} do
      {:ok, text} = options.reader.read.("/pg/postgresql.conf")

      assert [%GenLSP.Structures.DocumentLink{target: "file:///pg/shared.conf", range: range}] =
               Features.document_links("file:///pg/postgresql.conf", text, options)

      assert range.start == %Position{line: 1, character: 8}
      assert range.end == %Position{line: 1, character: 21}
    end
  end

  test "postgresql.conf completion offers setting names and enum values" do
    name_items =
      Features.completion(
        "file:///tmp/postgresql.conf",
        "shared_",
        %Position{line: 0, character: 7},
        %{"pg" => 16}
      ).items

    assert Enum.any?(name_items, &(&1.label == "shared_buffers"))

    value_items =
      Features.completion(
        "file:///tmp/postgresql.conf",
        "password_encryption = scr",
        %Position{line: 0, character: 26},
        %{"pg" => 16}
      ).items

    assert Enum.any?(value_items, &(&1.label == "scram-sha-256"))
  end

  test "pg_hba.conf completion offers address keywords and methods" do
    address_items =
      Features.completion(
        "file:///tmp/pg_hba.conf",
        "host all all ",
        %Position{line: 0, character: 14}
      ).items

    assert Enum.any?(address_items, &(&1.label == "samehost"))
    assert Enum.any?(address_items, &(&1.label == "samenet"))

    method_items =
      Features.completion(
        "file:///tmp/pg_hba.conf",
        "host all all 10.0.0.0/8 ",
        %Position{line: 0, character: 25}
      ).items

    assert Enum.any?(method_items, &(&1.label == "scram-sha-256"))
    assert Enum.any?(method_items, &(&1.label == "reject"))
  end

  test "pg_hba.conf completion offers the options the rule's method takes" do
    labels = fn text ->
      Features.completion(
        "file:///tmp/pg_hba.conf",
        text,
        %Position{line: 0, character: String.length(text)}
      ).items
      |> Enum.map(& &1.label)
    end

    assert labels.("host all all 10.0.0.0/8 ldap ") ==
             ~w(ldapurl ldaptls ldapscheme ldapserver ldapport ldapbinddn ldapbindpasswd ldapsearchattribute ldapsearchfilter ldapbasedn ldapprefix ldapsuffix)

    assert labels.("hostssl all all 10.0.0.0/8 cert ") == ~w(clientcert clientname map)
    assert labels.("local all all peer ") == ~w(map)
    assert labels.("local all all peer map=x ") == ~w(map)
    assert labels.("host all all 10.0.0.0/8 md5 ") == []

    assert labels.("host all all 10.0.0.0/8 oauth ") ==
             ~w(map issuer scope validator delegate_ident_mapping)

    old =
      Features.completion(
        "file:///tmp/pg_hba.conf",
        "# postern: pg=13\nhostssl all all 10.0.0.0/8 cert ",
        %Position{line: 1, character: 32}
      ).items
      |> Enum.map(& &1.label)

    assert old == ~w(clientcert map)
  end

  test "live HBA completion includes database and role names" do
    snapshot = %{databases: [%{"datname" => "billing"}], roles: [%{"rolname" => "app_user"}]}

    database_items =
      Features.completion(
        "file:///tmp/pg_hba.conf",
        "host ",
        %Position{line: 0, character: 5},
        %{live_snapshot: snapshot}
      ).items

    role_items =
      Features.completion(
        "file:///tmp/pg_hba.conf",
        "host billing ",
        %Position{line: 0, character: 14},
        %{live_snapshot: snapshot}
      ).items

    assert Enum.any?(database_items, &(&1.label == "billing"))
    assert Enum.any?(role_items, &(&1.label == "app_user"))
  end

  test "the trust hint carries a quick fix that turns the hint off" do
    [hint] = Postern.PgHbaDiagnostics.diagnostics("host all all all trust\n")
    assert hint.code == "trust"

    assert [%{title: title, command: %{command: "postern.disableTrustHints"}}] =
             Features.code_actions([hint])

    assert title =~ "trust"
    assert Features.code_actions([%{hint | code: nil}]) == []
  end
end
