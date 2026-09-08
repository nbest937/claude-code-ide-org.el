;;; check-org-dev-skill.el --- doctest for org-dev/SKILL.md claims -*- lexical-binding: t; -*-
;;
;; The elisp core of bin/check-org-dev-skill, loaded into the RUNNING
;; Emacs via emacsclient by that thin sh stub (TODO.org :ID: 84b7d8b3:
;; needs-live-Emacs scripts keep their logic in elisp).  Most of these
;; checks interrogate live state -- the MCP port, loaded org facilities,
;; Doom settings -- which is exactly why the fish original shelled to
;; emacsclient seven separate times; running inboard, the queries are
;; direct and the file checks come along for free.
;;
;; Verifies the *documentation* in org-dev/SKILL.md hasn't drifted from
;; the environment it describes -- the concrete facts it asserts (port
;; numbers, paths, facility names), not whether the skill's prose
;; triggers correctly (not scriptable; judged by spot-checking sessions).
;;
;; Writes one report line per check to REPORT-FILE and returns the fail
;; flag (0 or 1), which the stub turns into its exit code.  The
;; accumulator contract matches bin/lib/check.sh's: ok/FAIL/skip lines,
;; exit code is the verdict, output is for humans.

(defvar ccio-dev-check--lines nil)
(defvar ccio-dev-check--fail 0)

(defun ccio-dev-check--emit (line)
  (push line ccio-dev-check--lines))

(defun ccio-dev-check (desc got want)
  "Compare GOT against WANT, reporting under DESC."
  (if (equal got want)
      (ccio-dev-check--emit (format "ok   - %s" desc))
    (ccio-dev-check--emit (format "FAIL - %s: expected '%s', got '%s'"
                                  desc want got))
    (setq ccio-dev-check--fail 1)))

(defun ccio-dev-check-ok (desc)
  (ccio-dev-check--emit (format "ok   - %s" desc)))

(defun ccio-dev-check-fail (desc)
  (ccio-dev-check--emit (format "FAIL - %s" desc))
  (setq ccio-dev-check--fail 1))

(defun ccio-dev-check--file-head (path n)
  "First N bytes of PATH as a unibyte string, or nil."
  (when (file-readable-p path)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path nil 0 n)
      (buffer-string))))

