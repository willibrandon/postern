defmodule Postern.PgHbaOptions do
  @moduledoc """
  The authentication options a `pg_hba.conf` rule can carry and the methods
  each one belongs to, as `parse_hba_auth_opt` in PostgreSQL's hba.c lays
  them out for the target version. The messages are the ones
  `pg_hba_file_rules` reports, so a rule the server would refuse reads the
  same way in the editor.
  """

  # Each group is the methods that take the options, the way PostgreSQL names
  # those methods in its message, and the options themselves. These are the
  # same on every version Postern knows.
  @groups [
    {~w(pam), "pam", ~w(pamservice pam_use_hostname)},
    {~w(ldap), "ldap",
     ~w(ldapurl ldaptls ldapscheme ldapserver ldapport ldapbinddn ldapbindpasswd ldapsearchattribute ldapsearchfilter ldapbasedn ldapprefix ldapsuffix)},
    {~w(gss sspi), "gssapi and sspi", ~w(krb_realm include_realm)},
    {~w(sspi), "sspi", ~w(compat_realm upn_username)},
    {~w(radius), "radius", ~w(radiusservers radiusports radiussecrets radiusidentifiers)}
  ]

  # PostgreSQL 18 added the oauth method and its options.
  @oauth_options ~w(issuer scope validator delegate_ident_mapping)

  @by_name Map.new(
             for {methods, label, names} <- @groups, name <- names, do: {name, {methods, label}}
           )

  @doc "The methods that take a `map=` option, and so a map name from pg_ident.conf."
  @spec map_methods(pos_integer()) :: [String.t()]
  def map_methods(version) when version >= 18, do: ~w(ident peer gss sspi cert oauth)
  def map_methods(_version), do: ~w(ident peer gss sspi cert)

  @doc """
  Checks one option of a rule the way PostgreSQL does when it loads the file.

  `value` is `true` for an option written without `=`.
  """
  @spec check(String.t(), String.t() | true, String.t(), String.t(), pos_integer()) ::
          :ok | {:error, String.t()}
  def check(name, true, _connection_type, _method, _version),
    do: {:error, "authentication option not in name=value format: #{name}"}

  def check("map", _value, _connection_type, method, version),
    do: method_check("map", map_methods(version), map_label(version), method)

  # clientcert and clientname go with the connection type rather than the
  # method. clientname arrived in 14.
  def check("clientcert", value, connection_type, method, version) do
    if connection_type == "hostssl" do
      clientcert(value, method, version)
    else
      {:error, ~s(clientcert can only be configured for "hostssl" rows)}
    end
  end

  def check("clientname", value, connection_type, _method, version) when version >= 14 do
    cond do
      connection_type != "hostssl" ->
        {:error, ~s(clientname can only be configured for "hostssl" rows)}

      value in ~w(CN DN) ->
        :ok

      true ->
        {:error, ~s(invalid value for clientname: "#{value}")}
    end
  end

  def check(name, _value, _connection_type, method, version)
      when name in @oauth_options and version >= 18,
      do: method_check(name, ~w(oauth), "oauth", method)

  def check(name, _value, _connection_type, method, _version) do
    case Map.fetch(@by_name, name) do
      {:ok, {methods, label}} -> method_check(name, methods, label, method)
      :error -> {:error, ~s(unrecognized authentication option name: "#{name}")}
    end
  end

  @doc "The options a rule with this connection type and method takes, for completion."
  @spec for_rule(String.t(), String.t(), pos_integer()) :: [String.t()]
  def for_rule(connection_type, method, version) do
    by_type = if connection_type == "hostssl", do: hostssl_options(version), else: []
    map = if method in map_methods(version), do: ["map"], else: []
    oauth = if method == "oauth" and version >= 18, do: @oauth_options, else: []
    by_type ++ map ++ oauth ++ group_options(method)
  end

  @doc "Every option name the version knows, for completion when the rule's shape is unclear."
  @spec all(pos_integer()) :: [String.t()]
  def all(version) do
    oauth = if version >= 18, do: @oauth_options, else: []
    names = for {_methods, _label, names} <- @groups, name <- names, do: name
    hostssl_options(version) ++ ["map"] ++ oauth ++ names
  end

  defp map_label(version) when version >= 18, do: "ident, peer, gssapi, sspi, cert, and oauth"
  defp map_label(_version), do: "ident, peer, gssapi, sspi, and cert"

  defp hostssl_options(version) when version >= 14, do: ~w(clientcert clientname)
  defp hostssl_options(_version), do: ~w(clientcert)

  defp group_options(method) do
    for {methods, _label, names} <- @groups, method in methods, name <- names, do: name
  end

  # 13 also took 1 for verify-ca and 0 or no-verify for no check at all.
  defp clientcert(value, method, version) when version <= 13 do
    cond do
      value in ~w(0 no-verify) and method == "cert" ->
        {:error, ~s(clientcert cannot be set to "no-verify" when using "cert" authentication)}

      value in ~w(1 verify-ca verify-full 0 no-verify) ->
        :ok

      true ->
        {:error, ~s(invalid value for clientcert: "#{value}")}
    end
  end

  defp clientcert("verify-ca", "cert", _version),
    do: {:error, ~s(clientcert can only be set to "verify-full" when using "cert" authentication)}

  defp clientcert(value, _method, _version) when value in ~w(verify-ca verify-full), do: :ok

  defp clientcert(value, _method, _version),
    do: {:error, ~s(invalid value for clientcert: "#{value}")}

  defp method_check(name, methods, label, method) do
    if method in methods do
      :ok
    else
      {:error,
       ~s(authentication option "#{name}" is only valid for authentication methods #{label})}
    end
  end
end
