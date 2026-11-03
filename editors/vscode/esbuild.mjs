import { build } from "esbuild";
import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { languageClientMinimatch } from "./scripts/languageclient-minimatch.mjs";

const root = import.meta.dirname;
const production = !process.argv.includes("--development");
const common = {
  absWorkingDir: root,
  bundle: true,
  external: ["vscode"],
  format: "cjs",
  legalComments: "none",
  logLevel: "info",
  mainFields: ["module", "main"],
  minify: production,
  sourcemap: production ? false : "external",
  sourcesContent: false,
  target: "es2025",
};

await mkdir(resolve(root, "dist"), { recursive: true });

await Promise.all([
  build({
    ...common,
    entryPoints: ["src/desktop.ts"],
    outfile: "dist/extension.cjs",
    platform: "node",
    plugins: [languageClientMinimatch],
  }),
  build({
    ...common,
    entryPoints: ["src/browser.ts"],
    outfile: "dist/browser.js",
    platform: "browser",
    define: { global: "globalThis" },
  }),
]);
