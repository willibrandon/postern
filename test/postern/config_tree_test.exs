defmodule Postern.ConfigTreeTest do
  use ExUnit.Case, async: true

  alias Postern.ConfigTree
  alias Postern.Files

  @etc "/etc/postgresql/16/main"
  @root "/etc/postgresql/16/main/postgresql.conf"
  @data "/var/lib/postgresql/16/main"

  defp files do
    Files.in_memory(%{
      @root => """
      data_directory = '#{@data}'
      shared_buffers = 128MB
      include 'shared.conf'
      include_if_exists 'missing.conf'
      include_dir 'conf.d'
      work_mem = 2MB
      """,
      "#{@etc}/shared.conf" => "work_mem = 4MB\n",
      "#{@etc}/conf.d/10-memory.conf" => "shared_buffers = 256MB\n",
      "#{@etc}/conf.d/20-logging.conf" => "log_min_duration_statement = 250\n",
      "#{@etc}/conf.d/Z.conf" => "work_mem = 8MB\n",
      "#{@etc}/conf.d/a.conf" => "Work_Mem = 16MB\n",
      "#{@etc}/conf.d/.hidden.conf" => "port = 1\n",
      "#{@etc}/conf.d/notes.txt" => "port = 2\n",
      "#{@etc}/conf.d/x.conf" => "port = 3\n",
      "#{@data}/postgresql.auto.conf" => "shared_buffers = 512MB\n"
    })
  end

  test "reads the files in PostgreSQL's order, with the data directory's auto.conf last" do
    tree = ConfigTree.resolve(:postgresql_conf, @root, files())

    assert tree.files == [
             @root,
             "#{@etc}/shared.conf",
             "#{@etc}/conf.d/10-memory.conf",
             "#{@etc}/conf.d/20-logging.conf",
             "#{@etc}/conf.d/Z.conf",
             "#{@etc}/conf.d/a.conf",
             "#{@etc}/conf.d/x.conf",
             "#{@data}/postgresql.auto.conf"
           ]

    assert [%{severity: 4, message: message, path: @root, span: %{line: 4}}] = tree.problems
    assert message == ~s(skipping missing configuration file "#{@etc}/missing.conf")
  end

  test "the last assignment of a name counts, whatever its case" do
    tree = ConfigTree.resolve(:postgresql_conf, @root, files())

    assert %{path: "#{@data}/postgresql.auto.conf", entry: %{value: "512MB"}} =
             ConfigTree.winner(tree, "shared_buffers")

    # The include_dir line splices its files in where it stands, so the
    # root's own line 6 comes after everything in conf.d.
    assert %{path: @root, entry: %{value: "2MB", span: %{line: 6}}} =
             ConfigTree.winner(tree, "work_mem")

    assert ConfigTree.winner(tree, "port") == %{
             path: "#{@etc}/conf.d/x.conf",
             entry: ConfigTree.winner(tree, "port").entry
           }

    losers =
      tree
      |> ConfigTree.overridden()
      |> Enum.map(fn {loser, winner} ->
        {ConfigTree.relative(loser.path, @root), loser.entry.span.line,
         ConfigTree.relative(winner.path, @root)}
      end)
      |> Enum.sort()

    assert losers == [
             {"conf.d/10-memory.conf", 1, "/var/lib/postgresql/16/main/postgresql.auto.conf"},
             {"conf.d/Z.conf", 1, "postgresql.conf"},
             {"conf.d/a.conf", 1, "postgresql.conf"},
             {"postgresql.conf", 2, "/var/lib/postgresql/16/main/postgresql.auto.conf"},
             {"shared.conf", 1, "postgresql.conf"}
           ]
  end

  test "a missing include, a missing include_dir and recursion are the server's errors" do
    files =
      Files.in_memory(%{
        "/pg/postgresql.conf" =>
          "include 'gone.conf'\ninclude_dir 'nowhere'\ninclude 'postgresql.conf'\n"
      })

    tree = ConfigTree.resolve(:postgresql_conf, "/pg/postgresql.conf", files)

    assert Enum.map(tree.problems, &{&1.span.line, &1.severity, &1.message}) == [
             {1, 1, ~s(could not open file "/pg/gone.conf")},
             {2, 1, ~s(could not open directory "/pg/nowhere")},
             {3, 1, "configuration file recursion"}
           ]
  end

  test "nesting stops at ten levels, where the server stops" do
    chain =
      for n <- 1..12, into: %{}, do: {"/pg/#{n}.conf", "include '#{n + 1}.conf'\nport = #{n}\n"}

    files = Files.in_memory(Map.put(chain, "/pg/postgresql.conf", "include '1.conf'\n"))

    tree = ConfigTree.resolve(:postgresql_conf, "/pg/postgresql.conf", files)

    assert length(tree.files) == 11

    assert [%{path: "/pg/10.conf", severity: 1, message: "nesting depth exceeded"}] =
             tree.problems
  end

  test "an included file belongs to the tree of the root above it, whatever it is called" do
    assert ConfigTree.root(:postgresql_conf, "#{@etc}/conf.d/10-memory.conf", files()) == @root
    assert ConfigTree.kind_of("#{@etc}/conf.d/10-memory.conf", files()) == :postgresql_conf
    assert ConfigTree.kind_of("#{@etc}/conf.d/notes.txt", files()) == :unknown
    assert ConfigTree.root(:postgresql_conf, "#{@etc}/conf.d/notes.txt", files()) == nil

    stray = ConfigTree.for_document(:postgresql_conf, "#{@etc}/conf.d/notes.txt", files())
    assert stray.root == "#{@etc}/conf.d/notes.txt"
    assert stray.files == ["#{@etc}/conf.d/notes.txt"]
  end

  test "a root three directories down the workspace is found too" do
    workspace = Path.join(System.tmp_dir!(), "postern-tree-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "cluster/main/conf.d"))
    File.mkdir_p!(Path.join(workspace, "shared"))
    on_exit(fn -> File.rm_rf!(workspace) end)
    root = Path.join(workspace, "cluster/main/postgresql.conf")
    shared = Path.join(workspace, "shared/memory.conf")
    File.write!(root, "include '../../shared/memory.conf'\ninclude_dir 'conf.d'\n")
    File.write!(shared, "work_mem = 4MB\n")

    assert ConfigTree.root(:postgresql_conf, shared, Files.disk()) == nil
    assert ConfigTree.root(:postgresql_conf, shared, Files.disk(), workspace: workspace) == root
  end

  test "pg_hba.conf and pg_ident.conf trees splice their includes in the same way" do
    files =
      Files.in_memory(%{
        "/pg/pg_hba.conf" => "include_dir hba.d\nlocal all all peer\ninclude gone.conf\n",
        "/pg/hba.d/10-app.conf" => "host app app 10.0.0.0/8 scram-sha-256\n",
        "/pg/pg_ident.conf" => "include_if_exists maps.conf\n"
      })

    hba = ConfigTree.resolve(:pg_hba_conf, "/pg/pg_hba.conf", files)
    assert hba.files == ["/pg/pg_hba.conf", "/pg/hba.d/10-app.conf"]

    assert [%{entry: %{databases: ["app"]}}, %{entry: %{connection_type: "local"}}] =
             Enum.filter(hba.entries, &(&1.entry.type == :rule))

    assert [%{severity: 1, message: message}] = hba.problems
    assert message == ~s(could not open file "/pg/gone.conf": No such file or directory)

    # An older target has no directives to follow.
    old = ConfigTree.resolve(:pg_hba_conf, "/pg/pg_hba.conf", files, version: 15)
    assert old.files == ["/pg/pg_hba.conf"]
    assert old.problems == []

    ident = ConfigTree.resolve(:pg_ident_conf, "/pg/pg_ident.conf", files)
    assert [%{severity: 4, message: skipped}] = ident.problems
    assert skipped == ~s(skipping missing authentication file "/pg/maps.conf")
  end
end