(defun claude-code-ide-org-dev-skill-check (repo-root report-file)
  "Run every org-dev/SKILL.md accuracy check; write REPORT-FILE, return 0/1."
  (setq ccio-dev-check--lines nil
        ccio-dev-check--fail 0)
  (let ((default-directory repo-root))

    ;; 1. MCP server port pinned in the running Doom config, matching
    ;; .mcp.json.
    (ccio-dev-check "emacsclient MCP port"
                    (if (fboundp 'claude-code-ide-mcp-server-get-port)
                        (format "%s" (claude-code-ide-mcp-server-get-port))
                      "unreachable")
                    "45571")
    (let ((mcp-json (expand-file-name ".mcp.json" repo-root)))
      (ccio-dev-check ".mcp.json port matches"
                      (or (and (file-readable-p mcp-json)
                               (with-temp-buffer
                                 (insert-file-contents mcp-json)
                                 (and (re-search-forward "localhost:\\([0-9]+\\)" nil t)
                                      (match-string 1))))
                          "missing")
                      "45571"))

    ;; 2. Each skill is a plain-text SKILL.md at its native-format path.
    (dolist (rel '(".claude/skills/org/SKILL.md"
                   ".claude/skills/org-dev/SKILL.md"))
      (let ((full (expand-file-name rel repo-root)))
        (if (file-exists-p full)
            (ccio-dev-check (format "%s is plain text (not zip)" rel)
                            (if (equal (ccio-dev-check--file-head full 2) "PK")
                                "zip" "text")
                            "text")
          (ccio-dev-check (format "%s exists" rel) "missing" full))))

    ;; 3. bin/test's build-* glob resolves to a real straight org checkout.
    ;; `seq-find #'file-directory-p', not `car': the regexp also matches
    ;; build-29.4-cache.el, a FILE the fish original's `find -type d'
    ;; excluded -- and car picked it, failing the check against a healthy
    ;; install on this script's very first run.
    (let* ((straight (expand-file-name "~/.config/emacs/.local/straight"))
           (build (seq-find #'file-directory-p
                            (and (file-directory-p straight)
                                 (directory-files straight t "\\`build-" t)))))
      (if (and build (file-directory-p (expand-file-name "org" build)))
          (ccio-dev-check-ok (format "bin/test build-* glob resolves (%s/org)" build))
        (ccio-dev-check-fail "bin/test build-* glob did not resolve to a directory containing org/")))

    ;; 4. org-dev/SKILL.md describes the tool-registration block by
    ;; anchor ("the last top-level form"), not line number, so a
    ;; config.el edit can't put the doc out of date.  Verify that claim
    ;; structurally: the block exists, and nothing is defined after it.
    (let ((config-el (expand-file-name
                      "modules/tools/claude-code-ide-org/config.el" repo-root)))
      (with-temp-buffer
        (insert-file-contents config-el)
        (goto-char (point-min))
        (if (not (re-search-forward "with-eval-after-load 'claude-code-ide" nil t))
            (ccio-dev-check-fail "config.el: with-eval-after-load 'claude-code-ide anchor not found")
          (let ((anchor-line (line-number-at-pos))
                last-line)
            (goto-char (point-min))
            (while (re-search-forward "^(" nil t)
              (setq last-line (line-number-at-pos)))
            (ccio-dev-check "config.el tool-registration block is the last top-level form"
                            last-line anchor-line)))))

    ;; 5. Section 0b points at paths inside the straight org checkout.
    ;; Those paths ARE the section -- a reader who cannot find the source
    ;; falls back to guessing -- and they rot when straight relayouts.
    (let ((org-repo (expand-file-name "~/.config/emacs/.local/straight/repos/org")))
      (dolist (rel '("lisp/org-id.el" "lisp/org-archive.el"
                     "lisp/org-datetree.el" "doc/org-manual.org" "etc/ORG-NEWS"))
        (if (file-exists-p (expand-file-name rel org-repo))
            (ccio-dev-check-ok (format "org-dev 0b path exists (%s)" rel))
          (ccio-dev-check-fail
           (format "org-dev 0b cites %s under %s, which does not exist" rel org-repo)))))

    ;; 6. Section 0b names org facilities this repo leans on rather than
    ;; reimplementing.  The requires are load-bearing, not tidy: most of
    ;; these names are NOT autoloaded, so a bare fboundp answers "did
    ;; this session happen to load the file", not "does this Emacs have
    ;; it".  Measured 2026-08-31: the same check passed at 11:23 and
    ;; failed at 12:08 against the same org 9.8.7, the difference being
    ;; an archive had pulled org-datetree in.
    (require 'org)
    (ignore-errors (require 'org-id))
    (ignore-errors (require 'org-archive))
    (ignore-errors (require 'org-datetree))
    (dolist (fn '(org-add-archive-files org-id-locations org-id-search-archives
                  org-datetree-find-create-hierarchy org-datetree-comparefun-from-regex
                  org-archive-reversed-order org-agenda-prefix-format))
      (if (or (fboundp fn) (boundp fn))
          (ccio-dev-check-ok (format "org facility still exists (%s)" fn))
        (ccio-dev-check-fail
         (format "org-dev 0b names %s, which this Emacs does not have" fn))))

    ;; 7. Two Doom settings this project leans on that nothing else
    ;; asserts.  Behavioural, not a text diff against SKILL.md's prose:
    ;; §7 stopped quoting the config on 2026-08-28 precisely because a
    ;; transcription drifts and cannot be checked by reading it.
    ;;
    ;; Not asserted, deliberately: the org-todo-keywords sequence.  It
    ;; disagrees with TODO.org's own `#+TODO:' and nothing is broken,
    ;; because a buffer-local header wins -- a check failing on a latent
    ;; inconsistency is one people learn to ignore.
    (ccio-dev-check "find-file-visit-truename is set (symlinked TODO.org opens once)"
                    (if find-file-visit-truename "t" "nil") "t")

    ;; Must resolve inside this repo; unset falls back to
    ;; `org-default-notes-file' and targetless captures land in
    ;; ~/org/notes.org (TODO.org :ID: bd482c92).  Compared through
    ;; `file-truename', since the config deliberately names the symlink.
    ;; Against the COMMON git dir's parent, not repo-root: a worktree
    ;; invokes this from a root the live Emacs never loaded, and
    ;; comparing against it misreports "different checkout" as a
    ;; capture-file misconfiguration (TODO.org :ID: f8c86914).
    (let* ((common (string-trim
                    (with-temp-buffer
                      (if (eq 0 (call-process "git" nil t nil
                                              "-C" repo-root "rev-parse"
                                              "--path-format=absolute"
                                              "--git-common-dir"))
                          (buffer-string)
                        ""))))
           (main-root (if (string-empty-p common)
                          repo-root
                        (directory-file-name (file-name-directory common)))))
      (ccio-dev-check "claude-code-ide-org-capture-file resolves into this repo (via the common git dir)"
                      (if (boundp 'claude-code-ide-org-capture-file)
                          (file-truename claude-code-ide-org-capture-file)
                        "unbound")
                      (expand-file-name "TODO.org" main-root))))

  (with-temp-file report-file
    (insert (mapconcat #'identity (nreverse ccio-dev-check--lines) "\n") "\n"))
  ccio-dev-check--fail)

(provide 'check-org-dev-skill)
;;; check-org-dev-skill.el ends here
