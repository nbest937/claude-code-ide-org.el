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

;;; Unknown :ID: handling -------------------------------------------------

(ert-deftest claude-code-ide-org-test-unknown-id-returns-error-string ()
  (claude-code-ide-org-test--with-heading
    (should (string-match-p "\\`Error: no org heading found with :ID: \"bogus\""
                            (claude-code-ide-org-clock-in "bogus")))
    (should (string-match-p "\\`Error: no org heading found with :ID: \"bogus\""
                            (claude-code-ide-org-set-todo "bogus" "DOING")))
    (should (string-match-p "\\`Error: no org heading found with :ID: \"bogus\""
                            (claude-code-ide-org-archive "bogus")))))

(provide 'claude-code-ide-org-config-test)

;;; config-test.el ends here
