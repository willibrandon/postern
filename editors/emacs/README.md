Postern for Emacs is `postgresql-conf-ts-mode`, a major mode for `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` and `pg_ident.conf` in Emacs 29.1 or newer. Highlighting, Imenu and defun navigation come from the [tree-sitter grammar](https://github.com/willibrandon/tree-sitter-postgresql-conf); Eglot runs the [Postern](https://github.com/willibrandon/postern) language server, `postern` on your `PATH` when it is there. Without one, `M-x postgresql-conf-ts-mode-install-server` fetches the binary for your platform from the latest release into `~/.emacs.d/postern/`, checks it against the checksums the release carries, and Eglot uses it from then on; with a prefix argument it asks for a version.

The mode also owns `postgresql.base.conf`, which Patroni keeps the original file as, a `.conf` file under a `conf.d` directory below a `postgresql` directory, which is how Debian lays out an `include_dir`, and any file whose first line is a `# postern:` comment.

Install from a checkout:

```elisp
(add-to-list 'load-path "~/src/postern/editors/emacs")
(require 'postgresql-conf-ts-mode)
```

or with `package-vc-install`:

```elisp
(package-vc-install '(postgresql-conf-ts-mode :url "https://github.com/willibrandon/postern" :lisp-dir "editors/emacs"))
```

The parser is a library Emacs compiles from the grammar. `M-x postgresql-conf-ts-mode-install-grammar` builds it into `~/.emacs.d/tree-sitter/`, which needs Git and a C compiler; Emacs 31 offers to do that the first time the mode opens a file. Until then the mode only knows the comment syntax.

Start the server with `M-x eglot`, or add `postgresql-conf-ts-mode-hook` to `eglot-ensure`. The quick fix on a trust hint is an ordinary code action, `M-x eglot-code-actions`. To turn those hints off for good:

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(postgresql-conf-ts-mode . ("postern" :initializationOptions (:reportTrust :json-false)))))
```

Tests run in batch and need `POSTERN_PARSER_DIR` pointing at a directory with the compiled grammar library:

    emacs -Q --batch -L . -l tests/postgresql-conf-ts-mode-test.el -f ert-run-tests-batch-and-exit
