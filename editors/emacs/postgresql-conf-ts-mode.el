;;; postgresql-conf-ts-mode.el --- Major mode for PostgreSQL configuration files  -*- lexical-binding: t; -*-

;; Author: Brandon Williams
;; Version: 0.2.1
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/willibrandon/postern
;; Keywords: languages
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; A major mode for postgresql.conf, postgresql.auto.conf, pg_hba.conf and
;; pg_ident.conf, powered by tree-sitter and paired with the Postern language
;; server through Eglot.  One grammar covers the three files, so one mode
;; does too.  It also takes postgresql.base.conf, a .conf file under a
;; conf.d directory below a postgresql directory, and any file whose first
;; line is a `# postern:' comment.
;;
;; The parser is a compiled library built from the grammar.  Emacs builds it
;; with `treesit-install-language-grammar', which this file gives the
;; repository for; `postgresql-conf-ts-mode-install-grammar' runs it.  Until
;; the parser exists the mode still knows the comment syntax.

;;; Code:

(require 'treesit)

(declare-function treesit-parser-create "treesit.c")
(declare-function treesit-node-type "treesit.c")
(declare-function treesit-node-child-by-field-name "treesit.c")
;; Emacs 31 additions, used only when present.
(declare-function treesit-ensure-installed "treesit" (lang))
(defvar treesit-primary-parser)

(defgroup postgresql-conf nil
  "PostgreSQL configuration files."
  :group 'languages)

(add-to-list 'treesit-language-source-alist
             '(postgresql-conf "https://github.com/willibrandon/tree-sitter-postgresql-conf")
             t)

(defvar postgresql-conf-ts-mode--syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?= "." table)
    (modify-syntax-entry ?\' "\"" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    table)
  "Syntax table for `postgresql-conf-ts-mode'.")

(defvar postgresql-conf-ts-mode--font-lock-settings
  (treesit-font-lock-rules
   :language 'postgresql-conf
   :feature 'comment
   '((comment) @font-lock-comment-face)

   :language 'postgresql-conf
   :feature 'keyword
   '((connection_type) @font-lock-keyword-face
     (include ["include" "include_if_exists" "include_dir"] @font-lock-keyword-face))

   :language 'postgresql-conf
   :feature 'string
   '([(string) (quoted_name) (system_user) (option_value)] @font-lock-string-face
     (include path: (path) @font-lock-string-face)
     (file_reference (path) @font-lock-string-face)
     (regex) @font-lock-regexp-face)

   :language 'postgresql-conf
   :feature 'number
   '((number) @font-lock-number-face)

   ;; The unit is inside the number, so it has to override the number's face.
   :language 'postgresql-conf
   :feature 'number
   :override t
   '((unit) @font-lock-type-face)

   :language 'postgresql-conf
   :feature 'constant
   '([(boolean) (bare_value) (backreference)] @font-lock-constant-face
     (address [(hostname) (ip_address)] @font-lock-constant-face)
     (netmask) @font-lock-constant-face
     (auth_method) @font-lock-builtin-face)

   :language 'postgresql-conf
   :feature 'property
   '((setting name: (setting_name) @font-lock-property-name-face)
     (auth_option name: (option_name) @font-lock-property-name-face)
     (user_mapping map: (map_name) @font-lock-type-face))

   :language 'postgresql-conf
   :feature 'variable
   '([(name) (database_user)] @font-lock-variable-name-face)

   ;; The words all, sameuser, samerole, samegroup, replication, samehost and
   ;; samenet are keywords in the positions where a name or host may appear.
   :language 'postgresql-conf
   :feature 'builtin
   :override t
   '(((name) @font-lock-builtin-face
      (:match "\\`\\(?:all\\|sameuser\\|samerole\\|samegroup\\|replication\\)\\'"
              @font-lock-builtin-face))
     ((hostname) @font-lock-builtin-face
      (:match "\\`\\(?:all\\|samehost\\|samenet\\)\\'" @font-lock-builtin-face)))

   :language 'postgresql-conf
   :feature 'delimiter
   '(["="] @font-lock-operator-face
     [","] @font-lock-delimiter-face
     ["+" "@"] @font-lock-punctuation-face)

   :language 'postgresql-conf
   :feature 'error
   :override t
   '((ERROR) @font-lock-warning-face))
  "Font-lock settings for `postgresql-conf-ts-mode'.")

