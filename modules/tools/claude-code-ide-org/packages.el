;; -*- no-byte-compile: t; -*-
;;; tools/claude-code-ide-org/packages.el

;; org-ql (for org_query) is the only additional package required.
;; Depends on claude-code-ide, which must be declared in your root packages.el:
;;
;;   (package! claude-code-ide
;;     :recipe (:host github :repo "manzaltu/claude-code-ide.el"))

(package! org-ql
  :recipe (:host github :repo "alphapapa/org-ql"))
