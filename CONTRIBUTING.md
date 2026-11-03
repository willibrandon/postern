# Contributing

Postern is a language server written in Elixir, with the editor packages beside it under
`editors/`, and every check in it is measured against what PostgreSQL itself does. This page says
what a change needs before it goes in; the [README](README.md) has the commands under Development.

## What a check has to be

A check reports what the server would refuse, in the words the server would use. The wording comes
from the server's own sources, `guc.c`, `hba.c` and the manual, and it differs by version, so a
message is written per version where the server's is. A check that says something the server would
not say is wrong even when it is helpful. Before a check is done it is compared with a running
server of each version it applies to, through `pg_file_settings` and `pg_hba_file_rules`, or
`ALTER SYSTEM SET` for a value, and the live tests under `test/` keep that comparison. They are
tagged `live` and run only when `PGHOST` names a server:

```sh
PGHOST=127.0.0.1 PGPORT=5418 PGUSER=postgres mix test --only live
```

The catalogs in `priv/catalog` and the hover text in `priv/docs` are generated from a PostgreSQL
checkout and the servers, by `mix postern.catalog` and `mix postern.docs`; they are not edited by
hand.

## Before a pull request

CI runs the server's suite on Elixir 1.20 against PostgreSQL 13 through 18, and each editor package
with its own tools, so the same commands pass locally first:

```sh
mix compile --warnings-as-errors
mix test
mix credo --strict
mix format --check-formatted
mix docs --warnings-as-errors
mix dialyzer
npx --yes pyright@1.1.414
```

The Python smoke test uses strict type checking. Dialyzer checks the server and Mix tasks;
its first run builds a dependency cache. VS Code treats the generated `mix.lock` as plain text
because Mix's quoted keys otherwise produce unnecessary-quote warnings in ElixirLS.

Postgrex is temporarily pinned to an official upstream commit that includes its text-query
typespec fix and the security fixes in 0.22.4. Move it back to Hex when a release includes
[the typespec correction](https://github.com/elixir-ecto/postgrex/pull/784).

ElixirLS 0.31.1 can crash in this project because its bundled `GenLSP` modules collide with
the project's dependency. Use a build containing [ElixirLS #1287](https://github.com/elixir-lsp/elixir-ls/pull/1287)
via `elixirLS.languageServerOverridePath` until that fix is released. Clearing `.elixir_ls`
or repeatedly restarting the unpatched server does not resolve the collision.

For the editor packages: `npm run verify` and `npm test` in `editors/vscode`, `npm run validate` in
`editors/fresh`, `nvim -l tests/minit.lua --busted` in `editors/nvim`, the batch `ert` run named in
`editors/emacs/README.md`, and `cargo build --release --target wasm32-wasip2` in `editors/zed`. A
change to what a user sees gets a bullet in `CHANGELOG.md`, under the version it will ship in, and
the extension's `editors/vscode/CHANGELOG.md` gets one when the extension's behaviour changes.

## Writing

A commit subject says what the change does, in the imperative, with no prefix, and the body says
why in a short paragraph. A pull request body is the same in a few paragraphs, ending with the issue
it closes. Documentation, the changelog and messages in the editor are plain and concise, say only
what was verified, and stop when the point is made.

## Releases

A release is cut from `main`: the version moves in `mix.exs` and each editor package, the changelog
entries get their date, and the Release workflow runs once as a dry run before the tag `vX.Y.Z` is
pushed. The tag is annotated, `git tag -a`, with `Postern X.Y.Z` as its first line and the changelog
entry as the rest, because the workflow takes the release notes from the tag message. The tag builds
the binaries and the Windows installer, publishes the extension, updates the Homebrew tap and the
Scoop bucket, opens the winget pull request, publishes the Neovim plugin and moves the action's
major tag. A winget pull request still waiting on a moderator when the next one opens is closed as
superseded.

Security issues go through the [security policy](SECURITY.md), not an issue.
