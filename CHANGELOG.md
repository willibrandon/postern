# Changelog

## [Unreleased]

- Every option on a `pg_hba.conf` rule is checked against the connection type, the method and
  the target PostgreSQL version the way hba.c checks it, with the messages `pg_hba_file_rules`
  reports, and the problem is marked on the option. `map=` on a peer, cert, gss, sspi or oauth
  rule is now looked up in `pg_ident.conf`, and the map it names no longer shows as unused
  there. Completion offers the options the rule's method takes.
- The Zed extension is `postgresql-conf`, the id Zed's guidelines give a language extension, carries
  its own license and references the grammar's 0.1.0 release, ready for the extension registry.
- An Emacs package in `editors/emacs`: a tree-sitter major mode for the four files with Imenu and
  navigation, registered with Eglot for the server.
- The Zed extension asks the release for the asset names it actually has when it downloads the
  server.

## [0.1.7] - 2026-09-16

- The server advertises its commands, which Zed and Neovim require before they will run a code
  action's command, and finds trust hints in the requested range itself instead of relying on
  the diagnostics a client sends back.
- A tree-sitter grammar, [tree-sitter-postgresql-conf](https://github.com/willibrandon/tree-sitter-postgresql-conf),
  with editor packages that use it: the Neovim plugin registers it for `:TSInstall` and ships
  queries, `editors/helix` has a `languages.toml` entry and queries, and `editors/zed` is an
  extension that also fetches the server from the latest release.

## [0.1.6] - 2026-09-16

- A Neovim plugin in `editors/nvim` for Neovim 0.11 or newer: filetypes for the four files and
  the server enabled through Neovim's own client, with no nvim-lspconfig needed.
- A Fresh bundle in `editors/fresh` for Fresh 0.4.10 or newer: a grammar for the four files, their
  names claimed when the bundle loads, and the server started through Fresh's own client. The
  trust hint is a toggle in Fresh Settings.
- The server handles the quick fix that stops trust hints itself, so it works from Fresh as well
  as VS Code. The hint stays off until the server restarts.
- Changes sent as ranges, which Fresh does whatever the server asks for, are applied to the
  document. Before, the text of the last change replaced the whole file.

## [0.1.5] - 2026-09-16

- The VS Code extension logs what the server writes to stderr at the level the line states, so
  the runtime wrapper's notice about removing an older version no longer shows as an error.

## [0.1.4] - 2026-09-16

- The VS Code extension is published as platform packages only. The universal package matched
  every platform and the Marketplace validated it before the platform packages, so an update in
  that window installed a package with no server binary.

## [0.1.3] - 2026-09-16

- `trust` or `password` on a non-local `pg_hba.conf` rule is now a hint rather than a warning, so
  it stays out of the Problems panel, and loopback and `samehost` rules are not reported at all.
  The `reportTrust` initialization option turns the hint off, and the hint carries a quick fix
  that does so in VS Code.
- The shadowing check no longer treats `all` as covering `replication`, since PostgreSQL's `all`
  keyword never matches a replication connection.
- The server halts as soon as the editor closes its input pipe. Before, that started a graceful
  stop that could not complete under Burrito, so VS Code waited two seconds and killed the
  process on every restart, and logged two formatter crashes on the way.

## [0.1.2] - 2026-09-16

- Settings whose changes need a server restart are no longer reported as problems. That is a
  property of the setting, not a fault in the file, so it now appears in the hover instead. A
  live server that has not yet applied a changed value still gets its pending-restart note.

## [0.1.1] - 2026-09-16

- Fixed a crash when a live server was reachable: the oracle returned its snapshot wrapped in
  `{:ok, map}` while diagnostics, completion, inlay hints and code actions expected the map, so
  every request on an open file failed once a connection succeeded. Inlay hints and code actions
  now apply to `postgresql.conf` only.

## [0.1.0] - 2026-09-16

- Language server for `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` and
  `pg_ident.conf`, speaking LSP over stdio.
- Offline diagnostics from catalogs of `pg_settings` for PostgreSQL 13 through 18: unknown
  settings with a suggestion, bad values and units, settings removed between versions, duplicate
  keys, and `pg_hba.conf` rules that an earlier rule shadows.
- Live diagnostics from `pg_file_settings`, `pg_hba_file_rules` and `pg_ident_file_mappings` when a
  connection string is configured, so the editor shows the server's own parse errors before a
  reload.
- Hover, completion, inlay hints and code actions.
- `postern check` for scripts and CI, plus `--help` and `--version`.
- Logs go to stderr without colour, so they can never corrupt the protocol stream.
- Single-file binaries for Linux, macOS and Windows, and a VS Code extension.
