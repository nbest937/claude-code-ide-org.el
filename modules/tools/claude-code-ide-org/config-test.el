;;; tools/claude-code-ide-org/config-test.el -*- lexical-binding: t; -*-
;;
;; ERT tests for the MCP tool wrappers in config.el.  Run with:
;;
;;   bin/test
;;
;; or directly:
;;
;;   emacs --batch -Q -l config.el -l config-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'org)
(require 'org-id)
(require 'org-clock)
(require 'json)

;;; Fixture -----------------------------------------------------------------

(defmacro claude-code-ide-org-test--with-heading (&rest body)
  "Create a scratch org file with one TODO heading and run BODY there.
Binds `id' to the heading's :ID: property, `file' to the org
file's path, and `archive-file' to the archive target's path.
Everything lives under a fresh temp directory that is deleted
afterwards, and org-id's global location cache is redirected
there too so tests never touch real user state. Also redirects
`claude-code-ide-org-clock-status-file' into the same temp
directory, so the many tests here that clock in/out incidentally
(not just the dedicated clock-status-file tests) never write a
stray clock-status.json into the real module directory."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "claude-code-ide-org-test" t)))
          (file (expand-file-name "test.org" dir))
          (archive-file (expand-file-name "DONE.org" dir))
          (org-id-locations-file (expand-file-name ".org-id-locations" dir))
          (org-id-locations (make-hash-table :test 'equal))
          (org-id-files nil)
          (org-clock-persist nil)
          (org-clock-history nil)
          (claude-code-ide-org-clock-status-file (expand-file-name "clock-status.json" dir))
          (claude-code-ide-org--audit-pending nil)
          (claude-code-ide-org--log-source nil)
          (claude-code-ide-org--planning-owner-session-id nil)
          (id "test-0001"))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "#+TODO: TODO NEXT(n!) PLANNING(p!) DOING(d!) WAIT(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n"
                     "#+TAGS: code comms research review\n"
                     "#+ARCHIVE: DONE.org::* Done\n"
                     "\n"
                     "* TODO Test heading                                                 :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       " id "\n"
                     ":END:\n"))
           (find-file file)
           (org-id-update-id-locations (list file))
           ,@body)
       (when (org-clocking-p) (org-clock-out))
       (dolist (path (list file archive-file))
         (let ((buf (get-file-buffer path)))
           (when buf
             (with-current-buffer buf (set-buffer-modified-p nil))
             (kill-buffer buf))))
       (delete-directory dir t))))

(defun claude-code-ide-org-test--disk-contents (path)
  "Return the on-disk contents of PATH, bypassing any Emacs buffer."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun claude-code-ide-org-test--sha256-disk (path)
  "Independently compute the sha256 of PATH's on-disk bytes, the same
way `claude-code-ide-org--sha256-file' does (a literal read straight
from disk into a temp buffer, never through any buffer visiting
PATH), so audit-log assertions can cross-check the logged hash
against a value computed fresh at the moment the test calls this,
rather than trusting the production code's own bookkeeping."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(defun claude-code-ide-org-test--audit-log-entries (file)
  "Return the JSONL audit log entries covering FILE, oldest first,
each as an alist (json-read's default object representation). Reads
straight from disk via `claude-code-ide-org--audit-log-path', the
same path resolution the production code itself uses. Empty list if
the log file does not exist (nothing has been flushed yet)."
  (let ((path (claude-code-ide-org--audit-log-path file)))
    (if (not (file-exists-p path))
        nil
      (let (entries)
        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (while (not (eobp))
            (let ((line (buffer-substring (line-beginning-position) (line-end-position))))
              (unless (string-empty-p line)
                (push (json-read-from-string line) entries)))
            (forward-line 1)))
        (nreverse entries)))))

;;; claude-code-ide-org-clock-in ---------------------------------------------

(ert-deftest claude-code-ide-org-test-clock-in-opens-logbook-and-saves ()
  (claude-code-ide-org-test--with-heading
    (let ((result (claude-code-ide-org-clock-in id)))
      (should (string-match-p "\\`Clocked in: \"Test heading\"\\'" result)))
    (should (org-clocking-p))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (should (string-match-p "CLOCK: \\[" (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-clock-in-saves-auto-closed-previous-buffer-in-other-file ()
  "Regression test: `org-clock-in' auto-closes whatever clock was
already running before opening the new one. When that previously-
clocked heading lives in a DIFFERENT file than the one being clocked
into, org_clock_in must save that other buffer too -- not just the
buffer of the heading it was asked to clock into. Live-caught
2026-07-29: clocking into a scratch heading in another file silently
left TODO.org's buffer modified (the auto-closed CLOCK line never
persisted to disk) until an explicit save-buffer."
  (claude-code-ide-org-test--with-heading
    (let ((other-file (expand-file-name "other.org" dir)))
      (with-temp-file other-file
        (insert (concat "#+TODO: TODO NEXT(n!) PLANNING(p!) DOING(d!) WAIT(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n"
                         "#+TAGS: code comms research review\n"
                         "\n"
                         "* TODO Other heading                                               :code:\n"
                         ":PROPERTIES:\n"
                         ":ID:       test-0002\n"
                         ":END:\n")))
      (find-file other-file)
      (org-id-update-id-locations (list file other-file))
      (unwind-protect
          (progn
            (claude-code-ide-org-clock-in id)
            (should (equal "Clocked in: \"Other heading\""
                            (claude-code-ide-org-clock-in "test-0002")))
            (should (not (buffer-modified-p (get-file-buffer file))))
            (should (not (buffer-modified-p (get-file-buffer other-file))))
            (should (string-match-p "CLOCK: \\[.*\\]--\\[.*\\] =>"
                                    (claude-code-ide-org-test--disk-contents file))))
        (when (org-clocking-p) (org-clock-out))
        (let ((buf (get-file-buffer other-file)))
          (when buf
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))))))

;;; claude-code-ide-org-clock-out ---------------------------------------------

(ert-deftest claude-code-ide-org-test-clock-out-closes-and-saves ()
  "Regression test: org_clock_out must persist the closed clock to disk.
It previously reported success while leaving the closed CLOCK entry
only in the buffer, never calling `save-buffer'."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    ;; Back-date the already-written open CLOCK line's timestamp text
    ;; — `org-clock-out' parses the start time directly from the
    ;; buffer (see org-clock.el's own `org-clock-out'), not from any
    ;; elisp variable — so the resulting interval survives on-the-fly
    ;; consolidation's zero-duration rounding. A same-instant clock-
    ;; in/out would otherwise round to 0:00 and be dropped by design
    ;; (see claude-code-ide-org-test-consolidate-history-rounds-
    ;; merges-and-drops-zero), which isn't what this particular test
    ;; means to exercise.
    (with-current-buffer (get-file-buffer file)
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "CLOCK: \\[[^]]+\\]")
        (replace-match (format-time-string "CLOCK: [%Y-%m-%d %a %H:%M]"
                                            (time-subtract (current-time) 600))))
      (save-buffer))
    (let* ((org-clock-out-remove-zero-time-clocks nil)
           (result (claude-code-ide-org-clock-out)))
      (should (string-match-p "\\`Clocked out: \"Test heading\" (id: test-0001)\\'" result)))
    (should (not (org-clocking-p)))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (should (string-match-p "CLOCK: \\[.*\\]--\\[.*\\] =>"
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-clock-out-suppresses-zero-time-removal ()
  "org_clock_out must not let a global org-clock-out-remove-zero-time-
clocks setting (t in this user's real Doom config -- not anything this
project itself sets, and not loaded at all under `bin/test's `-Q' batch
environment, hence the explicit `t' binding here) delete a CLOCK line
via org's own raw-duration check before
`claude-code-ide-org-consolidate-history' gets a chance to apply this
project's own rounding-aware version of the same intent (see
`claude-code-ide-org--consolidate-logbook-text's docstring).  Verified
directly by capturing the dynamic value `org-clock-out-remove-zero-
time-clocks' actually has at the moment org-clock.el's own
`org-clock-out' runs -- must be nil there even though the test's own
outer binding, simulating Doom's override, is t.  A same-minute clock-
in/out is exactly the case org's raw check targets (its duration
computation is minute-resolution, so any raw duration under a full
minute floors to 0h0m); at that same resolution, this project's own
rounding would independently reach the same drop decision for an
isolated interval, so asserting on final disk content alone cannot
distinguish buggy from fixed here -- only capturing the dynamic
binding proves the actual mechanism is in place."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (let ((org-clock-out-remove-zero-time-clocks t)
          (seen-value 'unset))
      (advice-add 'org-clock-out :before
                  (lambda (&rest _)
                    (setq seen-value org-clock-out-remove-zero-time-clocks))
                  '((name . claude-code-ide-org-test--capture-zero-time-clocks-value)))
      (unwind-protect
          (claude-code-ide-org-clock-out)
        (advice-remove 'org-clock-out
                        'claude-code-ide-org-test--capture-zero-time-clocks-value))
      (should (eq seen-value nil)))))

(ert-deftest claude-code-ide-org-test-clock-out-safe-when-no-clock ()
  (claude-code-ide-org-test--with-heading
    (should (equal "No clock is currently running." (claude-code-ide-org-clock-out)))))

(ert-deftest claude-code-ide-org-test-clock-out-consolidates-on-the-fly ()
  "org_clock_out must consolidate the heading it just closed
immediately, without a separate consolidate-history call. Proven by:
a manual consolidate-history call right afterward is already a
no-op, which can only be true if clock-out already ran it."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (with-current-buffer (get-file-buffer file)
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "CLOCK: \\[[^]]+\\]")
        (replace-match (format-time-string "CLOCK: [%Y-%m-%d %a %H:%M]"
                                            (time-subtract (current-time) 600))))
      (save-buffer))
    (claude-code-ide-org-clock-out)
    (let ((before (claude-code-ide-org-test--disk-contents file)))
      (should (equal "Nothing to consolidate on \"Test heading\""
                     (claude-code-ide-org-consolidate-history id)))
      (should (equal before (claude-code-ide-org-test--disk-contents file))))))

;;; Clock status file -------------------------------------------------------

(ert-deftest claude-code-ide-org-test-clock-status-file-reflects-active-clock ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (should (file-exists-p claude-code-ide-org-clock-status-file))
    (let ((status (json-read-file claude-code-ide-org-clock-status-file)))
      (should (eq t (cdr (assq 'active status))))
      (should (equal "Test heading" (cdr (assq 'heading status))))
      (should (equal id (cdr (assq 'id status))))
      (should (stringp (cdr (assq 'start status)))))))

(ert-deftest claude-code-ide-org-test-clock-status-file-reflects-idle-on-clock-out ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (claude-code-ide-org-clock-out)
    (let ((status (json-read-file claude-code-ide-org-clock-status-file)))
      (should (eq :json-false (cdr (assq 'active status))))
      (should (null (assq 'heading status))))))

(ert-deftest claude-code-ide-org-test-clock-status-file-noop-when-directory-missing ()
  "The status write must fail silently, without erroring back into
org's own clock-in machinery, when its target directory does not
(yet) exist."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-clock-status-file
           (expand-file-name "no-such-subdir/clock-status.json" dir)))
      (should (equal "Clocked in: \"Test heading\"" (claude-code-ide-org-clock-in id)))
      (should (not (file-exists-p claude-code-ide-org-clock-status-file))))))

;;; :SESSIONS: bracketing log --------------------------------------------------

(ert-deftest claude-code-ide-org-test-clock-in-out-log-sessions-drawer ()
  "org_clock_in/org_clock_out must log to :SESSIONS:, separately from
the :LOGBOOK: CLOCK entries, so the full pause/resume history survives
even when CLOCK entries themselves get fragmented into short bursts."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (claude-code-ide-org-clock-out)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p ":SESSIONS:" disk))
      (should (string-match-p "- Resumed \\[" disk))
      (should (string-match-p "- Paused \\[" disk)))))

(ert-deftest claude-code-ide-org-test-session-pause-closes-clock ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (claude-code-ide-org-session-pause)
    (should (not (org-clocking-p)))
    (should (string-match-p "- Paused \\["
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-session-resume-resumes-same-heading ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (claude-code-ide-org-session-pause)
    (let ((result (claude-code-ide-org-session-resume)))
      (should (string-match-p "\\`Resumed: \"Test heading\"\\'" result)))
    (should (org-clocking-p))
    (should (equal id (org-with-point-at org-clock-marker (org-id-get))))
    (let* ((disk (claude-code-ide-org-test--disk-contents file))
           (pos-1 (string-match "- Resumed \\[" disk))
           (pos-2 (and pos-1 (string-match "- Paused \\[" disk (match-end 0))))
           (pos-3 (and pos-2 (string-match "- Resumed \\[" disk (match-end 0)))))
      ;; Resumed, Paused, Resumed — in that order.
      (should (and pos-1 pos-2 pos-3 (< pos-1 pos-2) (< pos-2 pos-3))))))

(ert-deftest claude-code-ide-org-test-session-resume-noop-when-already-clocking ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (should (equal "Already clocking; nothing to resume."
                   (claude-code-ide-org-session-resume)))))

(ert-deftest claude-code-ide-org-test-session-resume-noop-when-no-history ()
  (claude-code-ide-org-test--with-heading
    (should (equal "No paused task to resume."
                   (claude-code-ide-org-session-resume)))))

(ert-deftest claude-code-ide-org-test-session-resume-noop-when-history-head-done ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (claude-code-ide-org-session-pause)
    (claude-code-ide-org-set-todo id "DONE")
    (should (equal "Most recently paused task is already DONE; nothing to resume."
                   (claude-code-ide-org-session-resume)))
    (should (not (org-clocking-p)))))

;;; Session identity (concurrent Claude Code sessions) ----------------------
;;
;; Covers claude-code-ide-org--clock-owner-session-id and the guards it
;; drives in session-pause/session-resume — TODO.org :ID:
;; 337f7fb2-b9e9-4c02-82dd-d88e60df364b. All five tests above call both
;; functions with zero arguments and must keep passing unchanged; these
;; new tests exercise the optional session-id argument specifically.

(ert-deftest claude-code-ide-org-test-session-pause-noop-for-different-session-owner ()
  "A session must not be able to pause a clock owned by a different
session — the whole point of the concurrency fix."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (claude-code-ide-org-session-pause "session-A")
    (claude-code-ide-org-session-resume "session-A")
    (should (org-clocking-p))
    (should (equal "Clock is owned by a different session; not pausing."
                   (claude-code-ide-org-session-pause "session-B")))
    (should (org-clocking-p))
    (should (equal id (org-with-point-at org-clock-marker (org-id-get))))))

(ert-deftest claude-code-ide-org-test-session-pause-succeeds-for-matching-session-owner ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (claude-code-ide-org-session-pause "session-A")
    (claude-code-ide-org-session-resume "session-A")
    (should (equal "Clocked out: \"Test heading\" (id: test-0001)"
                   (claude-code-ide-org-session-pause "session-A")))
    (should (not (org-clocking-p)))))

(ert-deftest claude-code-ide-org-test-session-pause-with-no-session-id-ignores-owner ()
  "A manual/legacy call with no session-id (the default, e.g. a Claude
Code version whose hook payload omits it) must still pause
unconditionally, exactly as before this feature existed, regardless of
any recorded owner."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (claude-code-ide-org-session-pause "session-A")
    (claude-code-ide-org-session-resume "session-A")
    (should (org-clocking-p))
    (should (equal "Clocked out: \"Test heading\" (id: test-0001)"
                   (claude-code-ide-org-session-pause)))
    (should (not (org-clocking-p)))))

(ert-deftest claude-code-ide-org-test-session-resume-noop-for-different-session-owner ()
  "A session must not be able to steal an actively-running clock owned
by a different session — the other half of the concurrency fix."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (claude-code-ide-org-session-pause "session-A")
    (claude-code-ide-org-session-resume "session-A")
    (should (org-clocking-p))
    (should (equal "Clock is owned by a different session; not resuming."
                   (claude-code-ide-org-session-resume "session-B")))
    (should (org-clocking-p))
    (should (equal id (org-with-point-at org-clock-marker (org-id-get))))))

(ert-deftest claude-code-ide-org-test-session-resume-logs-session-id-in-drawer ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (claude-code-ide-org-session-pause "session-A")
    (claude-code-ide-org-session-resume "session-A")
    (should (string-match-p "- Resumed \\[[^]]+\\] (session session-A)"
                            (claude-code-ide-org-test--disk-contents file)))))

;;; claude-code-ide-org-set-todo -----------------------------------------------

