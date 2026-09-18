defmodule Postern.Docs do
  @moduledoc """
  The manual's words for what stands at a position in pg_hba.conf or
  pg_ident.conf, from the generated `priv/docs/pgNN.json`.

  A connection type, a field, a method or a directive is an entry of the
  chapter's section on pg_hba.conf; an option is an entry of its method's
  section, or, for the ones the chapter describes in the field's own text,
  the entry for the options field; a pg_ident.conf token gets the opening
  of the section on user name maps.
  """

  @hba "auth-pg-hba-conf"
  @maps "auth-username-maps"

  @method_sections %{
    "trust" => "auth-trust",
    "scram-sha-256" => "auth-password",
    "md5" => "auth-password",
    "password" => "auth-password",
    "gss" => "gssapi-auth",
    "sspi" => "sspi-auth",
    "ident" => "auth-ident",
    "peer" => "auth-peer",
    "ldap" => "auth-ldap",
    "radius" => "auth-radius",
    "cert" => "auth-cert",
    "pam" => "auth-pam",
    "bsd" => "auth-bsd",
    "oauth" => "auth-oauth"
  }

  @doc "Loads the documentation for a PostgreSQL major version, or `nil` without it."
  @spec load(pos_integer(), keyword()) :: map() | nil
  def load(version, opts \\ []) do
    path =
      Path.join(
        Keyword.get(opts, :docs_dir, Path.join(:code.priv_dir(:postern), "docs")),
        "pg#{version}.json"
      )

    with {:ok, json} <- File.read(path),
         {:ok, %{"sections" => sections}} <- Jason.decode(json) do
      sections
    else
      _other -> nil
    end
  end

  @doc "The text for a connection type, a field, a method or a directive of pg_hba.conf."
  @spec hba(map() | nil, String.t()) :: String.t() | nil
  def hba(nil, _term), do: nil
  def hba(sections, term), do: get_in(sections, [@hba, "entries", term])

  @doc """
  The text for an option of a rule with the method, from the method's
  section first, then wherever the chapter has it, then the field's own
  text.
  """
  @spec option(map() | nil, String.t(), String.t()) :: String.t() | nil
  def option(nil, _method, _name), do: nil

  def option(sections, method, name) do
    sections_to_search =
      [Map.get(@method_sections, method)] ++ Map.keys(sections)

    Enum.find_value(sections_to_search, fn
      nil -> nil
      id -> get_in(sections, [id, "entries", name])
    end) || hba(sections, "auth-options")
  end

  @doc "The opening of the section on user name maps."
  @spec maps(map() | nil) :: String.t() | nil
  def maps(nil), do: nil
  def maps(sections), do: get_in(sections, [@maps, "intro"])

  @doc "The title of a method's section, when it has one."
  @spec method_section(map() | nil, String.t()) :: String.t() | nil
  def method_section(nil, _method), do: nil

  def method_section(sections, method) do
    case Map.get(@method_sections, method) do
      nil -> nil
      id -> get_in(sections, [id, "title"])
    end
  end
end
