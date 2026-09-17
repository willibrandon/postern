Postern for Helix is a `languages.toml` entry and a set of queries. The entry names the [Postern](https://github.com/willibrandon/postern) language server and the [tree-sitter grammar](https://github.com/willibrandon/tree-sitter-postgresql-conf) for `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` and `pg_ident.conf`; the queries give Helix highlighting and text objects for settings, rules, maps and options.

Append `languages.toml` to `~/.config/helix/languages.toml`, put the `queries/postgresql-conf` directory under `~/.config/helix/runtime/queries/`, then run `hx --grammar fetch` and `hx --grammar build`. From a checkout, `scripts/install-local.sh` does all of that. The server must be on your `PATH` as `postern`; download a binary from the [releases page](https://github.com/willibrandon/postern/releases).

The entry also claims `postgresql.base.conf`, which Patroni keeps the original file as, and a `.conf` file under a `conf.d` directory below a `postgresql` directory, which is how Debian lays out an `include_dir`. For another layout, add a `glob` to `file-types`.

`hx --health postgresql-conf` shows what Helix found.
