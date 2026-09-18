# Postern

A language server for PostgreSQL configuration files: `postgresql.conf`, `postgresql.auto.conf`,
`pg_hba.conf` and `pg_ident.conf`.

Postern parses the three formats itself and checks them against catalogs of `pg_settings` for
PostgreSQL 13 through 18, so it works with no server running. When it can reach a server, it reads
`pg_file_settings`, `pg_hba_file_rules` and `pg_ident_file_mappings`. Those views are PostgreSQL
parsing its own configuration files and reporting the line and the error, which means the editor
shows the exact message a reload would produce, before the reload.

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
- A setting a later line overrides, in the same file or in one PostgreSQL reads after it, since
  it keeps the last one. Postern follows `include`, `include_if_exists` and `include_dir` the way
  the server does and reads `postgresql.auto.conf` last, so a value `ALTER SYSTEM` or a
  `conf.d` file overrides is marked where it stands, and an include the server could not open
  is an error. Hover says where the value that counts is set, go to definition goes there, and
  an include line links to its file.
- `pg_hba.conf` rules that an earlier rule shadows, options that do not apply to the method, and
  ident maps that are missing or unused.
- Hover with the setting's description, default and range; completion of names, enum values,
  authentication methods and, with a live connection, database and role names.

## Install

Download a binary for your platform from the
[releases page](https://github.com/willibrandon/postern/releases) and put it on your `PATH` as
`postern`. The binary is self-contained; it unpacks the Erlang runtime into your user data
directory on first run.

Visual Studio Code users can install the Postern extension from the
[Visual Studio Marketplace](https://marketplace.visualstudio.com/items?itemName=willibrandon.postern)
or [Open VSX](https://open-vsx.org/extension/willibrandon/postern). It bundles the binary; see the
[extension README](editors/vscode/README.md) for its settings.

### Neovim

Neovim 0.11 or newer. Put `editors/nvim` from a checkout on the runtime path, for example with
lazy.nvim:

```lua
{ dir = "~/src/postern/editors/nvim" }
```

It gives the four files their filetypes, enables the server, which must be on your `PATH`, and
registers the [tree-sitter grammar](https://github.com/willibrandon/tree-sitter-postgresql-conf)
so `:TSInstall postgresql_conf` gives them highlighting and text objects. See
[editors/nvim/README.md](editors/nvim/README.md).

### Fresh

Fresh 0.4.10 or newer. Run `Package: Install from URL` with
`https://github.com/willibrandon/postern#editors/fresh`. It highlights the four files and starts
the server, which must be on your `PATH`. See [editors/fresh/README.md](editors/fresh/README.md).

### Helix

Append [editors/helix/languages.toml](editors/helix/languages.toml) to your `languages.toml`, put
its queries under `runtime/queries/postgresql-conf`, then `hx --grammar fetch` and
`hx --grammar build`. See [editors/helix/README.md](editors/helix/README.md).

### Emacs

Emacs 29.1 or newer. Load `editors/emacs` and require `postgresql-conf-ts-mode`; it owns the four
files, highlights them through the tree-sitter grammar, and registers the server with Eglot. See
[editors/emacs/README.md](editors/emacs/README.md).

### Zed

Install [editors/zed](editors/zed) as a dev extension. It highlights the four files and downloads
the server for your platform when `postern` is not on your `PATH`. See
[editors/zed/README.md](editors/zed/README.md).

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
postern check --json pg_hba.conf
postern --help
```

`check` exits 1 when any file has an error. Files are recognised by name, or by the
`postgresql.conf`, `pg_hba.conf` or `pg_ident.conf` above them that includes them, and checking a
root checks every file it reads.

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

MIT
