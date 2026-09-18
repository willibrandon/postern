# Changelog

## [Unreleased]

- The postgresql.conf checks say what the server logs, as the pg_hba.conf checks already
  did: `unrecognized configuration parameter "shared_buffrs"`, with the closest catalog name
  on a second line the way the server phrases a hint, and `invalid value for parameter
  "wal_level": "nope"` with `Available values: minimal, replica, logical.` below it. A line
  the server cannot read is now scanned the way guc-file.l scans it, so it is refused on the
  token the scanner stops at, `syntax error near token "GB"` for `work_mem = 1.5GB`, since a
  real takes no unit letters and the quotes are what make `'1.5GB'` a value, and a path, a
  `*` or an unquoted `"` is refused where it stands. A quoted value takes the escapes the
  server takes, and `include` is recognised in any case. `postern check` prints a hint
  indented under its message.
- A setting with a dot in its name, `pg_stat_statements.max` say, is no longer an unknown
  setting. The server keeps such a value as a placeholder until the module that owns it loads
  and checks it, and says nothing before then, so neither does Postern.
- A setting with the internal context, `block_size` or `data_checksums` say, is an error on its
  name in the server's words, `parameter "block_size" cannot be changed`, whatever its value.
  The build, initdb or the server itself fixed it, which the hover now says, and completion no
  longer offers it.
- A number, its unit and a boolean are read the way guc.c reads them. A leading `0` is octal
  and `0x` is hex, so `log_file_mode = 0600` and `unix_socket_permissions = 0777` are the
  values the manual gives rather than errors; a fraction rounds to the nearest integer; white
  space may stand between the number and its unit; the unit is matched as written, so `128mb`
  is refused with the server's hint naming the units the parameter takes; a fraction of a unit
  rounds to a multiple of the next smaller one; and a boolean needs two letters of `on` or
  `off`, so `o` is refused. A value out of range is reported in the server's words, in the
  base unit and, from 17, with the unit on the bounds too.
- An enum value with a space in it, `default_transaction_isolation = 'read committed'` say, is
  one of the values again. The catalog holds the array literal `pg_settings` prints, in which
  such a value is double-quoted, and the quotes were being compared as part of the value. The
  literal is decoded when the catalog loads, so the check, the hover and completion all see the
  bare value, and completion inserts a value that needs quoting in the file with its quotes.

## [0.2.1] - 2026-09-17

- Paths are compared in one canonical form and a file URI carries a Windows drive the way
  editors write it, so include trees and the file next to a document resolve on Windows too.
- A configured server that is not there no longer holds up every request for the seconds
  Postgrex waits before it drops a query from its queue. The live oracle takes the connection's
  own notifications instead, so a check answers at once while the server is away, apart from
  the first one after the language server starts, which waits up to two seconds for the
  connection to come up.
- CI and releases build on Elixir 1.20.4 and Erlang/OTP 28.5.0.6, and the suite runs on macOS
  and Windows as well as Linux. `mix test` alone runs all of it on a fresh clone: the stdio
  tests start their server from the test build, and the transport they need is a setting,
  `config :postern, stdio: false`, that the test environment turns off.
- A live server's rows about a file no longer crash its check. The oracle's text protocol sends
  a line number as text, and the live diagnostics read it as a number.

## [0.2.0] - 2026-09-17

- The Zed extension takes the grammar's 0.1.1 release, in which a single quote is an ordinary
  character in `pg_hba.conf` and `pg_ident.conf`, as it is to the server. The other packages
  follow the grammar's main branch and have it already.
- A line of `pg_hba.conf` or `pg_ident.conf` that ends with a backslash goes on with the next
  one, the way the server has read it since 14, joined as it is, so the continuation works inside
  a quoted token or a comment and an empty line ends the record. The record carries the number
  of the line it starts on, as `pg_hba_file_rules` reports it, and a problem on a later line is
  marked there. A target older than 14 reads every line on its own.
- A `pg_hba.conf` rule is checked as a whole the way hba.c checks it once its options are read:
  gssapi on a local socket, peer anywhere else and cert without hostssl are errors, ldap must
  choose between a simple bind and search+bind and take one of ldapsearchattribute and
  ldapsearchfilter, radius needs its servers and secrets with lists that fit, and oauth needs an
  issuer and a scope and no map next to delegate_ident_mapping, each in the server's words for
  the target version. A comma in an option field starts another option, as it does for the
  server, so a list meant as one value is quoted. ident on a local socket gets a hint that the
  server reads it as peer.
- A `pg_hba.conf` rule is read field by field the way hba.c reads it, so a line that ends too
  soon, a list where one value belongs, a host name with a CIDR mask, a mask that does not fit
  its address and a method the target version does not know are the server's errors in its
  words, and a token meant as an address that the server would look up as a host name gets a
  warning. `scram-sha-256-plus`, a SASL mechanism rather than a method, is no longer taken for
  one. The include directives and regular expressions in `pg_hba.conf` and `pg_ident.conf` are
  checked against the version, which took them in 16, oauth against 18, and includes are not
  followed for an older target. Completion offers the methods the version has.
- Postern follows `include`, `include_if_exists` and `include_dir` the way the server does,
  relative to the file that names them, in C locale order for a directory, and reads
  `postgresql.auto.conf` from the data directory last, so a setting a later file overrides gets
  a hint on the line that loses naming the file and line that win, and an include the server
  could not open gets the error `pg_file_settings` would show. The hint for a setting repeated in
  one file moved to the line that loses too. Hover says where the value that counts is set, go to
  definition goes there, and an include line links to its file. `pg_hba.conf` and `pg_ident.conf`
  trees work the same way, so a rule an included file shadows and a map an included file defines
  are seen. A file with another name is known by the root that includes it, `postern check`
  walks the tree of a root it is given, and a live check reports a line `pg_file_settings` left
  unapplied for a later entry. The resolver is compared with `pg_file_settings` on every
  supported version in CI.
- A file with another name is checked as what the editor calls it: `postgresql-conf`, `pg-hba` or
  `pg-ident`. The editor packages claim `postgresql.base.conf`, which Patroni keeps the original
  file as, and a `.conf` file under a `conf.d` directory below a `postgresql` directory, which is
  how Debian lays out an `include_dir`; Neovim, Emacs and Zed also take a file whose first line is
  a `# postern:` comment. The Zed extension sends `postgresql-conf` as the language id.
- A check on `pg_hba.conf` reads the `pg_ident.conf` next to it, and the other way round: from
  the editor while the file is open, from the disk otherwise. A map no longer shows as missing
  or unused because of which files happen to be open, and when one of the two changes the other
  is checked again. Without the other file there to look at, map names are not checked at all.
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
