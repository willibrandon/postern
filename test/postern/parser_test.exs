defmodule Postern.ParserTest do
  use ExUnit.Case, async: true

  alias Postern.Parser.PgHba
  alias Postern.Parser.PgIdent
  alias Postern.Parser.PostgresqlConf

  @fixtures Path.expand("../fixtures", __DIR__)

  describe "postgresql.conf" do
    test "round trips the stock PostgreSQL fixture" do
      content = fixture!("postgresql.conf.sample")

      assert {:ok, entries} = PostgresqlConf.parse(content)
      assert Enum.all?(entries, &(&1.type != :error))
      assert Enum.map_join(entries, "\n", & &1.raw) == content
    end

    test "parses assignments with optional equals, quoted values and comments" do
      assert {:ok, entries} =
               PostgresqlConf.parse("""
               shared_buffers = 128MB
               port 5432
               application_name = 'postern # not a comment'
               include_if_exists = 'conf.d/local.conf' # trailing comment
               """)

      assignments = Enum.filter(entries, &(&1.type == :assignment))
      assert Enum.map(assignments, & &1.name) == ["shared_buffers", "port", "application_name"]
      assert Enum.at(assignments, 0).value == "128MB"
      assert Enum.at(assignments, 1).value == "5432"
      assert Enum.at(assignments, 2).value == "postern # not a comment"

      [include] = Enum.filter(entries, &(&1.type == :include))
      assert include.directive == "include_if_exists"
      assert include.file == "conf.d/local.conf"
      assert include.file_span == %{line: 4, col: 21, end_line: 4, end_col: 40}
    end

    test "tracks one-based name and value spans" do
      assert {:ok, [%{type: :assignment} = assignment]} =
               PostgresqlConf.parse("  shared_buffers = 128MB\n")
               |> then(fn {:ok, entries} ->
                 {:ok, Enum.filter(entries, &(&1.type == :assignment))}
               end)

      assert assignment.name_span == %{line: 1, col: 3, end_line: 1, end_col: 17}
      assert assignment.value_span == %{line: 1, col: 20, end_line: 1, end_col: 25}
      assert assignment.span == %{line: 1, col: 1, end_line: 1, end_col: 25}
    end

    test "reports malformed assignments at the source line" do
      assert {:ok, entries} = PostgresqlConf.parse("port =\n")
      assert [%{type: :error} = error] = Enum.filter(entries, &(&1.type == :error))
      assert error.span.line == 1
      assert error.span.col == 1
    end
  end

  describe "pg_hba.conf" do
    test "round trips the stock PostgreSQL fixture" do
      content = fixture!("pg_hba.conf")

      assert {:ok, entries} = PgHba.parse(content)
      assert Enum.all?(entries, &(&1.type != :error))
      assert Enum.map_join(entries, "\n", & &1.raw) == content
    end

    test "parses local and host rules with lists, netmasks and options" do
      assert {:ok, entries} =
               PgHba.parse("""
               local all all peer
               host db1,db2 user1,user2 192.168.0.0 255.255.0.0 ldap ldapserver=db.example.com
               hostssl all /^(app_.*)$/ 10.0.0.0/8 scram-sha-256
               include "extra/pg_hba.conf"
               """)

      [local, host, hostssl, include] = Enum.filter(entries, &(&1.type in [:rule, :include]))
      assert local.connection_type == "local"
      assert local.address == nil
      assert local.auth_method == "peer"

      assert host.databases == ["db1", "db2"]
      assert host.users == ["user1", "user2"]
      assert host.address == "192.168.0.0"
      assert host.netmask == "255.255.0.0"
      assert host.options == %{"ldapserver" => "db.example.com"}

      assert hostssl.connection_type == "hostssl"
      assert hostssl.users == ["/^(app_.*)$/"]
      assert hostssl.address == "10.0.0.0/8"

      assert include.directive == "include"
      assert include.file == "extra/pg_hba.conf"
    end

    test "tracks spans for every top-level token" do
      assert %{type: :rule, tokens: tokens} = PgHba.parse_line("host all all 0.0.0.0/0 trust", 7)

      assert Enum.map(tokens, & &1.value) == ["host", "all", "all", "0.0.0.0/0", "trust"]
      assert Enum.map(tokens, & &1.span.col) == [1, 6, 10, 14, 24]
      assert Enum.all?(tokens, &(&1.span.line == 7))
    end

    test "quotes with double quotes only, as the server's tokenizer does" do
      {:ok, entries} =
        PgHba.parse("""
        host "my db" "a,b" 10.0.0.0/8 md5
        host 'db' all 10.0.0.0/8 md5
        include_dir "hba.d"
        """)

      [quoted, single, include] = Enum.filter(entries, &(&1.type in [:rule, :include]))
      assert quoted.databases == ["my db"]
      assert quoted.users == ["a,b"]
      assert single.databases == ["'db'"]
      assert include.file == "hba.d"
    end

    test "reads the fields the way parse_hba_line does and says where a line ends too soon" do
      shape = fn line -> PgHba.parse_line(line, 3) end

      for {line, message} <- [
            {"host", "end-of-line before database specification"},
            {"host all", "end-of-line before role specification"},
            {"host all all", "end-of-line before IP address specification"},
            {"host all all 10.0.0.0", "end-of-line before netmask specification"},
            {"host all all 10.0.0.0/8", "end-of-line before authentication method"},
            {"local all all", "end-of-line before authentication method"},
            {"host,hostssl all all all md5", "multiple values specified for connection type"},
            {"host all all 10.0.0.0/8,10.1.0.0/8 md5",
             "multiple values specified for host address"},
            {"host all all 10.0.0.0 255.0.0.0,255.255.0.0 md5",
             "multiple values specified for netmask"},
            {"host all all all md5,trust", "multiple values specified for authentication type"},
            {"host all all 10.0.0.0 md5", ~s(invalid IP mask "md5")},
            {"host all all 10.0.0.0 ffff::0 md5", "IP address and mask do not match"},
            {"host all all example.com/24 md5",
             ~s(specifying both host name and CIDR mask is invalid: "example.com/24")},
            {"host all all 10.0.0.0/33 md5", ~s(invalid CIDR mask in address "10.0.0.0/33")},
            {~s("host" all all 10.0.0.0/8 md5), ~s(invalid connection type "host")},
            {"not_a_connection_type all all trust",
             ~s(invalid connection type "not_a_connection_type")}
          ] do
        assert %{type: :error, message: ^message, span: %{line: 3}} = shape.(line), line
      end

      # A host name and a keyword stand alone, so the next field is the
      # method, whatever it says; only a bare IP address takes a netmask.
      assert %{
               address: "example.com",
               address_kind: :host,
               netmask: nil,
               auth_method: "255.255.255.0"
             } =
               shape.("host all all example.com 255.255.255.0 md5")

      assert %{address: "10.0.0.0", address_kind: :ip, netmask: "255.255.0.0", auth_method: "md5"} =
               shape.("host all all 10.0.0.0 255.255.0.0 md5")

      assert %{address_kind: :keyword, auth_method: "255.255.0.0"} =
               shape.("host all all all 255.255.0.0 md5")

      assert %{address_kind: :host, address: "all", auth_method: "md5"} =
               shape.(~s(host all all "all" md5))

      assert %{address_kind: :cidr, auth_method: "scram-sha-256-plus", method_span: %{col: 25}} =
               shape.("host all all 10.0.0.0/8 scram-sha-256-plus")
    end
  end

  describe "pg_ident.conf" do
    test "round trips the stock PostgreSQL fixture" do
      content = fixture!("pg_ident.conf.sample")

      assert {:ok, entries} = PgIdent.parse(content)
      assert Enum.all?(entries, &(&1.type != :error))
      assert Enum.map_join(entries, "\n", & &1.raw) == content
    end

    test "parses regex system users and substitutions" do
      line = "mymap /^app_(.*)$/ app_\\1"
      assert %{type: :mapping} = mapping = PgIdent.parse_line(line, 12)
      assert mapping.map == "mymap"
      assert mapping.system_user == "/^app_(.*)$/"
      assert mapping.pg_user == "app_\\1"
      assert Enum.map(mapping.tokens, & &1.value) == ["mymap", "/^app_(.*)$/", "app_\\1"]
      assert mapping.system_span.line == 12
    end

    test "parses include directives and malformed mappings" do
      assert %{type: :include, file: "maps.conf"} = PgIdent.parse_line("include maps.conf", 1)
      assert %{type: :error, span: %{line: 2}} = PgIdent.parse_line("mymap only_two_fields", 2)
    end
  end

  defp fixture!(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
  end
end
