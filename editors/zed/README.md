Postern for Zed is the `postgresql-conf` language extension. It gives `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` and `pg_ident.conf` highlighting, an outline and text objects from the [tree-sitter grammar](https://github.com/willibrandon/tree-sitter-postgresql-conf), and runs the [Postern](https://github.com/willibrandon/postern) language server for them. The server is `postern` on your `PATH` when there is one; otherwise the extension downloads the binary for your platform from the latest release.

It also takes `postgresql.base.conf`, which Patroni keeps the original file as, and a file whose first line is a `# postern:` comment. Zed matches names rather than patterns, so a `.conf` file under a `conf.d` directory, Debian's `include_dir`, is a setting:

```json
{ "file_types": { "PostgreSQL Config": ["**/postgresql/**/conf.d/*.conf"] } }
```

Install it from a checkout with `zed: install dev extension` in the command palette, choosing this directory. Zed compiles the extension, which needs a Rust toolchain.

Initialization options go in Zed's settings. This one stops the hint about trust on non-local `pg_hba.conf` rules:

```json
{ "lsp": { "postern": { "initialization_options": { "reportTrust": false } } } }
```