(defvar postgresql-conf-ts-mode--font-lock-feature-list
  '((comment)
    (keyword string)
    (constant number property variable builtin)
    (delimiter error))
  "Font-lock feature list for `postgresql-conf-ts-mode'.")

(defun postgresql-conf-ts-mode--field (node field)
  "The text of NODE's FIELD, or nil."
  (when-let* ((child (treesit-node-child-by-field-name node field)))
    (treesit-node-text child t)))

(defun postgresql-conf-ts-mode--defun-name (node)
  "The name of a setting, rule or map NODE for Imenu and navigation."
  (pcase (treesit-node-type node)
    ("setting" (postgresql-conf-ts-mode--field node "name"))
    ("hba_rule"
     (mapconcat (lambda (field) (postgresql-conf-ts-mode--field node field))
                '("type" "database" "user") " "))
    ("user_mapping"
     (concat (postgresql-conf-ts-mode--field node "map") " "
             (postgresql-conf-ts-mode--field node "system_user")))))

;;;###autoload
(define-derived-mode postgresql-conf-ts-mode prog-mode "PostgreSQL Config"
  "Major mode for postgresql.conf, pg_hba.conf and pg_ident.conf.
Highlighting, Imenu and navigation come from the tree-sitter grammar;
Eglot runs the Postern language server."
  :group 'postgresql-conf
  :syntax-table postgresql-conf-ts-mode--syntax-table
  (setq-local comment-start "# ")
  (setq-local comment-start-skip "#+\\s-*")
  (setq-local comment-end "")
  (when (and (or (not (fboundp 'treesit-ensure-installed))
                 (treesit-ensure-installed 'postgresql-conf))
             (treesit-ready-p 'postgresql-conf))
    (let ((parser (treesit-parser-create 'postgresql-conf)))
      (when (boundp 'treesit-primary-parser)
        (setq treesit-primary-parser parser)))
    (setq-local treesit-font-lock-settings postgresql-conf-ts-mode--font-lock-settings)
    (setq-local treesit-font-lock-feature-list postgresql-conf-ts-mode--font-lock-feature-list)
    (setq-local treesit-defun-type-regexp (rx bos (or "setting" "hba_rule" "user_mapping") eos))
    (setq-local treesit-defun-name-function #'postgresql-conf-ts-mode--defun-name)
    (setq-local treesit-thing-settings
                `((postgresql-conf
                   (sentence ,(rx bos (or "setting" "hba_rule" "user_mapping") eos))
                   (text ,(rx bos "comment" eos)))))
    (setq-local treesit-simple-imenu-settings
                '(("Setting" "\\`setting\\'" nil nil)
                  ("Rule" "\\`hba_rule\\'" nil nil)
                  ("Map" "\\`user_mapping\\'" nil nil)))
    (treesit-major-mode-setup)))

(defun postgresql-conf-ts-mode-install-grammar ()
  "Build and install the tree-sitter grammar for PostgreSQL configuration files."
  (interactive)
  (treesit-install-language-grammar 'postgresql-conf))

;;;###autoload
(add-to-list 'auto-mode-alist
             (cons (rx (or (seq "/" (or "postgresql.conf" "postgresql.auto.conf" "postgresql.base.conf"
                                        "pg_hba.conf" "pg_ident.conf"))
                           ;; An include_dir under a postgresql directory, as Debian
                           ;; lays it out: /etc/postgresql/16/main/conf.d/*.conf
                           (seq "/postgresql/" (* nonl) "/conf.d/" (+ (not (any "/"))) ".conf"))
                       eos)
                   #'postgresql-conf-ts-mode))

;; A file with another name that starts with the comment Postern reads for
;; the target version.
;;;###autoload
(add-to-list 'magic-mode-alist
             (cons (rx bos "#" (* blank) "postern:") #'postgresql-conf-ts-mode))

(require 'subr-x)

(defcustom postgresql-conf-ts-mode-server-directory
  (expand-file-name "postern" user-emacs-directory)
  "Where `postgresql-conf-ts-mode-install-server' puts the server binary."
  :type 'directory
  :group 'postgresql-conf-ts-mode)

(defun postgresql-conf-ts-mode--installed-server ()
  "The path of the server `postgresql-conf-ts-mode-install-server' fetches."
  (expand-file-name (if (eq system-type 'windows-nt) "postern.exe" "postern")
                    postgresql-conf-ts-mode-server-directory))

(defun postgresql-conf-ts-mode-server-program (&optional _interactive)
  "The command Eglot starts the server with.
`postern' on the PATH when it is there, otherwise the binary
`postgresql-conf-ts-mode-install-server' fetched, otherwise `postern'
for Eglot to report as missing."
  (cond ((executable-find "postern") '("postern"))
        ((file-executable-p (postgresql-conf-ts-mode--installed-server))
         (list (postgresql-conf-ts-mode--installed-server)))
        (t '("postern"))))

(defun postgresql-conf-ts-mode--release-asset (version)
  "The release asset name for this platform at VERSION."
  (let ((system (pcase system-type
                  ('gnu/linux "linux")
                  ('darwin "darwin")
                  ('windows-nt "win32")
                  (_ (user-error "Postern has no release for %s" system-type))))
        (arch (pcase (car (split-string system-configuration "-"))
                ((or "x86_64" "amd64") "x64")
                ((or "aarch64" "arm64") "arm64")
                (other (user-error "Postern has no release for %s" other)))))
    (format "postern-%s-%s-%s%s" version system arch
            (if (eq system-type 'windows-nt) ".exe" ""))))

(defun postgresql-conf-ts-mode--fetch (url file)
  "Download URL to FILE, signalling an error when it cannot be."
  (unless (url-copy-file url file t)
    (user-error "Could not fetch %s" url)))

(defun postgresql-conf-ts-mode--latest-version ()
  "The version of the latest release on GitHub."
  (with-temp-buffer
    (url-insert-file-contents "https://api.github.com/repos/willibrandon/postern/releases/latest")
    (string-remove-prefix "v" (gethash "tag_name" (json-parse-buffer)))))

;;;###autoload
(defun postgresql-conf-ts-mode-install-server (&optional version)
  "Fetch the server binary for this platform from a GitHub release.
The latest release, or VERSION such as \"0.2.1\" with a prefix argument.
The checksum the release carries is verified, and the binary goes into
`postgresql-conf-ts-mode-server-directory', which Eglot uses when
`postern' is not on the PATH."
  (interactive (list (and current-prefix-arg (read-string "Version: "))))
  (let* ((version (or version (postgresql-conf-ts-mode--latest-version)))
         (asset (postgresql-conf-ts-mode--release-asset version))
         (base (format "https://github.com/willibrandon/postern/releases/download/v%s" version))
         (dir postgresql-conf-ts-mode-server-directory)
         (part (expand-file-name (concat asset ".part") dir))
         (sums (expand-file-name "SHA256SUMS" dir))
         (path (postgresql-conf-ts-mode--installed-server)))
    (make-directory dir t)
    (postgresql-conf-ts-mode--fetch (concat base "/" asset) part)
    (postgresql-conf-ts-mode--fetch (concat base "/SHA256SUMS") sums)
    (let ((expected (with-temp-buffer
                      (insert-file-contents sums)
                      (and (re-search-forward (concat "^\\([0-9a-f]+\\) +\\*?" (regexp-quote asset) "$") nil t)
                           (match-string 1))))
          (actual (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally part)
                    (secure-hash 'sha256 (current-buffer)))))
      (unless (equal expected actual)
        (delete-file part)
        (user-error "The checksum of %s does not match the release's SHA256SUMS" asset)))
    (rename-file part path t)
    (set-file-modes path #o755)
    (delete-file sums)
    (message "Postern: installed %s" path)
    path))

(defvar eglot-server-programs)

;;;###autoload
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(postgresql-conf-ts-mode . postgresql-conf-ts-mode-server-program)))

(provide 'postgresql-conf-ts-mode)
;;; postgresql-conf-ts-mode.el ends here
