import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path: string) => readFileSync(join(root, path), "utf8");
const manifest = JSON.parse(read("package.json"));
const language = manifest.fresh.languages[0];
const plugin = read(manifest.fresh.plugins[0].entry);
const GRAMMAR = "grammars/postgresql-conf.sublime-syntax";
const FILENAMES = [
  "postgresql.conf",
  "postgresql.auto.conf",
  "postgresql.base.conf",
  "pg_hba.conf",
  "pg_ident.conf",
];

test("the manifest is a bundle with one language served by postern", () => {
  assert.equal(manifest.type, "bundle");
  assert.equal(manifest.fresh.min_version, "0.4.10");
  assert.equal(manifest.fresh.languages.length, 1);
  assert.equal(language.id, "postgresql-conf");
  assert.equal(language.language.commentPrefix, "#");
  assert.equal(language.lsp.command, "postern");
  assert.equal(language.lsp.autoStart, true);
});

test("the package version follows the server", () => {
  const mix = readFileSync(join(root, "..", "..", "mix.exs"), "utf8");
  assert.equal(manifest.version, mix.match(/version: "([^"]+)"/)?.[1]);
});

test("the grammar is registered by the plugin, not the manifest", () => {
  assert.equal(language.grammar, undefined);
  assert.ok(existsSync(join(root, GRAMMAR)));
  assert.match(read(GRAMMAR), /^scope: source\.postgresql-conf$/m);
  assert.match(read(GRAMMAR), /^name: PostgreSQL Config$/m);
  assert.ok(plugin.includes('"PostgreSQL Config"'));
  assert.doesNotMatch(read(GRAMMAR), /^file_extensions:/m);
  for (const part of GRAMMAR.split("/")) {
    assert.ok(plugin.includes(`"${part}"`), part);
  }
});

test("the plugin offers the trust hint as a setting", () => {
  assert.ok(plugin.includes('defineConfigBoolean("reportTrust"'));
  assert.ok(plugin.includes('editor.on("config_changed"'));
});

test("the plugin claims the file names and the include_dir pattern for the language", () => {
  assert.ok(plugin.includes('"postgresql-conf"'));
  for (const name of FILENAMES) {
    assert.ok(plugin.includes(`"${name}"`), name);
  }
  assert.ok(plugin.includes('"**/postgresql/**/conf.d/*.conf"'));
});
