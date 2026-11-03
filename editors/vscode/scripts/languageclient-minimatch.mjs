import { readFile } from "node:fs/promises";

// vscode-languageclient 11 uses makeRe() only to validate these patterns.
// Minimatch 11 no longer builds regular expressions; an empty parsed set
// still identifies an empty/comment pattern. Remove this patch when the
// language client supports Minimatch 11 itself.
export const languageClientMinimatch = {
  name: "languageclient-minimatch",
  setup(build) {
    build.onLoad(
      {
        filter:
          /[\\/]vscode-languageclient[\\/]lib[\\/]common[\\/](fileOperations|utils[\\/]globPattern)\.js$/,
      },
      async ({ path }) => {
        const contents = await readFile(path, "utf8");
        const check = "if (!matcher.makeRe()) {";
        if (contents.split(check).length !== 2) {
          throw new Error(`Review the Minimatch compatibility patch for ${path}`);
        }
        return {
          contents: contents.replace(check, "if (matcher.set.length === 0) {"),
          loader: "js",
        };
      },
    );
  },
};
