;;; vesti-mode.el -- Regex highlighting for Vesti -*- lexical-binding: t; -*-

;;; Commentary:
;; Plain font-lock (non-Tree-sitter) highlighting for the Vesti language.
;; File extensions: .ves

(require 'regexp-opt)

(defgroup vesti nil
  "Major mode for the Vesti language."
  :group 'languages)

;; Faces
(defface vesti-keyword-face    '((t :inherit font-lock-keyword-face)) "Keywords.")
(defface vesti-attribute-face  '((t :inherit font-lock-constant-face)) "Attributes like #label.")
(defface vesti-env-face        '((t :inherit font-lock-type-face))     "Environment names.")
(defface vesti-func-face       '((t :inherit font-lock-function-name-face)) "Defined function names.")
(defface vesti-math-face       '((t :inherit font-lock-string-face))   "Inline/display math.")
(defface vesti-rawlatex-face   '((t :inherit shadow))                  "Raw LaTeX sections.")
(defface vesti-luacode-face    '((t :inherit font-lock-preprocessor-face)) "Lua code blocks.")
(defface vesti-command-face    '((t :inherit font-lock-builtin-face))  "LaTeX-style \\commands.")

;; Keywords taken from your grammar.js
(defconst vesti--keywords
  '("docclass" "importpkg" "importmod" "cpfile" "importves"
    "startdoc" "useenv" "begenv" "endenv" "defun" "defenv" "compty" "#lu:"))

(defconst vesti--compile-types '("plain" "pdf" "xe" "lua"))

;; Regexes
(defconst vesti--rx-attribute    "#[A-Za-z0-9][A-Za-z0-9_]*")
(defconst vesti--rx-env-name     "[A-Za-z][A-Za-z0-9-]*\\(?:\\*\\)?")
(defconst vesti--rx-filepath     "[[:alnum:][:word:]/@._-]+")
(defconst vesti--rx-latex-cmd
  (rx "\\" (or (seq (+ (any "@" upper lower)) (* "*"))
               (not (any " \t\r\n")))))

;; % comments:
;;   - line: %...<eol> (but not starting with %! or %# or %- or %*)
;;   - block: %* ... *%  (balanced-ish)
;; Raw LaTeX blocks:
;;   - singleline: %#...<eol> or %##<eol>
;;   - multiline:  %#  ...  #% ... %
;;
;; We’ll mark these via syntax-propertize so font-lock treats them as comments.
(defconst vesti--block-comment-start "%\\*")
(defconst vesti--block-comment-end   "\\*%")

;; Lua block delimiters
(defconst vesti--luacode-start "^#lu:[ \t]*\\(?:\\(.+\\)\\)?$")
(defconst vesti--luacode-end   "^:lu#[ \t]*$")

(defun vesti--syntax-propertize (start end)
  "Apply syntax properties in region START..END."
  (save-excursion
    ;; Block comments %* ... *%
    (goto-char start)
    (while (re-search-forward vesti--block-comment-start end t)
      (put-text-property (match-beginning 0) (match-end 0)
                         'syntax-table (string-to-syntax "< b")))
    (goto-char start)
    (while (re-search-forward vesti--block-comment-end end t)
      (put-text-property (match-beginning 0) (match-end 0)
                         'syntax-table (string-to-syntax "> b")))
    ;; Treat '%' as comment-starter elsewhere
    (goto-char start)
    (while (re-search-forward "%" end t)
      (put-text-property (match-beginning 0) (match-end 0)
                         'syntax-table (string-to-syntax "<"))
      ;; newline closes the comment
      (when (looking-at "[^\n]*\\(\n\\)")
        (put-text-property (match-beginning 1) (match-end 1)
                           'syntax-table (string-to-syntax ">"))))))

(defun vesti--font-lock-luacode (limit)
  "Fontify #lu: ... :lu# blocks up to LIMIT.
Applies `vesti-luacode-face' to the whole body."
  (when (re-search-forward vesti--luacode-start limit t)
    (let ((beg (match-beginning 0)))
      (if (re-search-forward vesti--luacode-end limit t)
          (let ((end (match-end 0)))
            (put-text-property beg end 'font-lock-face 'vesti-luacode-face)
            (set-match-data (list beg end))
            t)
        ;; unterminated: color to limit
        (put-text-property beg limit 'font-lock-face 'vesti-luacode-face)
        (set-match-data (list beg limit))
        t))))

(defun vesti--font-lock-rawlatex (limit)
  "Fontify \"%# …\"-style raw LaTeX up to LIMIT."
  (when (re-search-forward "^%#\\(?:#?\\)?[^\n]*\\(\n\\|\\'\\)" limit t)
    (let ((beg (match-beginning 0))
          (end (match-end 0)))
      (put-text-property beg end 'font-lock-face 'vesti-rawlatex-face)
      (set-match-data (list beg end))
      t)))

(defun vesti--font-lock-display-math (limit)
  "Fontify display math $$…$$ up to LIMIT."
  (when (re-search-forward "\\$\\$" limit t)
    (let ((beg (match-beginning 0)))
      (when (re-search-forward "\\$\\$" limit t)
        (let ((end (match-end 0)))
          (put-text-property beg end 'font-lock-face 'vesti-math-face)
          (set-match-data (list beg end))
          t)))))

(defun vesti--font-lock-inline-math (limit)
  "Fontify inline math $…$ up to LIMIT (single-line best effort)."
  (when (re-search-forward "\\$" limit t)
    (let ((beg (match-beginning 0)))
      (when (re-search-forward "\\$" (line-end-position) t)
        (let ((end (match-end 0)))
          (put-text-property beg end 'font-lock-face 'vesti-math-face)
          (set-match-data (list beg end))
          t)))))

;; Imenu (optional)
(defconst vesti-imenu-generic-expression
  `(("Functions"  ,(concat "^\\s-*defun\\s-+\\(" vesti--rx-env-name "\\)\\b") 1)
    ("Envs"       ,(concat "^\\s-*defenv\\s-+\\(" vesti--rx-env-name "\\)\\b") 1)
    ("Use env"    ,(concat "^\\s-*useenv\\s-+\\(" vesti--rx-env-name "\\)\\b") 1)))

;; Font-lock keyword rules (order matters: earlier gets precedence)
(defconst vesti-font-lock-keywords
  `(
    ;; Lua blocks (greedy)
    (vesti--font-lock-luacode . 0)

    ;; Raw LaTeX single-line %#...
    (vesti--font-lock-rawlatex . 0)

    ;; Display math $$...$$ (multi-line)
    (vesti--font-lock-display-math . 0)

    ;; Inline math $...$ (same line)
    (vesti--font-lock-inline-math . 0)

    ;; Keywords
    (,(regexp-opt vesti--keywords 'symbols) . 'vesti-keyword-face)

    ;; compile_type symbols when used standalone
    (,(regexp-opt vesti--compile-types 'symbols) . 'font-lock-constant-face)

    ;; Attributes like #label
    (,vesti--rx-attribute . 'vesti-attribute-face)

    ;; LaTeX-style commands
    (,vesti--rx-latex-cmd . 'vesti-command-face)

    ;; env/file names in various forms
    (,(concat "\\_<\\(useenv\\|begenv\\|endenv\\)\\_>\\s-+\\(" vesti--rx-env-name "\\)")
     (2 'vesti-env-face))
    (,(concat "\\_<\\(defenv\\)\\_>\\s-+\\(" vesti--rx-env-name "\\)")
     (2 'vesti-env-face))
    (,(concat "\\_<\\(defun\\)\\_>\\s-+\\(?:" "\\[[^]]*\\]\\s-*\\)?" "\\(" vesti--rx-env-name "\\)")
     (2 'vesti-func-face))

    ;; Filepath in (importmod|importves|compty)(...)
    (,(concat "\\_<\\(importmod\\|importves\\|compty\\)\\_>\\s-*("
              "\\(" vesti--rx-filepath "\\)" ")")
     (2 'font-lock-string-face))

    ;; Option lists: (opt1,opt2,...)
    ("(\\([[:alnum:]_\\-]+\\(?:,[[:alnum:]_\\-]+\\)*,?\\))" . (1 font-lock-variable-name-face))
    ))

;; Syntax table
(defvar vesti-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; Comments: '%' starts a comment; newline ends it
    (modify-syntax-entry ?% "<" st)
    (modify-syntax-entry ?\n ">" st)
    ;; Quotes are ordinary in Vesti
    (modify-syntax-entry ?\" "." st)
    ;; Braces/parens
    (modify-syntax-entry ?{ "(}" st)
    (modify-syntax-entry ?} "){" st)
    (modify-syntax-entry ?( "()" st)
    (modify-syntax-entry ?) ")(" st)
    (modify-syntax-entry ?[ "(]" st)
    (modify-syntax-entry ?] ")[" st)
    ;; Backslash as word constituent for LaTeX commands
    (modify-syntax-entry ?\\ "_" st)
    st))

;;;###autoload
(define-derived-mode vesti-mode prog-mode "Vesti"
  "Major mode for the Vesti language (regex font-lock)."
  :group 'vesti
  :syntax-table vesti-mode-syntax-table
  (setq-local comment-start "%")
  (setq-local comment-end   "")
  (setq-local comment-use-syntax t)

  ;; Make font-lock extend over multi-line constructs (e.g., $$…$$, %*…*%, #lu:…:lu#)
  (setq-local font-lock-multiline t)

  ;; Syntax-propertize handles %* … *% and lines with %
  (setq-local syntax-propertize-function #'vesti--syntax-propertize)

  ;; Imenu
  (setq-local imenu-generic-expression vesti-imenu-generic-expression)

  ;; Font-lock
  (setq-local font-lock-defaults
              '(vesti-font-lock-keywords
                ;; keywords-only? -> nil (we still want strings/comments)
                nil
                ;; case-fold? -> nil (case-sensitive)
                nil))

  ;; Indentation (very light: preserve, but indent after certain starters)
  (setq-local indent-line-function #'indent-relative))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ves\\'"   . vesti-mode))
;;;;;###autoload
;;(add-to-list 'auto-mode-alist '("\\.vesti\\'" . vesti-mode))

(provide 'vesti-mode)
;;; vesti-mode.el ends here
