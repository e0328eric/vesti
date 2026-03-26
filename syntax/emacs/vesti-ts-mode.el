;;; vesti-ts-mode.el --- Tree-sitter support for Vesti -*- lexical-binding: t; -*-

;; Author: e0328eric
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages tree-sitter vesti latex
;; URL: https://github.com/e0328eric/tree-sitter-vesti

;;; Commentary:

;; Major mode for editing Vesti files (.vesti), powered by Emacs's
;; built-in Tree-sitter support (Emacs 29+).
;;
;; Vesti is a LaTeX preprocessor language.  This mode provides syntax
;; highlighting via tree-sitter-vesti, with optional Lua injection for
;; luacode blocks.
;;
;; Installation:
;;
;; 1. Install the tree-sitter grammar:
;;
;;    M-x treesit-install-language-grammar RET vesti RET
;;
;;    Or manually:
;;      cd tree-sitter-vesti
;;      cc -shared -fPIC -O2 -I src src/parser.c -o libtree-sitter-vesti.so
;;      cp libtree-sitter-vesti.so ~/.emacs.d/tree-sitter/
;;
;; 2. Add to your init file:
;;
;;    (require 'vesti-ts-mode)

;;; Code:

(require 'treesit)
(eval-when-compile (require 'rx))

(defgroup vesti-ts nil
  "Major mode for Vesti files using Tree-sitter."
  :group 'languages
  :prefix "vesti-ts-")

(defcustom vesti-ts-mode-indent-offset 4
  "Number of spaces for each indentation step in `vesti-ts-mode'."
  :type 'natnum
  :group 'vesti-ts)

;;; Font-lock

(defvar vesti-ts-mode--font-lock-rules
  (treesit-font-lock-rules
   ;; --- Level 1: Comments ---
   :language 'vesti
   :feature 'comment
   '((line_comment) @font-lock-comment-face
     (long_comment) @font-lock-comment-face)

   ;; --- Level 2: Keywords ---
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
     (KEYWORD_compty) @font-lock-keyword-face
     (attributes) @font-lock-keyword-face)

   ;; --- Level 2: Strings (math & raw LaTeX) ---
   :language 'vesti
   :feature 'string
   '((inline_math) @font-lock-string-face
     (display_math) @font-lock-string-face
     (singleline_raw_latex) @font-lock-string-face
     (multiline_raw_latex) @font-lock-string-face)

   ;; --- Level 3: Types ---
   :language 'vesti
   :feature 'type
   '((class_pkg_name) @font-lock-type-face
     (env_name) @font-lock-type-face
     (luacode_start) @font-lock-type-face
     (luacode_end) @font-lock-type-face)

   ;; --- Level 3: Functions ---
   :language 'vesti
   :feature 'function
   '((latex_function_name) @font-lock-function-name-face)

   ;; --- Level 4: Constants (options & arguments) ---
   :language 'vesti
   :feature 'constant
   '((options) @font-lock-constant-face
     (mandantory_arg) @font-lock-constant-face
     (optional_arg) @font-lock-constant-face))
  "Font-lock rules for `vesti-ts-mode'.")

;;; Indentation

(defvar vesti-ts-mode--indent-rules
  `((vesti
     ((parent-is "source_file") column-0 0)
     ((node-is "}") parent-bol 0)
     ((node-is "]") parent-bol 0)
     ((node-is ")") parent-bol 0)
     ((parent-is "block") parent-bol vesti-ts-mode-indent-offset)
     ((parent-is "environment_block") parent-bol vesti-ts-mode-indent-offset)
     ((parent-is "luacode_block") parent-bol vesti-ts-mode-indent-offset)
     (no-node parent-bol 0)))
  "Indentation rules for `vesti-ts-mode'.
Adjust these after inspecting your AST with `treesit-explore-mode'.")

;;; Navigation

(defvar vesti-ts-mode--defun-type-regexp
  (rx (or "defun_statement" "defenv_statement" "environment_block"))
  "Regexp matching Tree-sitter node types for defun-like navigation.")

;;; Major mode

;;;###autoload
(define-derived-mode vesti-ts-mode prog-mode "Vesti"
  "Major mode for editing Vesti files, powered by Tree-sitter.

Vesti is a LaTeX preprocessor language.  This mode requires the
tree-sitter grammar from `https://github.com/e0328eric/tree-sitter-vesti'.

\\{vesti-ts-mode-map}"

  (unless (treesit-ready-p 'vesti)
    (error "Tree-sitter grammar for Vesti is not available; \
install it with `treesit-install-language-grammar'"))

  (treesit-parser-create 'vesti)

  ;; Comments
  (setq-local comment-start "// ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "//+\\s-*")

  ;; Font-lock
  (setq-local treesit-font-lock-settings vesti-ts-mode--font-lock-rules)
  (setq-local treesit-font-lock-feature-list
              '((comment)
                (keyword string)
                (type function)
                (constant)))

  ;; Indentation
  (setq-local treesit-simple-indent-rules vesti-ts-mode--indent-rules)

  ;; Navigation
  (setq-local treesit-defun-type-regexp vesti-ts-mode--defun-type-regexp)

  (treesit-major-mode-setup))

;;; File association & grammar source

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ves\\'" . vesti-ts-mode))

(add-to-list 'treesit-language-source-alist
             '(vesti "https://github.com/e0328eric/tree-sitter-vesti" "main" "src"))

(provide 'vesti-ts-mode)
;;; vesti-ts-mode.el ends here
