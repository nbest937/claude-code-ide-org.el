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
          (id "test-0001"))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "#+TODO: TODO NEXT DOING WAIT MAYBE | DONE CANCELLED\n"
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
        (insert (concat "#+TODO: TODO NEXT DOING WAIT MAYBE | DONE CANCELLED\n"
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
      (should (string-match-p "\\`Clocked out: \"Test heading\"\\'" result)))
    (should (not (org-clocking-p)))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (should (string-match-p "CLOCK: \\[.*\\]--\\[.*\\] =>"
                            (claude-code-ide-org-test--disk-contents file)))))

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
    (should (equal "Clocked out: \"Test heading\""
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
    (should (equal "Clocked out: \"Test heading\""
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
      (should (string-match-p "\\`TODO state set to DOING: \"Test heading\"\\'" result)))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (should (string-match-p "^\\* DOING Test heading"
                            (claude-code-ide-org-test--disk-contents file)))))

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
        (insert (concat "#+TODO: TODO NEXT DOING WAIT MAYBE | DONE CANCELLED\n"
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
    (let ((other-id "test-0002"))
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
      (should (string-match-p "\\`TODO state set to DONE: \"Other heading\"\\'"
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
               "#+TODO: TODO NEXT DOING WAIT MAYBE | DONE CANCELLED\n#+TAGS:"
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
             (insert "#+TODO: TODO NEXT DOING WAIT MAYBE | DONE CANCELLED\n"
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

(provide 'claude-code-ide-org-config-test)

;;; config-test.el ends here
