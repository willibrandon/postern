;;; postgresql-conf-ts-mode-test.el --- Tests for postgresql-conf-ts-mode  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:  emacs -Q --batch -L . -l tests/postgresql-conf-ts-mode-test.el \
;;                  -f ert-run-tests-batch-and-exit
;; POSTERN_PARSER_DIR names a directory holding the compiled grammar library;
;; the tests that need a parser are skipped without one.

;;; Code:

(require 'ert)
(require 'postgresql-conf-ts-mode)

(when-let* ((dir (getenv "POSTERN_PARSER_DIR")))
  (add-to-list 'treesit-extra-load-path dir))

(defun postgresql-conf-ts-mode-test--face-at (text)
  "The face at the start of TEXT in the current buffer."
  (goto-char (point-min))
  (search-forward text)
  (get-text-property (match-beginning 0) 'face))

(ert-deftest postgresql-conf-ts-mode-owns-the-four-file-names ()
  (dolist (name '("postgresql.conf" "postgresql.auto.conf" "postgresql.base.conf"
                  "pg_hba.conf" "pg_ident.conf"))
    (should (eq (assoc-default (concat "/etc/postgresql/" name) auto-mode-alist #'string-match-p)
                'postgresql-conf-ts-mode)))
  (should-not (eq (assoc-default "/etc/nginx/nginx.conf" auto-mode-alist #'string-match-p)
                  'postgresql-conf-ts-mode)))

(ert-deftest postgresql-conf-ts-mode-owns-an-include-dir-under-postgresql ()
  (should (eq (assoc-default "/etc/postgresql/16/main/conf.d/10-memory.conf"
                             auto-mode-alist #'string-match-p)
              'postgresql-conf-ts-mode))
  (should-not (eq (assoc-default "/etc/nginx/conf.d/default.conf" auto-mode-alist #'string-match-p)
                  'postgresql-conf-ts-mode))
  (should-not (eq (assoc-default "/etc/postgresql/16/main/conf.d/notes.txt"
                                 auto-mode-alist #'string-match-p)
                  'postgresql-conf-ts-mode)))

(ert-deftest postgresql-conf-ts-mode-owns-a-file-that-starts-with-a-postern-comment ()
  (should (eq (assoc-default "# postern: pg=16\nport = 5432\n" magic-mode-alist #'string-match-p)
              'postgresql-conf-ts-mode))
  (should-not (eq (assoc-default "port = 5432\n# postern: pg=16\n" magic-mode-alist #'string-match-p)
                  'postgresql-conf-ts-mode)))

(ert-deftest postgresql-conf-ts-mode-parses-and-highlights-a-rule ()
  (skip-unless (treesit-ready-p 'postgresql-conf t))
  (with-temp-buffer
    (insert "# rules\nhost all all 10.0.0.0/8 scram-sha-256\n")
    (postgresql-conf-ts-mode)
    (font-lock-ensure)
    (should (equal (treesit-node-type (treesit-node-child (treesit-buffer-root-node) 1))
                   "hba_rule"))
    (should (eq (postgresql-conf-ts-mode-test--face-at "# rules") 'font-lock-comment-face))
    (should (eq (postgresql-conf-ts-mode-test--face-at "host") 'font-lock-keyword-face))
    (should (eq (postgresql-conf-ts-mode-test--face-at "all") 'font-lock-builtin-face))
    (should (eq (postgresql-conf-ts-mode-test--face-at "10.0.0.0/8") 'font-lock-constant-face))
    (should (eq (postgresql-conf-ts-mode-test--face-at "scram-sha-256") 'font-lock-builtin-face))))

(ert-deftest postgresql-conf-ts-mode-highlights-a-setting ()
  (skip-unless (treesit-ready-p 'postgresql-conf t))
  (with-temp-buffer
    (insert "shared_buffers = 128MB\nlisten_addresses = '*'\n")
    (postgresql-conf-ts-mode)
    (font-lock-ensure)
    (should (eq (postgresql-conf-ts-mode-test--face-at "shared_buffers") 'font-lock-property-name-face))
    (should (eq (postgresql-conf-ts-mode-test--face-at "128") 'font-lock-number-face))
    (should (eq (postgresql-conf-ts-mode-test--face-at "MB") 'font-lock-type-face))
    (should (eq (postgresql-conf-ts-mode-test--face-at "'*'") 'font-lock-string-face))))

(ert-deftest postgresql-conf-ts-mode-lists-settings-rules-and-maps-in-imenu ()
  (skip-unless (treesit-ready-p 'postgresql-conf t))
  (with-temp-buffer
    (insert "port = 5432\nlocal all all peer\nmymap brandon postgres\n")
    (postgresql-conf-ts-mode)
    (let ((index (funcall imenu-create-index-function)))
      (should (assoc "port" (cdr (assoc "Setting" index))))
      (should (assoc "local all all" (cdr (assoc "Rule" index))))
      (should (assoc "mymap brandon" (cdr (assoc "Map" index)))))))

(ert-deftest postgresql-conf-ts-mode-registers-the-server-with-eglot ()
  (require 'eglot)
  (should (eq (alist-get 'postgresql-conf-ts-mode eglot-server-programs)
              'postgresql-conf-ts-mode-server-program)))

(ert-deftest postgresql-conf-ts-mode-names-the-server-on-the-path-or-the-fetched-one ()
  (let ((program (postgresql-conf-ts-mode-server-program)))
    (should (listp program))
    (should (stringp (car program)))
    (should (string-match-p "postern" (car program))))
  (let ((postgresql-conf-ts-mode-server-directory (make-temp-file "postern-test" t)))
    (let ((path (postgresql-conf-ts-mode--installed-server)))
      (with-temp-file path (insert "#!/bin/sh\n"))
      (set-file-modes path #o755)
      (if (executable-find "postern")
          (should (equal (postgresql-conf-ts-mode-server-program) '("postern")))
        (should (equal (postgresql-conf-ts-mode-server-program) (list path)))))))

(ert-deftest postgresql-conf-ts-mode-names-the-release-asset-for-this-platform ()
  (let ((asset (postgresql-conf-ts-mode--release-asset "0.2.1")))
    (should (string-prefix-p "postern-0.2.1-" asset))
    (should (string-match-p "-\\(linux\\|darwin\\|win32\\)-\\(x64\\|arm64\\)" asset))))

(provide 'postgresql-conf-ts-mode-test)
;;; postgresql-conf-ts-mode-test.el ends here
