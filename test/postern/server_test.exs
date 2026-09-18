defmodule Postern.ServerTest do
  use ExUnit.Case, async: true

  import GenLSP.Test

  setup do
    id = System.unique_integer([:positive])

    server =
      server(Postern.Server,
        test_mode: true,
        buffer_id: :"buffer_#{id}",
        assigns_id: :"assigns_#{id}",
        task_supervisor_id: :"task_supervisor_#{id}",
        lsp_id: :"lsp_#{id}"
      )

    client = client(server)

    on_exit(fn ->
      :gen_tcp.close(client.socket)
    end)

    %{server: server, client: client}
  end

  describe "initialize" do
    test "replies with server capabilities", %{server: _server, client: client} do
      id = 1

      request(client, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "initialize",
        "params" => %{
          "processId" => nil,
          "rootUri" => nil,
          "capabilities" => %{},
          "initializationOptions" => %{}
        }
      })

      assert_result(^id, %{
        "capabilities" => %{
          "textDocumentSync" => %{
            "openClose" => true,
            "change" => 1,
            "save" => %{"includeText" => true}
          },
          "referencesProvider" => true,
          "renameProvider" => %{"prepareProvider" => true},
          "documentSymbolProvider" => true
        },
        "serverInfo" => %{"name" => "postern", "version" => _}
      })
    end

    test "stores initializationOptions and rootUri", %{server: server, client: client} do
      id = 2

      request(client, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "initialize",
        "params" => %{
          "processId" => nil,
          "rootUri" => "file:///workspace",
          "capabilities" => %{},
          "initializationOptions" => %{"pg" => 16}
        }
      })

      assert_result(^id, _result)

      # Give the server a moment to process the assign
      Process.sleep(50)
      assigns = server_assigns(server)
      assert assigns[:root_uri] == "file:///workspace"
      assert assigns[:initialization_options] == %{"pg" => 16}
    end
  end

  describe "shutdown / exit" do
    test "shutdown sets exit_code to 0", %{server: server, client: client} do
      # initialize first (required by LSP spec)
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 10,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })

      assert_result(10, _)

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "initialized",
        "params" => %{}
      })

      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 11,
        "method" => "shutdown"
      })

      assert_result(11, nil)
      Process.sleep(50)
      assigns = server_assigns(server)
      assert assigns[:exit_code] == 0
    end

    test "exit does not crash when test_mode true", %{server: server, client: client} do
      notify(client, %{"jsonrpc" => "2.0", "method" => "exit"})
      Process.sleep(50)
      assert alive?(server)
    end
  end

  describe "the files a tree reads while they are closed" do
    test "get diagnostics of their own, and lose them when the tree's last document closes", %{
      client: client
    } do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 420,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })

      assert_result(420, _result)

      directory =
        Path.join(System.tmp_dir!(), "postern-tree-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(directory, "conf.d"))
      File.write!(Path.join(directory, "postgresql.conf"), "port = 5432\ninclude_dir 'conf.d'\n")
      File.write!(Path.join(directory, "conf.d/10-memory.conf"), "shared_buffrs = 1\n")
      on_exit(fn -> File.rm_rf!(directory) end)

      root = Postern.FileKind.path_to_uri(Path.join(directory, "postgresql.conf"))
      included = Postern.FileKind.path_to_uri(Path.join(directory, "conf.d/10-memory.conf"))

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => root,
            "languageId" => "postgresql-conf",
            "version" => 1,
            "text" => "port = 5432\ninclude_dir 'conf.d'\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^root,
        "diagnostics" => []
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^included,
        "diagnostics" => [
          %{"message" => "unrecognized configuration parameter \"shared_buffrs\"" <> _rest}
        ]
      })

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didClose",
        "params" => %{"textDocument" => %{"uri" => root}}
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^root,
        "diagnostics" => []
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^included,
        "diagnostics" => []
      })
    end
  end

  describe "files on the disk" do
    test "a client that can watch files is asked to report changes to any .conf file", %{
      client: client
    } do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 400,
        "method" => "initialize",
        "params" => %{
          "processId" => nil,
          "rootUri" => nil,
          "capabilities" => %{
            "workspace" => %{"didChangeWatchedFiles" => %{"dynamicRegistration" => true}}
          }
        }
      })

      assert_result(400, _result)
      notify(client, %{"jsonrpc" => "2.0", "method" => "initialized", "params" => %{}})

      assert_request(client, "client/registerCapability", fn params ->
        assert [
                 %{
                   "method" => "workspace/didChangeWatchedFiles",
                   "registerOptions" => %{"watchers" => [%{"globPattern" => "**/*.conf"}]}
                 }
               ] =
                 params["registrations"]

        nil
      end)
    end

    test "a client that cannot watch files is not asked", %{client: client} do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 401,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })

      assert_result(401, _result)
      notify(client, %{"jsonrpc" => "2.0", "method" => "initialized", "params" => %{}})
      refute_receive %{"method" => "client/registerCapability"}, 200
    end

    test "a save and a change to a watched file check the open documents again", %{client: client} do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 402,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })

      assert_result(402, _result)
      uri = "file:///etc/postgresql.conf"

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => "postgresql-conf",
            "version" => 1,
            "text" => "shared_buffrs = 1\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^uri,
        "diagnostics" => [_one]
      })

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didSave",
        "params" => %{"textDocument" => %{"uri" => uri}}
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^uri,
        "diagnostics" => [_one]
      })

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "workspace/didChangeWatchedFiles",
        "params" => %{"changes" => [%{"uri" => "file:///etc/conf.d/10-memory.conf", "type" => 2}]}
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^uri,
        "diagnostics" => [_one]
      })
    end
  end

  describe "workspace/executeCommand" do
    setup %{client: client} do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 300,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })

      assert_result(300, _)
      :ok
    end

    test "the commands are advertised", %{client: client} do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 302,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })

      assert_result(302, %{
        "capabilities" => %{"executeCommandProvider" => %{"commands" => commands}}
      })

      assert "postern.disableTrustHints" in commands
      assert "postern.reloadConfig" in commands
    end

    test "a quick fix is offered for a postgresql.conf line without diagnostics in the request",
         %{client: client} do
      uri = "file:///etc/postgresql.conf"

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => "postgresql-conf",
            "version" => 1,
            "text" => "shared_buffrs = 128MB\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri})

      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 306,
        "method" => "textDocument/codeAction",
        "params" => %{
          "textDocument" => %{"uri" => uri},
          "range" => %{
            "start" => %{"line" => 0, "character" => 2},
            "end" => %{"line" => 0, "character" => 2}
          },
          "context" => %{"diagnostics" => []}
        }
      })

      assert_result(306, [
        %{
          "title" => "Replace with shared_buffers",
          "edit" => %{"changes" => %{^uri => [%{"newText" => "shared_buffers"}]}}
        }
      ])
    end

    test "a live command's outcome comes back as a message the editor shows", %{client: client} do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 305,
        "method" => "workspace/executeCommand",
        "params" => %{
          "command" => "postern.applyAlterSystem",
          "arguments" => ["file:///etc/postgresql.conf", "work_mem", "64MB"]
        }
      })

      assert_notification("window/showMessage", %{
        "type" => 1,
        "message" => "No server is reachable, so nothing ran."
      })

      assert_result(305, nil)
    end

    test "the trust quick fix is offered without diagnostics in the request", %{client: client} do
      uri = "file:///etc/pg_hba.conf"

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => "conf",
            "version" => 1,
            "text" => "local all all peer\nhost all all 10.0.0.0/8 trust\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri})

      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 303,
        "method" => "textDocument/codeAction",
        "params" => %{
          "textDocument" => %{"uri" => uri},
          "range" => %{
            "start" => %{"line" => 1, "character" => 0},
            "end" => %{"line" => 1, "character" => 0}
          },
          "context" => %{"diagnostics" => []}
        }
      })

      assert_result(303, [%{"command" => %{"command" => "postern.disableTrustHints"}}])

      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 304,
        "method" => "textDocument/codeAction",
        "params" => %{
          "textDocument" => %{"uri" => uri},
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 0}
          },
          "context" => %{"diagnostics" => []}
        }
      })

      assert_result(304, [])
    end

    test "postern.disableTrustHints stops the hint for open pg_hba.conf files", %{client: client} do
      uri = "file:///etc/pg_hba.conf"

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => "conf",
            "version" => 1,
            "text" => "host all all 10.0.0.0/8 trust\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^uri,
        "diagnostics" => [%{"code" => "trust"}]
      })

      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 301,
        "method" => "workspace/executeCommand",
        "params" => %{"command" => "postern.disableTrustHints", "arguments" => []}
      })

      assert_result(301, nil)

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri, "diagnostics" => []})
    end
  end

  describe "textDocument/didOpen, didChange, didClose" do
    setup %{server: _server, client: client} do
      # Ensure initialized
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 100,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })

      assert_result(100, _)

      :ok
    end

    test "stores document on didOpen", %{server: server, client: client} do
      uri = "file:///tmp/postgresql.conf"

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => "ini",
            "version" => 1,
            "text" => "shared_buffers = 128MB\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri, "version" => 1})
      docs = server_assigns(server)[:documents]
      assert docs[uri].text == "shared_buffers = 128MB\n"
      assert docs[uri].version == 1
      assert docs[uri].kind == :postgresql_conf
      assert docs[uri].uri == uri
    end

    test "detects file kind for pg_hba.conf", %{server: server, client: client} do
      uri = "file:///etc/pg_hba.conf"

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => "conf",
            "version" => 1,
            "text" => "local all all trust\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri, "version" => 1})
      docs = server_assigns(server)[:documents]
      assert docs[uri].kind == :pg_hba_conf
    end

    test "a file the editor calls postgresql-conf is checked as one", %{
      server: server,
      client: client
    } do
      uri = "file:///etc/postgresql/16/main/conf.d/10-memory.conf"

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => "postgresql-conf",
            "version" => 1,
            "text" => "shared_buffrs = 128MB\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^uri,
        "diagnostics" => [%{"message" => message}]
      })

      assert message =~ "shared_buffers"
      assert server_assigns(server)[:documents][uri].kind == :postgresql_conf

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didChange",
        "params" => %{
          "textDocument" => %{"uri" => uri, "version" => 2},
          "contentChanges" => [%{"text" => "shared_buffers = 128MB\n"}]
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri, "diagnostics" => []})

      assert server_assigns(server)[:documents][uri].kind == :postgresql_conf
    end

    test "updates document on didChange (full sync)", %{server: server, client: client} do
      uri = "file:///tmp/postgresql.conf"

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => "ini",
            "version" => 1,
            "text" => "shared_buffers = 128MB\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri, "version" => 1})

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didChange",
        "params" => %{
          "textDocument" => %{"uri" => uri, "version" => 2},
          "contentChanges" => [%{"text" => "shared_buffers = 256MB\n"}]
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri, "version" => 2})
      docs = server_assigns(server)[:documents]
      assert docs[uri].text == "shared_buffers = 256MB\n"
      assert docs[uri].version == 2
    end

    test "removes document on didClose", %{server: server, client: client} do
      uri = "file:///tmp/pg_ident.conf"

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => "conf",
            "version" => 1,
            "text" => "mymap user1 pguser1\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri, "version" => 1})
      assert Map.has_key?(server_assigns(server)[:documents], uri)

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didClose",
        "params" => %{"textDocument" => %{"uri" => uri}}
      })

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri, "diagnostics" => []})

      refute Map.has_key?(server_assigns(server)[:documents], uri)
    end

    test "later didOpen overrides earlier", %{server: server, client: client} do
      uri = "file:///tmp/postgresql.conf"

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => "ini",
            "version" => 1,
            "text" => "a = 1\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri, "version" => 1})

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => uri,
            "languageId" => "ini",
            "version" => 2,
            "text" => "b = 2\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri, "version" => 2})
      docs = server_assigns(server)[:documents]
      assert docs[uri].text == "b = 2\n"
      assert docs[uri].version == 2
    end
  end

  describe "the file next to the document" do
    setup %{client: client} do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 400,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })

      assert_result(400, _)

      directory =
        Path.join(System.tmp_dir!(), "postern-server-#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)
      %{directory: directory}
    end

    test "pg_ident.conf is read from the disk, then from the editor while it is open", %{
      client: client,
      directory: directory
    } do
      File.write!(Path.join(directory, "pg_ident.conf"), "known root postgres\n")
      hba_uri = Postern.FileKind.path_to_uri(Path.join(directory, "pg_hba.conf"))
      ident_uri = Postern.FileKind.path_to_uri(Path.join(directory, "pg_ident.conf"))

      missing = fn diagnostics ->
        for %{"message" => m} <- diagnostics, m =~ "does not exist", do: m
      end

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => hba_uri,
            "languageId" => "pg-hba",
            "version" => 1,
            "text" => "local all all peer map=known\nlocal all all peer map=extra\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^hba_uri,
        "diagnostics" => from_disk
      })

      assert missing.(from_disk) == [~s(ident map "extra" does not exist in pg_ident.conf)]

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => ident_uri,
            "languageId" => "pg-ident",
            "version" => 1,
            "text" => "known root postgres\nextra root postgres\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^ident_uri,
        "diagnostics" => []
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^hba_uri,
        "diagnostics" => from_editor
      })

      assert missing.(from_editor) == []

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didClose",
        "params" => %{"textDocument" => %{"uri" => ident_uri}}
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^ident_uri,
        "diagnostics" => []
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^hba_uri,
        "diagnostics" => after_close
      })

      assert missing.(after_close) == [~s(ident map "extra" does not exist in pg_ident.conf)]
    end
  end

  describe "the tree of files the server reads" do
    setup %{client: client} do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 500,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })

      assert_result(500, _)

      directory =
        Path.join(System.tmp_dir!(), "postern-tree-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(directory, "conf.d"))
      on_exit(fn -> File.rm_rf!(directory) end)

      File.write!(
        Path.join(directory, "postgresql.conf"),
        "shared_buffers = 128MB\ninclude 'extra.conf'\ninclude_dir 'conf.d'\n"
      )

      File.write!(Path.join(directory, "extra.conf"), "work_mem = 4MB\n")
      File.write!(Path.join(directory, "conf.d/10-memory.conf"), "shared_buffrs = 256MB\n")

      %{
        root: Postern.FileKind.path_to_uri(Path.join(directory, "postgresql.conf")),
        included: Postern.FileKind.path_to_uri(Path.join(directory, "conf.d/10-memory.conf")),
        extra: Postern.FileKind.path_to_uri(Path.join(directory, "extra.conf"))
      }
    end

    test "a file the root includes is checked as one of its kind, and the root follows it", %{
      server: server,
      client: client,
      root: root,
      included: included,
      extra: extra
    } do
      messages = fn diagnostics -> for %{"message" => message} <- diagnostics, do: message end

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => included,
            "languageId" => "plaintext",
            "version" => 1,
            "text" => "shared_buffrs = 256MB\n"
          }
        }
      })

      assert_notification("textDocument/publishDiagnostics", %{
        "uri" => ^included,
        "diagnostics" => [%{"message" => misspelled}]
      })

      assert misspelled =~ ~s(Perhaps you meant "shared_buffers")
      assert server_assigns(server)[:documents][included].kind == :postgresql_conf

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => root,
            "languageId" => "postgresql-conf",
            "version" => 1,
            "text" => "shared_buffers = 128MB\ninclude 'extra.conf'\ninclude_dir 'conf.d'\n"
          }
        }
      })

      # A closed file of the tree is published too, so a URI may be published
      # more than once per step; the last publish is the one that stands.
      before = last_diagnostics(root)
      refute Enum.any?(messages.(before), &String.contains?(&1, "overridden"))
      # Opening the root checks the included file again, with the same result.
      assert [_] = last_diagnostics(included)

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didChange",
        "params" => %{
          "textDocument" => %{"uri" => included, "version" => 2},
          "contentChanges" => [%{"text" => "shared_buffers = 256MB\n"}]
        }
      })

      assert last_diagnostics(included) == []
      after_edit = last_diagnostics(root)

      assert [
               %{
                 "code" => "override",
                 "severity" => 4,
                 "message" => message,
                 "range" => %{"start" => %{"line" => 0}}
               }
             ] =
               Enum.filter(after_edit, &(&1["code"] == "override"))

      assert message == "overridden by a later entry in conf.d/10-memory.conf on line 1"

      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 501,
        "method" => "textDocument/definition",
        "params" => %{
          "textDocument" => %{"uri" => root},
          "position" => %{"line" => 0, "character" => 3}
        }
      })

      assert_result(501, %{
        "uri" => ^included,
        "range" => %{"start" => %{"line" => 0, "character" => 0}}
      })

      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 502,
        "method" => "textDocument/documentLink",
        "params" => %{"textDocument" => %{"uri" => root}}
      })

      assert_result(502, [
        %{"target" => ^extra, "range" => %{"start" => %{"line" => 1, "character" => 8}}}
      ])
    end
  end

  describe "JSON-RPC pipe behavior" do
    test "initialize over TCP (simulates pipe) returns capabilities", %{
      server: _server,
      client: client
    } do
      id = 999

      request(client, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "initialize",
        "params" => %{
          "processId" => nil,
          "rootUri" => nil,
          "capabilities" => %{}
        }
      })

      assert_result(^id, result)
      assert result["serverInfo"]["name"] == "postern"
      assert get_in(result, ["capabilities", "textDocumentSync", "openClose"]) == true
    end
  end

  describe "hover and completion" do
    setup %{client: client} do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 300,
        "method" => "initialize",
        "params" => %{"processId" => nil, "rootUri" => nil, "capabilities" => %{}}
      })

      assert_result(300, _)

      notify(client, %{
        "jsonrpc" => "2.0",
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => "file:///tmp/postgresql.conf",
            "languageId" => "conf",
            "version" => 1,
            "text" => "shared_buffers = 128MB\n"
          }
        }
      })

      uri = "file:///tmp/postgresql.conf"
      assert_notification("textDocument/publishDiagnostics", %{"uri" => ^uri, "version" => 1})
      :ok
    end

    test "answers textDocument/hover", %{client: client} do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 301,
        "method" => "textDocument/hover",
        "params" => %{
          "textDocument" => %{"uri" => "file:///tmp/postgresql.conf"},
          "position" => %{"line" => 0, "character" => 7}
        }
      })

      assert_result(301, %{"contents" => %{"kind" => "markdown", "value" => value}})
      assert value =~ "shared_buffers"
    end

    test "answers textDocument/completion", %{client: client} do
      request(client, %{
        "jsonrpc" => "2.0",
        "id" => 302,
        "method" => "textDocument/completion",
        "params" => %{
          "textDocument" => %{"uri" => "file:///tmp/postgresql.conf"},
          "position" => %{"line" => 0, "character" => 7}
        }
      })

      assert_result(302, %{"isIncomplete" => false, "items" => items})
      assert Enum.any?(items, &(&1["label"] == "shared_buffers"))
    end
  end

  defp server_assigns(server) do
    GenLSP.Assigns.get(server.assigns)
  end

  # The last diagnostics published for a URI, once the server has gone
  # quiet about it.
  defp last_diagnostics(uri, previous \\ nil) do
    receive do
      %{
        "method" => "textDocument/publishDiagnostics",
        "params" => %{"uri" => ^uri, "diagnostics" => diagnostics}
      } ->
        last_diagnostics(uri, diagnostics)
    after
      400 -> previous || flunk("no diagnostics were published for #{uri}")
    end
  end
end
