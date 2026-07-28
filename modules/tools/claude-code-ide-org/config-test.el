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

;;; Fixture -----------------------------------------------------------------

(defmacro claude-code-ide-org-test--with-heading (&rest body)
  "Create a scratch org file with one TODO heading and run BODY there.
Binds `id' to the heading's :ID: property, `file' to the org
file's path, and `archive-file' to the archive target's path.
Everything lives under a fresh temp directory that is deleted
afterwards, and org-id's global location cache is redirected
there too so tests never touch real user state."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "claude-code-ide-org-test" t)))
          (file (expand-file-name "test.org" dir))
          (archive-file (expand-file-name "DONE.org" dir))
          (org-id-locations-file (expand-file-name ".org-id-locations" dir))
          (org-id-locations (make-hash-table :test 'equal))
          (org-id-files nil)
          (org-clock-persist nil)
          (org-clock-history nil)
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

;;; claude-code-ide-org-clock-in ---------------------------------------------

(ert-deftest claude-code-ide-org-test-clock-in-opens-logbook-and-saves ()
  (claude-code-ide-org-test--with-heading
    (let ((result (claude-code-ide-org-clock-in id)))
      (should (string-match-p "\\`Clocked in: \"Test heading\"\\'" result)))
    (should (org-clocking-p))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (should (string-match-p "CLOCK: \\[" (claude-code-ide-org-test--disk-contents file)))))

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

(provide 'claude-code-ide-org-config-test)

;;; config-test.el ends here
