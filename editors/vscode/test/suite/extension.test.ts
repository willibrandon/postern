import * as assert from "node:assert/strict";
import * as vscode from "vscode";

const workspace = (): vscode.Uri => {
  const folder = vscode.workspace.workspaceFolders?.[0];
  if (folder === undefined) throw new Error("The test workspace is missing.");
  return folder.uri;
};

async function waitFor<T>(
  read: () => T | undefined,
  timeoutMs = 60_000,
  intervalMs = 250,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = read();
    if (value !== undefined) return value;
    if (Date.now() > deadline) throw new Error("Timed out waiting for the language server.");
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}

suite("Postern", () => {
  suiteSetup(async () => {
    const extension = vscode.extensions.getExtension("willibrandon.postern");
    assert.ok(extension, "extension is installed");
    await extension.activate();
  });

  test("reports a pg_hba.conf rule that an earlier rule shadows", async () => {
    const uri = vscode.Uri.joinPath(workspace(), "pg_hba.conf");
    const document = await vscode.workspace.openTextDocument(uri);
    assert.equal(document.languageId, "pg-hba");
    await vscode.window.showTextDocument(document);

    const diagnostics = await waitFor(() => {
      const found = vscode.languages.getDiagnostics(uri).filter((d) => d.source === "postern");
      return found.length > 0 ? found : undefined;
    });
    const shadowed = diagnostics.find((d) => d.message.includes("shadows it"));
    assert.ok(shadowed, `expected a shadowed-rule diagnostic, got ${JSON.stringify(diagnostics)}`);
    assert.equal(shadowed.range.start.line, 3);
    assert.equal(shadowed.severity, vscode.DiagnosticSeverity.Warning);
  });

  test("suggests the closest setting name in postgresql.conf", async () => {
    const uri = vscode.Uri.joinPath(workspace(), "postgresql.conf");
    const document = await vscode.workspace.openTextDocument(uri);
    assert.equal(document.languageId, "postgresql-conf");
    await vscode.window.showTextDocument(document);

    const diagnostics = await waitFor(() => {
      const found = vscode.languages.getDiagnostics(uri).filter((d) => d.source === "postern");
      return found.length > 0 ? found : undefined;
    });
    const unknown = diagnostics.find((d) => d.message.includes("Perhaps you meant"));
    assert.ok(unknown, `expected a suggestion, got ${JSON.stringify(diagnostics)}`);
    assert.equal(unknown.range.start.line, 3);
  });

  test("takes a conf.d file under a postgresql directory as postgresql.conf", async () => {
    const uri = vscode.Uri.joinPath(
      workspace(),
      "postgresql",
      "16",
      "main",
      "conf.d",
      "10-memory.conf",
    );
    const document = await vscode.workspace.openTextDocument(uri);
    assert.equal(document.languageId, "postgresql-conf");
    await vscode.window.showTextDocument(document);

    const diagnostics = await waitFor(() => {
      const found = vscode.languages.getDiagnostics(uri).filter((d) => d.source === "postern");
      return found.length > 0 ? found : undefined;
    });
    const unknown = diagnostics.find((d) => d.message.includes("shared_buffers"));
    assert.ok(unknown, `expected a suggestion, got ${JSON.stringify(diagnostics)}`);
    assert.equal(unknown.range.start.line, 1);
  });

  test("hovers a setting with its catalog entry", async () => {
    const uri = vscode.Uri.joinPath(workspace(), "postgresql.conf");
    await vscode.workspace.openTextDocument(uri);
    const result = await vscode.commands.executeCommand<vscode.Hover[]>(
      "vscode.executeHoverProvider",
      uri,
      new vscode.Position(2, 3),
    );
    const text = result
      .flatMap((hover) => hover.contents)
      .map((content) => (content instanceof vscode.MarkdownString ? content.value : ""))
      .join("\n");
    assert.match(text, /shared_buffers/);
    assert.match(text, /postmaster/);
  });
});
