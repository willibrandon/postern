defmodule Postern.SymbolsTest do
  use ExUnit.Case, async: true

  alias GenLSP.Enumerations.SymbolKind
  alias Postern.Symbols

  @fixtures Path.expand("../fixtures", __DIR__)

  defp outline(symbols),
    do: Enum.map(symbols, &{&1.name, &1.detail, &1.kind, outline(&1.children || [])})

  test "postgresql.conf is its sections and subsections with the settings under each" do
    text = """
    port = 5432

    #------------------------------------------------------------------------------
    # CONNECTIONS AND AUTHENTICATION
    #------------------------------------------------------------------------------

    # - Connection Settings -

    listen_addresses = 'localhost'
    #port = 5432
    max_connections = 100

    # - TCP settings -

    tcp_keepalives_idle = 0
    include 'extra.conf'

    #------------------------------------------------------------------------------
    # RESOURCE USAGE (except WAL)
    #------------------------------------------------------------------------------

    shared_buffers = 128MB
    """

    symbols = Symbols.document_symbols(:postgresql_conf, text, 18)

    assert outline(symbols) == [
             {"port", "5432", SymbolKind.property(), []},
             {"CONNECTIONS AND AUTHENTICATION", nil, SymbolKind.namespace(),
              [
                {"Connection Settings", nil, SymbolKind.namespace(),
                 [
                   {"listen_addresses", "'localhost'", SymbolKind.property(), []},
                   {"max_connections", "100", SymbolKind.property(), []}
                 ]},
                {"TCP settings", nil, SymbolKind.namespace(),
                 [
                   {"tcp_keepalives_idle", "0", SymbolKind.property(), []},
                   {"extra.conf", "include", SymbolKind.file(), []}
                 ]}
              ]},
             {"RESOURCE USAGE (except WAL)", nil, SymbolKind.namespace(),
              [{"shared_buffers", "128MB", SymbolKind.property(), []}]}
           ]

    [_port, connections, _resources] = symbols
    assert connections.range.start.line == 3
    assert connections.range.end.line == 15
    assert connections.selection_range.start.line == 3
  end

  test "the stock sample outlines into its sections" do
    symbols =
      Symbols.document_symbols(
        :postgresql_conf,
        File.read!(Path.join(@fixtures, "postgresql.conf.sample")),
        18
      )

    names = Enum.map(symbols, & &1.name)
    assert "FILE LOCATIONS" in names
    assert "CONNECTIONS AND AUTHENTICATION" in names
    assert Enum.all?(symbols, &(&1.kind == SymbolKind.namespace()))
  end

  test "pg_hba.conf is one symbol per rule, and pg_ident.conf one per map with its mappings" do
    hba =
      "local all all peer\nhost all all 10.0.0.0/8 scram-sha-256 clientcert=verify-full\ninclude_dir conf.d\n"

    assert outline(Symbols.document_symbols(:pg_hba_conf, hba, 18)) == [
             {"local all all", "peer", SymbolKind.object(), []},
             {"host all all 10.0.0.0/8", "scram-sha-256", SymbolKind.object(), []},
             {"conf.d", "include_dir", SymbolKind.file(), []}
           ]

    ident = "ops alice alice\nother carol carol\nops bob bob\n"
    [ops, other] = Symbols.document_symbols(:pg_ident_conf, ident, 18)

    assert outline([ops, other]) == [
             {"ops", nil, SymbolKind.namespace(),
              [
                {"alice alice", nil, SymbolKind.property(), []},
                {"bob bob", nil, SymbolKind.property(), []}
              ]},
             {"other", nil, SymbolKind.namespace(),
              [{"carol carol", nil, SymbolKind.property(), []}]}
           ]

    assert ops.range.start.line == 0 and ops.range.end.line == 2
  end
end
