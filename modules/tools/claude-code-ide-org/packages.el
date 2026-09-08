;; -*- no-byte-compile: t; -*-
;;; tools/claude-code-ide-org/packages.el

;; Requires org 9.7+ (org-element-type-p / org-element-contents-end);
;; config.el enforces this at load.  Doom's straight-managed org
;; satisfies it; the org bundled with Emacs 29 (9.6.x) does not.
;;
;; org-ql (for org_query) is the only additional package required.
;; Depends on claude-code-ide, which must be declared in your root packages.el:
;;
;;   (package! claude-code-ide
;;     :recipe (:host github :repo "manzaltu/claude-code-ide.el"))

(package! org-ql
  :recipe (:host github :repo "alphapapa/org-ql"))
