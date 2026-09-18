defmodule Postern.DocsGeneratorTest do
  use ExUnit.Case, async: true

  alias Postern.Docs
  alias Postern.DocsGenerator

  @chapter """
  <chapter id="client-authentication">
   <sect1 id="auth-pg-hba-conf">
    <title>The <filename>pg_hba.conf</filename> File</title>
    <indexterm zone="auth-pg-hba-conf">
     <primary>pg_hba.conf</primary>
    </indexterm>
    <para>
     Client authentication is controlled by a configuration file,
     which traditionally is named <filename>pg_hba.conf</filename>.
    </para>
    <variablelist>
     <varlistentry>
      <term><literal>local</literal></term>
      <listitem>
       <para>
        This record matches connection attempts using Unix-domain
        sockets.  Without a record of this type, Unix-domain socket
        connections are disallowed.
       </para>
      </listitem>
     </varlistentry>
     <varlistentry>
      <term><replaceable>auth-method</replaceable></term>
      <listitem>
       <para>
        Specifies the authentication method to use.  The possible choices are:
       </para>
       <variablelist>
        <varlistentry>
         <term><literal>trust</literal></term>
         <listitem>
          <para>
           Allow the connection unconditionally.  See <xref linkend="auth-trust"/>
           for details.
          </para>
         </listitem>
        </varlistentry>
       </variablelist>
      </listitem>
     </varlistentry>
    </variablelist>
   </sect1>
   <sect1 id="auth-trust">
    <title>Trust Authentication</title>
    <para>
     When <literal>trust</literal> authentication is specified,
     <productname>PostgreSQL</productname> assumes that anyone who can
     connect to the server is authorized.
    </para>
    <itemizedlist>
     <listitem><para>one</para></listitem>
     <listitem><para>two &amp; three</para></listitem>
    </itemizedlist>
   </sect1>
  </chapter>
  """

  test "keeps each section's title, opening and entries, innermost first" do
    sections = DocsGenerator.sections(@chapter)
    assert Map.keys(sections) == ["auth-pg-hba-conf", "auth-trust"]

    hba = sections["auth-pg-hba-conf"]
    assert hba["title"] == "The `pg_hba.conf` File"

    assert hba["intro"] ==
             "Client authentication is controlled by a configuration file, which traditionally is named `pg_hba.conf`."

    assert hba["entries"]["local"] ==
             "This record matches connection attempts using Unix-domain sockets. Without a record of this type, Unix-domain socket connections are disallowed."

    # The nested entry is read first and removed, so the outer keeps its own text.
    assert hba["entries"]["auth-method"] ==
             "Specifies the authentication method to use. The possible choices are:"

    assert hba["entries"]["trust"] ==
             ~s(Allow the connection unconditionally. See "Trust Authentication" for details.)

    trust = sections["auth-trust"]
    assert trust["intro"] =~ "When `trust` authentication is specified, PostgreSQL assumes"
    refute trust["intro"] =~ "- one"
  end

  test "renders a list and an entity" do
    assert DocsGenerator.markdown(
             "<para>a &amp; b</para><itemizedlist><listitem><para>one</para></listitem><listitem><para>two</para></listitem></itemizedlist>"
           ) ==
             "a & b\n\n- one\n- two"
  end

  test "the generated files hold the chapter of every version" do
    for version <- Postern.Catalog.versions() do
      docs = Docs.load(version)
      assert Docs.hba(docs, "hostssl") =~ "SSL"
      assert Docs.option(docs, "ldap", "ldapbasedn") =~ "search"
      assert Docs.maps(docs) =~ "user name map"
    end

    assert Docs.hba(Docs.load(18), "oauth") =~ "OAuth"
    assert Docs.hba(Docs.load(17), "oauth") == nil
  end
end
