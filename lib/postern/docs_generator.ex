defmodule Postern.DocsGenerator do
  @moduledoc """
  Generates `priv/docs/pgNN.json`, the words the hover shows for
  pg_hba.conf and pg_ident.conf, from the client authentication chapter of
  each version's manual in a git checkout of PostgreSQL.

  The chapter describes every connection type, field, method, option and
  directive in a `varlistentry` with a term, and each section opens with
  paragraphs of its own, so the generator keeps, per section, the text of
  every entry by its term and the section's opening paragraphs, rendered
  as Markdown. The text is the PostgreSQL Global Development Group's, under
  the PostgreSQL License, which `priv/docs/LICENSE` carries.
  """

  @chapter "doc/src/sgml/client-auth.sgml"

  @doc "Generates the documentation of one version from the checkout at `source`."
  @spec generate(Path.t(), pos_integer(), keyword()) :: :ok
  def generate(source, version, opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir, "priv/docs")
    ref = release_branch(source, version)
    sgml = git!(source, ["show", "#{ref}:#{@chapter}"])

    docs = %{
      "version" => version,
      "source" => "#{@chapter} of PostgreSQL #{version}, under the PostgreSQL License",
      "sections" => sections(sgml)
    }

    File.mkdir_p!(output_dir)

    File.write!(
      Path.join(output_dir, "pg#{version}.json"),
      Jason.encode!(docs, pretty: true) <> "\n"
    )

    :ok
  end

  @doc """
  The sections of a chapter: each `sect1` by its id, with its title, its
  opening paragraphs before any list or subsection, and the text of every
  entry in it by the entry's term.
  """
  @spec sections(String.t()) :: %{String.t() => map()}
  def sections(sgml) do
    sections =
      ~r/<sect1 id="([^"]+)">(.*?)<\/sect1>/s
      |> Regex.scan(sgml)
      |> Map.new(fn [_all, id, body] ->
        {id, %{"title" => title(body, id), "intro" => intro(body), "entries" => entries(body)}}
      end)

    # A cross reference to a section of the chapter reads as that section's
    # title; one to anywhere else as the words of its id.
    titles = Map.new(sections, fn {id, section} -> {id, section["title"]} end)
    Map.new(sections, fn {id, section} -> {id, resolve(section, titles)} end)
  end

  defp title(body, id) do
    case Regex.run(~r/<title>(.*?)<\/title>/s, body) do
      [_all, title] -> markdown(title)
      nil -> id
    end
  end

  defp resolve(section, titles) do
    section
    |> Map.update!("intro", &references(&1, titles))
    |> Map.update!("entries", fn entries ->
      Map.new(entries, fn {term, text} -> {term, references(text, titles)} end)
    end)
  end

  defp references(text, titles) do
    Regex.replace(~r/\[\[([^\]]+)\]\]/, text, fn _all, id ->
      ~s("#{Map.get(titles, id, String.replace(id, "-", " "))}")
    end)
  end

  @doc """
  The entries of a section: the innermost `varlistentry` blocks first, each
  removed once read so that an outer entry keeps its own text alone, with
  the text keyed by every term the entry has.
  """
  @spec entries(String.t()) :: %{String.t() => String.t()}
  def entries(body), do: entries(body, %{})

  defp entries(body, acc) do
    case Regex.run(~r/<varlistentry>((?:(?!<varlistentry>).)*?)<\/varlistentry>/s, body,
           return: :index
         ) do
      [{start, size}, {inner_start, inner_size}] ->
        inner = binary_part(body, inner_start, inner_size)

        terms =
          ~r/<term>(.*?)<\/term>/s
          |> Regex.scan(inner)
          |> Enum.map(fn [_all, term] -> term |> strip_tags() |> String.trim() end)

        text =
          case Regex.run(~r/<listitem>(.*?)<\/listitem>/s, inner) do
            [_all, item] -> markdown(item)
            nil -> ""
          end

        acc = Enum.reduce(terms, acc, &Map.put_new(&2, &1, text))

        rest =
          binary_part(body, 0, start) <>
            binary_part(body, start + size, byte_size(body) - start - size)

        entries(rest, acc)

      nil ->
        acc
    end
  end

  # The paragraphs before the first list or subsection.
  defp intro(body) do
    cut =
      [~r/<variablelist>/, ~r/<sect2/, ~r/<itemizedlist>/, ~r/<programlisting>/]
      |> Enum.map(fn regex ->
        case Regex.run(regex, body, return: :index) do
          [{start, _size}] -> start
          nil -> byte_size(body)
        end
      end)
      |> Enum.min()

    body |> binary_part(0, cut) |> markdown()
  end

  @doc """
  A piece of the chapter as Markdown: paragraphs apart, inline markup as
  code or emphasis, lists as lists, listings as code blocks, and the index
  terms, footnotes and cross references the hover cannot follow left out.
  """
  @spec markdown(String.t()) :: String.t()
  def markdown(sgml) do
    sgml
    |> String.replace(~r/<indexterm[^>]*>.*?<\/indexterm>/s, "")
    |> String.replace(~r/<footnote[^>]*>.*?<\/footnote>/s, "")
    |> String.replace(~r/<title>.*?<\/title>/s, "")
    |> String.replace(~r/<sect2 id="[^"]+">.*?<\/sect2>/s, "")
    |> String.replace(~r/<!--.*?-->/s, "")
    |> replace(~r/<programlisting>(.*?)<\/programlisting>/s, &code_block/2)
    |> replace(~r/<synopsis>(.*?)<\/synopsis>/s, &code_block/2)
    |> String.replace(~r/<listitem>\s*<para>/s, "<listitem>")
    |> String.replace(~r/<\/para>\s*<\/listitem>/s, "</listitem>")
    |> replace(~r/<listitem>(.*?)<\/listitem>/s, fn _all, item ->
      "\n- " <> squeeze(item) <> "\n"
    end)
    |> String.replace(
      ~r/<\/?(?:itemizedlist|orderedlist|simplelist|note|tip|warning|caution|important)>/,
      "\n"
    )
    |> replace(~r/<xref linkend="([^"]+)"\/>/, fn _all, id -> "[[#{id}]]" end)
    |> String.replace(~r/<link linkend="[^"]+">(.*?)<\/link>/s, "\\1")
    |> String.replace(~r/<ulink url="([^"]+)">(.*?)<\/ulink>/s, "[\\2](\\1)")
    |> String.replace(
      ~r/<(literal|command|filename|varname|option|type|function|envar|parameter|symbol|userinput|computeroutput|structname|structfield)>(.*?)<\/\1>/s,
      "`\\2`"
    )
    |> String.replace(~r/<(replaceable|emphasis|firstterm)>(.*?)<\/\1>/s, "*\\2*")
    |> String.replace(~r/<quote>(.*?)<\/quote>/s, "\"\\1\"")
    |> String.replace(~r/<\/?para(?: [^>]*)?>/, "\n\n")
    |> String.replace(
      ~r/<\/?(?:productname|application|acronym|systemitem|token|member|abbrev|phrase|sgmltag|tag|glossterm|citetitle)>/,
      ""
    )
    |> String.replace(~r/<[^>]+>/, "")
    |> entities()
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(&paragraph/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce("", &join_paragraph/2)
  end

  # Items of one list stay together; anything else is a paragraph apart.
  defp join_paragraph(paragraph, ""), do: paragraph

  defp join_paragraph("- " <> _rest = item, acc) do
    if String.starts_with?(List.last(String.split(acc, "\n")), "- "),
      do: acc <> "\n" <> item,
      else: acc <> "\n\n" <> item
  end

  defp join_paragraph(paragraph, acc), do: acc <> "\n\n" <> paragraph

  defp replace(text, regex, fun), do: Regex.replace(regex, text, fun)

  defp code_block(_all, code), do: "\n\n```\n" <> String.trim(code, "\n") <> "\n```\n\n"

  # A paragraph on one line, a list item or a code block as it is.
  defp paragraph(text) do
    cond do
      String.starts_with?(String.trim_leading(text), "```") ->
        String.trim(text)

      String.starts_with?(String.trim_leading(text), "- ") ->
        text |> String.trim() |> String.replace(~r/\n\s*- /, "\n- ")

      true ->
        squeeze(text)
    end
  end

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp strip_tags(text), do: text |> String.replace(~r/<[^>]+>/, "") |> entities()

  defp entities(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&ndash;", "-")
    |> String.replace("&mdash;", ", ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&hellip;", "...")
    |> String.replace("&amp;", "&")
  end

  defp release_branch(source, version) do
    Enum.find(["REL_#{version}_STABLE", "origin/REL_#{version}_STABLE"], fn ref ->
      match?(
        {_out, 0},
        System.cmd("git", ["-C", source, "rev-parse", "--verify", "--quiet", ref])
      )
    end) || raise "no REL_#{version}_STABLE branch in #{source}"
  end

  defp git!(source, args) do
    case System.cmd("git", ["-C", source | args], stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> raise "git #{Enum.join(args, " ")} failed with #{status}: #{out}"
    end
  end
end
