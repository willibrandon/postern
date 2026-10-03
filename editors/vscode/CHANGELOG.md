# Changelog

## [0.3.2] - 2026-10-03

- Bundles server 0.3.2, whose dependencies carry the current security fixes. The language client
  moves to 10.1.2, which logs the connection's messages to the output channel rather than the
  console. Nothing else changes in the extension.

## [0.3.1] - 2026-09-18

- Bundles server 0.3.1, in which a `# postern: pg=16` comment at the top of a file overrides the
  `postern.pg` setting, as the setting's description always said. Nothing changes in the extension
  itself.

## [0.3.0] - 2026-09-18

- Bundles server 0.3.0. Values are read the way the server reads them, numbers with their units,
  booleans, enums with the entries the server keeps hidden, and the strings the server checks with a
  hook, so the editor shows what a reload would refuse; the settings of the contrib modules are in
  the catalogs, and the postmaster's start checks run on the file. In `pg_hba.conf` an `@file` list
  is followed, a regular expression is compiled the server's way, hover shows the manual's words for
  each field, and a map name goes to and renames with its `pg_ident.conf` lines. Quick fixes replace
  a misspelled name or unit, quote a value or drop a line an override makes useless, the outline
  lists settings, rules and maps, a change on disk to a file a check reads checks the open documents
  again, and a file the root includes reports its own problems while it is closed. With a
  connection, the live rows land on the document their lines match, and the action writes the
  setting under the cursor with `ALTER SYSTEM SET`. Nothing changes in the extension itself.

## [0.2.1] - 2026-09-17

- Bundles server 0.2.1, which resolves an include tree and the file next to a document on Windows
  too, answers at once while a configured server is away rather than waiting on it at every request,
  and no longer crashes on a live server's rows about an open file. Nothing changes in the extension
  itself.

## [0.2.0] - 2026-09-17

- Files under a `conf.d` directory below a `postgresql` directory, Debian's `include_dir`, and
  `postgresql.base.conf`, which Patroni keeps the original file as, open as PostgreSQL
  configuration. A file no language claims by name or extension is taken when its first line is a
  `# postern:` comment, and any file mapped to `postgresql-conf`, `pg-hba` or `pg-ident` in
  `files.associations` is checked as that.
- Bundles server 0.2.0, which follows `include`, `include_if_exists`, `include_dir` and
  `postgresql.auto.conf` the way the server does. A setting a later file overrides gets a hint
  naming the file and line that win, hover says where the value that counts is set, go to definition
  goes there, and an include line links to its file. A `pg_hba.conf` rule is read and checked the
  way hba.c does it, with the server's messages for the target version, and a line that ends with a
  backslash goes on with the next one. `pg_hba.conf` and `pg_ident.conf` see each other from the
  disk when only one is open.

## [0.1.7] - 2026-09-16

- The trust quick fix command is registered by the language client, since the server now advertises
  it, and handled through the client's middleware. It still saves the setting.

## [0.1.6] - 2026-09-16

- Bundles server 0.1.6, which applies edits sent as ranges and handles the trust quick fix command
  itself. Neither changes anything for VS Code, which sends full text and runs the quick fix on its
  own.

## [0.1.5] - 2026-09-16

- Lines the server writes to stderr are logged at their own level. The wrapper's "Uninstalled older
  version" notice after an update is information, not an error.

## [0.1.4] - 2026-09-16

- Published as platform packages only. The universal package could be installed in the minutes
  before the platform package for a new version finished validating, leaving no server binary.

## [0.1.3] - 2026-09-16

- Trust on a non-local `pg_hba.conf` rule is a hint instead of a warning, and a new
  `postern.hba.reportTrust` setting, also reachable as a quick fix on the hint, turns it off.
- `all` no longer counts as shadowing `replication` rules.

## [0.1.2] - 2026-09-16

- Settings that need a restart to change are no longer listed as problems; the hover says so
  instead.

## [0.1.1] - 2026-09-16

- Fixed the bundled server crashing on every request once it could reach a PostgreSQL server.

## [0.1.0] - 2026-09-16

- Language support for `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` and `pg_ident.conf`.
- Bundled Postern language server for Linux, macOS and Windows, with `postern.path` for another
  binary.
- Settings for the target PostgreSQL version and for a live connection string.
- Highlighting only in VS Code for the Web.