(ert-deftest claude-code-ide-org-test-set-todo-transitions-and-saves ()
  (claude-code-ide-org-test--with-heading
    (let ((result (claude-code-ide-org-set-todo id "DOING")))
      ;; The `(was TODO)' clause is load-bearing, not cosmetic:
      ;; bin/hooks/queue-append parses it back out to record the `from'
      ;; state on the queued event (TODO.org :ID: f9f61c04-...).
      (should (string-match-p "\\`TODO state set to DOING (was TODO): \"Test heading\"\\'" result)))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (should (string-match-p "^\\* DOING Test heading"
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-set-todo-reports-none-for-keywordless-heading ()
  "A heading carrying no TODO keyword at all must report `(was none)',
not an empty string. bin/hooks/queue-append recovers the prior state
from this reply by regexp; `(was )' would parse to an empty `from'
that is indistinguishable from a missing one, and the review command's
stale-transition check would then silently not fire (TODO.org :ID:
f9f61c04-150b-4ee7-96c9-582cf2bda95a)."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* Bare heading                                                     :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0003\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (should (string-match-p "\\`TODO state set to NEXT (was none): \"Bare heading\"\\'"
                            (claude-code-ide-org-set-todo "test-0003" "NEXT")))))

(ert-deftest claude-code-ide-org-test-set-todo-suppresses-native-logging-for-every-state ()
  "org_set_todo must suppress org's own native state-change logging
for every STATE, not just `@'-flagged ones -- confirmed live that even
a plain `!' marker's deferred log-line insertion blocks when triggered
non-interactively (see TODO.org :ID:
04d0e7d5-ab6b-4972-925d-d517484c7595), so `org-inhibit-logging' is
unconditional in the wrapper. No native \"State ...\" line should
appear for a plain NEXT transition through org_set_todo."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-set-todo id "NEXT")
    (should (not (string-match-p "State \"NEXT\""
                                 (claude-code-ide-org-test--disk-contents file))))))

(ert-deftest claude-code-ide-org-test-set-todo-reports-success-when-hook-cascade-moves-point ()
  "Regression test, found live: setting a heading to NEXT through
org_set_todo while a sibling is already NEXT triggers the demote hook,
which visits and edits that OTHER sibling via its own org-with-point-
at/org-todo calls. org_set_todo's own post-transition check must not
be fooled by point having moved off the original heading -- it must
still report success for the heading actually requested, not silently
describe whatever heading point happens to be sitting on afterward."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* NEXT Sibling B                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let ((result (claude-code-ide-org-set-todo id "NEXT")))
      (should (string-match-p "\\`TODO state set to NEXT (was TODO): \"Test heading\"\\'" result)))
    (should (equal "NEXT" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))
    (should (equal "TODO" (org-with-point-at (org-id-find "test-0002" 'marker) (org-get-todo-state))))))

(ert-deftest claude-code-ide-org-test-set-todo-suppresses-interactive-note-for-wait-and-cancelled ()
  "WAIT and CANCELLED are `@'-flagged (note required) in this project's
`#+TODO:' line -- the case org_set_todo's blanket org-inhibit-logging
protection most obviously needs to cover. Going through the
non-interactive `org_set_todo' path must never pop org's interactive
`*Org Note*' buffer for either."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-set-todo id "WAIT")
    (should (not (get-buffer "*Org Note*")))
    (claude-code-ide-org-set-todo id "CANCELLED")
    (should (not (get-buffer "*Org Note*")))))

;;; claude-code-ide-org-archive ------------------------------------------------

(ert-deftest claude-code-ide-org-test-archive-moves-heading-and-saves ()
  "Regression test: org_archive must persist the cut subtree to the
source file, not just the archive target. It previously left the
source file's on-disk copy of the heading in place, since
`org-archive-subtree' was never followed by `save-buffer'."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-set-todo id "DONE")
    (let ((result (claude-code-ide-org-archive id)))
      (should (string-match-p "\\`Archived: \"Test heading\"\\'" result)))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (should (not (string-match-p "Test heading"
                                 (claude-code-ide-org-test--disk-contents file))))
    (should (file-exists-p archive-file))
    (let ((archived (claude-code-ide-org-test--disk-contents archive-file)))
      (should (string-match-p "Test heading" archived))
      (should (string-match-p ":ID: +test-0001" archived))
      (should (string-match-p ":ARCHIVE_TODO: +DONE" archived)))))

;;; Tool-call audit log ---------------------------------------------------

(ert-deftest claude-code-ide-org-test-audit-log-real-timer-fires-without-manual-flush ()
  "Integration check for the one link every other audit-log test
deliberately bypasses by calling `claude-code-ide-org--audit-flush'
by hand: that the zero-delay `run-at-time' timer queued by
`claude-code-ide-org--audit-queue' actually fires on its own once
Emacs goes idle, with no explicit flush call anywhere in this test.
Without this, every other test could pass while the real MCP/
interactive path never wrote a single log line, because nothing
would ever call flush in production. `sleep-for' pumps Emacs's timer
queue even in `--batch' mode, which is what lets this run
deterministically under ERT."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (sleep-for 0.2)
    (let ((entry (car (last (claude-code-ide-org-test--audit-log-entries file)))))
      (should entry)
      (should (equal "org_clock_in" (cdr (assq 'tool entry))))
      (should (equal id (cdr (assq 'id entry))))
      (should (equal "saved" (cdr (assq 'result entry)))))))

(ert-deftest claude-code-ide-org-test-audit-log-clock-in-out-hashes-match-disk ()
  "A normal, correctly-behaving clock-in/out (going through the MCP
wrappers, which do call `save-buffer') must produce JSONL audit
entries whose before/after sha256 fields equal independently
computed hashes of the file's actual on-disk content at those two
points in time -- proving the audit log's hashes are trustworthy,
not merely present, and that they differ (a real mutation reached
disk) rather than accidentally matching."
  (claude-code-ide-org-test--with-heading
    (let ((before-in (claude-code-ide-org-test--sha256-disk file)))
      (claude-code-ide-org-clock-in id)
      (claude-code-ide-org--audit-flush)
      (let* ((after-in (claude-code-ide-org-test--sha256-disk file))
             (entry (car (last (claude-code-ide-org-test--audit-log-entries file)))))
        (should entry)
        (should (equal "org_clock_in" (cdr (assq 'tool entry))))
        (should (equal id (cdr (assq 'id entry))))
        (should (equal file (cdr (assq 'file entry))))
        (should (equal before-in (cdr (assq 'before_sha256 entry))))
        (should (equal after-in (cdr (assq 'after_sha256 entry))))
        (should (not (equal before-in after-in)))
        (should (equal "saved" (cdr (assq 'result entry))))))
    ;; Back-date the already-written open CLOCK line so clock-out's
    ;; interval doesn't round to zero duration and get dropped by
    ;; on-the-fly consolidation -- same concern as the existing
    ;; claude-code-ide-org-test-clock-out-closes-and-saves regression
    ;; test above.
    (with-current-buffer (get-file-buffer file)
      (save-excursion
        (goto-char (point-min))
        (re-search-forward "CLOCK: \\[[^]]+\\]")
        (replace-match (format-time-string "CLOCK: [%Y-%m-%d %a %H:%M]"
                                            (time-subtract (current-time) 600))))
      (save-buffer))
    (let ((before-out (claude-code-ide-org-test--sha256-disk file))
          (org-clock-out-remove-zero-time-clocks nil))
      (claude-code-ide-org-clock-out)
      (claude-code-ide-org--audit-flush)
      (let* ((after-out (claude-code-ide-org-test--sha256-disk file))
             (entry (car (last (claude-code-ide-org-test--audit-log-entries file)))))
        (should entry)
        (should (equal "org_clock_out" (cdr (assq 'tool entry))))
        (should (equal id (cdr (assq 'id entry))))
        (should (equal before-out (cdr (assq 'before_sha256 entry))))
        (should (equal after-out (cdr (assq 'after_sha256 entry))))
        (should (not (equal before-out after-out)))
        (should (equal "saved" (cdr (assq 'result entry))))))))

(ert-deftest claude-code-ide-org-test-audit-log-detects-unsaved-mismatch ()
  "The exact bug class this feature exists to catch: a mutation lands
in the buffer but never reaches disk, while the caller nonetheless
believes it succeeded. Simulated by calling `org-clock-in' directly
--- bypassing the wrapper, which would otherwise always save --- and
then flushing before any `save-buffer' happens. The audit log must
show before_sha256 == after_sha256 and flag the mismatch: exactly the
signal that would have caught the historical org_clock_out and
org_archive save-buffer bugs immediately instead of via ad-hoc manual
disk inspection."
  (claude-code-ide-org-test--with-heading
    (org-id-goto id)
    (org-clock-in)                      ; buffer mutated, deliberately NOT saved
    (claude-code-ide-org--audit-flush)  ; simulate Emacs going idle
    (let ((entry (car (last (claude-code-ide-org-test--audit-log-entries file)))))
      (should entry)
      (should (equal id (cdr (assq 'id entry))))
      (should (cdr (assq 'before_sha256 entry)))
      (should (equal (cdr (assq 'before_sha256 entry)) (cdr (assq 'after_sha256 entry))))
      (should (equal "UNSAVED-MISMATCH" (cdr (assq 'result entry)))))))

(ert-deftest claude-code-ide-org-test-audit-log-logs-hand-edits ()
  "Direct M-x-style manipulation -- never routed through any MCP
wrapper, so no wrapper ever let-binds `claude-code-ide-org--log-source'
-- must still be captured and attributed as \"hand-edit\". This is the
whole reason the audit hooks live at the org-native layer
(org-after-todo-state-change-hook here) instead of only inside the
wrappers: a hook-based PostToolUse-style approach could never see
this at all."
  (claude-code-ide-org-test--with-heading
    (org-id-goto id)
    (org-todo "DOING")   ; hand-edit: no wrapper, no let-bound source
    (save-buffer)        ; the human remembered to save this time
    (claude-code-ide-org--audit-flush)
    (let ((entry (car (last (claude-code-ide-org-test--audit-log-entries file)))))
      (should entry)
      (should (equal "hand-edit" (cdr (assq 'tool entry))))
      (should (equal id (cdr (assq 'id entry))))
      (should (equal "saved" (cdr (assq 'result entry))))
      (should (not (equal (cdr (assq 'before_sha256 entry)) (cdr (assq 'after_sha256 entry))))))))

(ert-deftest claude-code-ide-org-test-audit-log-attributes-archive ()
  "org_archive must be attributed by name, and audited against the
SOURCE file (the one the heading is cut from), not the archive
target -- since that's the file the original org_archive bug failed
to save."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-set-todo id "DONE")
    (claude-code-ide-org--audit-flush) ; drain the set-todo record first
    (claude-code-ide-org-archive id)
    (claude-code-ide-org--audit-flush)
    (let ((entry (car (last (claude-code-ide-org-test--audit-log-entries file)))))
      (should entry)
      (should (equal "org_archive" (cdr (assq 'tool entry))))
      (should (equal id (cdr (assq 'id entry))))
      (should (equal file (cdr (assq 'file entry))))
      (should (equal "saved" (cdr (assq 'result entry))))
      (should (not (equal (cdr (assq 'before_sha256 entry)) (cdr (assq 'after_sha256 entry))))))))

(ert-deftest claude-code-ide-org-test-set-todo-reports-blocked-transition ()
  "Regression test: org_set_todo must not report success when
org-blocker-hook actually refused the transition.  It previously
always echoed the requested STATE back regardless of whether
`org-todo' applied it, so a transition silently blocked by e.g.
org-enforce-todo-dependencies or org-depend's :BLOCKER: property
looked exactly like a success."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "** TODO Child heading\n")
    (let ((org-blocker-hook (list 'org-block-todo-from-children-or-siblings-or-parent))
          (org-enforce-todo-dependencies t))
      (should (string-match-p "\\`Error:.*blocked"
                              (claude-code-ide-org-set-todo id "DONE"))))
    (should (equal "TODO"
                   (org-with-point-at (org-id-find id 'marker)
                     (org-get-todo-state))))))

;;; claude-code-ide-org-refile --------------------------------------------

(ert-deftest claude-code-ide-org-test-refile-within-same-file ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* TODO Target heading                                              :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let ((result (claude-code-ide-org-refile id "test-0002")))
      (should (string-match-p "\\`Refiled: \"Test heading\" under \"Target heading\"\\'" result)))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      ;; Test heading is now a level-2 child, nested after Target heading.
      (should (string-match-p "^\\* TODO Target heading" disk))
      (should (string-match-p "^\\*\\* TODO Test heading" disk))
      (should (< (string-match "^\\* TODO Target heading" disk)
                 (string-match "^\\*\\* TODO Test heading" disk))))))

(ert-deftest claude-code-ide-org-test-refile-across-files-and-saves-both ()
  "Regression-shaped test for the exact bug class that already bit
org_archive and org_clock_out: refiling across two files must save
BOTH buffers, not just the one org-refile happens to leave point in."
  (claude-code-ide-org-test--with-heading
    (let ((target-file (expand-file-name "target.org" dir)))
      (with-temp-file target-file
        (insert (concat "#+TODO: TODO NEXT(n!) PLANNING(p!) DOING(d!) WAIT(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n"
                         "#+TAGS: code comms research review\n"
                         "\n"
                         "* TODO Target heading                                              :code:\n"
                         ":PROPERTIES:\n"
                         ":ID:       test-0002\n"
                         ":END:\n")))
      (find-file target-file)
      (org-id-update-id-locations (list file target-file))
      (unwind-protect
          (progn
            (let ((result (claude-code-ide-org-refile id "test-0002")))
              (should (string-match-p "\\`Refiled: \"Test heading\" under \"Target heading\"\\'" result)))
            (should (not (buffer-modified-p (get-file-buffer file))))
            (should (not (buffer-modified-p (get-file-buffer target-file))))
            (should (not (string-match-p "Test heading"
                                         (claude-code-ide-org-test--disk-contents file))))
            (let ((disk (claude-code-ide-org-test--disk-contents target-file)))
              (should (string-match-p "^\\* TODO Target heading" disk))
              (should (string-match-p "^\\*\\* TODO Test heading" disk))
              (should (string-match-p ":ID: +test-0001" disk))))
        (let ((buf (get-file-buffer target-file)))
          (when buf
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))))))

(ert-deftest claude-code-ide-org-test-refile-unresolvable-target-returns-error ()
  (claude-code-ide-org-test--with-heading
    (should (string-match-p
             "\\`Error: no org heading found with target :ID: \"bogus\"\\'"
             (claude-code-ide-org-refile id "bogus")))
    ;; No-op: source heading must be left completely untouched.
    (should (string-match-p "Test heading" (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-refile-unresolvable-source-returns-error ()
  (claude-code-ide-org-test--with-heading
    (should (string-match-p
             "\\`Error: no org heading found with :ID: \"bogus\"\\'"
             (claude-code-ide-org-refile "bogus" id)))))

(ert-deftest claude-code-ide-org-test-refile-into-own-subtree-returns-error ()
  "org-refile itself refuses to refile a heading into its own subtree
\(or into itself\); confirm that failure surfaces as an Error string
rather than escaping condition-case."
  (claude-code-ide-org-test--with-heading
    (should (string-match-p "\\`Error:" (claude-code-ide-org-refile id id)))
    (should (string-match-p "Test heading" (claude-code-ide-org-test--disk-contents file)))))

;;; Native transition enforcement (org-blocker-hook / org-trigger-hook) ----
;;
;; These cover claude-code-ide-org--blocker-clock-running-p and
;; claude-code-ide-org--trigger-auto-clock-in, registered globally on
;; org-blocker-hook/org-trigger-hook in config.el via with-eval-after-
;; load 'org. Being global hooks, they are already active for every
;; other test in this file too -- see the commentary at each call site
;; above for why that's harmless (e.g. claude-code-ide-org-test-set-
;; todo-reports-blocked-transition locally shadows org-blocker-hook via
;; `let', and no other existing test clocks in and then requests DONE
;; on the very same heading).

(ert-deftest claude-code-ide-org-test-blocker-hook-blocks-done-while-clock-running ()
  "org-blocker-hook must deny DONE while a clock is still running on
that heading -- structural enforcement inside org itself, catching
violations regardless of path. If claude-code-ide-org--trigger-auto-
clock-in already opened the clock when this heading became DOING,
the explicit clock-in below is a safe no-op (org-clock-in itself
recognizes clocking into the already-current task as a continuation,
not a new interval)."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-set-todo id "DOING")
    (unless (org-clocking-p) (claude-code-ide-org-clock-in id))
    (should (org-clocking-p))
    (should (string-match-p "\\`Error:.*blocked"
                            (claude-code-ide-org-set-todo id "DONE")))
    (should (org-clocking-p))
    (should (equal "DOING"
                    (org-with-point-at (org-id-find id 'marker)
                      (org-get-todo-state))))
    (should (string-match-p "^\\* DOING Test heading"
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-blocker-hook-permits-done-when-not-clocking ()
  "The DONE blocker must never fire when nothing is clocking at all --
only the presence of a running clock on that heading is grounds to
deny the transition."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-set-todo id "DOING")
    (when (org-clocking-p) (claude-code-ide-org-clock-out))
    (should (not (org-clocking-p)))
    (should (string-match-p "\\`TODO state set to DONE"
                            (claude-code-ide-org-set-todo id "DONE")))))

(ert-deftest claude-code-ide-org-test-blocker-hook-only-blocks-own-heading ()
  "The DONE blocker must only fire for a clock running on THAT exact
heading -- a clock running on a different heading in the same file
must never block this one from going DONE."
  (claude-code-ide-org-test--with-heading
    ;; Locally exclude the single-NEXT-per-level triggers: once `id'
    ;; goes DOING, `other-id' becomes the sole TODO survivor of a
    ;; 2-heading group with no NEXT, which the promote trigger would
    ;; otherwise (correctly, but incidentally to what this test is
    ;; about) flip to NEXT -- unrelated to the DONE-blocker behavior
    ;; under test here.
    (let ((org-trigger-hook (list #'claude-code-ide-org--trigger-auto-clock-in))
          (other-id "test-0002"))
      (goto-char (point-max))
      (insert (concat "* TODO Other heading                                               :code:\n"
                       ":PROPERTIES:\n"
                       ":ID:       " other-id "\n"
                       ":END:\n"))
      (save-buffer)
      (org-id-update-id-locations (list file))
      (claude-code-ide-org-set-todo id "DOING")
      (unless (org-clocking-p) (claude-code-ide-org-clock-in id))
      (should (org-clocking-p))
      ;; The clock is running on `id', not `other-id' -- going DONE on
      ;; `other-id' must be permitted.
      (should (string-match-p "\\`TODO state set to DONE (was TODO): \"Other heading\"\\'"
                              (claude-code-ide-org-set-todo other-id "DONE")))
      (should (equal "DONE"
                     (org-with-point-at (org-id-find other-id 'marker)
                       (org-get-todo-state))))
      ;; The unrelated running clock on `id' must be left untouched.
      (should (org-clocking-p))
      (should (equal id (org-with-point-at org-clock-marker
                          (org-entry-get nil "ID")))))))

(ert-deftest claude-code-ide-org-test-trigger-hook-auto-clocks-in-on-direct-org-todo ()
  "org-trigger-hook must auto-clock-in the moment DOING is set through
ANY path, not just claude-code-ide-org-set-todo -- this is the layer
that also catches hand-edits made directly in Emacs. Exercised via a
bare `org-todo' call, deliberately bypassing the wrapper entirely, to
prove the enforcement lives in org itself and not merely in
claude-code-ide-org-set-todo's own logic."
  (claude-code-ide-org-test--with-heading
    (should (not (org-clocking-p)))
    (org-with-point-at (org-id-find id 'marker)
      (org-todo "DOING"))
    (should (org-clocking-p))
    (should (equal id (org-with-point-at org-clock-marker
                        (org-entry-get nil "ID"))))
    ;; A bare `org-todo' call never saves the buffer -- that's
    ;; `claude-code-ide-org-set-todo's job, not org's own -- so check
    ;; the in-memory buffer for the CLOCK line, not the on-disk file.
    (should (string-match-p "CLOCK: \\["
                            (with-current-buffer (get-file-buffer file)
                              (buffer-string))))))

(ert-deftest claude-code-ide-org-test-trigger-hook-skips-clock-in-when-already-clocked-there ()
  "If a clock is already running on the heading being set to DOING
(e.g. via org_clock_in called ahead of the state change), the trigger
must not additionally invoke `org-clock-in' -- no second, duplicate
open CLOCK line."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (org-with-point-at (org-id-find id 'marker) (org-todo "DOING"))
    (should (org-clocking-p))
    (let ((disk (claude-code-ide-org-test--disk-contents file))
          (count 0) (start 0))
      (while (string-match "CLOCK: \\[" disk start)
        (setq count (1+ count) start (match-end 0)))
      (should (= 1 count)))))

(ert-deftest claude-code-ide-org-test-trigger-hook-does-not-fire-for-other-states ()
  "The auto-clock-in trigger must only fire on a transition TO DOING,
never on transitions to any other state."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker) (org-todo "NEXT"))
    (should (not (org-clocking-p)))
    (org-with-point-at (org-id-find id 'marker) (org-todo "WAIT"))
    (should (not (org-clocking-p)))))

(ert-deftest claude-code-ide-org-test-trigger-hook-auto-clocks-in-on-planning ()
  "org-trigger-hook must also auto-clock-in the moment PLANNING is set
-- TODO.org :ID: b95b9fba-f78e-48fe-8546-988709cce309 -- mirroring the
existing DOING coverage above."
  (claude-code-ide-org-test--with-heading
    (should (not (org-clocking-p)))
    (org-with-point-at (org-id-find id 'marker)
      (org-todo "PLANNING"))
    (should (org-clocking-p))
    (should (equal id (org-with-point-at org-clock-marker
                        (org-entry-get nil "ID"))))))

(ert-deftest claude-code-ide-org-test-trigger-hook-skips-clock-in-when-already-clocked-on-planning ()
  "No duplicate CLOCK line when a clock is already running on the
heading being set to PLANNING."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (org-with-point-at (org-id-find id 'marker) (org-todo "PLANNING"))
    (should (org-clocking-p))
    (let ((disk (claude-code-ide-org-test--disk-contents file))
          (count 0) (start 0))
      (while (string-match "CLOCK: \\[" disk start)
        (setq count (1+ count) start (match-end 0)))
      (should (= 1 count)))))

;;; PLANNING -> DOING promotion (ExitPlanMode) -------------------------------
;;
;; Covers claude-code-ide-org--maybe-record-planning-owner and
;; claude-code-ide-org--promote-planning-to-doing -- TODO.org :ID:
;; b95b9fba-f78e-48fe-8546-988709cce309, including the cross-session
;; guard added under design decision 4.

(defun claude-code-ide-org-test--write-json (payload)
  "Write PAYLOAD (an alist) as JSON to a fresh temp file and return its path."
  (let ((path (make-temp-file "claude-code-ide-org-test-payload")))
    (with-temp-file path (insert (json-encode payload)))
    path))

(ert-deftest claude-code-ide-org-test-promote-planning-to-doing-promotes-when-owner-matches ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (org-with-point-at (org-id-find id 'marker) (org-todo "PLANNING"))
    (setq claude-code-ide-org--planning-owner-session-id "session-A")
    (let ((result (claude-code-ide-org--promote-planning-to-doing "session-A")))
      (should (string-match-p "\\`Promoted \"Test heading\"" result)))
    (should (equal "DOING" (org-with-point-at (org-id-find id 'marker)
                             (org-get-todo-state))))
    (should (org-clocking-p))
    (should (null claude-code-ide-org--planning-owner-session-id))
    (let ((disk (claude-code-ide-org-test--disk-contents file))
          (count 0) (start 0))
      (while (string-match "CLOCK: \\[" disk start)
        (setq count (1+ count) start (match-end 0)))
      (should (= 1 count))
      (should (string-match-p "Auto-promoted" disk)))))

(ert-deftest claude-code-ide-org-test-promote-planning-to-doing-promotes-when-owner-nil ()
  "A hand-edited PLANNING state (no org_set_todo-recorded owner) must
still promote normally -- the permissive fallback for the ordinary
single-session/manual case."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (org-with-point-at (org-id-find id 'marker) (org-todo "PLANNING"))
    (should (null claude-code-ide-org--planning-owner-session-id))
    (let ((result (claude-code-ide-org--promote-planning-to-doing "session-A")))
      (should (string-match-p "\\`Promoted \"Test heading\"" result)))
    (should (equal "DOING" (org-with-point-at (org-id-find id 'marker)
                             (org-get-todo-state))))))

(ert-deftest claude-code-ide-org-test-promote-planning-to-doing-noop-for-different-owner ()
  "The cross-session guard this whole revision exists for: a different
session's ExitPlanMode must not promote a PLANNING heading it doesn't own."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (org-with-point-at (org-id-find id 'marker) (org-todo "PLANNING"))
    (setq claude-code-ide-org--planning-owner-session-id "session-A")
    (let ((result (claude-code-ide-org--promote-planning-to-doing "session-B")))
      (should (string-match-p "belongs to a different session" result)))
    (should (equal "PLANNING" (org-with-point-at (org-id-find id 'marker)
                               (org-get-todo-state))))
    (should (org-clocking-p))
    (should (equal "session-A" claude-code-ide-org--planning-owner-session-id))))

(ert-deftest claude-code-ide-org-test-promote-planning-to-doing-noop-when-clocked-state-not-planning ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (org-with-point-at (org-id-find id 'marker) (org-todo "DOING"))
    (let ((result (claude-code-ide-org--promote-planning-to-doing "session-A")))
      (should (string-match-p "not PLANNING" result)))
    (should (equal "DOING" (org-with-point-at (org-id-find id 'marker)
                            (org-get-todo-state))))))

(ert-deftest claude-code-ide-org-test-promote-planning-to-doing-noop-when-nothing-clocked ()
  (claude-code-ide-org-test--with-heading
    (should (not (org-clocking-p)))
    (let ((result (claude-code-ide-org--promote-planning-to-doing "session-A")))
      (should (string-match-p "\\`No clock running" result)))))

(ert-deftest claude-code-ide-org-test-maybe-record-planning-owner-sets-owner-for-planning ()
  (claude-code-ide-org-test--with-heading
    (let ((payload (claude-code-ide-org-test--write-json
                    `((session_id . "session-A")
                      (tool_input . ((state . "PLANNING") (id . ,id)))))))
      (unwind-protect
          (progn
            (claude-code-ide-org--maybe-record-planning-owner payload)
            (should (equal "session-A" claude-code-ide-org--planning-owner-session-id)))
        (delete-file payload)))))

(ert-deftest claude-code-ide-org-test-maybe-record-planning-owner-ignores-other-states ()
  (claude-code-ide-org-test--with-heading
    (let ((payload (claude-code-ide-org-test--write-json
                    `((session_id . "session-A")
                      (tool_input . ((state . "DOING") (id . ,id)))))))
      (unwind-protect
          (progn
            (claude-code-ide-org--maybe-record-planning-owner payload)
            (should (null claude-code-ide-org--planning-owner-session-id)))
        (delete-file payload)))))

;;; Single NEXT action per level (org-trigger-hook) -------------------------
;;
;; Cover claude-code-ide-org--trigger-demote-conflicting-next and
;; claude-code-ide-org--trigger-auto-promote-sole-todo, registered
;; alongside the pair above.

(ert-deftest claude-code-ide-org-test-single-next-demotes-old-next-among-top-level-headings ()
  "Setting a top-level sibling to NEXT while another top-level sibling
is already NEXT must demote the old one back to TODO, with an
explanatory LOGBOOK note, and leave the new one at NEXT."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker) (org-todo "NEXT"))
    (goto-char (point-max))
    (insert (concat "* TODO Sibling B                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find "test-0002" 'marker) (org-todo "NEXT"))
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))
    (should (equal "NEXT" (org-with-point-at (org-id-find "test-0002" 'marker) (org-get-todo-state))))
    (save-buffer)
    (should (string-match-p "Auto-demoted: superseded by sibling \"Sibling B\" becoming NEXT"
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-single-next-demotes-old-next-among-direct-children ()
  "The same demotion must apply one level down, among a heading's own
direct children, not just at the top level."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "** TODO Child A                                                     :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"
                     "** TODO Child B                                                     :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0003\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find "test-0002" 'marker) (org-todo "NEXT"))
    (org-with-point-at (org-id-find "test-0003" 'marker) (org-todo "NEXT"))
    (should (equal "TODO" (org-with-point-at (org-id-find "test-0002" 'marker) (org-get-todo-state))))
    (should (equal "NEXT" (org-with-point-at (org-id-find "test-0003" 'marker) (org-get-todo-state))))
    ;; The parent (a different level) must be untouched.
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))))

(ert-deftest claude-code-ide-org-test-single-next-does-not-touch-unrelated-subtree ()
  "A NEXT transition under one parent must never reach into a sibling
parent's own children."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "** NEXT Child under Test heading                                    :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"
                     "* TODO Other parent                                                :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0003\n"
                     ":END:\n"
                     "** TODO Child under Other parent                                    :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0004\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find "test-0004" 'marker) (org-todo "NEXT"))
    ;; The unrelated NEXT under a different parent must survive untouched.
    (should (equal "NEXT" (org-with-point-at (org-id-find "test-0002" 'marker) (org-get-todo-state))))
    (should (equal "NEXT" (org-with-point-at (org-id-find "test-0004" 'marker) (org-get-todo-state))))))

(ert-deftest claude-code-ide-org-test-single-next-promotes-sole-remaining-todo-when-sibling-goes-done ()
  "Reducing a sibling group to exactly one TODO survivor via a
transition to DONE (not NEXT) must auto-promote that survivor to
NEXT, with an explanatory LOGBOOK note."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* NEXT Sibling B                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    ;; Group is now {id=TODO, B=NEXT}; drop B to DONE so `id' becomes
    ;; the sole TODO survivor with no NEXT in the group.
    (org-with-point-at (org-id-find "test-0002" 'marker) (org-todo "DONE"))
    (should (equal "NEXT" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))
    (save-buffer)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "Auto-promoted: sole remaining TODO in its sibling group" disk))
      ;; NEXT is `!'-marked in the test fixture's own #+TODO: line, so
      ;; without org-inhibit-logging around the hook's nested org-todo
      ;; call this would double-log: one native line plus this custom
      ;; one. Exactly one "State \"NEXT\"" line must exist.
      (let ((count 0) (start 0))
        (while (string-match "State \"NEXT\"" disk start)
          (setq count (1+ count) start (match-end 0)))
        (should (= 1 count))))))

(ert-deftest claude-code-ide-org-test-single-next-leaves-non-todo-sole-survivor-alone ()
  "A sole survivor sitting in WAIT (not TODO) must never be
force-promoted to NEXT."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker) (org-todo "WAIT"))
    (goto-char (point-max))
    (insert (concat "* NEXT Sibling B                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find "test-0002" 'marker) (org-todo "DONE"))
    (should (equal "WAIT" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))))

(ert-deftest claude-code-ide-org-test-single-next-leaves-two-todos-alone ()
  "A sibling group with two TODOs and no NEXT must not have either
one promoted -- promotion requires an unambiguous sole survivor."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* TODO Sibling B                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"
                     "* NEXT Sibling C                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0003\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    ;; Drop C so the group becomes {id=TODO, B=TODO} -- two TODOs, none NEXT.
    (org-with-point-at (org-id-find "test-0003" 'marker) (org-todo "DONE"))
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))
    (should (equal "TODO" (org-with-point-at (org-id-find "test-0002" 'marker) (org-get-todo-state))))))

(ert-deftest claude-code-ide-org-test-single-next-no-sibling-conflict-is-noop ()
  "A single NEXT among otherwise-non-TODO siblings must be left alone."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* WAIT Sibling B                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find id 'marker) (org-todo "NEXT"))
    (should (equal "NEXT" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))
    (should (equal "WAIT" (org-with-point-at (org-id-find "test-0002" 'marker) (org-get-todo-state))))))

(ert-deftest claude-code-ide-org-test-single-next-does-not-recreate-double-next-on-race ()
  "The core correctness case: a 2-sibling group with A already NEXT,
setting B to NEXT must not result in BOTH ending up NEXT -- the
promote trigger's re-derivation from the live buffer must see A's
just-applied demotion, not stale change-plist state."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker) (org-todo "NEXT"))
    (goto-char (point-max))
    (insert (concat "* TODO Sibling B                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find "test-0002" 'marker) (org-todo "NEXT"))
    (let ((next-count 0))
      (dolist (heading-id (list id "test-0002"))
        (when (equal "NEXT" (org-with-point-at (org-id-find heading-id 'marker) (org-get-todo-state)))
          (setq next-count (1+ next-count))))
      (should (= 1 next-count)))))

(ert-deftest claude-code-ide-org-test-single-next-pre-existing-invalid-state-collapses-to-one-next ()
  "Two siblings hand-constructed as already (invalidly) NEXT:
transitioning a third sibling to NEXT must still leave exactly one
NEXT survivor across the whole group afterward."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* NEXT Sibling B                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"
                     "* NEXT Sibling C                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0003\n"
                     ":END:\n"
                     "* TODO Sibling D                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0004\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find "test-0004" 'marker) (org-todo "NEXT"))
    (let ((next-count 0))
      (dolist (heading-id (list id "test-0002" "test-0003" "test-0004"))
        (when (equal "NEXT" (org-with-point-at (org-id-find heading-id 'marker) (org-get-todo-state)))
          (setq next-count (1+ next-count))))
      (should (= 1 next-count))
      (should (equal "NEXT" (org-with-point-at (org-id-find "test-0004" 'marker) (org-get-todo-state)))))))

(ert-deftest claude-code-ide-org-test-single-next-fires-through-bare-org-todo ()
  "Mirrors the auto-clock-in trigger's own bare-org-todo test: the
demote/promote enforcement must live in org itself, not just in
claude-code-ide-org-set-todo's wrapper."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker) (org-todo "NEXT"))
    (goto-char (point-max))
    (insert (concat "* TODO Sibling B                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"))
    (org-with-point-at (org-id-find "test-0002" 'marker) (org-todo "NEXT"))
    (let ((disk (with-current-buffer (get-file-buffer file) (buffer-string))))
      (should (string-match-p "^\\* TODO Test heading" disk))
      (should (string-match-p "^\\* NEXT Sibling B" disk)))))

(ert-deftest claude-code-ide-org-test-single-next-lone-heading-with-no-siblings-is-not-auto-promoted ()
  "A heading with no siblings at all is never auto-promoted, and
manually demoting a solitary NEXT back to TODO sticks -- promotion
only resolves conflicts among >= 2 competing candidates."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker) (org-todo "WAIT"))
    (org-with-point-at (org-id-find id 'marker) (org-todo "TODO"))
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))
    (org-with-point-at (org-id-find id 'marker) (org-todo "NEXT"))
    (org-with-point-at (org-id-find id 'marker) (org-todo "TODO"))
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))))


;;; Session context ("what was I last doing") -----------------------------

(ert-deftest claude-code-ide-org-test-session-context-empty-when-nothing ()
  "No running clock and no WAIT headings: session-context reports
nothing, and the JSON wrapper collapses that to an empty hook object."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-query-files (list file)))
      (should (equal "" (claude-code-ide-org-session-context)))
      (should (equal "{}" (claude-code-ide-org--session-context-hook-json))))))

(ert-deftest claude-code-ide-org-test-session-context-includes-clocked-heading ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-session-context)))
      (should (string-match-p "\\`Currently clocked in: \"Test heading\"" result))
      (should (string-match-p (regexp-quote id) result))
      (should (string-match-p "test.org" result)))))

(ert-deftest claude-code-ide-org-test-session-context-includes-wait-headings ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* WAIT Blocked heading                                              :code:\n"
            ":PROPERTIES:\n:ID:       test-0002\n:END:\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-session-context)))
      (should (string-match-p "WAIT: \"Blocked heading\" (:ID: test-0002, in test.org)" result)))))

(ert-deftest claude-code-ide-org-test-session-context-clocked-then-waits-order ()
  "When both a clocked heading and WAIT headings exist, the clocked
heading is reported first."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* WAIT Blocked heading                                              :code:\n"
            ":PROPERTIES:\n:ID:       test-0002\n:END:\n")
    (save-buffer)
    (claude-code-ide-org-clock-in id)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-session-context))
           (pos-clocked (string-match "Currently clocked in" result))
           (pos-wait (string-match "WAIT: " result)))
      (should (and pos-clocked pos-wait (< pos-clocked pos-wait))))))

(ert-deftest claude-code-ide-org-test-session-context-ignores-non-wait-states ()
  "A DONE heading must not be mistaken for a WAIT heading."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* DONE Finished heading                                             :code:\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-session-context)))
      (should (equal "" result)))))

(ert-deftest claude-code-ide-org-test-session-context-kills-buffers-it-opened ()
  "Scanning for WAIT headings must not leave stray buffers behind for
files that were not already open — but must leave alone (and not
kill) a file the user already had open."
  (claude-code-ide-org-test--with-heading
    (let* ((other-dir (file-name-as-directory (make-temp-file "claude-code-ide-org-test-other" t)))
           (other-file (expand-file-name "other.org" other-dir)))
      (unwind-protect
          (progn
            (with-temp-file other-file
              (insert "* WAIT Other file heading                                           :code:\n"))
            ;; `file' (the base fixture's own org file) is already open —
            ;; via `find-file' in the fixture itself — so it must survive
            ;; the scan; `other-file' is not yet open and must be killed
            ;; again after the scan reads it.
            (should (get-file-buffer file))
            (should (not (get-file-buffer other-file)))
            (let ((claude-code-ide-org-query-files (list file other-file)))
              (claude-code-ide-org-session-context)
              (should (get-file-buffer file))
              (should (not (get-file-buffer other-file)))))
        (delete-directory other-dir t)))))

(ert-deftest claude-code-ide-org-test-write-session-context-report-writes-json ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (let* ((claude-code-ide-org-query-files (list file))
           (out (make-temp-file "claude-code-ide-org-test-report")))
      (unwind-protect
          (progn
            (claude-code-ide-org-write-session-context-report out)
            (let ((contents (claude-code-ide-org-test--disk-contents out)))
              (should (string-match-p "\"hookEventName\":\"SessionStart\"" contents))
              (should (string-match-p "Currently clocked in" contents))))
        (delete-file out)))))

;;; Statusline -------------------------------------------------------------

(ert-deftest claude-code-ide-org-test-statusline-empty-when-nothing-and-no-history ()
  (claude-code-ide-org-test--with-heading
    (should (equal "" (claude-code-ide-org--statusline-task-string)))))

(ert-deftest claude-code-ide-org-test-statusline-shows-clocked-in-task ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (let ((result (claude-code-ide-org--statusline-task-string)))
      ;; Default fixture :ID: is "test-0001" (9 chars) -- truncated to 8.
      (should (string-match-p "\\` | Test heading \\[test-000\\] (clocked in, " result)))))

(ert-deftest claude-code-ide-org-test-statusline-shows-clocked-out-task-from-history ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (claude-code-ide-org-clock-out)
    (should (not (org-clocking-p)))
    (let ((result (claude-code-ide-org--statusline-task-string)))
      (should (string-match-p "\\` | Test heading \\[test-000\\] (clocked out, " result)))))

(ert-deftest claude-code-ide-org-test-statusline-truncates-long-heading-name ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-min))
    (re-search-forward "Test heading")
    (replace-match "This heading name is deliberately much longer than thirty characters")
    (save-buffer)
    (claude-code-ide-org-clock-in id)
    (let ((result (claude-code-ide-org--statusline-task-string)))
      (should (string-match-p "This heading name is delibera…" result))
      (should (not (string-match-p "thirty" result))))))

(ert-deftest claude-code-ide-org-test-statusline-prefers-running-clock-over-history ()
  "If a clock is actively running, it must win over org-clock-history
even if history's head points somewhere else -- org-clocking-p is
checked first."
  (claude-code-ide-org-test--with-heading
    (let ((other-id "test-0002"))
      (goto-char (point-max))
      (insert (concat "* TODO Other heading                                               :code:\n"
                       ":PROPERTIES:\n"
                       ":ID:       " other-id "\n"
                       ":END:\n"))
      (save-buffer)
      (org-id-update-id-locations (list file))
      (claude-code-ide-org-clock-in other-id)
      (claude-code-ide-org-clock-out)
      (claude-code-ide-org-clock-in id)
      (let ((result (claude-code-ide-org--statusline-task-string)))
        (should (string-match-p "\\` | Test heading \\[test-000\\]" result))))))

(ert-deftest claude-code-ide-org-test-statusline-model-name-from-payload ()
  (let ((in (make-temp-file "claude-code-ide-org-test-statusline-in")))
    (unwind-protect
        (progn
          (with-temp-file in
            (insert "{\"model\":{\"display_name\":\"Claude Sonnet 5\"}}"))
          (should (equal "Claude Sonnet 5"
                         (claude-code-ide-org--statusline-model-name in))))
      (delete-file in))))

(ert-deftest claude-code-ide-org-test-statusline-model-name-missing-field ()
  (let ((in (make-temp-file "claude-code-ide-org-test-statusline-in")))
    (unwind-protect
        (progn
          (with-temp-file in (insert "{}"))
          (should (equal "" (claude-code-ide-org--statusline-model-name in))))
      (delete-file in))))

(ert-deftest claude-code-ide-org-test-statusline-model-name-malformed-json ()
  (let ((in (make-temp-file "claude-code-ide-org-test-statusline-in")))
    (unwind-protect
        (progn
          (with-temp-file in (insert "not json at all {{{"))
          (should (equal "" (claude-code-ide-org--statusline-model-name in))))
      (delete-file in))))

(ert-deftest claude-code-ide-org-test-statusline-model-name-missing-file ()
  (should (equal "" (claude-code-ide-org--statusline-model-name
                      "/nonexistent/path/does-not-exist.json"))))

(ert-deftest claude-code-ide-org-test-write-statusline-report-combines-model-and-task ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (let ((in (make-temp-file "claude-code-ide-org-test-statusline-in"))
          (out (make-temp-file "claude-code-ide-org-test-statusline-out")))
      (unwind-protect
          (progn
            (with-temp-file in
              (insert "{\"model\":{\"display_name\":\"Claude Sonnet 5\"}}"))
            (claude-code-ide-org-write-statusline-report in out)
            (let ((result (claude-code-ide-org-test--disk-contents out)))
              (should (string-match-p
                       "\\`Claude Sonnet 5 | Test heading \\[test-000\\] (clocked in, "
                       result))))
        (delete-file in)
        (delete-file out)))))

;;; Stale interval recovery ----------------------------------------------

(ert-deftest claude-code-ide-org-test-guess-stop-time-uses-working-hours ()
  (let* ((claude-code-ide-org-working-hours '(9 . 18))
         (start (encode-time 0 0 14 15 6 2026)) ; 2026-06-15 14:00
         (guess (claude-code-ide-org--guess-stop-time start))
         (decoded (decode-time guess)))
    (should (= 18 (nth 2 decoded)))
    (should (= 0 (nth 1 decoded)))
    (should (= 15 (nth 3 decoded)))))

(ert-deftest claude-code-ide-org-test-guess-stop-time-clamped-after-hours ()
  "If work started after working hours end, the guess must still be
after the start time, not before it."
  (let* ((claude-code-ide-org-working-hours '(9 . 18))
         (start (encode-time 0 0 21 15 6 2026)) ; 2026-06-15 21:00
         (guess (claude-code-ide-org--guess-stop-time start)))
    (should (time-less-p start guess))))

(ert-deftest claude-code-ide-org-test-find-stale-open-intervals-detects-yesterday ()
  (claude-code-ide-org-test--with-heading
    (let ((yesterday (format-time-string "[%Y-%m-%d %a %H:%M]"
                                          (time-subtract (current-time) (* 2 86400)))))
      (goto-char (point-max))
      (insert (format ":SESSIONS:\n- Resumed %s\n:END:\n:LOGBOOK:\nCLOCK: %s\n:END:\n"
                       yesterday yesterday))
      (save-buffer))
    (let* ((claude-code-ide-org-query-files (list file))
           (findings (claude-code-ide-org-find-stale-open-intervals)))
      (should (= 1 (length findings)))
      (should (equal id (plist-get (car findings) :id))))))

(ert-deftest claude-code-ide-org-test-find-stale-open-intervals-ignores-today ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (let* ((claude-code-ide-org-query-files (list file))
           (findings (claude-code-ide-org-find-stale-open-intervals)))
      (should (null findings)))))

(ert-deftest claude-code-ide-org-test-find-stale-open-intervals-respects-disabled-flag ()
  (claude-code-ide-org-test--with-heading
    (let ((yesterday (format-time-string "[%Y-%m-%d %a %H:%M]"
                                          (time-subtract (current-time) (* 2 86400)))))
      (goto-char (point-max))
      (insert (format ":LOGBOOK:\nCLOCK: %s\n:END:\n" yesterday))
      (save-buffer))
    (let* ((claude-code-ide-org-query-files (list file))
           (claude-code-ide-org-session-recovery-enabled nil)
           (findings (claude-code-ide-org-find-stale-open-intervals)))
      (should (null findings)))))

(ert-deftest claude-code-ide-org-test-close-open-interval-preserves-surrounding-content ()
  "Regression test: closing a stale interval must not corrupt
unrelated file content. `org-time-string-to-time' (needed to compute
the recovered CLOCK duration) does its own internal regexp matching,
which previously clobbered the match data `replace-match' relied on
from the original CLOCK-line search — replace-match then replaced
text at a stale, wrong position instead of the actual CLOCK line,
corrupting the file header."
  (claude-code-ide-org-test--with-heading
    (let ((yesterday "[2026-07-27 Mon 14:00]"))
      (goto-char (point-max))
      (insert (format ":SESSIONS:\n- Resumed %s\n:END:\n:LOGBOOK:\nCLOCK: %s\n:END:\n"
                       yesterday yesterday))
      (save-buffer))
    (claude-code-ide-org-close-open-interval id "[2026-07-27 Mon 17:45]")
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      ;; The file header must be completely untouched.
      (should (string-prefix-p
               "#+TODO: TODO NEXT(n!) PLANNING(p!) DOING(d!) WAIT(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n#+TAGS:"
               disk))
      ;; CLOCK line correctly closed with the right duration (3:45).
      (should (string-match-p
               "CLOCK: \\[2026-07-27 Mon 14:00\\]--\\[2026-07-27 Mon 17:45\\] =>  3:45"
               disk))
      ;; :SESSIONS: entry correctly closed too.
      (should (string-match-p "- Paused \\[2026-07-27 Mon 17:45\\] (recovered)" disk)))))

(ert-deftest claude-code-ide-org-test-close-open-interval-consolidates-on-the-fly ()
  "claude-code-ide-org-close-open-interval must also consolidate the
heading's history immediately afterward, same as clock-out — proven
the same way: a manual consolidate-history call right afterward is
already a no-op."
  (claude-code-ide-org-test--with-heading
    (let ((yesterday "[2026-07-27 Mon 14:00]"))
      (goto-char (point-max))
      (insert (format ":SESSIONS:\n- Resumed %s\n:END:\n:LOGBOOK:\nCLOCK: %s\n:END:\n"
                       yesterday yesterday))
      (save-buffer))
    (claude-code-ide-org-close-open-interval id "[2026-07-27 Mon 17:45]")
    (let ((before (claude-code-ide-org-test--disk-contents file)))
      (should (equal "Nothing to consolidate on \"Test heading\""
                     (claude-code-ide-org-consolidate-history id)))
      (should (equal before (claude-code-ide-org-test--disk-contents file))))))

;;; Historical consolidation ----------------------------------------------

(defun claude-code-ide-org-test--ts (s)
  "Parse the org timestamp string S into a time value, for building
test fixtures."
  (org-time-string-to-time s))

(ert-deftest claude-code-ide-org-test-round-time-nearest-5-minutes ()
  (dolist (case '(("[2026-07-28 Tue 11:00]" . "[2026-07-28 Tue 11:00]")
                  ("[2026-07-28 Tue 11:02]" . "[2026-07-28 Tue 11:00]")
                  ("[2026-07-28 Tue 11:03]" . "[2026-07-28 Tue 11:05]")
                  ("[2026-07-28 Tue 11:58]" . "[2026-07-28 Tue 12:00]")
                  ("[2026-07-28 Tue 23:58]" . "[2026-07-29 Wed 00:00]")))
    (let ((got (format-time-string "[%Y-%m-%d %a %H:%M]"
                                    (claude-code-ide-org--round-time-to-5-minutes
                                     (claude-code-ide-org-test--ts (car case))))))
      (should (equal (cdr case) got)))))

(ert-deftest claude-code-ide-org-test-merge-time-intervals-adjacent-and-overlapping ()
  (let* ((mk (lambda (a b) (cons (claude-code-ide-org-test--ts a)
                                  (claude-code-ide-org-test--ts b))))
         (intervals (list (funcall mk "[2026-07-28 Tue 10:00]" "[2026-07-28 Tue 10:05]")
                           (funcall mk "[2026-07-28 Tue 10:05]" "[2026-07-28 Tue 10:10]") ; adjacent
                           (funcall mk "[2026-07-28 Tue 10:08]" "[2026-07-28 Tue 10:20]") ; overlapping
                           (funcall mk "[2026-07-28 Tue 11:00]" "[2026-07-28 Tue 11:05]"))) ; separate
         (merged (claude-code-ide-org--merge-time-intervals intervals)))
    (should (= 2 (length merged)))
    (should (equal "[2026-07-28 Tue 10:00]" (format-time-string "[%Y-%m-%d %a %H:%M]" (car (nth 0 merged)))))
    (should (equal "[2026-07-28 Tue 10:20]" (format-time-string "[%Y-%m-%d %a %H:%M]" (cdr (nth 0 merged)))))
    (should (equal "[2026-07-28 Tue 11:00]" (format-time-string "[%Y-%m-%d %a %H:%M]" (car (nth 1 merged)))))
    (should (equal "[2026-07-28 Tue 11:05]" (format-time-string "[%Y-%m-%d %a %H:%M]" (cdr (nth 1 merged)))))))

(ert-deftest claude-code-ide-org-test-merge-time-intervals-contained ()
  "A later-starting interval fully contained in an earlier one must
not shrink the merged span."
  (let* ((mk (lambda (a b) (cons (claude-code-ide-org-test--ts a)
                                  (claude-code-ide-org-test--ts b))))
         (intervals (list (funcall mk "[2026-07-28 Tue 10:00]" "[2026-07-28 Tue 10:30]")
                           (funcall mk "[2026-07-28 Tue 10:10]" "[2026-07-28 Tue 10:15]")))
         (merged (claude-code-ide-org--merge-time-intervals intervals)))
    (should (= 1 (length merged)))
    (should (equal "[2026-07-28 Tue 10:30]" (format-time-string "[%Y-%m-%d %a %H:%M]" (cdr (car merged)))))))

(ert-deftest claude-code-ide-org-test-consolidate-history-rounds-merges-and-drops-zero ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             ":SESSIONS:\n"
             "- Resumed [2026-07-28 Tue 10:53]\n"
             "- Paused [2026-07-28 Tue 10:54]\n"
             "- Resumed [2026-07-28 Tue 10:57]\n"
             "- Paused [2026-07-28 Tue 10:59]\n"
             ":END:\n"
             ":LOGBOOK:\n"
             "CLOCK: [2026-07-28 Tue 10:57]--[2026-07-28 Tue 10:59] =>  0:02\n"
             "CLOCK: [2026-07-28 Tue 10:53]--[2026-07-28 Tue 10:54] =>  0:01\n"
             ":END:\n"))
    (save-buffer)
    (let ((result (claude-code-ide-org-consolidate-history id)))
      (should (string-match-p "\\`Consolidated :LOGBOOK: and :SESSIONS: on \"Test heading\"\\'" result)))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      ;; 10:53--10:54 rounds to 10:55--10:55 (zero-duration, dropped);
      ;; 10:57--10:59 rounds to 10:55--11:00 — the only surviving CLOCK line.
      ;; Splitting on a separator that occurs once yields 2 parts, not 1.
      (should (= 2 (length (split-string disk "CLOCK:"))))
      (should (string-match-p
               ":LOGBOOK:\nCLOCK: \\[2026-07-28 Tue 10:55\\]--\\[2026-07-28 Tue 11:00\\] =>  0:05\n:END:"
               disk))
      ;; :SESSIONS: collapses to one min-to-max pair for the single day.
      (should (string-match-p "- Resumed \\[2026-07-28 Tue 10:53\\]" disk))
      (should (string-match-p "- Paused \\[2026-07-28 Tue 10:59\\]" disk))
      (should (not (string-match-p "10:54\\]\\|10:57\\]" disk))))))

(ert-deftest claude-code-ide-org-test-consolidate-history-preserves-open-interval ()
  "An open CLOCK line and a trailing unmatched Resumed — today's
live interval — must never be touched, even when closed history
before them gets rounded/merged."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             ":SESSIONS:\n"
             "- Resumed [2026-07-28 Tue 09:00]\n"
             "- Paused [2026-07-28 Tue 09:01]\n"
             "- Resumed [2026-07-28 Tue 12:00]\n"
             ":END:\n"
             ":LOGBOOK:\n"
             "CLOCK: [2026-07-28 Tue 12:00]\n"
             "CLOCK: [2026-07-28 Tue 09:00]--[2026-07-28 Tue 09:01] =>  0:01\n"
             ":END:\n"))
    (save-buffer)
    (claude-code-ide-org-consolidate-history id)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "CLOCK: \\[2026-07-28 Tue 12:00\\]\\s-*$" disk))
      (should (string-match-p "- Resumed \\[2026-07-28 Tue 12:00\\]\\s-*$" disk)))))

(ert-deftest claude-code-ide-org-test-consolidate-history-separate-days-stay-separate ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             ":SESSIONS:\n"
             "- Resumed [2026-07-27 Mon 09:00]\n"
             "- Paused [2026-07-27 Mon 10:00]\n"
             "- Resumed [2026-07-28 Tue 09:00]\n"
             "- Paused [2026-07-28 Tue 10:00]\n"
             ":END:\n"))
    (save-buffer)
    (claude-code-ide-org-consolidate-history id)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "- Resumed \\[2026-07-27 Mon 09:00\\]" disk))
      (should (string-match-p "- Paused \\[2026-07-27 Mon 10:00\\]" disk))
      (should (string-match-p "- Resumed \\[2026-07-28 Tue 09:00\\]" disk))
      (should (string-match-p "- Paused \\[2026-07-28 Tue 10:00\\]" disk)))))

(ert-deftest claude-code-ide-org-test-consolidate-history-preserves-non-clock-logbook-lines ()
  "Consolidation must never delete non-CLOCK :LOGBOOK: content —
native state-change notes (including their backslash-continuation
lines) survive verbatim while CLOCK lines still get rounded/merged.
Regression test for the live incident where the epic heading's
'State \"NEXT\" from \"TODO\"' note was silently destroyed by the
Stop-hook clock-out's consolidation pass (TODO.org :ID:
ba8249c1-28cd-4ff1-918b-4b8439345d9a); this input reproduces that
heading's exact drawer shape."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             ":LOGBOOK:\n"
             "CLOCK: [2026-08-06 Thu 21:43]\n"
             "CLOCK: [2026-08-06 Thu 15:44]--[2026-08-06 Thu 16:51] =>  1:07\n"
             "- State \"NEXT\"       from \"TODO\"       [2026-08-06 Thu 12:07] \\\\\n"
             "  Auto-promoted: sole remaining TODO in its sibling group.\n"
             ":END:\n"))
    (save-buffer)
    (claude-code-ide-org-consolidate-history id)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      ;; Open clock untouched, closed clock rounded to 5-minute marks.
      (should (string-match-p "CLOCK: \\[2026-08-06 Thu 21:43\\]\\s-*$" disk))
      (should (string-match-p
               "CLOCK: \\[2026-08-06 Thu 15:45\\]--\\[2026-08-06 Thu 16:50\\] =>  1:05"
               disk))
      ;; The state-change note and its continuation line both survive.
      (should (string-match-p
               "- State \"NEXT\"       from \"TODO\"       \\[2026-08-06 Thu 12:07\\] \\\\\\\\"
               disk))
      (should (string-match-p
               "  Auto-promoted: sole remaining TODO in its sibling group\\."
               disk)))))

(ert-deftest claude-code-ide-org-test-consolidate-history-preserves-non-session-lines ()
  "Consolidation must never delete :SESSIONS: lines that aren't
Resumed/Paused entries — e.g. org_log_background_plan's
\"Background-planned\" write-backs — while Resumed/Paused pairs
still collapse per day (same losslessness rule as the :LOGBOOK:
test above, TODO.org :ID: ba8249c1-28cd-4ff1-918b-4b8439345d9a)."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             ":SESSIONS:\n"
             "- Resumed [2026-07-28 Tue 10:53]\n"
             "- Paused [2026-07-28 Tue 10:54]\n"
             "- Background-planned [2026-07-28 Tue 11:15] (session abc123-bg1)\n"
             "- Resumed [2026-07-28 Tue 10:57]\n"
             "- Paused [2026-07-28 Tue 10:59]\n"
             ":END:\n"))
    (save-buffer)
    (claude-code-ide-org-consolidate-history id)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      ;; Day still collapses to its min-to-max pair...
      (should (string-match-p "- Resumed \\[2026-07-28 Tue 10:53\\]" disk))
      (should (string-match-p "- Paused \\[2026-07-28 Tue 10:59\\]" disk))
      (should (not (string-match-p "10:54\\]\\|10:57\\]" disk)))
      ;; ...and the Background-planned line survives verbatim.
      (should (string-match-p
               "- Background-planned \\[2026-07-28 Tue 11:15\\] (session abc123-bg1)"
               disk)))))

(ert-deftest claude-code-ide-org-test-consolidate-history-noop-when-nothing-to-do ()
  (claude-code-ide-org-test--with-heading
    (should (equal "Nothing to consolidate on \"Test heading\""
                   (claude-code-ide-org-consolidate-history id)))))

;;; Unknown :ID: handling -------------------------------------------------

(ert-deftest claude-code-ide-org-test-unknown-id-returns-error-string ()
  (claude-code-ide-org-test--with-heading
    (should (string-match-p "\\`Error: no org heading found with :ID: \"bogus\""
                            (claude-code-ide-org-clock-in "bogus")))
    (should (string-match-p "\\`Error: no org heading found with :ID: \"bogus\""
                            (claude-code-ide-org-set-todo "bogus" "DOING")))
    (should (string-match-p "\\`Error: no org heading found with :ID: \"bogus\""
                            (claude-code-ide-org-archive "bogus")))))

;;; claude-code-ide-org-capture -----------------------------------------------

(defmacro claude-code-ide-org-test--with-capture-file (&rest body)
  "Point `claude-code-ide-org-capture-file' at a fresh scratch org
file under a temp directory and run BODY there.  Binds `capture-file'
to its path.  Redirects org-id's global location cache the same way
`claude-code-ide-org-test--with-heading' does, so tests never touch
real user state.  Cleans up any buffer visiting the capture file and
the temp directory afterwards."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "claude-code-ide-org-capture-test" t)))
          (capture-file (expand-file-name "capture.org" dir))
          (org-id-locations-file (expand-file-name ".org-id-locations" dir))
          (org-id-locations (make-hash-table :test 'equal))
          (org-id-files nil)
          (org-clock-persist nil)
          (org-clock-history nil)
          (claude-code-ide-org-capture-file capture-file))
     (unwind-protect
         (progn
           (with-temp-file capture-file
             (insert "#+TODO: TODO NEXT(n!) PLANNING(p!) DOING(d!) WAIT(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n"
                     "#+TAGS: code comms research review\n"
                     "#+ARCHIVE: DONE.org::* Done\n"
                     "\n"))
           ,@body)
       (when (org-clocking-p) (org-clock-out))
       (let ((buf (get-file-buffer capture-file)))
         (when buf
           (with-current-buffer buf (set-buffer-modified-p nil))
           (kill-buffer buf)))
       (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-capture-creates-heading-with-id ()
  (claude-code-ide-org-test--with-capture-file
    (let ((result (claude-code-ide-org-capture "Buy stamps")))
      (should (string-match-p "\\`Captured: \"Buy stamps\" (ID: .+)\\'" result))
      (string-match "(ID: \\(.+\\))\\'" result)
      (let ((returned-id (match-string 1 result))
            (disk (claude-code-ide-org-test--disk-contents capture-file)))
        ;; A real, non-empty ID landed both in the return string and on disk.
        (should (> (length returned-id) 0))
        (should (string-match-p "^\\* TODO Buy stamps[ \t]*$" disk))
        (should (string-match-p (concat "^:ID: +" (regexp-quote returned-id) "[ \t]*$") disk))
        (should (not (buffer-modified-p (get-file-buffer capture-file))))))))

(ert-deftest claude-code-ide-org-test-capture-id-immediately-resolvable ()
  "Regression test: unlike `org-id-get-create' (the manual workflow
this tool replaces), plain `org-capture' writes :ID: as literal
template text and never itself registers the location in
`org-id-locations'.  Every other tool here (org_clock_in,
org_set_todo, ...) locates headings via `org-id-find', so a returned
:ID: that isn't yet registered would only resolve if the capture
target happens to be rescanned via `org-agenda-files'/
`org-id-extra-files' — not guaranteed, and not true of this test's
empty agenda.  The tool's contract is that the caller can immediately
clock in / set state on the new heading, so the ID must resolve
right away with no rescan needed."
  (claude-code-ide-org-test--with-capture-file
    (let* ((org-agenda-files nil)
           (result (claude-code-ide-org-capture "Round trip task")))
      (string-match "(ID: \\(.+\\))\\'" result)
      (let ((returned-id (match-string 1 result)))
        (should (org-id-find returned-id 'marker))
        (should (string-match-p
                 "\\`Clocked in: \"Round trip task\"\\'"
                 (claude-code-ide-org-clock-in returned-id)))))))

(ert-deftest claude-code-ide-org-test-capture-title-with-special-characters ()
  "A title containing characters that are meaningful elsewhere in org
templates/regexps (colons, percent signs, brackets, backslashes) must
survive into the heading verbatim via `%i', not get partially eaten
as template escapes or regexp backreferences."
  (claude-code-ide-org-test--with-capture-file
    (let* ((title "Reply to Jane: 100% [urgent] re: \\1 in Q3 report")
           (result (claude-code-ide-org-capture title)))
      (should (string-match-p (regexp-quote (format "Captured: \"%s\"" title)) result))
      (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
        (should (string-match-p (regexp-quote (concat "* TODO " title)) disk))))))

(ert-deftest claude-code-ide-org-test-capture-uses-org-default-notes-file-when-unset ()
  "When `claude-code-ide-org-capture-file' is nil, capture must fall
back to `org-default-notes-file', not error out or silently target
nothing."
  (let* ((dir (file-name-as-directory (make-temp-file "claude-code-ide-org-capture-test" t)))
         (notes-file (expand-file-name "notes.org" dir))
         (org-id-locations-file (expand-file-name ".org-id-locations" dir))
         (org-id-locations (make-hash-table :test 'equal))
         (org-id-files nil)
         (claude-code-ide-org-capture-file nil)
         (org-default-notes-file notes-file))
    (unwind-protect
        (progn
          (claude-code-ide-org-capture "Fallback target task")
          (let ((buf (get-file-buffer notes-file)))
            (when buf (with-current-buffer buf (save-buffer))))
          (should (file-exists-p notes-file))
          (should (string-match-p "Fallback target task"
                                  (claude-code-ide-org-test--disk-contents notes-file))))
      (let ((buf (get-file-buffer notes-file)))
        (when buf
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf)))
      (delete-directory dir t))))

;;; claude-code-ide-org-query -----------------------------------------------

(ert-deftest claude-code-ide-org-test-query-todo-basic ()
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-query "todo:TODO")))
      (should (string-match-p "TODO" result))
      (should (string-match-p "Test heading" result)))))

(ert-deftest claude-code-ide-org-test-query-includes-id ()
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-query "todo:TODO")))
      (should (string-match-p (regexp-quote id) result)))))

(ert-deftest claude-code-ide-org-test-query-tags-or-matches-either ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* NEXT Research heading                                            :research:\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-query "tags:code,research")))
      (should (string-match-p "Test heading" result))
      (should (string-match-p "Research heading" result)))))

(ert-deftest claude-code-ide-org-test-query-negation-excludes-done ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* DONE Finished heading                                             :code:\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-query "!todo:DONE")))
      (should (string-match-p "Test heading" result))
      (should (not (string-match-p "Finished heading" result))))))

(ert-deftest claude-code-ide-org-test-query-no-matches-returns-message ()
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-query "todo:CANCELLED")))
      (should (equal "No matches." result)))))

(ert-deftest claude-code-ide-org-test-query-blank-returns-error ()
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-query-files (list file)))
      (should (equal "Error: empty query." (claude-code-ide-org-query "   "))))))

(ert-deftest claude-code-ide-org-test-tracked-files-resolves-org-agenda-files-directory ()
  "Regression test: `claude-code-ide-org--tracked-files' must call the
`org-agenda-files' function, not return the raw variable, when it
falls back to it.  A directory entry in `org-agenda-files' (the shape
Doom's default config uses, e.g. a bare \"~/org\") only resolves to
its contained files through the function's expansion — passed through
raw, org-ql silently finds nothing.  Every other org_query test here
sidesteps this by binding `claude-code-ide-org-query-files' directly
to an explicit file list, so this is the only test that exercises the
`org-agenda-files' fallback path at all."
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-query-files nil)
           (org-agenda-files (list dir))
           (result (claude-code-ide-org-query "todo:TODO")))
      (should (string-match-p "Test heading" result)))))

;;; claude-code-ide-org-sort-children -----------------------------------

(ert-deftest claude-code-ide-org-test-sort-children-alpha ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             "** TODO Charlie\n"
             "** TODO Alpha\n"
             "** TODO Bravo\n"))
    (save-buffer)
    (let ((result (claude-code-ide-org-sort-children id "alpha")))
      (should (string-match-p
               "\\`Sorted children of \"Test heading\" by alpha\\'" result)))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (< (string-match-p "Alpha" disk) (string-match-p "Bravo" disk)))
      (should (< (string-match-p "Bravo" disk) (string-match-p "Charlie" disk))))))

(ert-deftest claude-code-ide-org-test-sort-children-todo-order ()
  "Names deliberately disagree with alpha order (Alpha/Bravo/Charlie
would sort Alpha<Bravo<Charlie alphabetically) so this test can only
pass if `org-sort-entries' is actually invoked with the todo-order
code (?o), not accidentally alpha (?a)."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             "** DONE Alpha\n"
             "** NEXT Bravo\n"
             "** TODO Charlie\n"))
    (save-buffer)
    (claude-code-ide-org-sort-children id "todo-order")
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      ;; Sequence order is TODO NEXT DOING WAIT MAYBE | DONE CANCELLED,
      ;; so Charlie (TODO) < Bravo (NEXT) < Alpha (DONE) — the reverse
      ;; of alpha-on-name order.
      (should (< (string-match-p "Charlie" disk) (string-match-p "Bravo" disk)))
      (should (< (string-match-p "Bravo" disk) (string-match-p "Alpha" disk))))))

(ert-deftest claude-code-ide-org-test-sort-children-unknown-sort-type ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "** TODO Only child\n")
    (save-buffer)
    (should (string-match-p "\\`Error: unknown sort-type \"bogus\""
                            (claude-code-ide-org-sort-children id "bogus")))))

;;; claude-code-ide-org-move-sibling --------------------------------------

(ert-deftest claude-code-ide-org-test-move-sibling-down-then-up ()
  (claude-code-ide-org-test--with-heading
    ;; "Test heading" (id) is first; add two more top-level siblings.
    (goto-char (point-max))
    (insert (concat
             "* TODO Second heading\n"
             "* TODO Third heading\n"))
    (save-buffer)
    (let ((result (claude-code-ide-org-move-sibling id "down")))
      (should (string-match-p "\\`Moved \"Test heading\" down\\'" result)))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      ;; Order is now: Second, Test heading, Third.
      (should (< (string-match-p "Second heading" disk)
                 (string-match-p "Test heading" disk)))
      (should (< (string-match-p "Test heading" disk)
                 (string-match-p "Third heading" disk))))
    (claude-code-ide-org-move-sibling id "up")
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      ;; Back to: Test heading, Second, Third.
      (should (< (string-match-p "Test heading" disk)
                 (string-match-p "Second heading" disk)))
      (should (< (string-match-p "Second heading" disk)
                 (string-match-p "Third heading" disk))))))

(ert-deftest claude-code-ide-org-test-move-sibling-boundary-errors ()
  "Moving the first sibling up, or the last sibling down, must
return a clean error string (relying on the shared
`claude-code-ide-org--at-id' dispatcher's condition-case for org's
own `user-error') rather than crashing."
  (claude-code-ide-org-test--with-heading
    ;; "Test heading" (id) is first; add a second sibling with its own
    ;; :ID:, registered in the id cache same as the fixture's own
    ;; heading, so it can be targeted directly.
    (goto-char (point-max))
    (insert (concat
             "* TODO Second heading\n"
             ":PROPERTIES:\n"
             ":ID:       test-0002\n"
             ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    ;; First sibling can't move up.
    (should (string-match-p "\\`Error:.*[Cc]annot move"
                            (claude-code-ide-org-move-sibling id "up")))
    ;; Last sibling can't move down.
    (should (string-match-p "\\`Error:.*[Cc]annot move"
                            (claude-code-ide-org-move-sibling "test-0002" "down")))
    ;; Neither attempt should have changed the on-disk order.
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (< (string-match-p "Test heading" disk)
                 (string-match-p "Second heading" disk))))))

(ert-deftest claude-code-ide-org-test-move-sibling-unknown-direction ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* TODO Second heading\n")
    (save-buffer)
    (should (string-match-p "\\`Error: Unknown direction \"sideways\""
                            (claude-code-ide-org-move-sibling id "sideways")))))

;;; claude-code-ide-org-clock-report -----------------------------------------

(ert-deftest claude-code-ide-org-test-clock-report-id-scoped-shows-own-time-only ()
  "id-scoped reports must cover only that heading's own subtree —
proven by adding a second heading with its own CLOCK entry and
confirming the id-scoped report shows the target's time but not the
other heading's."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             ":LOGBOOK:\n"
             "CLOCK: [2026-07-27 Mon 09:00]--[2026-07-27 Mon 10:00] =>  1:00\n"
             ":END:\n"
             "* DONE Other heading                                                :code:\n"
             ":PROPERTIES:\n"
             ":ID:       test-0002\n"
             ":END:\n"
             ":LOGBOOK:\n"
             "CLOCK: [2026-07-27 Mon 11:00]--[2026-07-27 Mon 13:00] =>  2:00\n"
             ":END:\n"))
    (save-buffer)
    (let ((result (claude-code-ide-org-clock-report id)))
      (should (string-match-p "Test heading" result))
      (should (string-match-p "1:00" result))
      (should (not (string-match-p "Other heading" result)))
      (should (not (string-match-p "2:00" result))))
    ;; The source buffer must never be narrowed, modified, or saved —
    ;; the report is computed from an in-memory copy of the subtree.
    (should (not (buffer-modified-p (get-file-buffer file))))
    (with-current-buffer (get-file-buffer file)
      (should (not (buffer-narrowed-p))))))

(ert-deftest claude-code-ide-org-test-clock-report-file-list-scoped-covers-all-headings ()
  "Without an id, the report must fall back to
`claude-code-ide-org-query-files' and cover every heading across
those files, same file-list mechanism org_query already uses."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             ":LOGBOOK:\n"
             "CLOCK: [2026-07-27 Mon 09:00]--[2026-07-27 Mon 10:00] =>  1:00\n"
             ":END:\n"
             "* DONE Other heading                                                :code:\n"
             ":PROPERTIES:\n"
             ":ID:       test-0002\n"
             ":END:\n"
             ":LOGBOOK:\n"
             "CLOCK: [2026-07-27 Mon 11:00]--[2026-07-27 Mon 13:00] =>  2:00\n"
             ":END:\n"))
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-clock-report)))
      (should (string-match-p "Test heading" result))
      (should (string-match-p "Other heading" result))
      (should (string-match-p "3:00" result)))))

(ert-deftest claude-code-ide-org-test-clock-report-explicit-tstart-tend ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             ":LOGBOOK:\n"
             "CLOCK: [2026-07-27 Mon 09:00]--[2026-07-27 Mon 10:00] =>  1:00\n"
             ":END:\n"))
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-clock-report
                    nil nil "[2026-07-27 Mon 00:00]" "[2026-07-28 Tue 00:00]")))
      (should (string-match-p "1:00" result)))
    ;; A range that excludes the entry entirely must report zero time.
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-clock-report
                    nil nil "[2026-08-01 Sat 00:00]" "[2026-08-02 Sun 00:00]")))
      (should (string-match-p "0:00" result))
      (should (not (string-match-p "1:00" result))))))

(ert-deftest claude-code-ide-org-test-clock-report-block-today ()
  "The :block param must reach `org-clock-special-range' correctly —
proven with a same-day CLOCK entry pinned to whole-minute boundaries
(so duration arithmetic can't be thrown off by stray seconds) and
:block \"today\", vs. a CLOCK entry from an earlier day, which
:block \"today\" must exclude."
  (claude-code-ide-org-test--with-heading
    (let* ((decoded (decode-time (current-time)))
           (today-start (encode-time 0 (nth 1 decoded) (nth 2 decoded)
                                      (nth 3 decoded) (nth 4 decoded) (nth 5 decoded)))
           (today-end (time-add today-start 3600))
           (yesterday-start (time-subtract today-start 86400))
           (yesterday-end (time-add yesterday-start 3600)))
      (goto-char (point-max))
      (insert (format ":LOGBOOK:\nCLOCK: %s--%s =>  1:00\n:END:\n"
                       (format-time-string "[%Y-%m-%d %a %H:%M]" today-start)
                       (format-time-string "[%Y-%m-%d %a %H:%M]" today-end)))
      (save-buffer)
      (let ((result (claude-code-ide-org-clock-report id "today")))
        (should (string-match-p "1:00" result)))
      (with-current-buffer (get-file-buffer file)
        (goto-char (point-min))
        (re-search-forward "CLOCK: \\[[^]]+\\]--\\[[^]]+\\] =>  1:00")
        (replace-match (format "CLOCK: %s--%s =>  1:00"
                                (format-time-string "[%Y-%m-%d %a %H:%M]" yesterday-start)
                                (format-time-string "[%Y-%m-%d %a %H:%M]" yesterday-end)))
        (save-buffer))
      (let ((result (claude-code-ide-org-clock-report id "today")))
        (should (string-match-p "0:00" result))
        (should (not (string-match-p "1:00" result)))))))

(ert-deftest claude-code-ide-org-test-clock-report-unrecognized-block-returns-error ()
  (claude-code-ide-org-test--with-heading
    (should (string-match-p "\\`Error:" (claude-code-ide-org-clock-report id "not-a-real-block")))))

(ert-deftest claude-code-ide-org-test-clock-report-unknown-id-returns-error-string ()
  (claude-code-ide-org-test--with-heading
    (should (string-match-p "\\`Error: no org heading found with :ID: \"bogus\""
                            (claude-code-ide-org-clock-report "bogus")))))

(ert-deftest claude-code-ide-org-test-clock-report-no-args-is-unrestricted ()
  "With neither id, block, nor tstart/tend, the report must cover
all clocked time in scope rather than erroring or defaulting to an
empty range."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             ":LOGBOOK:\n"
             "CLOCK: [2020-01-01 Wed 09:00]--[2020-01-01 Wed 10:00] =>  1:00\n"
             ":END:\n"))
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-clock-report)))
      (should (string-match-p "1:00" result)))))

;;; claude-code-ide-org-log-background-plan --------------------------------

(ert-deftest claude-code-ide-org-test-log-background-plan-inserts-link-and-sessions-entry ()
  (claude-code-ide-org-test--with-heading
    (let ((result (claude-code-ide-org-log-background-plan
                   id "~/.claude/plans/warm-marinating-puddle.md" "session-A-bg1")))
      (should (string-match-p "\\`Logged background plan for \"Test heading\"\\.\\'" result)))
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p
               "\\[\\[file:~/.claude/plans/warm-marinating-puddle.md\\]\\[Plan\\]\\]"
               disk))
      (should (string-match-p
               "- Background-planned \\[[^]]+\\] (session session-A-bg1)"
               disk)))))

(ert-deftest claude-code-ide-org-test-log-background-plan-is-idempotent ()
  "A heading only ever carries one Plan link -- a second call (e.g. a
later batch re-planning the same still-open heading) must not insert
a duplicate, even with a different plan-file path."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-log-background-plan id "~/.claude/plans/first.md" "session-A-bg1")
    (claude-code-ide-org-log-background-plan id "~/.claude/plans/second.md" "session-A-bg2")
    (let ((disk (claude-code-ide-org-test--disk-contents file))
          (count 0))
      (with-temp-buffer
        (insert disk)
        (goto-char (point-min))
        (while (re-search-forward "\\[\\[file:[^]]*\\]\\[Plan\\]\\]" nil t)
          (setq count (1+ count))))
      (should (= 1 count))
      (should (string-match-p "first\\.md" disk))
      (should (not (string-match-p "second\\.md" disk))))))

(ert-deftest claude-code-ide-org-test-log-background-plan-does-not-touch-todo-or-clock ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-log-background-plan id "~/.claude/plans/x.md" "session-A-bg1")
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))
    (should (not (org-clocking-p)))
    (should (not (string-match-p ":LOGBOOK:" (claude-code-ide-org-test--disk-contents file))))
    (should (not claude-code-ide-org--planning-owner-session-id))
    (should (not claude-code-ide-org--clock-owner-session-id))))

(ert-deftest claude-code-ide-org-test-log-background-plan-resolves-fresh-by-id ()
  "Mirrors set-todo-reports-success-when-hook-cascade-moves-point:
mutate the buffer (add a sibling, move point there) between two calls
and confirm each write still lands on the heading actually named by
id, not wherever point happened to be left."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* TODO Sibling B                                                    :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (goto-char (point-max))
    (claude-code-ide-org-log-background-plan id "~/.claude/plans/a.md" "session-A-bg1")
    (claude-code-ide-org-log-background-plan "test-0002" "~/.claude/plans/b.md" "session-A-bg2")
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "a\\.md" disk))
      (should (string-match-p "b\\.md" disk)))))

;;; Event queue -------------------------------------------------------------
;;
;; Reader-side tests for the append-only event queue (TODO.org :ID:
;; 32272061-1d78-4726-b13b-90338edb2ba5). Pure data in, pure data out --
;; no org buffers, no clock, no :ID: resolution -- so these need none of
;; the --with-heading fixture's machinery, only a redirected queue
;; directory.

(defmacro claude-code-ide-org-test--with-queue (&rest body)
  "Run BODY with `claude-code-ide-org-queue-directory' pointed at a
fresh temp directory, deleted afterwards, so tests never read or write
the real ~/.claude/org-updates."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "claude-code-ide-org-queue" t)))
          (claude-code-ide-org-queue-directory dir))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(defun claude-code-ide-org-test--queue-write (session-id &rest lines)
  "Append LINES verbatim to SESSION-ID's queue file.
Deliberately writes raw text rather than going through any encoder, so
a test can plant a torn or malformed line exactly as a crashed writer
would leave one."
  (let ((file (claude-code-ide-org--queue-file session-id)))
    (make-directory (file-name-directory file) t)
    (write-region (mapconcat #'identity lines "\n") nil file t 'silent)
    (write-region "\n" nil file t 'silent)))

(defun claude-code-ide-org-test--queue-event
    (ts kind &optional id state session-id note agent-id agent-type)
  "Return one encoded queue line, matching bin/hooks/queue-append's shape."
  (json-encode `((ts . ,ts)
                 (kind . ,kind)
                 (id . ,id)
                 (state . ,state)
                 (note . ,note)
                 (session_id . ,(or session-id "sess-a"))
                 (agent_id . ,agent-id)
                 (agent_type . ,agent-type)
                 (source . ,kind))))

(ert-deftest claude-code-ide-org-test-queue-round-trips-every-kind ()
  "Every event kind parses back with its fields and ordering intact."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:00-0500" "todo" "id-a" "DOING")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:01-0500" "clock_in" "id-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:12:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:31:00-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T10:20:00-0500" "clock_out" "id-a")))
    (let ((events (claude-code-ide-org--queue-events)))
      (should (equal (mapcar (lambda (e) (plist-get e :kind)) events)
                     '("todo" "clock_in" "pause" "resume" "clock_out")))
      (should (equal (plist-get (car events) :id) "id-a"))
      (should (equal (plist-get (car events) :state) "DOING"))
      (should (equal (plist-get (car events) :session-id) "sess-a"))
      ;; pause/resume are session-global: they carry no heading of their own.
      (should-not (plist-get (nth 2 events) :id)))))

(ert-deftest claude-code-ide-org-test-queue-carries-notes ()
  "The note rides through to the reader, and is absent where it should be."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:00-0500" "todo" "id-a" "DOING" nil
                  "plan approved, resuming implementation")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:01-0500" "clock_in" "id-a" nil nil
                  "clarify backend schema design")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:12:00-0500" "pause")))
    (let ((events (claude-code-ide-org--queue-events)))
      (should (equal (plist-get (nth 0 events) :note)
                     "plan approved, resuming implementation"))
      (should (equal (plist-get (nth 1 events) :note)
                     "clarify backend schema design"))
      ;; pause/resume are emitted by hooks Claude never calls, so there is
      ;; no call site that could supply a note -- null, not empty string.
      (should-not (plist-get (nth 2 events) :note)))))

(ert-deftest claude-code-ide-org-test-queue-carries-subagent-attribution ()
  "agent_id/agent_type ride through, and are null on the main thread.
Tool events fire the same hooks inside a subagent, and the payload then
carries both fields -- so a subagent's queue events are attributable with
no orchestrator-side reconstruction."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:00-0500" "clock_in" "id-a" nil nil
                  "main thread work")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:05:00-0500" "clock_in" "id-a" nil nil
                  "exploring the reader layer" "a4bb098d74a939dc9" "Explore")))
    (let ((events (claude-code-ide-org--queue-events)))
      (should-not (plist-get (nth 0 events) :agent-id))
      (should-not (plist-get (nth 0 events) :agent-type))
      (should (equal (plist-get (nth 1 events) :agent-id) "a4bb098d74a939dc9"))
      (should (equal (plist-get (nth 1 events) :agent-type) "Explore"))
      ;; Same session file either way: a subagent shares its parent's
      ;; session_id, and is distinguished only by these fields.
      (should (equal (plist-get (nth 0 events) :session-id)
                     (plist-get (nth 1 events) :session-id))))))

(ert-deftest claude-code-ide-org-test-queue-note-is-optional ()
  "A line written before the note field existed still parses."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org-test--queue-write
     "sess-a"
     (json-encode '((ts . "2026-08-07T09:00:00-0500") (kind . "clock_in")
                    (id . "id-a") (state . nil)
                    (session_id . "sess-a") (agent_id . nil) (source . "x"))))
    (let ((events (claude-code-ide-org--queue-events)))
      (should (= 1 (length events)))
      (should-not (plist-get (car events) :note)))))

(ert-deftest claude-code-ide-org-test-clock-out-reports-closed-id ()
  "org_clock_out names the :ID: it actually closed, since it takes no id
argument and the queue event would otherwise have nothing to record."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-clock-in id)
    (let ((result (let ((org-clock-out-remove-zero-time-clocks nil))
                    (claude-code-ide-org-clock-out))))
      (should (string-prefix-p "Clocked out: " result))
      (should (string-match-p "(id: test-0001)\\'" result)))))

(ert-deftest claude-code-ide-org-test-clock-out-omits-id-when-heading-has-none ()
  "A clock started by hand on a heading with no :ID: still clocks out
cleanly, without an empty \"(id: )\" suffix."
  (claude-code-ide-org-test--with-heading
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (insert "\n* Bare heading with no ID\n")
      (save-buffer)
      (goto-char (point-max))
      (org-back-to-heading t)
      (org-clock-in))
    (let ((result (let ((org-clock-out-remove-zero-time-clocks nil))
                    (claude-code-ide-org-clock-out))))
      (should (string-match-p "\\`Clocked out: " result))
      (should-not (string-match-p "(id:" result)))))

(ert-deftest claude-code-ide-org-test-queue-skips-unusable-lines ()
  "A torn, malformed, or unknown-kind line costs one event, not the file."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:00-0500" "clock_in" "id-a")
                 "{\"ts\":\"2026-08-07T09:05:00-0500\",\"kind\":\"clo"  ; torn
                 "not json at all"
                 (json-encode '((ts . "2026-08-07T09:06:00-0500")
                                (kind . "future_kind") (id . "id-a")))
                 (json-encode '((ts . "nonsense") (kind . "pause")))
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:10:00-0500" "pause")))
    (let ((events (claude-code-ide-org--queue-events)))
      (should (equal (mapcar (lambda (e) (plist-get e :kind)) events)
                     '("clock_in" "pause"))))))

(ert-deftest claude-code-ide-org-test-queue-applied-events-are-filtered ()
  "Applied events drop out; unapplied ones survive regardless of position,
including ones appended after a partial apply."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:00-0500" "clock_in" "id-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:05:00-0500" "pause")))
    (should (= 2 (length (claude-code-ide-org--queue-events))))
    (claude-code-ide-org--queue-mark-applied
     "sess-a" '("2026-08-07T09:00:00-0500" "2026-08-07T09:05:00-0500"))
    (should (= 0 (length (claude-code-ide-org--queue-events))))
    ;; The session keeps writing -- the queue file is never truncated, so
    ;; this must simply appear as newly pending.
    (claude-code-ide-org-test--queue-write
     "sess-a" (claude-code-ide-org-test--queue-event
               "2026-08-07T09:20:00-0500" "resume"))
    (let ((events (claude-code-ide-org--queue-events)))
      (should (equal (mapcar (lambda (e) (plist-get e :kind)) events) '("resume"))))))

(ert-deftest claude-code-ide-org-test-queue-applied-is-a-set-not-a-watermark ()
  "Applying a LATER event must not consume an earlier unapplied one.

A high-water mark cannot express this, which is why the applied state is
a set: review is per-item and non-contiguous by nature. Observed live on
2026-08-07 -- a real apply advanced no watermark at all, and every
applied item would have been re-proposed on the next pass."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:05:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:10:00-0500" "pause")))
    ;; Apply only the middle event.
    (claude-code-ide-org--queue-mark-applied "sess-a" '("2026-08-07T09:05:00-0500"))
    (let ((remaining (claude-code-ide-org--queue-events)))
      (should (= 2 (length remaining)))
      (should (equal (mapcar (lambda (e) (plist-get e :ts-string)) remaining)
                     '("2026-08-07T09:00:00-0500" "2026-08-07T09:10:00-0500"))))
    ;; A second partial apply accumulates rather than replacing.
    (claude-code-ide-org--queue-mark-applied "sess-a" '("2026-08-07T09:10:00-0500"))
    (should (equal (mapcar (lambda (e) (plist-get e :ts-string))
                           (claude-code-ide-org--queue-events))
                   '("2026-08-07T09:00:00-0500")))))

(ert-deftest claude-code-ide-org-test-queue-applied-write-is-atomic ()
  "No partial applied-set file is observable, and no temp file is left."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org--queue-mark-applied "sess-a" '("2026-08-07T09:05:00-0500"))
    (let ((file (claude-code-ide-org--queue-watermark-file "sess-a")))
      (should (file-readable-p file))
      (should (gethash "2026-08-07T09:05:00-0500"
                       (claude-code-ide-org--queue-applied "sess-a")))
      (should-not (directory-files claude-code-ide-org-queue-directory
                                   nil "\\`\\.queue-tmp-")))))

(ert-deftest claude-code-ide-org-test-queue-attributes-guideposts-across-a-return ()
  "The A -> B -> A case: returning to a heading that never left DOING
emits no todo event, so attribution must come from clock_in/clock_out.
This is the whole reason those two kinds are retained."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:00-0500" "todo" "id-a" "DOING")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:01-0500" "clock_in" "id-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:12:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T10:20:00-0500" "clock_out" "id-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T10:20:01-0500" "clock_in" "id-b")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T10:35:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T11:00:00-0500" "clock_out" "id-b")
                 ;; Back to A. A never left DOING, so no todo event fires.
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T11:00:01-0500" "clock_in" "id-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T11:15:00-0500" "pause")))
    (let* ((groups (claude-code-ide-org--queue-events-by-id))
           (a (alist-get "id-a" groups nil nil #'equal))
           (b (alist-get "id-b" groups nil nil #'equal))
           (pause-times (lambda (events)
                          (mapcar (lambda (e)
                                    (format-time-string "%H:%M" (plist-get e :ts)))
                                  (seq-filter
                                   (lambda (e) (equal (plist-get e :kind) "pause"))
                                   events)))))
      (should (equal (funcall pause-times a) '("09:12" "11:15")))
      (should (equal (funcall pause-times b) '("10:35"))))))

(ert-deftest claude-code-ide-org-test-queue-attribution-does-not-cross-sessions ()
  "One session's clock_in never captures another session's guideposts."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org-test--queue-write
     "sess-a" (claude-code-ide-org-test--queue-event
               "2026-08-07T09:00:00-0500" "clock_in" "id-a" nil "sess-a"))
    (claude-code-ide-org-test--queue-write
     "sess-b" (claude-code-ide-org-test--queue-event
               "2026-08-07T09:10:00-0500" "pause" nil nil "sess-b"))
    (let ((groups (claude-code-ide-org--queue-events-by-id)))
      ;; sess-b's pause has no clock_in of its own, so it stays unattributed
      ;; rather than being swept under sess-a's heading.
      (should (equal (mapcar (lambda (e) (plist-get e :kind))
                             (alist-get "id-a" groups nil nil #'equal))
                     '("clock_in")))
      (should (equal (mapcar (lambda (e) (plist-get e :kind))
                             (alist-get nil groups))
                     '("pause"))))))

(ert-deftest claude-code-ide-org-test-aggregate-guideposts-clusters-by-gap ()
  "A dense run collapses to one span; a wide gap starts a new one."
  (let* ((times '("2026-08-07T09:00:00-0500"   ; cluster one
                  "2026-08-07T09:05:00-0500"
                  "2026-08-07T09:12:00-0500"
                  "2026-08-07T11:00:00-0500"   ; cluster two, ~1h48m later
                  "2026-08-07T11:04:00-0500"))
         (events (mapcar (lambda (ts)
                           (list :ts (date-to-time ts) :kind "pause"))
                         times))
         (spans (claude-code-ide-org--aggregate-guideposts events 900)))
    (should (= 2 (length spans)))
    (should (equal (format-time-string "%H:%M" (car (nth 0 spans))) "09:00"))
    (should (equal (format-time-string "%H:%M" (cdr (nth 0 spans))) "09:12"))
    (should (equal (format-time-string "%H:%M" (car (nth 1 spans))) "11:00"))
    (should (equal (format-time-string "%H:%M" (cdr (nth 1 spans))) "11:04"))
    ;; A tighter threshold splits the first cluster at its 7-minute gap.
    (should (= 3 (length (claude-code-ide-org--aggregate-guideposts events 360))))))

(ert-deftest claude-code-ide-org-test-aggregate-guideposts-does-not-round ()
  "Spans keep their exact endpoints. A 2-minute span is preserved, where
consolidate-history's 5-minute rounding would drop it entirely."
  (let* ((events (mapcar (lambda (ts) (list :ts (date-to-time ts) :kind "pause"))
                         '("2026-08-06T22:43:00-0500" "2026-08-06T22:45:00-0500")))
         (spans (claude-code-ide-org--aggregate-guideposts events)))
    (should (= 1 (length spans)))
    (should (equal (format-time-string "%H:%M" (car (car spans))) "22:43"))
    (should (equal (format-time-string "%H:%M" (cdr (car spans))) "22:45"))
    ;; The behavior this deliberately departs from, asserted so the contrast
    ;; is a test rather than a comment: rounding collapses it to nothing.
    (should (string-empty-p
             (string-trim
              (claude-code-ide-org--consolidate-logbook-text
               "CLOCK: [2026-08-06 Thu 22:43]--[2026-08-06 Thu 22:45] =>  0:02\n"))))))

(ert-deftest claude-code-ide-org-test-aggregate-guideposts-edge-cases ()
  "No events yields no spans; one event yields one zero-width span."
  (should-not (claude-code-ide-org--aggregate-guideposts nil))
  (let ((spans (claude-code-ide-org--aggregate-guideposts
                (list (list :ts (date-to-time "2026-08-07T09:00:00-0500"))))))
    (should (= 1 (length spans)))
    (should (time-equal-p (car (car spans)) (cdr (car spans))))))

(ert-deftest claude-code-ide-org-test-queue-empty-and-missing-directory ()
  "A missing or empty queue directory reads as no events, never an error."
  (claude-code-ide-org-test--with-queue
    (should-not (claude-code-ide-org--queue-events))
    (should-not (claude-code-ide-org--queue-files))
    (should-not (claude-code-ide-org--queue-events-by-id)))
  (let ((claude-code-ide-org-queue-directory "/nonexistent/queue/dir"))
    (should-not (claude-code-ide-org--queue-events))
    (should-not (claude-code-ide-org--queue-session-ids))))

;;; Review and apply ----------------------------------------------------------

(defun claude-code-ide-org-test--logbook (file)
  "Return FILE's on-disk :LOGBOOK: body for the single test heading."
  (let ((text (claude-code-ide-org-test--disk-contents file)))
    (if (string-match ":LOGBOOK:\n\\(\\(?:.\\|\n\\)*?\\):END:" text)
        (match-string 1 text)
      "")))

(ert-deftest claude-code-ide-org-test-review-applies-exact-backdated-interval ()
  "A confirmed interval lands with its exact endpoints and duration --
no rounding, unlike consolidate-history."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'clock :id id
                      :start (date-to-time "2026-08-06T09:00:00-0500")
                      :end (date-to-time "2026-08-06T09:15:00-0500")
                      :note "clarify backend schema design"
                      :agent nil :suggested nil :events nil)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let ((logbook (claude-code-ide-org-test--logbook file)))
        (should (string-match-p "CLOCK: \\[2026-08-06 [A-Za-z]+ 09:00\\]--\\[2026-08-06 [A-Za-z]+ 09:15\\] =>  0:15"
                                logbook))
        ;; Human span -> ACTIVE timestamps, so org-agenda picks it up.
        (should (string-match-p "- <2026-08-06 [A-Za-z]+ 09:00>--<2026-08-06 [A-Za-z]+ 09:15> clarify backend schema design"
                                logbook))))))

(ert-deftest claude-code-ide-org-test-review-keeps-short-interval ()
  "A 2-minute interval survives, where consolidate-history drops it."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'clock :id id
                      :start (date-to-time "2026-08-06T22:43:00-0500")
                      :end (date-to-time "2026-08-06T22:45:00-0500")
                      :agent nil :suggested nil :events nil)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (should (string-match-p "22:43\\]--\\[2026-08-06 [A-Za-z]+ 22:45\\] =>  0:02"
                              (claude-code-ide-org-test--logbook file))))))

(ert-deftest claude-code-ide-org-test-review-help-falls-back-without-which-key ()
  "`?' must work in a config with no which-key -- including the batch
suite itself, which is why the dependency is resolved at call time."
  (should (commandp #'claude-code-ide-org-review-help))
  (should (eq (lookup-key claude-code-ide-org-review-mode-map (kbd "?"))
              #'claude-code-ide-org-review-help))
  ;; Bindings must survive a re-load of config.el. They live outside the
  ;; defvar initializer precisely because defvar would not reassign an
  ;; already-bound map, silently freezing them at first-load values.
  (should (eq (lookup-key claude-code-ide-org-review-mode-map (kbd "x"))
              #'claude-code-ide-org-review-apply))
  (cl-letf (((symbol-function 'describe-mode) (lambda (&rest _) 'fell-back)))
    (if (fboundp 'which-key-show-major-mode)
        (should t)   ; which-key present: the fallback is not the path taken
      (with-temp-buffer
        (claude-code-ide-org-review-mode)
        (should (eq (claude-code-ide-org-review-help) 'fell-back))))))

(ert-deftest claude-code-ide-org-test-review-mode-documents-itself ()
  "The mode docstring is user-facing help, not implementation notes --
`describe-mode' is the first thing anyone presses. Guards against it
regressing to a maintainer comment."
  (let ((doc (documentation 'claude-code-ide-org-review-mode)))
    (should doc)
    ;; Explains the two modes, which is the part a reader cannot guess.
    (should (string-match-p "suggested" doc))
    (should (string-match-p "agent" doc))
    ;; Warns about the two behaviours that surprise people.
    (should (string-match-p "discards your marks" doc))
    (should (string-match-p "consequential" doc))))

(ert-deftest claude-code-ide-org-test-review-zero-width-span-annotates-only ()
  "A lone guidepost is an interaction point, not a duration: it gets its
annotation but no CLOCK: line, since `=>  0:00' would claim an interval
that was never observed. Found against real queue data, where a single
unbracketed pause produced exactly this case."
  (claude-code-ide-org-test--with-heading
    (let* ((ts (date-to-time "2026-08-07T12:27:00-0500"))
           (item (list :type 'clock :id id :start ts :end ts
                       :agent nil :suggested t :events nil)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let ((text (claude-code-ide-org-test--disk-contents file)))
        (should (string-match-p "- <2026-08-07 [A-Za-z]+ 12:27>--<2026-08-07 [A-Za-z]+ 12:27>" text))
        (should-not (string-match-p "CLOCK:" text))))))

(ert-deftest claude-code-ide-org-test-review-agent-interval-is-inactive ()
  "A subagent interval annotates with INACTIVE timestamps, staying out
of the agenda -- unattended machine work is not attention."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'clock :id id
                      :start (date-to-time "2026-08-06T09:15:00-0500")
                      :end (date-to-time "2026-08-06T09:30:00-0500")
                      :note "unattended planning"
                      :agent "a4bb098d7" :suggested nil :events nil)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let ((logbook (claude-code-ide-org-test--logbook file)))
        (should (string-match-p "- \\[2026-08-06 [A-Za-z]+ 09:15\\]--\\[2026-08-06 [A-Za-z]+ 09:30\\] unattended planning"
                                logbook))
        (should-not (string-match-p "- <2026-08-06" logbook))))))

(ert-deftest claude-code-ide-org-test-review-applies-backdated-state-with-note ()
  "The native state-change line is written at the EVENT's time, not now,
with the note as its continuation."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'state :id id
                      :ts (date-to-time "2026-08-06T09:00:00-0500")
                      :to "DOING" :note "plan approved, resuming implementation"
                      :events nil)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let ((text (claude-code-ide-org-test--disk-contents file)))
        (should (string-match-p "^\\* DOING " text))
        (should (string-match-p "State \"DOING\"\\s-+from \"TODO\"\\s-+\\[2026-08-06 [A-Za-z]+ 09:00\\]"
                                text))
        (should (string-match-p "plan approved, resuming implementation" text))))))

(ert-deftest claude-code-ide-org-test-review-refuses-stale-state-transition ()
  "The literal 2026-08-07 shape: a `todo' event queued while the heading
was NEXT, applied after it had moved on to DOING. Apply must refuse and
change nothing, rather than faithfully regressing the heading and
writing a `State \"PLANNING\" from \"DOING\"' line that looks correct
(TODO.org :ID: f9f61c04-150b-4ee7-96c9-582cf2bda95a)."
  (claude-code-ide-org-test--with-heading
    ;; Reality has moved on to DOING; the queued event still says NEXT.
    (claude-code-ide-org-set-todo id "DOING")
    (let* ((before (claude-code-ide-org-test--disk-contents file))
           (item (list :type 'state :id id
                       :ts (date-to-time "2026-08-07T11:51:00-0500")
                       :from "NEXT" :to "PLANNING" :events nil))
           (result (claude-code-ide-org--review-apply-item item)))
      (should (stringp result))
      (should (string-match-p "refused stale NEXT -> PLANNING" result))
      (should (string-match-p "heading is now DOING" result))
      ;; Nothing reached the file: same keyword, no new log line.
      (should (equal "DOING" (org-with-point-at (org-id-find id 'marker)
                               (org-get-todo-state))))
      (should (equal before (claude-code-ide-org-test--disk-contents file)))
      (should-not (string-match-p "State \"PLANNING\""
                                  (claude-code-ide-org-test--disk-contents file)))
      ;; And it is visibly flagged, so a human sees it before deciding.
      (should (string-prefix-p "! " (claude-code-ide-org--review-describe item)))
      (should (string-match-p "NEXT -> PLANNING"
                              (claude-code-ide-org--review-describe item)))
      ;; Explicitly confirmed, the same item applies -- the human is the
      ;; validation step, so an override must exist and must be deliberate.
      (plist-put item :stale-confirmed t)
      (should-not (claude-code-ide-org--review-apply-item item))
      (should (equal "PLANNING" (org-with-point-at (org-id-find id 'marker)
                                  (org-get-todo-state)))))))

(ert-deftest claude-code-ide-org-test-review-applies-when-from-state-matches ()
  "A queued transition whose `from' still matches reality is not stale
and applies untouched -- the guard must not cost the normal case."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'state :id id
                      :ts (date-to-time "2026-08-06T09:00:00-0500")
                      :from "TODO" :to "DOING" :note "start" :events nil)))
      (should-not (claude-code-ide-org--review-state-stale-p item))
      ;; Checked before applying: afterwards the heading really has moved
      ;; to DOING, and the same item is then correctly stale.
      (should (string-prefix-p "  " (claude-code-ide-org--review-describe item)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let ((text (claude-code-ide-org-test--disk-contents file)))
        (should (string-match-p "^\\* DOING " text))
        (should (string-match-p "State \"DOING\"\\s-+from \"TODO\"\\s-+\\[2026-08-06 [A-Za-z]+ 09:00\\]"
                                text))))))

(ert-deftest claude-code-ide-org-test-review-applies-event-predating-the-from-field ()
  "An event queued before `from' existed carries nil, which means
\"unknown\", not \"none\". There is nothing to compare against, so it
must apply exactly as it did before the guard was added -- flagging
every legacy event would only teach the reader to ignore the flag."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-set-todo id "DOING")
    (let ((item (list :type 'state :id id
                      :ts (date-to-time "2026-08-06T09:00:00-0500")
                      :from nil :to "WAIT" :events nil)))
      (should-not (claude-code-ide-org--review-state-stale-p item))
      (should-not (claude-code-ide-org--review-apply-item item))
      (should (equal "WAIT" (org-with-point-at (org-id-find id 'marker)
                              (org-get-todo-state)))))))

(ert-deftest claude-code-ide-org-test-review-none-matches-a-keywordless-heading ()
  "`none' is the queue's spelling of \"the heading had no keyword\",
which org spells nil. The two must compare equal, or every transition
out of a bare heading would be reported stale."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* Bare heading                                                     :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0004\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (should-not (claude-code-ide-org--review-state-stale-p
                 (list :type 'state :id "test-0004" :from "none" :to "NEXT")))
    ;; ...and a heading that DOES carry a keyword is stale against `none'.
    (should (claude-code-ide-org--review-state-stale-p
             (list :type 'state :id id :from "none" :to "NEXT")))))

(ert-deftest claude-code-ide-org-test-review-unresolvable-id-is-not-reported-stale ()
  "An :ID: that no longer resolves is apply's own error to report, with
its own message. The staleness check must stay silent rather than
mislabel a missing heading as a state disagreement."
  (claude-code-ide-org-test--with-heading
    (should-not (claude-code-ide-org--review-state-stale-p
                 (list :type 'state :id "no-such-id-at-all"
                       :from "NEXT" :to "DOING")))))

(ert-deftest claude-code-ide-org-test-queue-parses-the-from-field ()
  "The reader carries `from' through from the JSONL, and tolerates its
absence on older events."
  (let ((with-from (claude-code-ide-org--queue-parse-line
                    "{\"ts\":\"2026-08-07T11:51:00-0500\",\"kind\":\"todo\",\"id\":\"x\",\"state\":\"PLANNING\",\"from\":\"NEXT\"}"))
        (without (claude-code-ide-org--queue-parse-line
                  "{\"ts\":\"2026-08-07T11:51:00-0500\",\"kind\":\"todo\",\"id\":\"x\",\"state\":\"PLANNING\"}")))
    (should (equal "NEXT" (plist-get with-from :from)))
    (should-not (plist-get without :from))))

(ert-deftest claude-code-ide-org-test-review-suppresses-the-auto-clock-in-trigger ()
  "Apply must not let `org-trigger-hook' open a clock at *now*.

Without `claude-code-ide-org--auto-clock-in-active' bound,
`claude-code-ide-org--trigger-auto-clock-in' fires on the -> DOING
transition and opens an unclosed clock stamped with the current time,
corrupting a backdated apply with a live interval nobody asked for.
This asserts both halves: the stray clock appears without the guard, and
does not with it.

Scope note, deliberately narrow: the *worse* symptom seen during
TODO.org :ID: 3d576d29's live verification -- the pending state-change
note being destroyed outright -- does **not** reproduce under `emacs
--batch`, where the note lands fine. That divergence is itself a
documented finding of 3d576d29, so this test asserts the part that is
environment-independent rather than pretending to cover the part that
is not."
  ;; Without the guard: a stray clock at now.
  (claude-code-ide-org-test--with-heading
    (let ((ts (date-to-time "2026-08-06T09:00:00-0500")))
      (claude-code-ide-org--at-id
       id
       (lambda ()
         (cl-letf (((symbol-function 'org-current-effective-time) (lambda () ts)))
           (org-todo "DOING"))
         (save-buffer)))
      (should (org-clocking-p))
      (should (string-match-p (format-time-string "CLOCK: \\[%Y-%m-%d")
                              (claude-code-ide-org-test--disk-contents file)))))
  ;; With the guard, via the real apply path: no clock at all, and the
  ;; note lands on the backdated state line.
  (claude-code-ide-org-test--with-heading
    (should-not (claude-code-ide-org--review-apply-item
                 (list :type 'state :id id
                       :ts (date-to-time "2026-08-06T09:00:00-0500")
                       :to "DOING" :note "this note must survive" :events nil)))
    (should-not (org-clocking-p))
    (let ((text (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "this note must survive" text))
      (should-not (string-match-p "CLOCK:" text)))))

(ert-deftest claude-code-ide-org-test-review-items-attribute-and-classify ()
  "Items are built per heading: todo events replay one-for-one, subagent
clock pairs are authoritative, human guideposts become suggested spans."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-06T09:00:00-0500" "todo" "id-a" "DOING" nil "starting")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-06T09:00:01-0500" "clock_in" "id-a" nil nil "backend schema")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-06T09:05:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-06T09:10:00-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-06T09:20:00-0500" "clock_in" "id-a" nil nil
                  "agent run" "agent-1" "Explore")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-06T09:35:00-0500" "clock_out" "id-a" nil nil
                  nil "agent-1" "Explore")))
    (let* ((items (claude-code-ide-org--review-items-from-queue))
           (states (seq-filter (lambda (i) (eq (plist-get i :type) 'state)) items))
           (agent (seq-find (lambda (i) (plist-get i :agent)) items))
           (human (seq-find (lambda (i) (plist-get i :suggested)) items)))
      (should (= 1 (length states)))
      (should (equal (plist-get (car states) :to) "DOING"))
      (should (equal (plist-get (car states) :note) "starting"))
      ;; Subagent pair is authoritative, not a suggestion.
      (should agent)
      (should-not (plist-get agent :suggested))
      (should (equal (format-time-string "%H:%M" (plist-get agent :start)) "09:20"))
      (should (equal (format-time-string "%H:%M" (plist-get agent :end)) "09:35"))
      ;; Human guideposts cluster into a suggested span labelled from the
      ;; enclosing clock_in's note.
      (should human)
      (should (equal (format-time-string "%H:%M" (plist-get human :start)) "09:05"))
      (should (equal (format-time-string "%H:%M" (plist-get human :end)) "09:10"))
      (should (equal (plist-get human :note) "backend schema")))))

(ert-deftest claude-code-ide-org-test-review-records-only-applied-events ()
  "Applying one item marks exactly its own events, leaving the rest."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-06T09:00:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-06T09:05:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-06T09:10:00-0500" "pause")))
    (claude-code-ide-org--review-record-applied
     (list (list :events (list (list :ts-string "2026-08-06T09:05:00-0500"
                                     :session-id "sess-a")))))
    (should (equal (mapcar (lambda (e) (plist-get e :ts-string))
                           (claude-code-ide-org--queue-events))
                   '("2026-08-06T09:00:00-0500" "2026-08-06T09:10:00-0500")))))

(ert-deftest claude-code-ide-org-test-review-closes-a-running-clock-first ()
  "Regression for the live corruption of 2026-08-07.

`org-clock-in' throws `abort' and opens nothing when a clock is already
running on the same heading at the same point (org-clock.el:1440), so a
following `org-clock-out' closes the PRE-EXISTING clock at our end time.
Live, that produced CLOCK: [15:53]--[13:17] =>  -3:24. Apply must close
any running clock before opening its own, and must never produce a
negative duration."
  (claude-code-ide-org-test--with-heading
    ;; Put a live clock on the very heading under review, exactly as the
    ;; UserPromptSubmit hook does pre-cutover.
    (claude-code-ide-org-clock-in id)
    (should (org-clocking-p))
    (should-not (claude-code-ide-org--review-apply-item
                 (list :type 'clock :id id
                       :start (date-to-time "2026-08-06T13:16:00-0500")
                       :end (date-to-time "2026-08-06T13:17:00-0500")
                       :agent nil :suggested nil :events nil)))
    (let ((logbook (claude-code-ide-org-test--logbook file)))
      ;; The requested interval landed, exactly.
      (should (string-match-p "13:16\\]--\\[2026-08-06 [A-Za-z]+ 13:17\\] =>  0:01" logbook))
      ;; And nothing negative was written.
      (should-not (string-match-p "=> *-" logbook)))))

(ert-deftest claude-code-ide-org-test-review-no-op-transition-writes-nothing-elsewhere ()
  "Reproduction for 3d93021d: apply wrote a DONE nobody queued, onto the
wrong heading.

`org-todo' only calls `org-add-log-setup' when the state actually
changes. Applying a state item whose heading is *already* in the
requested state is therefore a no-op that sets up no note -- but
`org-log-note-marker' and friends are global and survive from whatever
touched them last, possibly a different heading entirely. Driving
`org-store-log-note' unconditionally then writes that stale note at the
stale marker: a correctly-formatted `State \"X\" from \"Y\"' line, on the
wrong heading, citing a real timestamp, with no error anywhere.

Live on 2026-08-07 this marked feba67eb DONE while applying an event
that named 32272061."
  (claude-code-ide-org-test--with-heading
    (let ((other (expand-file-name "other.org" dir)))
      (with-temp-file other
        (insert "* NEXT Innocent bystander\n:PROPERTIES:\n:ID: bystander-1\n:END:\n"))
      (let ((buffer (find-file-noselect other)))
        (unwind-protect
            (progn
              ;; Prime the global note state to point at the bystander, as
              ;; any earlier org-todo on it would have.
              (with-current-buffer buffer
                (goto-char (point-min))
                (org-mode)
                (move-marker org-log-note-marker (point-max) buffer)
                (setq org-log-note-purpose 'state
                      org-log-note-state "DONE"
                      org-log-note-previous-state "NEXT"
                      org-log-note-effective-time (current-time)))
              ;; Now apply a NO-OP transition on a different heading: set
              ;; the test heading to TODO, which it already is.
              (should-not (claude-code-ide-org--review-apply-item
                           (list :type 'state :id id
                                 :ts (date-to-time "2026-08-06T09:00:00-0500")
                                 :to "TODO" :note nil :events nil)))
              ;; The bystander must be untouched.
              (with-current-buffer buffer (save-buffer))
              (should-not (string-match-p
                           "State \"DONE\""
                           (claude-code-ide-org-test--disk-contents other))))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest claude-code-ide-org-test-review-batch-does-not-leak-between-items ()
  "The literal shape of the 2026-08-07 failure: a batch whose first item
is a no-op, followed by a real one. Note state must not carry from item
to item, and only the intended headings may be written."
  (claude-code-ide-org-test--with-heading
    (let ((other (expand-file-name "other.org" dir)))
      (with-temp-file other
        (insert "* NEXT Innocent bystander\n:PROPERTIES:\n:ID: bystander-2\n:END:\n"))
      (let ((buffer (find-file-noselect other)))
        (unwind-protect
            (progn
              (org-id-update-id-locations (list file other))
              (let ((result (claude-code-ide-org--review-apply
                             (list
                              ;; No-op: the heading is already TODO.
                              (list :type 'state :id id
                                    :ts (date-to-time "2026-08-06T08:19:00-0500")
                                    :to "TODO" :note nil :events nil)
                              ;; Real transition, on the same heading.
                              (list :type 'state :id id
                                    :ts (date-to-time "2026-08-06T09:00:00-0500")
                                    :to "DOING" :note "real work" :events nil)))))
                (should (= 2 (plist-get result :applied)))
                (should-not (plist-get result :errors)))
              (with-current-buffer buffer (save-buffer))
              ;; The bystander is untouched...
              (let ((bystander (claude-code-ide-org-test--disk-contents other)))
                (should (string-match-p "^\\* NEXT Innocent bystander" bystander))
                (should-not (string-match-p "State \"" bystander)))
              ;; ...and the real transition landed where it belongs.
              (let ((text (claude-code-ide-org-test--disk-contents file)))
                (should (string-match-p "^\\* DOING " text))
                (should (string-match-p "real work" text))))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest claude-code-ide-org-test-review-cleans-up-the-log-note-hook ()
  "Regression for the live \"Marker does not point anywhere\" error.

`org-add-log-setup' registers `org-add-log-note' on `post-command-hook';
driving `org-store-log-note' directly bypasses the function that would
remove it, so it fires later against a cleared marker. Invisible to
batch, which has no command loop -- hence asserting the hook itself."
  (claude-code-ide-org-test--with-heading
    (should-not (claude-code-ide-org--review-apply-item
                 (list :type 'state :id id
                       :ts (date-to-time "2026-08-06T09:00:00-0500")
                       :to "DOING" :note "note" :events nil)))
    (should-not (memq 'org-add-log-note post-command-hook))
    (should-not org-log-setup)))

(ert-deftest claude-code-ide-org-test-review-state-note-lands-in-logbook ()
  "The state-change line belongs in :LOGBOOK:, per clock-template.org.
With `org-log-into-drawer' nil -- this user's setting -- org writes it
bare after the property drawer; apply binds the drawer locally so the
result matches the template without changing the user's own config."
  (claude-code-ide-org-test--with-heading
    (let ((org-log-into-drawer nil))
      (should-not (claude-code-ide-org--review-apply-item
                   (list :type 'state :id id
                         :ts (date-to-time "2026-08-06T09:00:00-0500")
                         :to "DOING" :note "in the drawer please" :events nil))))
    (should (string-match-p "in the drawer please"
                            (claude-code-ide-org-test--logbook file)))))

(ert-deftest claude-code-ide-org-test-review-clock-then-state-leaves-no-open-clock ()
  "Applying a clock item then a DONE transition must not be blocked --
the blocker hook refuses -> DONE while that heading's clock runs, so the
pair must close before any state change."
  (claude-code-ide-org-test--with-heading
    (should-not (claude-code-ide-org--review-apply-item
                 (list :type 'clock :id id
                       :start (date-to-time "2026-08-06T09:00:00-0500")
                       :end (date-to-time "2026-08-06T09:15:00-0500")
                       :agent nil :suggested nil :events nil)))
    (should-not (org-clocking-p))
    (should-not (claude-code-ide-org--review-apply-item
                 (list :type 'state :id id
                       :ts (date-to-time "2026-08-06T09:16:00-0500")
                       :to "DONE" :note "merged" :events nil)))
    (should (string-match-p "^\\* DONE "
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-review-apply-reports-unresolvable-id ()
  "A bad :ID: is reported, not thrown, and does not count as applied."
  (claude-code-ide-org-test--with-heading
    (let ((result (claude-code-ide-org--review-apply
                   (list (list :type 'state :id "no-such-id"
                               :ts (current-time) :to "DOING" :events nil)))))
      (should (= 0 (plist-get result :applied)))
      (should (= 1 (length (plist-get result :errors))))
      (should (string-match-p "\\`Error:" (car (plist-get result :errors)))))))

(provide 'claude-code-ide-org-config-test)

;;; config-test.el ends here
