# Postern

PostgreSQL configuration files in Visual Studio Code: `postgresql.conf`, `postgresql.auto.conf`,
`pg_hba.conf` and `pg_ident.conf`. The extension also takes `postgresql.base.conf`, which Patroni
keeps the original file as, and a `.conf` file under a `conf.d` directory below a `postgresql`
directory, which is how Debian lays out an `include_dir`. For another layout, map the files to
`postgresql-conf` in `files.associations` and the server follows. A file that no language claims by
name or extension is taken when its first line is a `# postern:` comment; `.conf` itself belongs to
Properties, so that does not reach a `.conf` file.

## Features

- Diagnostics for unknown or misspelled settings, values that do not fit a setting's type, unit or
  range, settings removed between versions, duplicate keys, and `pg_hba.conf` rules that an earlier
  rule shadows.
- Hover with a setting's description, default, range and context, including whether a change needs a
  restart.
- Completion of setting names, enum values, connection types, authentication methods and their
  options.
- Live checks against a running server. PostgreSQL exposes `pg_file_settings` and
  `pg_hba_file_rules`, views in which the server parses its own configuration files and reports the
  line and the error. With a connection string configured, those messages show up in the editor
  before you reload.
- Syntax highlighting and comment toggling, including in VS Code for the Web.

Checks work offline from catalogs of `pg_settings` for PostgreSQL 13 through 18.

## Requirements

The extension bundles the Postern language server and is published for Linux (x64, arm64, Alpine),
macOS (Intel, Apple silicon) and Windows (x64). On another platform, install a VSIX from the
[releases page](https://github.com/willibrandon/postern/releases) and set `postern.path` to a
`postern` binary you built, or put one on your `PATH`.

The language server does not run in the browser. On vscode.dev and github.dev the extension provides
highlighting only.

## Settings

| Setting                    | Default | Description                                                                                                                    |
| -------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `postern.path`             | `""`    | Path to the `postern` executable. Empty uses the bundled binary, then `postern` on the `PATH`.                                 |
| `postern.pg`               | newest  | PostgreSQL major version, 13 to 18, for offline checks. A `# postern: pg=16` comment at the top of a file overrides it.        |
| `postern.connectionString` | `""`    | `postgres://` URL of a server to check the open files against.                                                                 |
| `postern.hba.reportTrust`  | `true`  | Hint on `pg_hba.conf` rules that use `trust` or `password` on a non-local address. Loopback and `samehost` are never reported. |
| `postern.trace.server`     | `off`   | Log the traffic between VS Code and the language server.                                                                       |

In untrusted workspaces the executable path and connection string are read from user settings only.

## Live checks

Set `postern.connectionString` to a server that loads the files you are editing. Postern matches the
server's `pg_file_settings` and `pg_hba_file_rules` rows to the open file by path, so the file in
the editor has to be the one the server reads, which usually means editing on the database host or
through Remote SSH. When the server cannot be reached, the offline checks apply and one
informational diagnostic says so.

## Commands

- Postern: Restart Language Server
- Postern: Show Language Server Output
- Postern: Stop Reporting Trust on Non-local Rules, also offered as a quick fix on the hint

## Install

Search for **Postern** in the Extensions view or run:

```sh
code --install-extension willibrandon.postern
```

[Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=willibrandon.postern)
and [Open VSX](https://open-vsx.org/extension/willibrandon/postern) publish the same extension.

[Changelog](https://github.com/willibrandon/postern/blob/main/editors/vscode/CHANGELOG.md) ·
[Issues](https://github.com/willibrandon/postern/issues)

## Development

Requires Node.js 24. The integration tests need a `postern` binary in `server/`, which the
repository's release workflow places there for each platform.

```sh
npm ci
npm run verify
npm test
npm run package
```

## License

[MIT](https://github.com/willibrandon/postern/blob/main/editors/vscode/LICENSE)
