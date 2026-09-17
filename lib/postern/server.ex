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
  alias GenLSP.Notifications.TextDocumentPublishDiagnostics
  alias GenLSP.Requests.Initialize
  alias GenLSP.Requests.Shutdown
  alias GenLSP.Requests.TextDocumentCodeAction
  alias GenLSP.Requests.TextDocumentCompletion
  alias GenLSP.Requests.TextDocumentHover
  alias GenLSP.Requests.TextDocumentInlayHint
  alias GenLSP.Requests.WorkspaceExecuteCommand
  alias GenLSP.Structures.CompletionOptions
  alias GenLSP.Structures.ExecuteCommandOptions
  alias GenLSP.Structures.InitializeParams
  alias GenLSP.Structures.InitializeResult
  alias GenLSP.Structures.PublishDiagnosticsParams
  alias GenLSP.Structures.SaveOptions
  alias GenLSP.Structures.ServerCapabilities
  alias GenLSP.Structures.TextDocumentSyncOptions
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
       live_oracle: live_oracle
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
        live_oracle: live_oracle
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
        %{text: text} ->
          Features.hover(
            params.text_document.uri,
            text,
            params.position,
            feature_options(lsp)
          )

        nil ->
          nil
      end

    {:reply, reply, lsp}
  end

  def handle_request(%TextDocumentCompletion{params: params}, lsp) do
    reply =
      case DocumentStore.get(lsp, params.text_document.uri) do
        %{text: text} ->
          Features.completion(
            params.text_document.uri,
            text,
            params.position,
            Map.get(current_assigns(lsp), :initialization_options, %{})
          )

        nil ->
          nil
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
      live_feature_result(lsp, params.text_document.uri, fn uri, _text, snapshot ->
        LiveFeatures.code_actions(uri, snapshot)
      end)

    diagnostics =
      trust_diagnostics(
        lsp,
        params.text_document.uri,
        params.context.diagnostics || [],
        params.range
      )

    {:reply, Features.code_actions(diagnostics) ++ live, lsp}
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

  def handle_request(%WorkspaceExecuteCommand{params: params}, lsp) do
    arguments = params.arguments || []
    uri = List.first(arguments)

    arguments =
      case DocumentStore.get(lsp, uri) do
        %{text: text} -> arguments ++ [text]
        nil -> arguments
      end

    reply = LiveOracle.execute(current_assigns(lsp).live_oracle, params.command, arguments)
    {:reply, reply, lsp}
  end

  @impl true
  def handle_notification(%Initialized{}, lsp) do
    GenLSP.info(lsp, "[initialized] Postern language server initialized.")
    {:noreply, lsp}
  end

  def handle_notification(%ExitNotification{}, lsp) do
    exit_code = Map.get(current_assigns(lsp), :exit_code, 0)
    test_mode = Map.get(current_assigns(lsp), :test_mode, false)
    test_env = Code.ensure_loaded?(Mix) and Mix.env() == :test

    unless test_mode or test_env do
      System.halt(exit_code)
    end

    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidOpen{params: params}, lsp) do
    doc = params.text_document
    lsp = DocumentStore.put(lsp, doc.uri, doc.text, doc.version, doc.language_id)
    publish_diagnostics(lsp, doc.uri, doc.text, doc.version)
    publish_related(lsp, doc.uri)
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
    publish_related(lsp, uri)
    {:noreply, lsp}
  end

  def handle_notification(%TextDocumentDidClose{params: params}, lsp) do
    uri = params.text_document.uri
    lsp = DocumentStore.delete(lsp, uri)

    GenLSP.notify(lsp, %TextDocumentPublishDiagnostics{
      params: %PublishDiagnosticsParams{uri: uri, diagnostics: []}
    })

    publish_related(lsp, uri)
    {:noreply, lsp}
  end

  # Gracefully ignore other notifications (didSave, etc.)
  def handle_notification(_notification, lsp) do
    {:noreply, lsp}
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

  # What pg_hba.conf reports depends on pg_ident.conf and the other way round,
  # so when one changes, the other one open next to it is checked again. That
  # covers a close as well, since the check then falls back to the disk.
  defp publish_related(lsp, uri) do
    directory = uri |> FileKind.uri_to_path() |> Path.dirname()
    related = related_kinds(FileKind.detect(uri))

    for {other_uri, document} <- DocumentStore.all(lsp),
        other_uri != uri,
        document.kind in related,
        Path.dirname(FileKind.uri_to_path(other_uri)) == directory do
      publish_diagnostics(lsp, other_uri, document.text, document.version)
    end

    :ok
  end

  defp related_kinds(:pg_hba_conf), do: [:pg_ident_conf]
  defp related_kinds(:pg_ident_conf), do: [:pg_hba_conf]
  defp related_kinds(_kind), do: []

  # Clients differ in which diagnostics they send back with a code action
  # request, so the trust hints in the range come from the document itself
  # when the request carries none.
  defp trust_diagnostics(lsp, uri, context, range) do
    with false <- Enum.any?(context, &Features.trust_diagnostic?/1),
         %{text: text, kind: :pg_hba_conf} <- DocumentStore.get(lsp, uri) do
      hints =
        document_diagnostics(lsp, uri, text)
        |> Enum.filter(&(Features.trust_diagnostic?(&1) and overlaps?(&1.range, range)))

      context ++ hints
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
      |> Map.put(:live_snapshot, live_snapshot)
      |> Map.put(:live_configured, LiveOracle.connection_options(base_options) != nil)

    Diagnostics.for_document(uri, text, options)
  end

  # Inlay hints and code actions describe settings, so only postgresql.conf
  # documents get them.
  defp live_feature_result(lsp, uri, callback) do
    with :postgresql_conf <- FileKind.detect(uri),
         %{text: text} <- DocumentStore.get(lsp, uri) do
      snapshot = LiveOracle.snapshot(current_assigns(lsp).live_oracle)
      callback.(uri, text, snapshot)
    else
      _ -> []
    end
  end

  defp feature_options(lsp) do
    initialization_options = Map.get(current_assigns(lsp), :initialization_options, %{})

    base_options =
      if is_nil(initialization_options), do: %{}, else: Map.new(initialization_options)

    Map.put(base_options, :live_snapshot, LiveOracle.snapshot(current_assigns(lsp).live_oracle))
  end

  defp current_assigns(lsp), do: GenLSP.LSP.assigns(lsp)

  # The files a check reads besides the document: an open one as the editor
  # has it, any other from the disk.
  defp document_options(lsp), do: %{reader: Files.with_documents(DocumentStore.all(lsp))}

  defp client_name(%InitializeParams{client_info: %{name: name}}) when is_binary(name), do: name
  defp client_name(_params), do: "an unknown client"

  defp version, do: :postern |> Application.spec(:vsn) |> to_string()
end
