defmodule Postern.Server do
  @moduledoc """
  Language Server Protocol server for PostgreSQL configuration files.

  Handles lifecycle requests (`initialize`, `shutdown`, `exit`) and
  the document synchronization notifications (`textDocument/didOpen`,
  `textDocument/didChange`, `textDocument/didClose`). Documents are
  kept in an in-memory store keyed by URI, with the file kind detected
  from the basename.

  Diagnostics, hover and completion are provided by the server alongside
  document synchronization.
  """

  use GenLSP

  alias GenLSP.Enumerations.TextDocumentSyncKind
  alias GenLSP.Notifications.Exit, as: ExitNotification
  alias GenLSP.Notifications.Initialized
  alias GenLSP.Notifications.TextDocumentDidChange
  alias GenLSP.Notifications.TextDocumentDidClose
  alias GenLSP.Notifications.TextDocumentDidOpen
  alias GenLSP.Notifications.TextDocumentDidSave
  alias GenLSP.Notifications.TextDocumentPublishDiagnostics
  alias GenLSP.Notifications.WindowShowMessage
  alias GenLSP.Notifications.WorkspaceDidChangeWatchedFiles
  alias GenLSP.Requests.ClientRegisterCapability
  alias GenLSP.Requests.Initialize
  alias GenLSP.Requests.Shutdown
  alias GenLSP.Requests.TextDocumentCodeAction
  alias GenLSP.Requests.TextDocumentCompletion
  alias GenLSP.Requests.TextDocumentDefinition
  alias GenLSP.Requests.TextDocumentDocumentLink
  alias GenLSP.Requests.TextDocumentDocumentSymbol
  alias GenLSP.Requests.TextDocumentHover
  alias GenLSP.Requests.TextDocumentInlayHint
  alias GenLSP.Requests.TextDocumentPrepareRename
  alias GenLSP.Requests.TextDocumentReferences
  alias GenLSP.Requests.TextDocumentRename
  alias GenLSP.Requests.WorkspaceExecuteCommand
  alias GenLSP.Structures.CompletionOptions
  alias GenLSP.Structures.DidChangeWatchedFilesRegistrationOptions
  alias GenLSP.Structures.DocumentLinkOptions
  alias GenLSP.Structures.ExecuteCommandOptions
  alias GenLSP.Structures.FileSystemWatcher
  alias GenLSP.Structures.InitializeParams
  alias GenLSP.Structures.InitializeResult
  alias GenLSP.Structures.PublishDiagnosticsParams
  alias GenLSP.Structures.Registration
  alias GenLSP.Structures.RegistrationParams
  alias GenLSP.Structures.RenameOptions
  alias GenLSP.Structures.SaveOptions
  alias GenLSP.Structures.ServerCapabilities
  alias GenLSP.Structures.ShowMessageParams
  alias GenLSP.Structures.TextDocumentSyncOptions
  alias Postern.ConfigTree
  alias Postern.Diagnostics
  alias Postern.DocumentStore
  alias Postern.Features
  alias Postern.FileKind
  alias Postern.Files
  alias Postern.LiveFeatures
  alias Postern.LiveOracle

  @server_name "postern"

  # Public API

  @doc """
  Starts the language server.

  `args` is passed to `init/2`. `opts` is forwarded to `GenLSP.start_link/3`
  and should contain `:buffer`, `:assigns` and `:task_supervisor`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {args, gen_opts} = Keyword.split(opts, [:test_mode])

    gen_opts =
      Keyword.take(gen_opts, [:buffer, :assigns, :task_supervisor, :name, :sync_notifications])

    GenLSP.start_link(__MODULE__, args, gen_opts)
  end

  # Callbacks

  @impl true
  def init(lsp, args) do
    test_mode = Keyword.get(args, :test_mode, false)
    {:ok, live_oracle} = LiveOracle.start_link(nil)

    {:ok,
     assign(lsp,
       documents: %{},
       exit_code: 1,
       test_mode: test_mode,
       initialization_options: nil,
       root_uri: nil,
       live_oracle: live_oracle,
       watch_files: false
     )}
  end

  @impl true
  def handle_request(%Initialize{params: %InitializeParams{} = params}, lsp) do
    initialization_options = Map.get(params, :initialization_options)
    root_uri = Map.get(params, :root_uri)

    live_oracle =
      case LiveOracle.connection_options(initialization_options || %{}) do
        nil ->
          current_assigns(lsp).live_oracle

        options ->
          {:ok, oracle} = LiveOracle.start_link(options)
          oracle
      end

    lsp =
      assign(lsp,
        initialization_options: initialization_options,
        root_uri: root_uri,
        live_oracle: live_oracle,
        watch_files: watches_files?(params)
      )

    GenLSP.info(
      lsp,
      "[initialize] Initializing Postern language server for #{client_name(params)}."
    )

    result = %InitializeResult{
      capabilities: %ServerCapabilities{
        text_document_sync: %TextDocumentSyncOptions{
          open_close: true,
          change: TextDocumentSyncKind.full(),
          save: %SaveOptions{include_text: true}
        },
        hover_provider: true,
        completion_provider: %CompletionOptions{trigger_characters: [".", "="]},
        definition_provider: true,
        references_provider: true,
        rename_provider: %RenameOptions{prepare_provider: true},
        document_link_provider: %DocumentLinkOptions{resolve_provider: false},
        document_symbol_provider: true,
        inlay_hint_provider: true,
        code_action_provider: true,
        execute_command_provider: %ExecuteCommandOptions{commands: Features.commands()}
      },
      server_info: %{name: @server_name, version: version()}
    }

    {:reply, result, lsp}
  end

  def handle_request(%Shutdown{}, lsp) do
    GenLSP.info(lsp, "[shutdown] Stopping Postern language server.")
    {:reply, nil, assign(lsp, exit_code: 0)}
  end

  def handle_request(%TextDocumentHover{params: params}, lsp) do
    reply =
      case DocumentStore.get(lsp, params.text_document.uri) do
        %{text: text, kind: kind} ->
          Features.hover(
            params.text_document.uri,
            text,
            params.position,
            Map.put(feature_options(lsp), :kind, kind)
          )

        nil ->
          nil
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentCompletion{params: params}, lsp) do
    reply =
      case DocumentStore.get(lsp, params.text_document.uri) do
        %{text: text, kind: kind} ->
          Features.completion(
            params.text_document.uri,
            text,
            params.position,
            Map.put(feature_options(lsp), :kind, kind)
          )

        nil ->
          nil
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentReferences{params: params}, lsp) do
    reply =
      case DocumentStore.get(lsp, params.text_document.uri) do
        %{text: text, kind: kind} ->
          Features.references(
            params.text_document.uri,
            text,
            params.position,
            Map.put(feature_options(lsp), :kind, kind)
          )

        nil ->
          []
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentPrepareRename{params: params}, lsp) do
    reply =
      case DocumentStore.get(lsp, params.text_document.uri) do
        %{text: text, kind: kind} ->
          Features.prepare_rename(
            params.text_document.uri,
            text,
            params.position,
            Map.put(feature_options(lsp), :kind, kind)
          )

        nil ->
          nil
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentRename{params: params}, lsp) do
    reply =
      case DocumentStore.get(lsp, params.text_document.uri) do
        %{text: text, kind: kind} ->
          Features.rename(
            params.text_document.uri,
            text,
            params.position,
            params.new_name,
            Map.put(feature_options(lsp), :kind, kind)
          )

        nil ->
          nil
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentDefinition{params: params}, lsp) do
    reply =
      case DocumentStore.get(lsp, params.text_document.uri) do
        %{text: text, kind: kind} ->
          Features.definition(
            params.text_document.uri,
            text,
            params.position,
            Map.put(feature_options(lsp), :kind, kind)
          )

        nil ->
          nil
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentDocumentLink{params: params}, lsp) do
    reply =
      case DocumentStore.get(lsp, params.text_document.uri) do
        %{text: text, kind: kind} ->
          Features.document_links(
            params.text_document.uri,
            text,
            Map.put(feature_options(lsp), :kind, kind)
          )

        nil ->
          []
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentDocumentSymbol{params: params}, lsp) do
    reply =
      case DocumentStore.get(lsp, params.text_document.uri) do
        %{text: text, kind: kind} ->
          options = feature_options(lsp)

          version =
            Postern.PostgresqlConfDiagnostics.target_version(
              text,
              options,
              Postern.Catalog.versions()
            )

          Postern.Symbols.document_symbols(kind, text, version)

        nil ->
          []
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentInlayHint{params: params}, lsp) do
    reply =
      live_feature_result(lsp, params.text_document.uri, fn _uri, text, snapshot ->
        LiveFeatures.inlay_hints(text, snapshot)
      end)

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentCodeAction{params: params}, lsp) do
    live =
      live_feature_result(lsp, params.text_document.uri, fn uri, text, snapshot ->
        LiveFeatures.code_actions(uri, text, snapshot, params.range)
      end)

    diagnostics =
      actionable_diagnostics(
        lsp,
        params.text_document.uri,
        params.context.diagnostics || [],
        params.range
      )

    {:reply, Features.code_actions(diagnostics, params.text_document.uri) ++ live, lsp}
  end

  # The quick fix on a trust hint. Handling it here means it works from any
  # editor that runs code action commands; the hint stays off until the
  # server restarts. An editor that remembers the choice restarts the server
  # with `reportTrust` in its initialization options instead.
  def handle_request(
        %WorkspaceExecuteCommand{params: %{command: "postern.disableTrustHints"}},
        lsp
      ) do
    options =
      case Map.get(current_assigns(lsp), :initialization_options) do
        nil -> %{}
        options -> Map.new(options)
      end
      |> Map.drop([:reportTrust])
      |> Map.put("reportTrust", false)

    lsp = assign(lsp, initialization_options: options)

    for {uri, document} <- DocumentStore.all(lsp), document.kind == :pg_hba_conf do
      publish_diagnostics(lsp, uri, document.text, document.version)
    end

    {:reply, nil, lsp}
  end

  # A live command runs on the server, and what the server answered is
  # shown to the user as a message, since a client discards a command's
  # result.
  def handle_request(%WorkspaceExecuteCommand{params: params}, lsp) do
    arguments = params.arguments || []
    oracle = current_assigns(lsp).live_oracle
    result = LiveOracle.execute(oracle, params.command, arguments)

    case LiveFeatures.report(params.command, arguments, result, LiveOracle.snapshot(oracle)) do
      {type, message} ->
        GenLSP.notify(lsp, %WindowShowMessage{
          params: %ShowMessageParams{type: type, message: message}
        })

      nil ->
        :ok
    end

    {:reply, nil, lsp}
  end

  @impl true
  def handle_notification(%Initialized{}, lsp) do
    GenLSP.info(lsp, "[initialized] Postern language server initialized.")
    if current_assigns(lsp).watch_files, do: register_watchers(lsp)
    {:noreply, lsp}
  end

  def handle_notification(%ExitNotification{}, lsp) do
    exit_code = Map.get(current_assigns(lsp), :exit_code, 0)
    test_mode = Map.get(current_assigns(lsp), :test_mode, false)

    unless test_mode do
      System.halt(exit_code)
    end

    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidOpen{params: params}, lsp) do
    doc = params.text_document
    kind = opened_kind(lsp, doc.uri, doc.language_id)
    lsp = DocumentStore.put(lsp, doc.uri, doc.text, doc.version, doc.language_id, kind)
    publish_diagnostics(lsp, doc.uri, doc.text, doc.version)
    publish_related(lsp, doc.uri, document_kind(lsp, doc.uri))
    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidChange{params: params}, lsp) do
    uri = params.text_document.uri
    version = params.text_document.version

    current =
      case DocumentStore.get(lsp, uri) do
        %{text: text} -> text
        nil -> ""
      end

    text = DocumentStore.apply_changes(current, params.content_changes)
    lsp = DocumentStore.update(lsp, uri, text, version)
    publish_diagnostics(lsp, uri, text, version)
    publish_related(lsp, uri, document_kind(lsp, uri))
    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidClose{params: params}, lsp) do
    uri = params.text_document.uri
    kind = document_kind(lsp, uri)
    lsp = DocumentStore.delete(lsp, uri)

    GenLSP.notify(lsp, %TextDocumentPublishDiagnostics{
      params: %PublishDiagnosticsParams{uri: uri, diagnostics: []}
    })

    publish_related(lsp, uri, kind)
    {:noreply, lsp}
  end

  # A save may be what the server reads next, so the document and the ones
  # that share a tree with it are checked again, with a fresh snapshot.
  def handle_notification(%TextDocumentDidSave{params: params}, lsp) do
    uri = params.text_document.uri

    case DocumentStore.get(lsp, uri) do
      %{text: text, version: version, kind: kind} ->
        publish_diagnostics(lsp, uri, text, version)
        publish_related(lsp, uri, kind)

      nil ->
        :ok
    end

    {:noreply, lsp}
  end

  # A file the checks read from the disk changed: an include, the auto file
  # ALTER SYSTEM writes, or the file beside the open one. Every open
  # document is checked again, since any of them may read it.
  def handle_notification(%WorkspaceDidChangeWatchedFiles{}, lsp) do
    for {uri, document} <- DocumentStore.all(lsp) do
      publish_diagnostics(lsp, uri, document.text, document.version)
    end

    {:noreply, lsp}
  end

  # Gracefully ignore other notifications.
  def handle_notification(_notification, lsp) do
    {:noreply, lsp}
  end

  # The client is asked to report changes to any .conf file it can see,
  # which covers the four files, conf.d and most includes. A client that
  # cannot register watchers said so at initialize and is not asked.
  defp register_watchers(lsp) do
    GenLSP.request(
      lsp,
      %ClientRegisterCapability{
        id: "postern.watchers",
        params: %RegistrationParams{
          registrations: [
            %Registration{
              id: "postern.watched-files",
              method: "workspace/didChangeWatchedFiles",
              register_options: %DidChangeWatchedFilesRegistrationOptions{
                watchers: [%FileSystemWatcher{glob_pattern: "**/*.conf"}]
              }
            }
          ]
        }
      },
      5_000
    )
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp watches_files?(%InitializeParams{capabilities: capabilities}) do
    case capabilities do
      %{workspace: %{did_change_watched_files: %{dynamic_registration: true}}} -> true
      _other -> false
    end
  end

  defp publish_diagnostics(lsp, uri, text, version) do
    GenLSP.notify(lsp, %TextDocumentPublishDiagnostics{
      params: %PublishDiagnosticsParams{
        uri: uri,
        version: version,
        diagnostics: document_diagnostics(lsp, uri, text)
      }
    })
  end

  # The name says what a file is; failing that, the root that includes it;
  # failing that, what the editor calls it.
  defp opened_kind(lsp, uri, language_id) do
    with :unknown <- FileKind.detect(uri),
         :unknown <-
           ConfigTree.kind_of(
             FileKind.canonical(FileKind.uri_to_path(uri)),
             reader(lsp),
             workspace: workspace(lsp)
           ) do
      FileKind.detect(uri, language_id)
    end
  end

  # What a file reports depends on the others in its tree, and pg_hba.conf
  # and pg_ident.conf on each other, so when one changes every other open
  # file of a related kind is checked again. That covers a close as well,
  # since the check then falls back to the disk.
  defp publish_related(lsp, uri, kind) do
    related = related_kinds(kind)

    for {other_uri, document} <- DocumentStore.all(lsp),
        other_uri != uri,
        document.kind in related do
      publish_diagnostics(lsp, other_uri, document.text, document.version)
    end

    :ok
  end

  defp related_kinds(:postgresql_conf), do: [:postgresql_conf]
  defp related_kinds(:pg_hba_conf), do: [:pg_hba_conf, :pg_ident_conf]
  defp related_kinds(:pg_ident_conf), do: [:pg_ident_conf, :pg_hba_conf]
  defp related_kinds(_kind), do: []

  # Clients differ in which diagnostics they send back with a code action
  # request, and one that sends them may drop the data they carry, so the
  # diagnostics with a fix in the range come from the document itself.
  defp actionable_diagnostics(lsp, uri, context, range) do
    with false <- Enum.any?(context, &Features.actionable?/1),
         %{text: text} <- DocumentStore.get(lsp, uri) do
      fixes =
        document_diagnostics(lsp, uri, text)
        |> Enum.filter(&(Features.actionable?(&1) and overlaps?(&1.range, range)))

      context ++ fixes
    else
      _ -> context
    end
  end

  defp overlaps?(a, b), do: a.start.line <= b.end.line and a.end.line >= b.start.line

  defp document_diagnostics(lsp, uri, text) do
    initialization_options = Map.get(current_assigns(lsp), :initialization_options, %{})

    base_options =
      if is_nil(initialization_options), do: %{}, else: Map.new(initialization_options)

    live_oracle = Map.get(current_assigns(lsp), :live_oracle)
    live_snapshot = if is_pid(live_oracle), do: LiveOracle.snapshot(live_oracle), else: nil

    options =
      base_options
      |> Map.merge(document_options(lsp))
      |> Map.put(:kind, document_kind(lsp, uri))
      |> Map.put(:live_snapshot, live_snapshot)
      |> Map.put(:live_configured, LiveOracle.connection_options(base_options) != nil)

    Diagnostics.for_document(uri, text, options)
  end

  # The kind the document was opened with, or the name's when it is not open.
  defp document_kind(lsp, uri) do
    case DocumentStore.get(lsp, uri) do
      %{kind: kind} -> kind
      nil -> FileKind.detect(uri)
    end
  end

  # Inlay hints and code actions describe settings, so only postgresql.conf
  # documents get them.
  defp live_feature_result(lsp, uri, callback) do
    case DocumentStore.get(lsp, uri) do
      %{text: text, kind: :postgresql_conf} ->
        snapshot = LiveOracle.snapshot(current_assigns(lsp).live_oracle)
        callback.(uri, text, snapshot)

      _ ->
        []
    end
  end

  defp feature_options(lsp) do
    initialization_options = Map.get(current_assigns(lsp), :initialization_options, %{})

    base_options =
      if is_nil(initialization_options), do: %{}, else: Map.new(initialization_options)

    base_options
    |> Map.merge(document_options(lsp))
    |> Map.put(:live_snapshot, LiveOracle.snapshot(current_assigns(lsp).live_oracle))
  end

  defp current_assigns(lsp), do: GenLSP.LSP.assigns(lsp)

  # The files a check reads besides the document: an open one as the editor
  # has it, any other from the disk, and the workspace to look for a root in.
  defp document_options(lsp), do: %{reader: reader(lsp), workspace: workspace(lsp)}

  defp reader(lsp), do: Files.with_documents(DocumentStore.all(lsp))

  defp workspace(lsp) do
    case Map.get(current_assigns(lsp), :root_uri) do
      nil -> nil
      uri -> FileKind.canonical(FileKind.uri_to_path(uri))
    end
  end

  defp client_name(%InitializeParams{client_info: %{name: name}}) when is_binary(name), do: name
  defp client_name(_params), do: "an unknown client"

  defp version, do: :postern |> Application.spec(:vsn) |> to_string()
end
