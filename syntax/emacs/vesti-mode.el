;;; vesti-mode.el --- Major mode for the Vesti language -*- lexical-binding: t; -*-

;; Author: Generated from tree-sitter-vesti grammar & Vesti manual
;; Keywords: languages, tex, vesti
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; A major mode for editing Vesti source files (.ves / .vesti).
;; Vesti is a transpiler language that compiles to LaTeX.
;;
;; Highlights:
;;   Keywords ─ docclass, importpkg, startdoc, useenv, begenv, endenv,
;;     defun, defenv, importmod, cpfile, importves, compty, getfp,
;;     useltx3, makeatletter, makeatother, ltx3on, ltx3off
;;   Builtins ─ #label, #eq, #enum, #at_on, #at_off, #chardef, …
;;   LaTeX commands ─ \foo, \textbf{}, etc.
;;   Environment / class / package names after keywords
;;   Inline math $…$ and display math $$…$$
;;   Singleline raw LaTeX: %#…
;;   Multiline raw LaTeX: %-…-%
;;   Luacode blocks: #::…::#
;;   Lua-style comments: -- line, --[=*[…]=*] long
;;
;; Installation:
;;   (add-to-list 'load-path "/path/to/")
;;   (require 'vesti-mode)

;;; Code:

;; ─────────────────────────────────────────────────────────────
;; Customization
;; ─────────────────────────────────────────────────────────────

(defgroup vesti nil
  "Major mode for the Vesti language."
  :group 'languages
  :prefix "vesti-")

(defcustom vesti-indent-offset 2
  "Number of spaces for each indentation level in Vesti mode."
  :type 'integer
  :group 'vesti)

;; ─────────────────────────────────────────────────────────────
;; Syntax table
;; ─────────────────────────────────────────────────────────────

;; Minimal table.  Comments, math, raw‐LaTeX, and luacode are handled
;; entirely through `syntax-propertize-function' so that `-' in
;; identifiers (e.g. package names) is harmless.

(defvar vesti-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?{ "(}" st)
    (modify-syntax-entry ?} "){" st)
    (modify-syntax-entry ?\( "()" st)
    (modify-syntax-entry ?\) ")(" st)
    (modify-syntax-entry ?\[ "(]" st)
    (modify-syntax-entry ?\] ")[" st)
    (modify-syntax-entry ?\\ "\\" st)
    ;; Everything special is just punctuation — no comment chars here.
    (modify-syntax-entry ?$ "." st)
    (modify-syntax-entry ?# "." st)
    (modify-syntax-entry ?& "." st)
    (modify-syntax-entry ?% "." st)
    (modify-syntax-entry ?- "." st)
    (modify-syntax-entry ?_ "_" st)
    (modify-syntax-entry ?^ "." st)
    (modify-syntax-entry ?@ "_" st)
    st)
  "Syntax table for `vesti-mode'.")

;; ─────────────────────────────────────────────────────────────
;; Syntax propertize
;; ─────────────────────────────────────────────────────────────

;; We apply `syntax-table' text properties so that Emacs' built‐in
;; syntactic font‐lock (for comments and strings) works for:
;;   -- …\n             line comments
;;   --[=*[ … ]=*]      long comments
;;   $…$                inline math   (highlighted as "string")
;;   $$…$$              display math  (highlighted as "string")
;;   %#…\n              singleline raw LaTeX (as "string")
;;   %-…-%              multiline raw LaTeX  (as "string")
;;   #::…::#            luacode block        (as "string")
;;
;; We use syntax code `!' (generic comment delimiter, class 14) for
;; comments, and `|' (generic string fence, class 15) for the others.

(defun vesti--syntax-propertize (start end)
  "Apply syntax properties to Vesti constructs between START and END.
Handles the case where START falls inside a multiline construct by
backing up to the construct's opener."
  ;; Back up START if we're inside a multiline construct.
  (save-excursion
    (goto-char start)
    (let ((adjusted start))
      ;; Look backward for an unclosed #:: (luacode)
      (save-excursion
        (when (re-search-backward "#::" nil t)
          (unless (save-excursion
                    (goto-char (match-end 0))
                    (re-search-forward "::#" start t))
            (setq adjusted (min adjusted (match-beginning 0))))))
      ;; Look backward for an unclosed %- (multiline raw)
      (save-excursion
        (when (re-search-backward "%-" nil t)
          (unless (save-excursion
                    (goto-char (match-end 0))
                    (re-search-forward "-%" start t))
            (setq adjusted (min adjusted (match-beginning 0))))))
      ;; Look backward for an unclosed --[=*[ (long comment)
      (save-excursion
        (when (re-search-backward "--\\[=*\\[" nil t)
          (let* ((open-end (match-end 0))
                 (eq-count (- open-end (match-beginning 0) 4))
                 (close-re (concat "\\]" (make-string eq-count ?=) "\\]")))
            (unless (save-excursion
                      (goto-char open-end)
                      (re-search-forward close-re start t))
              (setq adjusted (min adjusted (match-beginning 0)))))))
      (setq start adjusted)))
  ;; Clear old properties and re-scan
  (remove-text-properties start end '(syntax-table nil))
  (goto-char start)
  (vesti--syntax-propertize-scan end))

(defun vesti--syntax-propertize-scan (end)
  "Scan for syntactic constructs up to END and propertize them.
Longer/more-specific patterns are tried first at each position."
  (let ((search-re
         ;; Ordered: longer specific patterns first.
         ;; Group 1: #::        luacode
         ;; Group 2: %-         multiline raw LaTeX
         ;; Group 3: %#         singleline raw LaTeX
         ;; Group 4: --[        potential long comment
         ;; Group 5: --         line comment (NOT --[ since that matched g4)
         ;; Group 6: $$         display math
         ;; Group 7: $          inline math
         (concat "\\(#::\\)"           ; 1
                 "\\|\\(%-\\)"         ; 2
                 "\\|\\(%#\\)"         ; 3
                 "\\|\\(--\\[\\)"      ; 4
                 "\\|\\(--\\)"         ; 5
                 "\\|\\(\\$\\$\\)"     ; 6
                 "\\|\\(\\$\\)")))     ; 7
    (while (re-search-forward search-re end t)
      (cond
       ((match-beginning 1) (vesti--propertize-luacode (match-beginning 1) end))
       ((match-beginning 2) (vesti--propertize-multiline-raw (match-beginning 2) end))
       ((match-beginning 3) (vesti--propertize-singleline-raw (match-beginning 3) end))
       ((match-beginning 4) (vesti--propertize-long-comment (match-beginning 4) end))
       ((match-beginning 5) (vesti--propertize-line-comment (match-beginning 5) end))
       ((match-beginning 6) (vesti--propertize-display-math (match-beginning 6) end))
       ((match-beginning 7) (vesti--propertize-inline-math (match-beginning 7) end))))))

(defsubst vesti--put-syntax (pos value)
  "Set syntax-table text property at POS to VALUE."
  (put-text-property pos (1+ pos) 'syntax-table value))

;; ── Comments ────────────────────────────────────────────────

;; Generic comment delimiter: syntax class 14, written as `(14)'.
;; A single (14) toggles comment state, so we place one at the start
;; of `--' and one at `\n' (or last `]' for long comments).

(defun vesti--propertize-line-comment (beg end)
  "Mark -- … \\n as a comment from BEG, up to END."
  ;; Mark first `-' as generic comment delimiter (opener)
  (vesti--put-syntax beg '(14))
  (goto-char (1+ beg))
  (let ((eol (line-end-position)))
    (if (< eol end)
        (progn
          ;; Mark the newline as generic comment delimiter (closer)
          (vesti--put-syntax eol '(14))
          (goto-char (1+ eol)))
      ;; At or past END / EOF — mark last available char
      (when (> eol beg)
        (vesti--put-syntax (1- (min eol (point-max))) '(14)))
      (goto-char (min eol end)))))

(defun vesti--propertize-long-comment (beg end)
  "Mark --[=*[…]=*] as a comment from BEG, up to END."
  (goto-char (+ beg 3))  ; past "--["
  (let ((eq-count 0))
    ;; Count `=' signs
    (while (and (< (point) end) (eq (char-after) ?=))
      (setq eq-count (1+ eq-count))
      (forward-char 1))
    (if (and (< (point) end) (eq (char-after) ?\[))
        (progn
          (forward-char 1)  ; past second `['
          ;; Mark first `-' as generic comment delimiter (opener)
          (vesti--put-syntax beg '(14))
          ;; Search for closing ]=*]
          (let ((close-re (concat "\\]" (make-string eq-count ?=) "\\(\\]\\)")))
            (if (re-search-forward close-re end t)
                ;; Mark the final `]' as generic comment delimiter (closer)
                (vesti--put-syntax (1- (match-end 1)) '(14))
              ;; Unterminated
              (goto-char end))))
      ;; Not a valid long bracket opener — fall back to line comment
      (goto-char beg)
      (vesti--propertize-line-comment beg end))))

;; ── Luacode: #::…::# ───────────────────────────────────────

;; Generic string fence: syntax class 15, written as `(15)'.
;; A (15) toggles string state, so one at opener and one at closer.

(defun vesti--propertize-luacode (beg end)
  "Mark #::…::#[suffix] as a string from BEG, up to END."
  ;; Mark the `#' of `#::' as generic string fence (opener)
  (vesti--put-syntax beg '(15))
  (if (re-search-forward "::#" end t)
      (let ((hash-pos (1- (point))))  ; position of the `#' in `::#'
        ;; Skip optional suffix: *, <…>, [name]
        (when (< (point) end)
          (cond
           ((eq (char-after) ?*)
            (forward-char 1))
           ((eq (char-after) ?<)
            (re-search-forward ">" end t))
           ((eq (char-after) ?\[)
            (re-search-forward "\\]" end t))))
        ;; Mark the last char of the whole ::#suffix as closer.
        ;; If there was a suffix, close after it; otherwise close on `#'.
        (vesti--put-syntax (1- (point)) '(15)))
    ;; Unterminated
    (goto-char end)))

;; ── Multiline raw LaTeX: %-…-% ─────────────────────────────

(defun vesti--propertize-multiline-raw (beg end)
  "Mark %-…-% as a string from BEG, up to END."
  (vesti--put-syntax beg '(15))  ; `%' of `%-'
  (if (re-search-forward "-%" end t)
      (vesti--put-syntax (1- (point)) '(15))  ; `%' of `-%'
    (goto-char end)))

;; ── Singleline raw LaTeX: %#…\n ────────────────────────────

(defun vesti--propertize-singleline-raw (beg end)
  "Mark %#…\\n as a string from BEG, up to END."
  (vesti--put-syntax beg '(15))  ; `%' of `%#'
  (let ((eol (line-end-position)))
    (if (< eol end)
        (progn
          (vesti--put-syntax eol '(15))  ; newline as closer
          (goto-char (1+ eol)))
      (when (> eol (1+ beg))
        (vesti--put-syntax (1- (min eol (point-max))) '(15)))
      (goto-char (min eol end)))))

;; ── Display math: $$…$$ ────────────────────────────────────

(defun vesti--propertize-display-math (beg end)
  "Mark $$…$$ as a string from BEG, up to END."
  ;; Mark first `$' as opener
  (vesti--put-syntax beg '(15))
  ;; Skip past the opening `$$'
  (goto-char (+ beg 2))
  (if (re-search-forward "\\$\\$" end t)
      ;; Mark the second `$' of closing `$$' as closer
      (vesti--put-syntax (1- (point)) '(15))
    (goto-char end)))

;; ── Inline math: $…$ ───────────────────────────────────────

(defun vesti--propertize-inline-math (beg end)
  "Mark $…$ as a string from BEG, up to END."
  (vesti--put-syntax beg '(15))
  (if (re-search-forward "\\$" end t)
      (vesti--put-syntax (1- (point)) '(15))
    (goto-char end)))

;; ─────────────────────────────────────────────────────────────
;; Font-lock keywords
;; ─────────────────────────────────────────────────────────────

(defconst vesti--keywords
  '("docclass" "importpkg" "importmod" "cpfile" "importves"
    "getfp" "startdoc" "useenv" "begenv" "endenv"
    "defun" "defenv" "compty")
  "Vesti reserved keywords (Table 1 in the manual).")

(defconst vesti--builtins
  '("at_off" "at_on" "chardef" "def" "enum" "enum_counter"
    "eq" "get_filepath" "label" "ltx3_off" "ltx3_on"
    "mathchardef" "mathmode" "noltx3" "picture" "raw_tex"
    "showfont" "textmode" "undef")
  "Vesti builtin functions (Table 2 in the manual), sans `#' prefix.")

;; Build regexps.
;; Keywords can have an optional `!' suffix (e.g. begenv!, defun!).
(defconst vesti--keyword-re
  (concat "\\<" (regexp-opt vesti--keywords t) "\\>\\(!\\)?")
  "Regexp matching a Vesti keyword with optional `!' bang.
Group 1 = keyword text, group 2 = optional `!'.")

;; Builtins always start with `#'.  Use \_> (symbol boundary) because
;; names contain `_' which is a symbol constituent, not word.
(defconst vesti--builtin-re
  (concat "#" (regexp-opt vesti--builtins t) "\\_>")
  "Regexp matching a Vesti builtin.  Group 1 = name sans `#'.")

(defconst vesti-font-lock-keywords
  (let* (;; LaTeX command: \foo, \foo*, \@bar, \& etc.
         (latex-cmd-re
          "\\\\\\(?:[@a-zA-Z]+\\*?\\|[^[:space:][:cntrl:]{}$#_^\\\\]\\)")
         ;; Names following docclass / importpkg (single)
         (cls-name-re
          (concat "\\<\\(?:docclass\\|importpkg\\)\\>"
                  "\\s-+\\([A-Za-z0-9_-]+\\)"))
         ;; Name following useenv / begenv (with optional !)
         (env-name-re
          (concat "\\<\\(?:useenv\\|begenv\\)\\(!\\)?"
                  "\\s-+\\([A-Za-z][A-Za-z0-9-]*\\**\\)"))
         ;; Name following defun / defenv (with optional ! and optional [attr])
         (def-name-re
          (concat "\\<\\(?:defun\\|defenv\\)\\(!\\)?"
                  "\\(?:\\s-*\\[[^]]*\\]\\)?"
                  "\\s-+\\([A-Za-z@][A-Za-z0-9@_-]*\\**\\)"))
         ;; Filepath inside importmod(...), cpfile(...), importves(...),
         ;; getfp(...), compty(...)
         (filepath-re
          (concat "\\<\\(?:importmod\\|cpfile\\|importves\\|getfp\\|compty\\)"
                  "(\\([^)]+\\))"))
         ;; Options in parens: (10pt, a4paper)  — after class/pkg name
         (options-re
          (concat "\\<\\(?:docclass\\|importpkg\\)\\>"
                  "\\s-+[A-Za-z0-9_-]+"
                  "\\s-*\\(([^)]*)\\)"))
         ;; Luacode delimiter highlighting
         (luacode-open-re "#::")
         (luacode-close-re "::#\\(?:\\*\\|<[^>]*>\\|\\[[^]]*\\]\\)?"))

    `(
      ;; ── Builtins: #label, #eq, … ──
      (,vesti--builtin-re . font-lock-builtin-face)

      ;; ── Keywords: docclass, useenv, … (and optional !) ──
      (,vesti--keyword-re (1 font-lock-keyword-face)
                          (2 font-lock-keyword-face nil t))

      ;; ── Class / package name after docclass / importpkg ──
      (,cls-name-re (1 font-lock-type-face))

      ;; ── Environment name after useenv / begenv ──
      (,env-name-re (2 font-lock-type-face))

      ;; ── Defined name after defun / defenv ──
      (,def-name-re (2 font-lock-type-face))

      ;; ── Filepaths inside importmod(…) etc. ──
      (,filepath-re (1 font-lock-string-face))

      ;; ── Options (…) after docclass/importpkg name ──
      (,options-re (1 font-lock-constant-face t))

      ;; ── Luacode delimiters ──
      (,luacode-open-re . font-lock-preprocessor-face)
      (,luacode-close-re . font-lock-preprocessor-face)

      ;; ── LaTeX commands: \foo, \textbf, etc. ──
      (,latex-cmd-re . font-lock-function-name-face)
      ))
  "Font-lock keywords for `vesti-mode'.")

;; ─────────────────────────────────────────────────────────────
;; Indentation
;; ─────────────────────────────────────────────────────────────

(defun vesti-indent-line ()
  "Indent the current line in Vesti mode."
  (interactive)
  (let ((indent (vesti--calculate-indent)))
    (when indent
      (save-excursion
        (beginning-of-line)
        (delete-horizontal-space)
        (indent-to indent))
      (when (< (current-column) indent)
        (back-to-indentation)))))

(defun vesti--calculate-indent ()
  "Return the indentation column for the current line."
  (save-excursion
    (beginning-of-line)
    (cond
     ;; BOB
     ((bobp) 0)

     ;; Line starts with `}' or `)' — match the opener
     ((looking-at "^[ \t]*[})]")
      (save-excursion
        (skip-chars-forward " \t")
        (condition-case nil
            (progn (backward-sexp 1) (current-indentation))
          (error 0))))

     ;; Line starts with `endenv' — find matching `begenv'
     ((looking-at "^[ \t]*\\<endenv\\>")
      (save-excursion
        (let ((depth 1))
          (while (and (> depth 0)
                      (re-search-backward
                       "\\<\\(begenv\\|endenv\\)\\>" nil t))
            (if (string= (match-string 1) "endenv")
                (setq depth (1+ depth))
              (setq depth (1- depth)))))
        (current-indentation)))

     ;; Default
     (t
      (let ((prev-indent 0) (delta 0))
        (save-excursion
          ;; Find previous non-blank line
          (forward-line -1)
          (while (and (not (bobp)) (looking-at "^[ \t]*$"))
            (forward-line -1))
          (setq prev-indent (current-indentation))
          ;; Count net opening delimiters on previous line
          (let ((eol (line-end-position)))
            (beginning-of-line)
            (while (< (point) eol)
              (let ((c (char-after)))
                (cond
                 ((memq c '(?{ ?\()) (setq delta (1+ delta)))
                 ((memq c '(?} ?\))) (setq delta (1- delta)))))
              (forward-char 1))
            ;; `begenv' without `{' on the same line opens a block
            (beginning-of-line)
            (when (and (looking-at ".*\\<begenv\\>")
                       (not (looking-at ".*{")))
              (setq delta (1+ delta)))))
        (max 0 (+ prev-indent (* delta vesti-indent-offset))))))))

;; ─────────────────────────────────────────────────────────────
;; Imenu
;; ─────────────────────────────────────────────────────────────

(defvar vesti-imenu-generic-expression
  `(("Functions"
     ,(concat "\\<defun\\>\\(!\\)?"
              "\\(?:\\s-*\\[[^]]*\\]\\)?"
              "\\s-+\\([A-Za-z@][A-Za-z0-9@_-]*\\**\\)")
     2)
    ("Environments"
     ,(concat "\\<defenv\\>\\(!\\)?"
              "\\(?:\\s-*\\[[^]]*\\]\\)?"
              "\\s-+\\([A-Za-z@][A-Za-z0-9@_-]*\\**\\)")
     2))
  "Imenu patterns for `vesti-mode'.")

;; ─────────────────────────────────────────────────────────────
;; Major mode definition
;; ─────────────────────────────────────────────────────────────

;;;###autoload
(define-derived-mode vesti-mode prog-mode "Vesti"
  "Major mode for editing Vesti source files.

Vesti is a transpiler language that compiles to LaTeX.

\\{vesti-mode-map}"
  :syntax-table vesti-mode-syntax-table
  :group 'vesti

  ;; ── Syntax propertize (comments, math, raw-latex, luacode) ──
  (setq-local syntax-propertize-function #'vesti--syntax-propertize)

  ;; ── Font-lock ──
  (setq font-lock-defaults
        '(vesti-font-lock-keywords
          nil   ; keywords-only: nil → also run syntactic highlighting
          nil   ; case-fold: nil
          nil   ; syntax-alist overrides
          nil   ; syntax-begin
          (font-lock-multiline . t)))

  ;; Ensure multiline constructs re-fontify on edits
  (add-hook 'font-lock-extend-region-functions
            #'font-lock-extend-region-wholelines nil t)

  ;; ── Comments (for M-; etc.) ──
  (setq-local comment-start "-- ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "--+[ \t]*")

  ;; ── Indentation ──
  (setq-local indent-line-function #'vesti-indent-line)
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width vesti-indent-offset)

  ;; ── Imenu ──
  (setq-local imenu-generic-expression vesti-imenu-generic-expression)

  ;; ── Electric pairs ──
  (setq-local electric-pair-pairs
              '((?{ . ?})
                (?\( . ?\))
                (?\[ . ?\])
                (?$ . ?$))))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ves\\'" . vesti-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.vesti\\'" . vesti-mode))

(provide 'vesti-mode)

;;; vesti-mode.el ends here
