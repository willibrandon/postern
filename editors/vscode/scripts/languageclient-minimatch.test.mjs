import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { build } from "esbuild";
import { languageClientMinimatch } from "./languageclient-minimatch.mjs";

const require = createRequire(import.meta.url);
const clientCommon = resolve(dirname(require.resolve("vscode-languageclient/node")), "../common");

// Exercise the installed client's code through the same build patch used
// by the extension, with only the VS Code host replaced.
async function loadClientModule(path, vscode = {}) {
  const result = await build({
    entryPoints: [resolve(clientCommon, path)],
    bundle: true,
    packages: "external",
    platform: "node",
    format: "cjs",
    write: false,
    plugins: [languageClientMinimatch],
  });
  const module = { exports: {} };
  runInNewContext(result.outputFiles[0].text, {
    module,
    exports: module.exports,
    require: (name) => (name === "vscode" ? vscode : require(name)),
  });
  return module.exports;
}

test("language client matches glob filters with patched Minimatch", async () => {
  const { matchGlobPattern } = await loadClientModule("utils/globPattern.js");
  assert.equal(matchGlobPattern("**/*.conf", { fsPath: "/etc/postgresql/postgresql.conf" }), true);
  assert.equal(matchGlobPattern("**/*.conf", { fsPath: "/etc/postgresql/README" }), false);
  assert.equal(matchGlobPattern("**/{pg_hba,pg_ident}.conf", { fsPath: "/etc/pg_hba.conf" }), true);
  assert.equal(matchGlobPattern("", { fsPath: "/etc/postgresql.conf" }), false);
  assert.equal(matchGlobPattern("# comment", { fsPath: "/etc/postgresql.conf" }), false);
});

test("language client registers and applies file operation filters", async () => {
  let disposed = false;
  const { DidCreateFilesFeature } = await loadClientModule("fileOperations.js", {
    workspace: {
      onDidCreateFiles: () => ({
        dispose() {
          disposed = true;
        },
      }),
    },
  });
  const feature = new DidCreateFilesFeature({
    code2ProtocolConverter: { asDidCreateFilesParams: (event) => event },
  });
  try {
    feature.register({
      id: "conf-files",
      registerOptions: {
        filters: [
          { scheme: "file", pattern: { glob: "**/*.conf", options: { ignoreCase: true } } },
        ],
      },
    });
    const files = [
      { scheme: "file", fsPath: "/etc/POSTGRESQL.CONF" },
      { scheme: "file", fsPath: "/etc/.hidden.conf" },
      { scheme: "file", fsPath: "/etc/README" },
      { scheme: "untitled", fsPath: "/etc/postgresql.conf" },
    ];
    const filtered = await feature.filter({ files }, (uri) => uri);
    assert.deepEqual(Array.from(filtered.files), files.slice(0, 2));
    assert.throws(
      () =>
        feature.register({
          id: "empty",
          registerOptions: { filters: [{ pattern: { glob: "" } }] },
        }),
      /Invalid pattern/,
    );
  } finally {
    feature.clear();
  }
  assert.equal(disposed, true);
});
