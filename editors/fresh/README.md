Postern for Fresh is a bundle for [Fresh](https://github.com/sinelaw/fresh) 0.4.10 or newer. It highlights `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` and `pg_ident.conf` and starts the [Postern](https://github.com/willibrandon/postern) language server for them, which adds diagnostics, hover, completion, inlay hints and code actions.

Install it with `Package: Install from URL` using https://github.com/willibrandon/postern#editors/fresh. The server is not bundled. Download a binary from the [releases page](https://github.com/willibrandon/postern/releases) and put it on your `PATH` as `postern`, or name its location in `config.json`:

```json
{ "lsp": { "postgresql-conf": { "command": "/path/to/postern" } } }
```

The hint about trust on non-local `pg_hba.conf` rules has a toggle in Fresh Settings under Plugin Settings, postern. The quick fix on such a rule turns it off until the server restarts.

The server inherits Fresh's environment, so `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` and `PGPASSWORD` decide whether it also checks settings against a running server.

A package manifest can only claim files by extension, and `.conf` is not ours, so the bundle's plugin claims the file names when it loads, with `postgresql.base.conf`, which Patroni keeps the original file as, and `**/postgresql/**/conf.d/*.conf`, which is how Debian lays out an `include_dir`, then reloads the grammar registry so files that were already open, including one named on the command line, are picked up too. That is a per-session setting; `config.json` is never modified, and names or globs you list under `languages.postgresql-conf.filenames` are kept.

Development requires Node 24 or newer and Fresh on the `PATH`.

    npm ci
    npm run validate
    scripts/install-local.sh

The last command copies the package into `~/.config/fresh/bundles/packages/postern`, where Fresh picks it up on the next start.
