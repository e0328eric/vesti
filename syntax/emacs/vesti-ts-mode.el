;;; vesti-ts-mode.el --- Tree-sitter major mode for the Vesti language -*- lexical-binding: t; -*-

;; Author: Sungbae Jeong <almagest0328@gmail.com>
;; Keywords: languages, tex, vesti
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A tree-sitter-based major mode for editing Vesti source files (.ves / .vesti).
;; Requires the tree-sitter-vesti grammar to be installed.
;;
;; To install the grammar, either:
;;   1. Use `treesit-install-language-grammar' interactively, or
;;   2. Add to `treesit-language-source-alist' and call it:
;;
;;     (add-to-list 'treesit-language-source-alist
;;                  '(vesti "https://github.com/e0328eric/tree-sitter-vesti"))
;;     (treesit-install-language-grammar 'vesti)
;;
;; Then just open a .ves or .vesti file; the mode activates automatically.
;;
;; Features:
;;   - Accurate syntax highlighting via tree-sitter queries
;;   - Indentation based on the parse tree
;;   - Imenu support for defun/defenv declarations
;;   - Comment support (Lua-style --)

;;; Code:

(require 'treesit)

(declare-function treesit-parser-create "treesit.c")
(declare-function treesit-node-type "treesit.c")

;; ─────────────────────────────────────────────────────────────
;; Customization
;; ─────────────────────────────────────────────────────────────

(defgroup vesti nil
  "Tree-sitter major mode for the Vesti language."
  :group 'languages
  :prefix "vesti-ts-")

(defcustom vesti-ts-mode-indent-offset 2
  "Number of spaces for each indentation level in Vesti."
  :type 'integer
  :group 'vesti)

;; ─────────────────────────────────────────────────────────────
;; Font-lock — map tree-sitter node types to Emacs faces
;; ─────────────────────────────────────────────────────────────

;; These queries mirror highlights.scm from tree-sitter-vesti,
;; translated to the Emacs treesit query format.

(defvar vesti-ts-mode--font-lock-rules
  (treesit-font-lock-rules

   ;; ── Level 1: Comments ──
   :language 'vesti
   :feature 'comment
   '((line_comment) @font-lock-comment-face
     (long_comment) @font-lock-comment-face)

   ;; ── Level 2: Keywords ──
   :language 'vesti
   :feature 'keyword
   '((KEYWORD_docclass) @font-lock-keyword-face
     (KEYWORD_importpkg) @font-lock-keyword-face
     (KEYWORD_importmod) @font-lock-keyword-face
     (KEYWORD_copyfile) @font-lock-keyword-face
     (KEYWORD_importves) @font-lock-keyword-face
     (KEYWORD_useltx3) @font-lock-keyword-face
     (KEYWORD_getfp) @font-lock-keyword-face
     (KEYWORD_startdoc) @font-lock-keyword-face
     (KEYWORD_useenv) @font-lock-keyword-face
     (KEYWORD_begenv) @font-lock-keyword-face
     (KEYWORD_endenv) @font-lock-keyword-face
     (KEYWORD_defun) @font-lock-keyword-face
     (KEYWORD_defenv) @font-lock-keyword-face
     (KEYWORD_makeatletter) @font-lock-keyword-face
     (KEYWORD_makeatother) @font-lock-keyword-face
     (KEYWORD_ltx3on) @font-lock-keyword-face
     (KEYWORD_ltx3off) @font-lock-keyword-face
     (KEYWORD_compty) @font-lock-keyword-face)

   ;; ── Level 2: Attributes / builtins (#label, #eq, …) ──
   :language 'vesti
   :feature 'keyword
   '((attributes) @font-lock-builtin-face)

   ;; ── Level 3: Types (class/pkg names, env names, luacode delimiters) ──
   :language 'vesti
   :feature 'type
   '((class_pkg_name) @font-lock-type-face
     (env_name) @font-lock-type-face
     (luacode_start) @font-lock-preprocessor-face
     (luacode_end) @font-lock-preprocessor-face)

   ;; ── Level 3: Functions (LaTeX commands) ──
   :language 'vesti
   :feature 'function
   '((latex_function_name) @font-lock-function-name-face)

   ;; ── Level 4: Strings (math, raw LaTeX, luacode payload) ──
   :language 'vesti
   :feature 'string
   '((inline_math) @font-lock-string-face
     (display_math) @font-lock-string-face
     (singleline_raw_latex) @font-lock-string-face
     (multiline_raw_latex) @font-lock-string-face
     (luacode_payload) @font-lock-doc-face)

   ;; ── Level 4: Constants (options, args) ──
   :language 'vesti
   :feature 'constant
   '((options) @font-lock-constant-face
     (mandantory_arg) @font-lock-constant-face
     (optional_arg) @font-lock-constant-face)

   ;; ── Level 4: Paths ──
   :language 'vesti
   :feature 'string
   '((filepath) @font-lock-string-face)

   ;; ── Level 4: Delimiters ──
   :language 'vesti
   :feature 'delimiter
   '((delimiter) @font-lock-punctuation-face))
  "Tree-sitter font-lock rules for `vesti-ts-mode'.")

;; ─────────────────────────────────────────────────────────────
;; Indentation
;; ─────────────────────────────────────────────────────────────

(defvar vesti-ts-mode--indent-rules
  `((vesti
     ;; Inside a brace_group: indent children
     ((parent-is "brace_group") parent-bol vesti-ts-mode-indent-offset)
     ;; Inside useenv_decl body
     ((parent-is "useenv_decl") parent-bol vesti-ts-mode-indent-offset)
     ;; Inside defun_decl / defenv_decl body
     ((parent-is "defun_decl") parent-bol vesti-ts-mode-indent-offset)
     ((parent-is "defenv_decl") parent-bol vesti-ts-mode-indent-offset)
     ;; Inside multipkg_decl (importpkg { ... })
     ((parent-is "multipkg_decl") parent-bol vesti-ts-mode-indent-offset)
     ;; Closing braces: align with parent
     ((node-is "}") parent-bol 0)
     ((node-is ")") parent-bol 0)
     ;; Between begenv and endenv
     ((and (parent-is "vesti_content")
           (lambda (node parent &rest _)
             (let ((prev (treesit-node-prev-sibling node t)))
               (and prev
                    (string= (treesit-node-type prev) "begenv_decl")))))
      parent-bol vesti-ts-mode-indent-offset)
     ;; endenv aligns with its begenv
     ((node-is "KEYWORD_endenv") parent-bol 0)
     ;; Luacode payload — don't indent (pass through to Lua)
     ((parent-is "luacode_block") no-indent 0)
     ;; Top-level: no indent
     ((parent-is "vesti_content") column-0 0)
     ;; Fallback
     (no-node parent-bol 0)))
  "Tree-sitter indentation rules for `vesti-ts-mode'.")

;; ─────────────────────────────────────────────────────────────
;; Imenu / defun navigation
;; ─────────────────────────────────────────────────────────────

(defvar vesti-ts-mode--imenu-settings
  '(("Function" "defun_decl" nil nil)
    ("Environment" "defenv_decl" nil nil))
  "Imenu node types for `vesti-ts-mode'.")

(defun vesti-ts-mode--defun-name (node)
  "Return the name defined by NODE (a defun_decl or defenv_decl)."
  (let ((name-node (treesit-node-child-by-field-name node "name")))
    ;; The grammar doesn't use field names, so find the env_name child
    (unless name-node
      (setq name-node
            (treesit-search-subtree node "env_name" nil nil 1)))
    (when name-node
      (treesit-node-text name-node t))))

;; ─────────────────────────────────────────────────────────────
;; Major mode
;; ─────────────────────────────────────────────────────────────

;;;###autoload
(define-derived-mode vesti-ts-mode prog-mode "Vesti"
  "Tree-sitter-based major mode for editing Vesti source files.

Requires the tree-sitter-vesti grammar.  To install it:

  (add-to-list \\='treesit-language-source-alist
               \\='(vesti \"https://github.com/e0328eric/tree-sitter-vesti\"))
  (treesit-install-language-grammar \\='vesti)

\\{vesti-ts-mode-map}"
  :group 'vesti
  :syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?{ "(}" st)
    (modify-syntax-entry ?} "){" st)
    (modify-syntax-entry ?\( "()" st)
    (modify-syntax-entry ?\) ")(" st)
    (modify-syntax-entry ?\[ "(]" st)
    (modify-syntax-entry ?\] ")[" st)
    (modify-syntax-entry ?\\ "\\" st)
    (modify-syntax-entry ?$ "." st)
    (modify-syntax-entry ?# "." st)
    (modify-syntax-entry ?& "." st)
    (modify-syntax-entry ?% "." st)
    (modify-syntax-entry ?- "." st)
    (modify-syntax-entry ?_ "_" st)
    (modify-syntax-entry ?^ "." st)
    (modify-syntax-entry ?@ "_" st)
    st)

  (unless (treesit-ready-p 'vesti)
    (error "Tree-sitter grammar for `vesti' is not available"))

  (treesit-parser-create 'vesti)

  ;; ── Font-lock ──
  (setq-local treesit-font-lock-settings vesti-ts-mode--font-lock-rules)
  (setq-local treesit-font-lock-feature-list
              '((comment)           ; level 1 — always on
                (keyword)           ; level 2
                (type function)     ; level 3
                (string constant delimiter)))  ; level 4

  ;; ── Indentation ──
  (setq-local treesit-simple-indent-rules vesti-ts-mode--indent-rules)

  ;; ── Imenu ──
  (setq-local treesit-simple-imenu-settings vesti-ts-mode--imenu-settings)
  (setq-local treesit-defun-name-function #'vesti-ts-mode--defun-name)
  (setq-local treesit-defun-type-regexp
              (rx (or "defun_decl" "defenv_decl")))

  ;; ── Comments (for M-; etc.) ──
  (setq-local comment-start "-- ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "--+[ \t]*")

  ;; ── Misc ──
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width vesti-ts-mode-indent-offset)
  (setq-local electric-pair-pairs
              '((?{ . ?})
                (?\( . ?\))
                (?\[ . ?\])
                (?$ . ?$)))

  (treesit-major-mode-setup))

;; ─────────────────────────────────────────────────────────────
;; Auto-mode & derived-mode remap
;; ─────────────────────────────────────────────────────────────

;; If tree-sitter grammar is available, prefer vesti-ts-mode.
;; Otherwise fall back to vesti-mode (regex-based) if loaded.

(if (treesit-ready-p 'vesti t)
    (progn
      (add-to-list 'auto-mode-alist '("\\.ves\\'" . vesti-ts-mode))
      (add-to-list 'auto-mode-alist '("\\.vesti\\'" . vesti-ts-mode)))
  ;; Grammar not available — don't register; let vesti-mode handle it
  (message "vesti-ts-mode: tree-sitter grammar for `vesti' not found; \
install it or use `vesti-mode' instead"))

(provide 'vesti-ts-mode)

;;; vesti-ts-mode.el ends here
