# Postern

A language server for PostgreSQL configuration files: `postgresql.conf`, `postgresql.auto.conf`,
`pg_hba.conf` and `pg_ident.conf`.

Postern parses the three formats itself and checks them against catalogs of `pg_settings` for
PostgreSQL 13 through 18, so it works with no server running. When it can reach a server, it reads
`pg_file_settings`, `pg_hba_file_rules` and `pg_ident_file_mappings`. Those views are PostgreSQL
parsing its own configuration files and reporting the line and the error, which means the editor
shows the exact message a reload would produce, before the reload, on the file the server
reads, recognised by its lines rather than its name and only while the buffer still matches
it. With a connection, a code
action writes the setting under the cursor with `ALTER SYSTEM SET`, or reloads, and shows what
the server answered.

These pages and the module documentation are also at
[willibrandon.github.io/postern](https://willibrandon.github.io/postern).

## What it reports

The offline checks use the words the server logs, so a message in the editor is the one the
log would show after a reload, hint included.

- Unknown or misspelled settings, with the closest catalog name. A setting of a contrib module
  or plpgsql, `pg_stat_statements.max` say, is checked like any other, and one of a module the
  catalog does not know is taken as the server takes it until that module checks it.
- Values that do not fit the setting's type, unit, range, enum or vocabulary, such as a time
  zone the server does not know or a log destination the version does not have.
- Settings removed or renamed between versions, with the version that did it and the name
  that took their place, and settings that need a restart.
- What the postmaster refuses at start although a reload passes it: `wal_level = minimal`
  with archiving or streaming on, more than one recovery target, and autovacuum without the
  statistics it needs.
- A setting a later line overrides, in the same file or in one PostgreSQL reads after it, since
  it keeps the last one. Postern follows `include`, `include_if_exists` and `include_dir` the way
  the server does and reads `postgresql.auto.conf` last, so a value `ALTER SYSTEM` or a
  `conf.d` file overrides is marked where it stands, and an include the server could not open
  is an error. Hover says where the value that counts is set, go to definition goes there, and
  an include line links to its file. A `map=`
  option and the map in `pg_ident.conf` are one name: definition, references and rename cross
  the two files.
- `pg_hba.conf` rules that an earlier rule shadows, options that do not apply to the method, a
  file of names given with `@` that the server could not open, a regular expression its engine
  refuses, and ident maps that are missing or unused.
- Quick fixes: the name the server would know, a unit spelled its way, a value quoted, and
  the line an override or an internal setting makes useless removed or commented out.
- An outline of the file for the editor's symbol views: sections and their settings, rules,
  and maps with their mappings.
- Hover with the setting's description, default and range, and on `pg_hba.conf` and
  `pg_ident.conf` with the manual's words for the connection type, the field, the method or
  the option under the cursor; completion of names, enum values, authentication methods and,
  with a live connection, database and role names.

## Install

With Homebrew on macOS or Linux:

```sh
brew install willibrandon/tap/postern
```

With Scoop on Windows:

```powershell
scoop bucket add willibrandon https://github.com/willibrandon/scoop-bucket
scoop install postern
```

Or with winget, which installs the MSI from the releases page into Program Files, once the
manifest each release submits to microsoft/winget-pkgs is in:

```powershell
winget install willibrandon.postern
```

The install script fetches the binary for your platform from the latest release, checks it
against the checksums the release carries, and puts it in `~/.local/bin`, or where `--dir` says:

```sh
curl -fsSL https://raw.githubusercontent.com/willibrandon/postern/main/scripts/install.sh | sh
```

On Windows, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/willibrandon/postern/main/scripts/install.ps1 | iex
```

Or download a binary for your platform from the
[releases page](https://github.com/willibrandon/postern/releases) and put it on your `PATH` as
`postern`. The binary is self-contained; it unpacks the Erlang runtime into your user data
directory on first run.

Visual Studio Code users can install the Postern extension from the
[Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=willibrandon.postern)
or [Open VSX](https://open-vsx.org/extension/willibrandon/postern). It bundles the binary; see the
[extension page](https://willibrandon.github.io/postern/vscode.html) for its settings.

### Neovim

Neovim 0.11 or newer. The plugin is
[willibrandon/postern.nvim](https://github.com/willibrandon/postern.nvim); with lazy.nvim:

```lua
{ "willibrandon/postern.nvim" }
```

It gives the four files their filetypes, enables the server, `postern` on your `PATH` or the
binary `:PosternInstall` fetches from the latest release, and registers the
[tree-sitter grammar](https://github.com/willibrandon/tree-sitter-postgresql-conf) so
`:TSInstall postgresql_conf` gives them highlighting and text objects. See the
[Neovim page](https://willibrandon.github.io/postern/neovim.html).

### Fresh

Fresh 0.4.10 or newer. Run `Package: Install from URL` with
`https://github.com/willibrandon/postern#editors/fresh`. It highlights the four files and starts
the server, which must be on your `PATH`. See the
[Fresh page](https://willibrandon.github.io/postern/fresh.html).

### Helix

Append [editors/helix/languages.toml](editors/helix/languages.toml) to your `languages.toml`, put
its queries under `runtime/queries/postgresql-conf`, then `hx --grammar fetch` and
`hx --grammar build`. See the
[Helix page](https://willibrandon.github.io/postern/helix.html).

### Emacs

Emacs 29.1 or newer. Load `editors/emacs` and require `postgresql-conf-ts-mode`; it owns the four
files, highlights them through the tree-sitter grammar, and registers the server with Eglot,
`postern` on your `PATH` or the binary `M-x postgresql-conf-ts-mode-install-server` fetches. See the
[Emacs page](https://willibrandon.github.io/postern/emacs.html).

### Zed

Install `editors/zed` as a dev extension. It highlights the four files and downloads
the server for your platform when `postern` is not on your `PATH`. See the
[Zed page](https://willibrandon.github.io/postern/zed.html).

### Other file names

Every package claims the four files by name, `postgresql.base.conf`, which Patroni keeps the
original file as, and a `.conf` file under a `conf.d` directory below a `postgresql` directory,
which is how Debian lays out an `include_dir`. Zed matches names rather than patterns, so there
the `conf.d` glob is a `file_types` setting. Neovim, Emacs and Zed also take a file whose first
line is a `# postern:` comment. For another layout, tell the editor the file is `postgresql-conf`,
`pg-hba` or `pg-ident`. The server itself knows a file by the root that includes it, looking for
`postgresql.conf`, `pg_hba.conf` or `pg_ident.conf` in the directories above it and up to three
directories down the workspace, and takes the editor's word only for a file no root reaches.

## Command line

```sh
postern check postgresql.conf pg_hba.conf
postern check --pg 16 --strict postgresql.conf
postern check --connection-string postgres://postgres@localhost/postgres postgresql.conf
postern check --format github conf.d/*.conf
postern check --stdin-filename pg_hba.conf < pg_hba.conf
postern --help
```

`check` exits 1 when any file has an error, or with `--strict` a warning. `--pg` picks the
version to check against, `--connection-string` or `--live`, which takes the `PG` environment
variables, compares the files with a running server the way the editor does, and
`--stdin-filename` reads a file from stdin as if it stood at that path, which is how an editor's
linter framework hands over an unsaved buffer. The output is for people, or with `--format` json,
github, which GitHub Actions turns into annotations on the lines, or sarif, which code scanning
shows on the pull request. Files are recognised by name, or by the `postgresql.conf`,
`pg_hba.conf` or `pg_ident.conf` above them that includes them, and checking a root checks every
file it reads.

### GitHub Actions

The action in this repository fetches the release for the runner and runs `check` with an
annotation on every line the server would refuse:

```yaml
- uses: willibrandon/postern@v0
  with:
    files: postgresql.conf pg_hba.conf
    pg: "17"
```

Without `files` it checks every `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` and
`pg_ident.conf` in the checkout. `strict` fails on a warning as well, `connection-string`
compares the files with a running server, `version` picks a release other than the latest, and
`path` runs a binary of your own.

### pre-commit

```yaml
- repo: https://github.com/willibrandon/postern
  rev: v0.3.0
  hooks:
    - id: postern
```

The hook runs `postern` from your `PATH` when it is there, and otherwise fetches the release
that matches `rev` once into pre-commit's cache.

## Configuration

The target PostgreSQL version comes from, in order, the `pg` initialization option, a
`# postern: pg=16` comment at the top of the file, or the newest catalog.

A live connection is configured with the `connectionString` initialization option
(`postgres://user:pass@host:5432/db`) or the usual `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` and
`PGPASSWORD` variables. When the server is unreachable, Postern falls back to the catalogs and says
so in one informational diagnostic.

## Development

Requires Elixir 1.18 or newer on Erlang/OTP 27 or newer.

```sh
mix deps.get
mix test
mix credo --strict
mix format --check-formatted
mix postern.catalog --source ~/src/postgres   # regenerate priv/catalog from the containers on ports 5413 to 5418
mix postern.docs --source ~/src/postgres      # regenerate priv/docs from the manual's client-auth.sgml
PGHOST=127.0.0.1 PGPORT=5418 PGUSER=postgres mix test --only live   # compare the checks with that server
```

Release binaries are built with [Burrito](https://github.com/burrito-elixir/burrito), which needs
Zig 0.16.0, `xz`, and `7z` for the Windows target:

```sh
MIX_ENV=prod mix release
```

The catalog task queries `pg_settings` on each server, with the contrib modules and plpgsql
loaded so that their settings are in it, and reads the enum tables of the same version from
the checkout, since the view leaves out the spellings the server takes without listing them,
`wal_level = archive` say. The servers need pg_stat_statements and pg_prewarm in
`shared_preload_libraries`, since those two define their settings only when preloaded.

Burrito caches the unpacked runtime by application version, so bump the version in `mix.exs` or
delete the `.burrito/postern_erts-*` directory when testing a rebuilt binary.

## License

MIT. The hover text for `pg_hba.conf` and `pg_ident.conf` under `priv/docs` is the PostgreSQL
manual's, under the PostgreSQL License, as `priv/docs/LICENSE` says.
