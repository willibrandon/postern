defmodule Postern.PgIdentDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Postern.Diagnostics

  @fixtures Path.expand("../fixtures", __DIR__)

  test "warns when a map is never referenced by pg_hba.conf" do
    diagnostics =
      Diagnostics.for_document(
        "file:///tmp/pg_ident.conf",
        fixture!("pg_ident_references.conf"),
        %{pg_hba_text: "host all all 10.0.0.0/8 ident map=used_map\n"}
      )

    assert [%{severity: 2, message: "ident map \"unused_map\" is never referenced"}] = diagnostics
  end

  test "a map referenced from peer, cert, gss, sspi or oauth is not unused" do
    hba = """
    local all all peer map=peer_map
    hostssl all all 10.0.0.0/8 cert map=cert_map
    host all all 10.0.0.0/8 gss map=gss_map
    host all all 10.0.0.0/8 sspi map=sspi_map
    host all all 10.0.0.0/8 oauth map=oauth_map issuer=https://issuer scope=openid
    host all all 10.0.0.0/8 md5 map=md5_map
    """

    ident = """
    peer_map root postgres
    cert_map root postgres
    gss_map root postgres
    sspi_map root postgres
    oauth_map root postgres
    md5_map root postgres
    """

    diagnostics =
      Diagnostics.for_document("file:///tmp/pg_ident.conf", ident, %{pg_hba_text: hba})

    assert [%{message: "ident map \"md5_map\" is never referenced"}] = diagnostics
  end

  test "no map is called unused without a pg_hba.conf to look at" do
    assert Diagnostics.for_document("file:///tmp/pg_ident.conf", "admins root postgres\n") == []
  end

  defp fixture!(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
  end
end
