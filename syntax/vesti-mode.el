;;; vesti-mode.el --- Major Mode for editing vesti syntax highlighting -*- lexical-binding: t -*-

(defconst glasm-mode-syntax-table
  (with-syntax-table (copy-syntax-table)
    (modify-syntax-entry ?/ ". 124b")
    (modify-syntax-entry ?* ". 23")
    (modify-syntax-entry ?\n "> b")
    (modify-syntax-entry ?\" "\"")
    (modify-syntax-entry ?\' "\"")
    (syntax-table))
  "Syntax table for `glasm-mode'.")

;;;###autoload
(define-derived-mode vesti-mode prog-mode "vesti"
  "Major Mode for editing vesti"
  (setq font-lock-defaults '(vesti-highlights))
  (set-syntax-table vesti-mode-syntax-table))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ves\\'" . vesti-mode))

(provide 'vesti-mode)

;;; vesti-mode.el ends here
