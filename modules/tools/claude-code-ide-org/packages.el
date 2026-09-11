;; -*- no-byte-compile: t; -*-
;;; tools/claude-code-ide-org/packages.el

;; Requires org 9.7+ (org-element-type-p / org-element-contents-end);
;; config.el enforces this at load.  Doom's straight-managed org
;; satisfies it; the org bundled with Emacs 29 (9.6.x) does not.
;;
;; The module declares its own host dependency (TODO.org :ID: e3caa21f):
;; Doom's package! merges duplicate declarations key-by-key with the
;; user's private packages.el processed last, so a root declaration --
;; the old hand-paste this replaces -- simply overrides per key and is
;; no longer required.  Pinned to the commit the module is developed
;; against; the module owning the dependency means owning which
;; revision is expected.  Re-verify the pin when deliberately upgrading
;; claude-code-ide.
(package! claude-code-ide
  :recipe (:host github :repo "manzaltu/claude-code-ide.el")
  :pin "1de17bbadc650962a05fd68463fdff71697ec649")  ; 2026-07-21

;; Pin org to the same commit Doom's :lang org pins (lang/org/packages.el,
;; Doom v2.2.0).  Without this, an init that enables only this module gets
;; org as an UNPINNED transitive dependency -- straight clones the mirror's
;; tip, a moving pre-release (10.0-pre on 2026-09-10) that no :lang org
;; user runs (TODO.org :ID: 4f8b5d99).  Straight's default org recipe
;; already targets the same emacs-straight mirror, so the pin alone aligns
;; the two paths; when :lang org IS enabled the identical pin makes this
;; declaration a no-op.  Declared before org-ql, matching Doom's own
;; ordering in lang/org; a fresh sandbox sync was verified to clone org
;; at this pin with this ordering (whether the order is load-bearing was
;; not isolated).  Keep in sync with Doom's pin; re-verify at a Doom
;; upgrade.  The version floor (org 9.7+) is enforced separately by
;; config.el at load.
(package! org
  :pin "cdc16898fd46a30d7187c0a5830b2b898ffbd2de")  ; release_9.8.7

(package! org-ql
  :recipe (:host github :repo "alphapapa/org-ql"))
