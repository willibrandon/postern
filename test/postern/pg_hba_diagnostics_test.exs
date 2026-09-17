defmodule Postern.PgHbaDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Postern.Diagnostics

  @fixtures Path.expand("../fixtures", __DIR__)

  test "warns when a later rule is shadowed by a broader earlier rule" do
    diagnostics =
      Diagnostics.for_document("file:///tmp/pg_hba.conf", fixture!("pg_hba_shadow.conf"))

    assert [%{severity: 2, message: message, range: range}] =
             Enum.filter(diagnostics, &String.contains?(&1.message, "can never match"))

    assert message =~ "earlier"
    assert range.start.line == 3
  end

  test "validates CIDR, netmask, method options and ident references" do
    diagnostics =
      Diagnostics.for_document(
        "file:///tmp/pg_hba.conf",
        fixture!("pg_hba_invalid.conf"),
        %{pg_ident_text: fixture!("pg_ident_references.conf")}
      )

    messages = Enum.map(diagnostics, & &1.message)
    assert ~s(invalid CIDR mask in address "10.0.0.0/33") in messages
    # A host name stands alone, so the netmask is read as the method.
    assert ~s(invalid authentication method "255.255.255.0") in messages

    assert Enum.count(messages, &(&1 == ~s(clientcert can only be configured for "hostssl" rows))) ==
             2

    assert ~s(authentication option "ldapserver" is only valid for authentication methods ldap) in messages

    assert Enum.any?(messages, &String.contains?(&1, "non-local rule"))
    assert Enum.any?(messages, &String.contains?(&1, "does not exist in pg_ident.conf"))
  end

  test "checks every option against the method the way hba.c does" do
    text = """
    host all all 10.0.0.0/8 scram-sha-256 map=admins
    host all all 10.0.0.0/8 md5 bogus=1
    host all all 10.0.0.0/8 md5 bogus
    hostssl all all 10.0.0.0/8 cert clientcert=verify-ca
    hostssl all all 10.0.0.0/8 md5 clientcert=nope
    hostssl all all 10.0.0.0/8 md5 clientname=XX
    host all all 10.0.0.0/8 md5 krb_realm=EXAMPLE
    host all all 10.0.0.0/8 md5 validator.foo=bar
    hostssl all all 10.0.0.0/8 md5 clientcert=verify-full clientname=DN
    host all all 10.0.0.0/8 gss krb_realm=EXAMPLE include_realm=0
    """

    errors =
      text
      |> Postern.PgHbaDiagnostics.diagnostics()
      |> Enum.filter(&(&1.severity == 1))
      |> Enum.map(&{&1.range.start.line, &1.range.start.character, &1.message})

    assert errors == [
             {0, 38,
              ~s(authentication option "map" is only valid for authentication methods ident, peer, gssapi, sspi, cert, and oauth)},
             {1, 28, ~s(unrecognized authentication option name: "bogus")},
             {2, 28, "authentication option not in name=value format: bogus"},
             {3, 32,
              ~s(clientcert can only be set to "verify-full" when using "cert" authentication)},
             {4, 31, ~s(invalid value for clientcert: "nope")},
             {5, 31, ~s(invalid value for clientname: "XX")},
             {6, 28,
              ~s(authentication option "krb_realm" is only valid for authentication methods gssapi and sspi)},
             {7, 28, ~s(unrecognized authentication option name: "validator.foo")}
           ]
  end

  test "looks up map= in pg_ident.conf for every method that takes it" do
    text = """
    host all all 10.0.0.0/8 ident map=known
    local all all peer map=known
    hostssl all all 10.0.0.0/8 cert map=missing
    host all all 10.0.0.0/8 gss map=missing
    host all all 10.0.0.0/8 sspi map=missing
    host all all 10.0.0.0/8 oauth map=missing issuer=https://issuer scope=openid
    """

    missing =
      text
      |> Postern.PgHbaDiagnostics.diagnostics("known root postgres\n")
      |> Enum.filter(&String.contains?(&1.message, "does not exist in pg_ident.conf"))
      |> Enum.map(&{&1.range.start.line, &1.range.start.character})

    assert missing == [{2, 32}, {3, 28}, {4, 29}, {5, 30}]
  end

  test "warns for trust and password on host rules" do
    diagnostics =
      Diagnostics.for_document(
        "file:///tmp/pg_hba.conf",
        "host all all 10.0.0.0/8 trust\nhost all all 10.0.0.0/8 password\n"
      )

    advice = Enum.filter(diagnostics, &String.contains?(&1.message, "non-local rule"))
    assert length(advice) == 2
    assert Enum.all?(advice, &(&1.severity == 4))
  end

  test "all does not shadow replication rules" do
    diagnostics =
      Postern.PgHbaDiagnostics.diagnostics(
        "local all all trust\nlocal replication all trust\nhost all all 0.0.0.0/0 trust\nhost replication all 10.0.0.0/8 trust\n"
      )

    refute Enum.any?(diagnostics, &String.contains?(&1.message, "shadows it"))
  end

  test "trust hints can be turned off" do
    diagnostics =
      Postern.PgHbaDiagnostics.diagnostics("host all all all trust\n", nil, %{report_trust: false})

    refute Enum.any?(diagnostics, &String.contains?(&1.message, "non-local rule"))
  end

  test "trust on loopback or samehost rules is not reported" do
    diagnostics =
      Postern.PgHbaDiagnostics.diagnostics(
        "host all all 127.0.0.1/32 trust\nhost all all ::1/128 trust\nhost all all samehost trust\n"
      )

    refute Enum.any?(diagnostics, &String.contains?(&1.message, "non-local rule"))
  end

  test "reject rules shadow every later matching rule" do
    text = "host all all 0.0.0.0/0 reject\nhost all all 10.0.0.0/8 scram-sha-256\n"
    diagnostics = Diagnostics.for_document("file:///tmp/pg_hba.conf", text)

    assert Enum.any?(diagnostics, &String.contains?(&1.message, "earlier reject rule"))
  end

  test "the options a version knows follow the target version" do
    errors = fn text ->
      text
      |> Postern.PgHbaDiagnostics.diagnostics()
      |> Enum.filter(&(&1.severity == 1))
      |> Enum.map(& &1.message)
    end

    assert errors.("""
           # postern: pg=17
           host all all 10.0.0.0/8 md5 map=admins
           host all all 10.0.0.0/8 md5 issuer=https://issuer
           """) == [
             ~s(authentication option "map" is only valid for authentication methods ident, peer, gssapi, sspi, and cert),
             ~s(unrecognized authentication option name: "issuer")
           ]

    assert errors.("""
           # postern: pg=13
           hostssl all all 10.0.0.0/8 md5 clientcert=1
           hostssl all all 10.0.0.0/8 cert clientcert=no-verify
           hostssl all all 10.0.0.0/8 md5 clientname=CN
           """) == [
             ~s(clientcert cannot be set to "no-verify" when using "cert" authentication),
             ~s(unrecognized authentication option name: "clientname")
           ]

    assert errors.("hostssl all all 10.0.0.0/8 md5 clientcert=1\n") == [
             ~s(invalid value for clientcert: "1")
           ]
  end

  test "map names are checked only when pg_ident.conf is there to look at" do
    text = "local all all peer map=admins\n"
    missing = &String.contains?(&1.message, "does not exist in pg_ident.conf")

    refute Enum.any?(Postern.PgHbaDiagnostics.diagnostics(text), missing)
    assert Enum.any?(Postern.PgHbaDiagnostics.diagnostics(text, ""), missing)
  end

  test "reads the address the way parse_hba_line reads it" do
    text = """
    host all all example.com/24 md5
    host all all 10.0.0.0 ffff::0 md5
    host all all 10.0.0.0 md5
    host all all 10.0.0.0 255.255.0.1 md5
    host all all 10.0.0.999 md5
    host all all all 255.255.0.0 md5
    """

    diagnostics = Postern.PgHbaDiagnostics.diagnostics(text)

    assert Enum.map(diagnostics, &{&1.range.start.line, &1.severity, &1.message}) == [
             {0, 1, ~s(specifying both host name and CIDR mask is invalid: "example.com/24")},
             {1, 1, "IP address and mask do not match"},
             {2, 1, ~s(invalid IP mask "md5")},
             {4, 2,
              ~s("10.0.0.999" is not an IP address, so PostgreSQL takes it for a host name)},
             {5, 1, ~s(invalid authentication method "255.255.0.0")}
           ]
  end

  test "methods, directives and regular expressions follow the target version" do
    errors = fn text ->
      text
      |> Postern.PgHbaDiagnostics.diagnostics()
      |> Enum.map(&{&1.range.start.line, &1.severity, &1.message})
    end

    oauth = "host all all 10.0.0.0/8 oauth issuer=https://issuer scope=openid\n"

    assert errors.("# postern: pg=17\n" <> oauth) == [
             {1, 1, ~s(invalid authentication method "oauth")}
           ]

    assert errors.("# postern: pg=18\n" <> oauth) == []

    assert errors.("host all all 10.0.0.0/8 scram-sha-256-plus\n") ==
             [{0, 1, ~s(invalid authentication method "scram-sha-256-plus")}]

    newer = "include_dir hba.d\nhost /^app_/ +ops 10.0.0.0/8 md5\n"

    assert errors.("# postern: pg=15\n" <> newer) == [
             {1, 1, ~s(invalid connection type "include_dir")},
             {2, 2, ~s("/^app_/" is a name to PostgreSQL 15; a regular expression here needs 16)}
           ]

    assert errors.("# postern: pg=16\n" <> newer) == []
  end

  defp fixture!(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
  end
end
