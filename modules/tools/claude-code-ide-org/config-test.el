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

(defconst claude-code-ide-org-test--repo-root
  (and load-file-name
       (expand-file-name "../../../" (file-name-directory load-file-name)))
  "This repo's root, captured at load time.
`load-file-name' is only bound while the file is being loaded, which is
why this is a defconst rather than something computed inside a test.
Lets a test read a checked-in fixture such as `clock-template.org';
tests that use it skip themselves when it is nil, so loading this file
some other way degrades to a skipped test rather than an error.")

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
             (insert "#+TODO: TODO NEXT(n!) DOING(d!) WAITING(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n"
                     "#+TAGS: code comms research review\n"
                     "#+ARCHIVE: DONE.org::\n"
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

;;; Append-only wrappers -----------------------------------------------------
;;
;; Every assertion in this section is the inverse of what it asserted
;; before the 2026-08-11 cutover (TODO.org :ID:
;; feba67eb-35b3-48bd-a892-8ecd47ca52e0): the wrappers used to be tested
;; for "the buffer and the clock changed", and are now tested for
;; "nothing changed and an event can be recorded". Apply is the only
;; writer -- its own coverage lives under "Review and apply" below.

(defun claude-code-ide-org-test--clock-in-for-real (id)
  "Open a real clock on ID, the way apply or a hand-edit would.
The wrappers no longer clock, so tests that need a *live* clock (the
status file, the blocker hook, apply closing a running clock) have to
say so explicitly rather than getting one as a side effect of
`claude-code-ide-org-clock-in'."
  (org-with-point-at (org-id-find id 'marker)
    (org-clock-in)))

(defun claude-code-ide-org-test--set-todo-for-real (id state)
  "Set ID's TODO keyword to STATE the way apply or a hand-edit would.
Same reason as `claude-code-ide-org-test--clock-in-for-real': the
wrapper only queues now, so any test that needs the *file* to hold a
state has to say so.  `org-inhibit-logging' is bound because these are
setup steps, not the thing under test -- WAITING and CANCELLED are
`@'-flagged and would otherwise block on a note prompt under batch."
  (org-with-point-at (org-id-find id 'marker)
    (let ((org-inhibit-logging t)) (org-todo state))
    (save-buffer)))

(ert-deftest claude-code-ide-org-test-clock-in-queues-without-clocking ()
  "org_clock_in validates and reports; it opens no clock and writes
nothing.  The reply is what `bin/hooks/queue-append' sees, so it must
not start with `Error:' -- that prefix is the hook's signal to drop the
event."
  (claude-code-ide-org-test--with-heading
    (let ((before (claude-code-ide-org-test--disk-contents file))
          (result (claude-code-ide-org-clock-in id "clarify backend schema design")))
      (should (equal "Queued clock_in on \"Test heading\"; pending review." result))
      (should-not (string-prefix-p "Error:" result))
      (should-not (org-clocking-p))
      (should-not (buffer-modified-p (get-file-buffer file)))
      (should (equal before (claude-code-ide-org-test--disk-contents file)))
      (should-not (string-match-p "CLOCK:" (claude-code-ide-org-test--disk-contents file))))))

(ert-deftest claude-code-ide-org-test-clock-in-still-rejects-a-bad-id ()
  "The one job left: a typo'd :ID: must come back as `Error:' so the
queue never accepts an event that cannot be applied."
  (claude-code-ide-org-test--with-heading
    (should (string-prefix-p "Error:" (claude-code-ide-org-clock-in "no-such-id")))))

(ert-deftest claude-code-ide-org-test-clock-out-queues-without-closing ()
  "org_clock_out reports and does nothing else -- including when a clock
IS running.  That case is not hypothetical: the only clock that can be
running now belongs to the human's own `org-clock-in', and closing it
would both destroy their interval and attribute this session's work to
whatever they happened to be clocking."
  (claude-code-ide-org-test--with-heading
    (should (equal "Queued clock_out; pending review." (claude-code-ide-org-clock-out)))
    (claude-code-ide-org-test--clock-in-for-real id)
    (should (equal "Queued clock_out; pending review."
                   (claude-code-ide-org-clock-out "wrapping up")))
    (should (org-clocking-p))
    (should-not (string-match-p "=>" (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-set-todo-queues-without-transitioning ()
  "org_set_todo reports the transition as queued and changes no keyword.
The `(was X)' clause is a contract with `bin/hooks/queue-append', which
recovers `from' from it with a sed -- so this asserts the shape that sed
matches, not merely that the words appear."
  (claude-code-ide-org-test--with-heading
    (let ((result (claude-code-ide-org-set-todo id "DOING" "starting the cutover")))
      (should (equal "Queued todo -> DOING (was TODO): \"Test heading\"; pending review."
                     result))
      ;; The literal recovery `bin/hooks/queue-append' performs:
      ;;   sed -n 's/.*(was \([^)]*\)).*/\1/p'
      (should (string-match ".*(was \\([^)]*\\)).*" result))
      (should (equal "TODO" (match-string 1 result))))
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker)
                            (org-get-todo-state))))
    (should-not (buffer-modified-p (get-file-buffer file)))
    (should (string-match-p "^\\* TODO Test heading"
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-set-todo-reports-none-for-keywordless-heading ()
  "A heading with no keyword must report `(was none)', never an empty
string: the queue has to keep \"had no keyword\" distinguishable from
\"we do not know\", or the staleness check silently stops firing."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker)
      (let ((org-inhibit-logging t)) (org-todo ""))
      (save-buffer))
    (let ((result (claude-code-ide-org-set-todo id "NEXT")))
      (should (string-match-p "(was none)" result))
      (should-not (string-prefix-p "Error:" result)))))

(ert-deftest claude-code-ide-org-test-set-todo-refuses-a-no-op-transition ()
  "Setting the state a heading already holds must not reach the queue.

TODO.org :ID: cc0c17a7. Such an event has nothing for apply to do and
org has no state change to log, so left queued it is offered at review,
marked, and only then fails -- hours after the context that would
explain it. Four occurrences in one day.

The `Error:' prefix is asserted specifically, not merely that a refusal
happened: `bin/hooks/queue-append' decides whether to write the event by
testing that prefix, so the prefix IS the refusal. A politely-worded
reply without it would queue the no-op anyway."
  (claude-code-ide-org-test--with-heading
    (let ((result (claude-code-ide-org-set-todo id "TODO" "already there")))
      (should (string-prefix-p "Error:" result))
      (should (string-match-p "already holds TODO" result))
      ;; Names the heading, so a caller with several in flight can tell
      ;; which one it was.
      (should (string-match-p "Test heading" result)))
    ;; A real transition on the same heading is unaffected -- the check
    ;; must not have swallowed the ordinary path.
    (should (string-prefix-p
             "Queued todo -> DOING (was TODO)"
             (claude-code-ide-org-set-todo id "DOING" "a real change")))
    ;; And a keyword-less heading going to a real keyword is not a no-op,
    ;; even though `from' renders as the string "none".
    (claude-code-ide-org--at-id
     id (lambda () (let ((org-inhibit-logging t)) (org-todo 'none)) (save-buffer)))
    (should (string-prefix-p
             "Queued todo -> TODO (was none)"
             (claude-code-ide-org-set-todo id "TODO" "from keywordless")))))

(ert-deftest claude-code-ide-org-test-set-todo-rejects-an-undeclared-keyword ()
  "A keyword this file's own `#+TODO:' line does not declare is refused
here, where the model can see why, rather than at apply time in front of
a human with no way to tell whose typo it was.  Validated against
`org-todo-keywords-1' (buffer-local, derived from the file) rather than
a list hard-coded in the wrapper."
  (claude-code-ide-org-test--with-heading
    (let ((result (claude-code-ide-org-set-todo id "DOIGN")))
      (should (string-prefix-p "Error:" result))
      (should (string-match-p "not a TODO keyword" result))
      (should (string-match-p "DOING" result)))
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker)
                            (org-get-todo-state))))))

;;; Clock status file -------------------------------------------------------

(ert-deftest claude-code-ide-org-test-clock-status-file-reflects-active-clock ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--clock-in-for-real id)
    (should (file-exists-p claude-code-ide-org-clock-status-file))
    (let ((status (json-read-file claude-code-ide-org-clock-status-file)))
      (should (eq t (cdr (assq 'active status))))
      (should (equal "Test heading" (cdr (assq 'heading status))))
      (should (equal id (cdr (assq 'id status))))
      (should (stringp (cdr (assq 'start status)))))))

(ert-deftest claude-code-ide-org-test-clock-status-file-reflects-idle-on-clock-out ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--clock-in-for-real id)
    (org-clock-out)
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
      (claude-code-ide-org-test--clock-in-for-real id)
      (should (org-clocking-p))
      (should (not (file-exists-p claude-code-ide-org-clock-status-file))))))

;; The session-pause/resume tests that stood here were deleted with the
;; functions at the 2026-08-11 cutover (TODO.org :ID:
;; feba67eb-35b3-48bd-a892-8ecd47ca52e0). They asserted that a turn
;; boundary closed and reopened a live clock, and that a session could
;; not pause a clock another session owned -- a concurrency guard whose
;; entire premise was several sessions writing to one live clock. No
;; session writes live state now, so there is nothing left to contend
;; over; what a turn boundary produces is a queue line, covered by
;; bin/queue-append-test.

(ert-deftest claude-code-ide-org-test-set-todo-never-pops-the-note-buffer ()
  "WAITING and CANCELLED are `@'-flagged (note required) in this project's
`#+TODO:' line.  Driving those through `org-todo' non-interactively is
what hangs (TODO.org :ID: 04d0e7d5-ab6b-4972-925d-d517484c7595), and the
wrapper used to need `org-inhibit-logging' bound to t to survive them.
It no longer calls `org-todo' at all, so this is now a cheap structural
guard: if anyone ever restores a live write here, the `@' keywords are
where it will show up first."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-set-todo id "WAITING")
    (should (not (get-buffer "*Org Note*")))
    (claude-code-ide-org-set-todo id "CANCELLED")
    (should (not (get-buffer "*Org Note*")))
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker)
                            (org-get-todo-state))))))

;;; claude-code-ide-org-archive ------------------------------------------------

(ert-deftest claude-code-ide-org-test-archive-moves-heading-and-saves ()
  "Regression test: org_archive must persist the cut subtree to the
source file, not just the archive target. It previously left the
source file's on-disk copy of the heading in place, since
`org-archive-subtree' was never followed by `save-buffer'."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--set-todo-for-real id "DONE")
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

(ert-deftest claude-code-ide-org-test-archive-moves-subtree-with-children ()
  "Archiving must move the whole subtree, not just the heading line.

Characterisation test, written before the 2026-08-17 archive sweep rather
than after it.  `claude-code-ide-org-archive' has shipped for weeks and
every existing test covers a *childless* heading -- yet the sweep's two
largest calls move subtrees of 3 and 31 children, b5f7c5c7 alone being
4,386 lines.  This asserts the behaviour the operation depends on before
it depends on it.

Note the level arithmetic, the part most likely to surprise.  Where the
archive target names a heading after `::', org pastes beneath it and a
level-1 source lands at level 2.  This project's target has had an *empty*
olpath since 2026-08-31, so a level-1 source stays at level 1 and its child
at level 2 -- the archive mirrors the source file's shape instead of being
nested one deeper inside a wrapper heading.  Relative depth is preserved
either way.  Flattening happens only when a *child* is archived directly."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file (concat "** DONE Child heading\n"
                  ":PROPERTIES:\n"
                  ":ID:       test-0002\n"
                  ":END:\n"
                  "Child body prose.\n"))
    (claude-code-ide-org-test--set-todo-for-real id "DONE")
    (claude-code-ide-org-archive id)
    (let ((src (claude-code-ide-org-test--disk-contents file))
          (arch (claude-code-ide-org-test--disk-contents archive-file)))
      ;; The source loses the entire subtree.  Checking the child's *body*
      ;; as well as its heading is deliberate: a cut that took the heading
      ;; line but orphaned its prose would satisfy a heading-only check.
      (should-not (string-match-p "Test heading" src))
      (should-not (string-match-p "Child heading" src))
      (should-not (string-match-p "Child body prose" src))
      ;; Both arrive, at the right levels, with the child still nested.
      (should (string-match-p "^\\* DONE Test heading" arch))
      (should (string-match-p "^\\*\\* DONE Child heading" arch))
      (should (string-match-p "Child body prose" arch))
      ;; The child carries its own :ID: and must still resolve afterwards.
      (should (org-id-find "test-0002" 'marker)))))

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
    (claude-code-ide-org-test--clock-in-for-real id)
    (with-current-buffer (get-file-buffer file) (save-buffer))
    (sleep-for 0.2)
    (let ((entry (car (last (claude-code-ide-org-test--audit-log-entries file)))))
      (should entry)
      ;; "hand-edit", not "org_clock_in": the wrapper no longer mutates,
      ;; so a real clock-in reaching org is by definition either apply or
      ;; a human at the keyboard. The audit log hooks org-native events
      ;; rather than the wrappers precisely so it still sees this.
      (should (equal "hand-edit" (cdr (assq 'tool entry))))
      (should (equal id (cdr (assq 'id entry))))
      (should (equal "saved" (cdr (assq 'result entry)))))))

(ert-deftest claude-code-ide-org-test-audit-log-apply-hashes-match-disk ()
  "The audit log's before/after hashes must equal independently computed
hashes of the file's real on-disk content -- proving they are
trustworthy, not merely present, and that they differ (a mutation
actually reached disk) rather than accidentally matching.

Exercised through apply, which is the only writer left after the
2026-08-11 cutover; this test used to drive the clock-in/clock-out
wrappers, which no longer touch a buffer at all."
  (claude-code-ide-org-test--with-heading
    (let ((before (claude-code-ide-org-test--sha256-disk file)))
      (should-not (claude-code-ide-org--review-apply-item
                   (list :type 'clock :id id
                         :start (date-to-time "2026-08-06T09:00:00-0500")
                         :end (date-to-time "2026-08-06T09:15:00-0500")
                         :agent nil :suggested nil :events nil)))
      (claude-code-ide-org--audit-flush)
      (let* ((after (claude-code-ide-org-test--sha256-disk file))
             (entries (claude-code-ide-org-test--audit-log-entries file))
             (entry (car (last entries))))
        (should entry)
        (should (equal "org_review_apply" (cdr (assq 'tool entry))))
        (should (equal id (cdr (assq 'id entry))))
        (should (equal file (cdr (assq 'file entry))))
        (should (equal after (cdr (assq 'after_sha256 entry))))
        (should (not (equal before after)))
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
    (claude-code-ide-org-test--set-todo-for-real id "DONE")
    (claude-code-ide-org--audit-flush) ; drain the state-change record first
    (claude-code-ide-org-archive id)
    (claude-code-ide-org--audit-flush)
    (let ((entry (car (last (claude-code-ide-org-test--audit-log-entries file)))))
      (should entry)
      (should (equal "org_archive" (cdr (assq 'tool entry))))
      (should (equal id (cdr (assq 'id entry))))
      (should (equal file (cdr (assq 'file entry))))
      (should (equal "saved" (cdr (assq 'result entry))))
      (should (not (equal (cdr (assq 'before_sha256 entry)) (cdr (assq 'after_sha256 entry))))))))

(ert-deftest claude-code-ide-org-test-set-todo-queues-a-transition-a-blocker-would-refuse ()
  "A transition `org-blocker-hook' would refuse still queues, and the
heading does not move.

The inverse of what this asserted before the cutover, and deliberately
so: the wrapper used to run `org-todo' and report the refusal, but it
was answering \"is this allowed?\" against a file that had already
moved.  Now nothing moves until apply, `org-todo' runs there, and the
blocker gets its say in front of a human who can respond to it.
Queueing an event that may be refused later is the design, not a gap --
the queue records intent, and apply is where intent meets the file."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "** TODO Child heading\n")
    (save-buffer)
    (let ((org-blocker-hook (list 'org-block-todo-from-children-or-siblings-or-parent))
          (org-enforce-todo-dependencies t))
      (should (string-prefix-p "Queued todo -> DONE"
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
        (insert (concat "#+TODO: TODO NEXT(n!) DOING(d!) WAITING(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n"
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
    (claude-code-ide-org-test--set-todo-for-real id "DOING")
    (unless (org-clocking-p) (claude-code-ide-org-test--clock-in-for-real id))
    (should (org-clocking-p))
    ;; Driven through org-todo directly, which is where the hook lives
    ;; and -- since the cutover -- the only path that reaches it: apply
    ;; and hand-edits. A blocked org-todo aborts silently when not
    ;; called interactively, so the resulting state is the assertion.
    (claude-code-ide-org-test--set-todo-for-real id "DONE")
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
    (claude-code-ide-org-test--set-todo-for-real id "DOING")
    (when (org-clocking-p) (org-clock-out))
    (should (not (org-clocking-p)))
    (claude-code-ide-org-test--set-todo-for-real id "DONE")
    (should (equal "DONE" (org-with-point-at (org-id-find id 'marker)
                            (org-get-todo-state))))))

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
    (let ((claude-code-ide-org-auto-clock-in-on-doing t)
          (org-trigger-hook (list #'claude-code-ide-org--trigger-auto-clock-in))
          (other-id "test-0002"))
      (goto-char (point-max))
      (insert (concat "* TODO Other heading                                               :code:\n"
                       ":PROPERTIES:\n"
                       ":ID:       " other-id "\n"
                       ":END:\n"))
      (save-buffer)
      (org-id-update-id-locations (list file))
      (claude-code-ide-org-test--set-todo-for-real id "DOING")
      (unless (org-clocking-p) (claude-code-ide-org-test--clock-in-for-real id))
      (should (org-clocking-p))
      ;; The clock is running on `id', not `other-id' -- going DONE on
      ;; `other-id' must be permitted.
      (claude-code-ide-org-test--set-todo-for-real other-id "DONE")
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
    (let ((claude-code-ide-org-auto-clock-in-on-doing t))
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
                              (buffer-string)))))))

(ert-deftest claude-code-ide-org-test-trigger-clocks-by-default ()
  "A heading going DOING opens a clock, and that is the default again.

Asserted against `claude-code-ide-org-auto-clock-in-on-doing''s real
value rather than a let-binding: the default IS the claim, and every
other trigger test in this file binds the flag explicitly, so this is the
only one that would notice it changing.

It was nil between 2026-08-18 and 2026-08-19. The defect that took it
away was double counting -- a trigger-opened clock and a queue-derived
span covering the same period on one heading -- and what let it come back
is `claude-code-ide-org--subtract-intervals\' (TODO.org :ID: dadc08cf),
which makes apply yield to whatever this trigger already recorded. The
two mechanisms now compose instead of summing, which is pinned by
`claude-code-ide-org-test-apply-yields-to-a-hand-clocked-interval\'."
  (claude-code-ide-org-test--with-heading
    (let ((org-trigger-hook (list #'claude-code-ide-org--trigger-auto-clock-in)))
      (should claude-code-ide-org-auto-clock-in-on-doing)
      (should-not (org-clocking-p))
      (org-with-point-at (org-id-find id 'marker) (org-todo "DOING"))
      (should (org-clocking-p))
      (should (equal id (org-with-point-at org-clock-marker (org-entry-get nil "ID"))))
      (should (equal "DOING" (org-with-point-at (org-id-find id 'marker)
                               (org-get-todo-state)))))))

(ert-deftest claude-code-ide-org-test-no-source-line-claims-the-trigger-is-off ()
  "No docstring or comment may assert in the present tense that
`claude-code-ide-org-auto-clock-in-on-doing' is off, while its standard
value is t.

*This is the defect it exists for, not a general prose lint.*  TODO.org
:ID: 6a21e08b: `eca3a77' re-enabled the variable on 2026-08-19 and
updated the `defcustom' but not its readers, so
`--trigger-auto-clock-in''s docstring went on telling the reader the
function was inert -- for a week, past a green suite and a clean
`bin/lint-org', and it very nearly landed the wrong answer in a heading
body.  That heading's complaint was precisely that such a contradiction
\"is invisible to every test\"; this is the test.

Scans *file text* rather than loaded docstrings, because half the drift
was in `config-test.el' comments, which are not docstrings and would
otherwise stay unguarded.

*The needles are assembled with `concat' rather than written out, and
this docstring spells them hyphenated*, because the scan reads the file
this test lives in: a needle written literally anywhere here is found by
its own search.  Discovered the moment it was first run.  The two are
off-by-default and which-is-nil.

*The needles are phrase-level, so the rule they actually enforce is
\"do not use that phrasing at all -- say *when* instead\".*  A historical
claim is welcome and several are kept, but it has to be worded so the
dates carry it: \"Off between 2026-08-18 and 2026-08-19\" passes, while
the same fact written as off-by-default-for-a-day does not.  That is a
narrower rule than it first looks, and it is the right one: the phrasing
is what a reader takes as current, whatever clause follows it.  Found by
running this -- one of the fixes made alongside it tripped it.

*What this does not cover, stated so nobody trusts it further than it
goes*: it pins two phrasings that actually drifted, not the meaning.
Prose asserting the same falsehood in new words passes.  A regression
test, in the ordinary sense."
  (skip-unless claude-code-ide-org-test--repo-root)
  (should (eval (car (get 'claude-code-ide-org-auto-clock-in-on-doing
                          'standard-value))))
  (let ((needles (list (concat "off by " "default")
                       (concat "which is " "nil")))
        (hits nil))
    (dolist (name '("config.el" "config-test.el"))
      (let ((file (expand-file-name
                   (concat "modules/tools/claude-code-ide-org/" name)
                   claude-code-ide-org-test--repo-root)))
        (skip-unless (file-readable-p file))
        (with-temp-buffer
          (insert-file-contents file)
          (dolist (needle needles)
            (goto-char (point-min))
            (let ((case-fold-search t))
              (while (re-search-forward (regexp-quote needle) nil t)
                ;; Collect where, not just whether -- a bare nil failure
                ;; on a whole-file scan tells whoever gets it nothing.
                (push (format "%s:%d: %S" name (line-number-at-pos) needle)
                      hits)))))))
    (should-not (nreverse hits))))

(ert-deftest claude-code-ide-org-test-trigger-hook-skips-clock-in-when-already-clocked-there ()
  "If a clock is already running on the heading being set to DOING
(e.g. via org_clock_in called ahead of the state change), the trigger
must not additionally invoke `org-clock-in' -- no second, duplicate
open CLOCK line."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--clock-in-for-real id)
    (org-with-point-at (org-id-find id 'marker) (org-todo "DOING"))
    (should (org-clocking-p))
    (let ((disk (with-current-buffer (get-file-buffer file) (buffer-string)))
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
    (org-with-point-at (org-id-find id 'marker) (org-todo "WAITING"))
    (should (not (org-clocking-p)))))

;; Container exemption -- TODO.org :ID: ab75d6d2-0e59-405d-92c6-2c67488db133.
;; Each of these binds `org-trigger-hook' down to the auto-clock-in
;; function alone, the same way the DONE-blocker test above does: adding
;; a child heading creates a second sibling group, which the single-NEXT
;; triggers would act on for reasons unrelated to what is under test.

(defun claude-code-ide-org-test--add-child (file text)
  "Append TEXT as a child heading of the fixture heading in FILE, save,
and refresh org-id's locations so `org-id-find' sees any new :ID:."
  (with-current-buffer (get-file-buffer file)
    (goto-char (point-max))
    (insert text)
    (save-buffer))
  (org-id-update-id-locations (list file)))

(ert-deftest claude-code-ide-org-test-container-heading-p-needs-a-keyword-child ()
  "The container predicate is norang's lazy definition: a descendant
carrying a TODO keyword. A childless heading is not a container, and
neither is one whose only child carries no keyword -- otherwise every
heading with a prose sub-section would be exempted from clocking."
  (claude-code-ide-org-test--with-heading
    (should (not (org-with-point-at (org-id-find id 'marker)
                   (claude-code-ide-org--container-heading-p))))
    (claude-code-ide-org-test--add-child file "** Just a sub-section\n")
    (should (not (org-with-point-at (org-id-find id 'marker)
                   (claude-code-ide-org--container-heading-p))))
    (claude-code-ide-org-test--add-child file "** TODO A real child\n")
    (should (org-with-point-at (org-id-find id 'marker)
              (claude-code-ide-org--container-heading-p)))
    ;; The child itself is a leaf, and must not be exempted.
    (should (not (org-with-point-at (org-id-find id 'marker)
                   (org-goto-first-child)
                   (claude-code-ide-org--container-heading-p))))))

(ert-deftest claude-code-ide-org-test-ensure-cookie-inserts-only-when-absent ()
  "`--ensure-statistics-cookie-at-point' establishes the slot org will not.

TODO.org :ID: 28415ca8. `org-update-statistics-cookies' *updates* a
cookie and never *inserts* one -- measured 2026-08-26 -- so a slice whose
creator did not type `[/]' was inert to every later refresh, silently and
permanently.

Idempotence is asserted, not assumed: this runs on every apply, so an
inserter that appended a second `[/]' each time would corrupt the
headline within a day.

The tagged case is the one that actually bites. Org requires tags to end
the headline, so appending to the raw line yields `... :code: [/]', which
org does not read as a cookie at all -- a fix that looks applied and
is not."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker)
      ;; The fixture heading carries a :code: tag, so this is the tagged case.
      (should (claude-code-ide-org--ensure-statistics-cookie-at-point))
      (let ((h (org-get-heading t t t t)))
        (should (string-match-p "\\[/\\]" h))
        ;; Position, not just presence. 13 of the corpus's 14 cookies sit
        ;; immediately after the keyword and the one exception was written
        ;; by this function -- asserting presence alone is what let that
        ;; through for two days.
        (should (string-prefix-p "[/] " h))
        ;; Cookie inside the headline text, tags still terminal.
        (should (equal '("code") (org-get-tags nil t))))
      ;; Idempotent: a second call inserts nothing.
      (should-not (claude-code-ide-org--ensure-statistics-cookie-at-point))
      (should (equal 1 (cl-count ?/ (org-get-heading t t t t))))
      ;; And org will now actually fill it, which is the whole point.
      (org-update-statistics-cookies nil)
      (should (string-match-p "\\[[0-9]*/[0-9]*\\]"
                              (org-get-heading t t t t))))))

(ert-deftest claude-code-ide-org-test-refresh-slice-self-heals-a-missing-cookie ()
  "A cookie-less slice gains one through the ordinary refresh path.

TODO.org :ID: 28415ca8, found on :ID: 979e02b6 by the user after it had
run a whole slice's life uncookied. Asserts the count too, not just
presence: a `[-]' member is not done and must not be counted as such,
which is what makes 1-of-2 rather than 2-of-2 the right answer here."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker)
      (org-entry-put nil "KIND" "slice")
      (org-entry-put nil "COOKIE_DATA" "checkbox recursive")
      (org-end-of-meta-data t)
      (insert "- [X] [[id:zzz-1][zzz-1]] DONE a finished member\n"
              "- [-] [[id:zzz-2][zzz-2]] REVIEW a member in review\n")
      (save-buffer))
    (let ((claude-code-ide-org-query-files (list file)))
      (claude-code-ide-org-refresh-slice))
    (should (equal "1/2"
                   (let ((h (org-with-point-at (org-id-find id 'marker)
                              (org-get-heading t t t t))))
                     (and (string-match "\\[\\([0-9]+/[0-9]+\\)\\]" h)
                          (match-string 1 h)))))))

(ert-deftest claude-code-ide-org-test-grouping-heading-p-covers-both-kinds ()
  "The grouping predicate is the union of the two ways a heading can be a
grouping, and is nil for a leaf.

TODO.org :ID: 95c27fca. A container is *emergent* -- it acquires
keyworded children -- and a slice is *declared*, by `:KIND: slice', so
neither existing predicate can answer for the other without
contradicting its own docstring. The union is what the two triggers
actually meant all along: a heading whose time and whose next action
live in its members."
  (claude-code-ide-org-test--with-heading
    ;; A bare leaf: neither.
    (should-not (org-with-point-at (org-id-find id 'marker)
                  (claude-code-ide-org--grouping-heading-p)))
    ;; Declared: a slice, with no children at all.
    (org-with-point-at (org-id-find id 'marker)
      (org-entry-put nil "KIND" "slice")
      (save-buffer))
    (should (org-with-point-at (org-id-find id 'marker)
              (claude-code-ide-org--slice-p)))
    (should-not (org-with-point-at (org-id-find id 'marker)
                  (claude-code-ide-org--container-heading-p)))
    (should (org-with-point-at (org-id-find id 'marker)
              (claude-code-ide-org--grouping-heading-p)))
    ;; Emergent: drop the declaration, add a keyworded child.
    (org-with-point-at (org-id-find id 'marker)
      (org-entry-delete nil "KIND")
      (save-buffer))
    (should-not (org-with-point-at (org-id-find id 'marker)
                  (claude-code-ide-org--grouping-heading-p)))
    (claude-code-ide-org-test--add-child file "** TODO A real child\n")
    (should (org-with-point-at (org-id-find id 'marker)
              (claude-code-ide-org--container-heading-p)))
    (should (org-with-point-at (org-id-find id 'marker)
              (claude-code-ide-org--grouping-heading-p)))))

(ert-deftest claude-code-ide-org-test-trigger-hook-skips-a-slice ()
  "Setting a slice to DOING must open no clock on the slice itself.

TODO.org :ID: 95c27fca, measured before the fix as `(:container-p nil
:auto-clock-in t :would-clock t)': the slice's members are `[[id:...]]'
links rather than descendants, so `--container-heading-p' said nil and
the exemption did not apply -- while its *reason* applied with full
force, since every referent carries its own clock.

The trigger is bound ON explicitly: a slice exempted from a trigger that
never fires would assert nothing.

Deliberately paired with a leaf in the same test. An exemption is only
correct if it is also *narrow*, and a predicate that returned t for
everything would pass the first half alone."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-auto-clock-in-on-doing t)
          (org-trigger-hook (list #'claude-code-ide-org--trigger-auto-clock-in)))
      (org-with-point-at (org-id-find id 'marker)
        (org-entry-put nil "KIND" "slice")
        (save-buffer))
      (org-with-point-at (org-id-find id 'marker) (org-todo "DOING"))
      (should-not (org-clocking-p))
      ;; Narrowness: the same transition on a plain leaf still clocks.
      (claude-code-ide-org-test--add-child
       file "* TODO A leaf\n:PROPERTIES:\n:ID:       test-leaf-1\n:END:\n")
      (org-with-point-at (org-id-find "test-leaf-1" 'marker) (org-todo "DOING"))
      (should (org-clocking-p))
      (should (equal "test-leaf-1"
                     (org-with-point-at org-clock-marker (org-entry-get nil "ID")))))))


(ert-deftest claude-code-ide-org-test-trigger-hook-skips-container-headings ()
  "Setting a container to DOING must NOT open a clock on it. Org already
rolls a subtree's time up to its parent natively, so a parent's own
CLOCK line adds a second quantity inside the same total rather than
producing the roll-up -- measured on TODO.org :ID: b5f7c5c7, where the
epic's own 1:08 was indistinguishable from its children's 13:44 once
summed. Driven through a bare `org-todo', because since the cutover a
hand-edit in Emacs is the only path that still reaches this trigger:
apply binds `claude-code-ide-org--auto-clock-in-active' throughout."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-auto-clock-in-on-doing t)
          (org-trigger-hook (list #'claude-code-ide-org--trigger-auto-clock-in)))
      (claude-code-ide-org-test--add-child file "** TODO A real child\n")
      (should (not (org-clocking-p)))
      (org-with-point-at (org-id-find id 'marker) (org-todo "DOING"))
      (should (not (org-clocking-p)))
      (should (not (string-match-p "CLOCK: \\["
                                   (with-current-buffer (get-file-buffer file)
                                     (buffer-string)))))
      ;; The state change itself must still happen -- this exempts the
      ;; clock, not the transition.
      (should (equal "DOING" (org-with-point-at (org-id-find id 'marker)
                               (org-get-todo-state)))))))

(ert-deftest claude-code-ide-org-test-trigger-hook-still-clocks-a-heading-with-a-plain-child ()
  "The discriminator for the test above: a heading whose only child
carries no TODO keyword is not a container, so DOING must still open a
clock exactly as it does for a childless leaf. Without this, a
predicate that merely tested `has any child' would pass the container
test and silently stop clocking ordinary headings."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-auto-clock-in-on-doing t)
          (org-trigger-hook (list #'claude-code-ide-org--trigger-auto-clock-in)))
      (claude-code-ide-org-test--add-child file "** Just a sub-section\n")
      (org-with-point-at (org-id-find id 'marker) (org-todo "DOING"))
      (should (org-clocking-p))
      (should (equal id (org-with-point-at org-clock-marker
                          (org-entry-get nil "ID")))))))

(ert-deftest claude-code-ide-org-test-container-still-accepts-a-deliberate-clock-in ()
  "The exemption is narrow by design: it suppresses the *automatic*
clock only. A parent's own coordination and planning time is real, so
an explicit `org-clock-in' on a container must still work -- a blanket
`only clock leaves' rule would discard that category."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-auto-clock-in-on-doing t)
          (org-trigger-hook (list #'claude-code-ide-org--trigger-auto-clock-in)))
      (claude-code-ide-org-test--add-child file "** TODO A real child\n")
      (claude-code-ide-org-test--clock-in-for-real id)
      (should (org-clocking-p))
      (should (equal id (org-with-point-at org-clock-marker
                          (org-entry-get nil "ID")))))))

;; The PLANNING -> DOING promotion tests stood here until the 2026-08-11
;; cutover (TODO.org :ID: feba67eb-35b3-48bd-a892-8ecd47ca52e0). They
;; covered two elisp functions that no longer exist: the promotion is
;; now a queue append made by bin/hooks/exitplanmode-promote-planning,
;; from the session's own queue file, with no Emacs in the path at all.
;; Its coverage is in bin/queue-append-test accordingly.

;;; Single NEXT action per level (org-trigger-hook) -------------------------
;;
;; Cover claude-code-ide-org--trigger-demote-conflicting-next and
;; claude-code-ide-org--trigger-auto-promote-sole-todo, registered
;; alongside the pair above.

(defun claude-code-ide-org-test--two-children (file)
  "Give the fixture heading two keyworded children and refresh org-id.

`NEXT' is only meaningful inside a container (TODO.org :ID: 62b65ad0),
so every demote test needs a real parent. The fixture heading becomes
one by acquiring these, which is `--container-heading-p''s own
definition -- nothing is declared."
  (claude-code-ide-org-test--add-child
   file (concat "** TODO Child A                                                    :code:\n"
                ":PROPERTIES:\n:ID:       test-0002\n:END:\n"))
  (claude-code-ide-org-test--add-child
   file (concat "** TODO Child B                                                    :code:\n"
                ":PROPERTIES:\n:ID:       test-0003\n:END:\n")))

(ert-deftest claude-code-ide-org-test-single-next-leaves-top-level-headings-alone ()
  "Two top-level headings both at NEXT must BOTH stay NEXT.

*Inverted 2026-08-26* (TODO.org :ID: 62b65ad0). This asserted the
opposite until then: that a top-level NEXT demoted its top-level peers.
The evidence says that was never right. `--map-siblings' walks with
`org-get-next-sibling', which at top level stops only at the file's
boundary -- so \"sibling group\" meant *every task in the corpus*, and
demoting among them asserts one next action for the whole file.

A category is a filing drawer, not a project. GTD's invariant is that a
live *project* has a next action, and a project here is a story or a
slice. Three of roughly eight real top-level auto-promotions ended up
parked as MAYBE, which is what a wrong nomination looks like after the
fact."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker) (org-todo "NEXT"))
    (goto-char (point-max))
    (insert (concat "* TODO Peer B                                                      :code:\n"
                    ":PROPERTIES:\n"
                    ":ID:       test-0002\n"
                    ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find "test-0002" 'marker) (org-todo "NEXT"))
    ;; Both survive.
    (should (equal "NEXT" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))
    (should (equal "NEXT" (org-with-point-at (org-id-find "test-0002" 'marker) (org-get-todo-state))))
    (save-buffer)
    (should-not (string-match-p "Auto-demoted"
                                (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-single-next-demote-note-falls-back-to-title ()
  "When the superseding sibling has no :ID:, the note names it by quoted
title rather than producing a broken link. A slightly stale name beats a
link that goes nowhere.

Runs inside a container: `NEXT' is only meaningful there (TODO.org
:ID: 62b65ad0)."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file (concat "** TODO Child A                                                    :code:\n"
                  ":PROPERTIES:\n:ID:       test-0002\n:END:\n"))
    ;; No :ID: on this one -- that is the case under test.
    (claude-code-ide-org-test--add-child file "** TODO Untracked child\n")
    (org-with-point-at (org-id-find "test-0002" 'marker) (org-todo "NEXT"))
    (org-with-point-at (org-id-find id 'marker)
      (org-goto-first-child)
      (org-get-next-sibling)
      (org-todo "NEXT"))
    (save-buffer)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "Auto-demoted: superseded by sibling \"Untracked child\" becoming NEXT"
                              disk)))))

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


(ert-deftest claude-code-ide-org-test-single-next-leaves-non-todo-sole-survivor-alone ()
  "A sole survivor sitting in WAITING (not TODO) must never be
force-promoted to NEXT."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker) (org-todo "WAITING"))
    (goto-char (point-max))
    (insert (concat "* NEXT Sibling B                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find "test-0002" 'marker) (org-todo "DONE"))
    (should (equal "WAITING" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))))

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
    (insert (concat "* WAITING Sibling B                                                   :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find id 'marker) (org-todo "NEXT"))
    (should (equal "NEXT" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))
    (should (equal "WAITING" (org-with-point-at (org-id-find "test-0002" 'marker) (org-get-todo-state))))))

(ert-deftest claude-code-ide-org-test-single-next-does-not-recreate-double-next-on-race ()
  "The core correctness case: a 2-child group with A already NEXT,
setting B to NEXT must not leave BOTH at NEXT -- the demote must see the
live buffer, not stale change-plist state.

Moved inside a container 2026-08-26 (TODO.org :ID: 62b65ad0); it used to
run against top-level headings, where there is no longer a sibling group."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--two-children file)
    (org-with-point-at (org-id-find "test-0002" 'marker) (org-todo "NEXT"))
    (org-with-point-at (org-id-find "test-0003" 'marker) (org-todo "NEXT"))
    (let ((next-count 0))
      (dolist (heading-id (list "test-0002" "test-0003"))
        (when (equal "NEXT" (org-with-point-at (org-id-find heading-id 'marker)
                              (org-get-todo-state)))
          (setq next-count (1+ next-count))))
      (should (= 1 next-count)))))

(ert-deftest claude-code-ide-org-test-single-next-pre-existing-invalid-state-collapses-to-one-next ()
  "Two children hand-constructed as already (invalidly) NEXT:
transitioning a third to NEXT must still leave exactly one NEXT across
the group.

Moved inside a container 2026-08-26 (TODO.org :ID: 62b65ad0)."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file (concat "** NEXT Child B                                                    :code:\n"
                  ":PROPERTIES:\n:ID:       test-0002\n:END:\n"
                  "** NEXT Child C                                                    :code:\n"
                  ":PROPERTIES:\n:ID:       test-0003\n:END:\n"
                  "** TODO Child D                                                    :code:\n"
                  ":PROPERTIES:\n:ID:       test-0004\n:END:\n"))
    (org-with-point-at (org-id-find "test-0004" 'marker) (org-todo "NEXT"))
    (let ((next-count 0))
      (dolist (heading-id (list "test-0002" "test-0003" "test-0004"))
        (when (equal "NEXT" (org-with-point-at (org-id-find heading-id 'marker)
                              (org-get-todo-state)))
          (setq next-count (1+ next-count))))
      (should (= 1 next-count))
      (should (equal "NEXT" (org-with-point-at (org-id-find "test-0004" 'marker)
                              (org-get-todo-state)))))))

(ert-deftest claude-code-ide-org-test-single-next-fires-through-bare-org-todo ()
  "The demote runs off `org-trigger-hook', so a bare `org-todo' reaches
it -- no MCP wrapper required. That is what makes it a safety net rather
than a convention.

Inside a container, per TODO.org :ID: 62b65ad0."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--two-children file)
    (org-with-point-at (org-id-find "test-0002" 'marker) (org-todo "NEXT"))
    (org-with-point-at (org-id-find "test-0003" 'marker) (org-todo "NEXT"))
    (should (equal "TODO" (org-with-point-at (org-id-find "test-0002" 'marker)
                            (org-get-todo-state))))
    (should (equal "NEXT" (org-with-point-at (org-id-find "test-0003" 'marker)
                            (org-get-todo-state))))))






(ert-deftest claude-code-ide-org-test-session-context-empty-when-nothing ()
  "No running clock and no WAITING headings: session-context reports
nothing, and the JSON wrapper collapses that to an empty hook object."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-query-files (list file)))
      (should (equal "" (claude-code-ide-org-session-context)))
      (should (equal "{}" (claude-code-ide-org--session-context-hook-json))))))

(ert-deftest claude-code-ide-org-test-session-context-includes-clocked-heading ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--clock-in-for-real id)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-session-context)))
      (should (string-match-p "\\`Currently clocked in: \"Test heading\"" result))
      (should (string-match-p (regexp-quote id) result))
      (should (string-match-p "test.org" result)))))

(ert-deftest claude-code-ide-org-test-session-context-includes-wait-headings ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* WAITING Blocked heading                                              :code:\n"
            ":PROPERTIES:\n:ID:       test-0002\n:END:\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-session-context)))
      (should (string-match-p "WAITING: \"Blocked heading\" (:ID: test-0002, in test.org)" result)))))

;; Abandoned DOING leaves -- TODO.org :ID: 9d7531f5-11c5-4203-89e3-56c3fe399df5.

(ert-deftest claude-code-ide-org-test-session-context-includes-abandoned-doing-leaf ()
  "A leaf left in DOING that the queue has nothing pending for is an
increment somebody walked away from, and is exactly what a starting
session needs told.

Wrapped in `claude-code-ide-org-test--with-queue' since the report began
keying on the queue (TODO.org :ID: e0904e93): without it this reads the
real ~/.claude/org-updates and its answer depends on the user's live
state."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org-test--with-heading
      (goto-char (point-max))
      (insert "* DOING Abandoned leaf                                              :code:\n"
              ":PROPERTIES:\n:ID:       test-0002\n:END:\n")
      (save-buffer)
      (let* ((claude-code-ide-org-query-files (list file))
             (result (claude-code-ide-org-session-context)))
        (should (string-match-p
                 "nothing ever queued for it: \"Abandoned leaf\" (:ID: test-0002, in test.org)"
                 result))))))

(ert-deftest claude-code-ide-org-test-nomination-reports-a-container-with-no-next ()
  "A container whose live members include no NEXT is named, with its
sole candidate.

TODO.org :ID: 62b65ad0. This replaces the trigger that used to set NEXT
by itself. The report states the fact and leaves the choice, which is
the contract the stale-interval and ceremony reports already keep --
and the reason a wrong nomination is no longer possible."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file (concat "** TODO The only candidate                                          :code:\n"
                  ":PROPERTIES:\n:ID:       test-0002\n:END:\n"))
    (let* ((claude-code-ide-org-query-files (list file))
           (lines (claude-code-ide-org--nomination-candidates-context)))
      (should (= 1 (length lines)))
      (should (string-match-p "no next action in \"Test heading\"" (car lines)))
      (should (string-match-p "one candidate, \"The only candidate\"" (car lines))))))

(ert-deftest claude-code-ide-org-test-nomination-is-quiet-when-a-next-exists ()
  "The whole value of the report is that it goes quiet when there is
nothing to do. A container that already has a NEXT is not named, and
neither is a plain leaf -- only a *container* can lack a next action,
because only a container is a project."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-query-files (list file)))
      ;; A bare leaf is never reported -- not by a predicate, but because
      ;; it has no members to have a next action among. That IS the
      ;; container test; a separate one would be redundant.
      (should-not (claude-code-ide-org--nomination-candidates-context))
      (claude-code-ide-org-test--add-child
       file (concat "** NEXT Already nominated                                           :code:\n"
                    ":PROPERTIES:\n:ID:       test-0002\n:END:\n"
                    "** TODO Another one                                                 :code:\n"
                    ":PROPERTIES:\n:ID:       test-0003\n:END:\n"))
      (should-not (claude-code-ide-org--nomination-candidates-context)))))

(ert-deftest claude-code-ide-org-test-nomination-counts-rather-than-picks ()
  "With several candidates the report counts them and names none.

That is the case no rule can decide, and the one the retired trigger
never reached: it only ever fired on a sole survivor. Naming one here
would be the same guess by a slower route."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--two-children file)
    (let* ((claude-code-ide-org-query-files (list file))
           (lines (claude-code-ide-org--nomination-candidates-context)))
      (should (= 1 (length lines)))
      (should (string-match-p "2 candidates" (car lines)))
      (should-not (string-match-p "Child A" (car lines)))
      (should-not (string-match-p "Child B" (car lines))))))

(ert-deftest claude-code-ide-org-test-nomination-handles-a-slice ()
  "A slice is a container whose members are links, so it is reported the
same way -- resolved through the referent index rather than by walking
children.

Both kinds matter: the user's decision was that NEXT belongs to
containers, \"slices and stories\", and a slice that reported nothing
would silently exempt exactly the grouping this project invented."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker)
      (org-entry-put nil "KIND" "slice")
      (save-buffer))
    (goto-char (point-max))
    (insert "* TODO A referent                                                   :code:\n"
            ":PROPERTIES:\n:ID:       test-0002\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find id 'marker)
      (org-end-of-meta-data t)
      (insert "- [ ] [[id:test-0002][test-0002]] TODO A referent\n")
      (save-buffer))
    (let* ((claude-code-ide-org-query-files (list file))
           (lines (claude-code-ide-org--nomination-candidates-context)))
      (should (= 1 (length lines)))
      (should (string-match-p "one candidate, \"A referent\"" (car lines))))))

(ert-deftest claude-code-ide-org-test-session-context-omits-doing-containers ()
  "A container in DOING is a true and unremarkable statement about the
project. Reporting it would add one permanent, never-changing line --
the failure mode this filter exists to prevent -- so it must be
excluded while an otherwise identical leaf is not."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* DOING Epic heading                                                :code:\n"
            ":PROPERTIES:\n:ID:       test-0002\n:END:\n"
            "** NEXT A real child                                                :code:\n"
            ":PROPERTIES:\n:ID:       test-0003\n:END:\n")
    (save-buffer)
    ;; The child is NEXT, not TODO, so the nomination advisory
    ;; (TODO.org :ID: 62b65ad0) stays quiet and this test keeps testing
    ;; only what it is named for. With a TODO child the container would
    ;; be reported as having no next action -- correctly, and by a
    ;; different rule.
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-session-context)))
      (should (not (string-match-p "Epic heading" result)))
      (should (equal "" result)))))

(ert-deftest claude-code-ide-org-test-session-context-does-not-repeat-the-clocked-heading ()
  "The clocked heading is already reported on its own line, so a DOING
heading that is currently clocked must not also appear as abandoned --
one heading, one line."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--set-todo-for-real id "DOING")
    ;; Clocked deliberately, not via the trigger. This used to rely on
    ;; `--trigger-auto-clock-in' firing on the DOING transition, which the
    ;; default switched off for the day between 2026-08-18 and 2026-08-19
    ;; -- and relying on it was wrong even before that, since what is under
    ;; test is how session-context reports a clocked heading, not what
    ;; opened the clock.
    (claude-code-ide-org-test--clock-in-for-real id)
    (should (org-clocking-p))
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-session-context)))
      (should (string-match-p "Currently clocked in" result))
      (should (not (string-match-p "not clocked" result))))))

(ert-deftest claude-code-ide-org-test-session-context-clocked-then-waits-order ()
  "When both a clocked heading and WAITING headings exist, the clocked
heading is reported first."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* WAITING Blocked heading                                              :code:\n"
            ":PROPERTIES:\n:ID:       test-0002\n:END:\n")
    (save-buffer)
    (claude-code-ide-org-test--clock-in-for-real id)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-session-context))
           (pos-clocked (string-match "Currently clocked in" result))
           (pos-wait (string-match "WAITING: " result)))
      (should (and pos-clocked pos-wait (< pos-clocked pos-wait))))))

(ert-deftest claude-code-ide-org-test-session-context-ignores-non-wait-states ()
  "A DONE heading must not be mistaken for a WAITING heading."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* DONE Finished heading                                             :code:\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-session-context)))
      (should (equal "" result)))))

(ert-deftest claude-code-ide-org-test-session-context-kills-buffers-it-opened ()
  "Scanning for WAITING headings must not leave stray buffers behind for
files that were not already open — but must leave alone (and not
kill) a file the user already had open."
  (claude-code-ide-org-test--with-heading
    (let* ((other-dir (file-name-as-directory (make-temp-file "claude-code-ide-org-test-other" t)))
           (other-file (expand-file-name "other.org" other-dir)))
      (unwind-protect
          (progn
            (with-temp-file other-file
              (insert "* WAITING Other file heading                                           :code:\n"))
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
    (claude-code-ide-org-test--clock-in-for-real id)
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
    (claude-code-ide-org-test--clock-in-for-real id)
    (let ((result (claude-code-ide-org--statusline-task-string)))
      ;; Default fixture :ID: is "test-0001" (9 chars) -- truncated to 8.
      (should (string-match-p "\\` | Test heading \\[test-000\\] (clocked in, " result)))))

(ert-deftest claude-code-ide-org-test-statusline-shows-clocked-out-task-from-history ()
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--clock-in-for-real id)
    (org-clock-out)
    (should (not (org-clocking-p)))
    (let ((result (claude-code-ide-org--statusline-task-string)))
      (should (string-match-p "\\` | Test heading \\[test-000\\] (clocked out, " result)))))

(ert-deftest claude-code-ide-org-test-statusline-truncates-long-heading-name ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-min))
    (re-search-forward "Test heading")
    (replace-match "This heading name is deliberately much longer than thirty characters")
    (save-buffer)
    (claude-code-ide-org-test--clock-in-for-real id)
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
      (claude-code-ide-org-test--clock-in-for-real other-id)
      (claude-code-ide-org-clock-out)
      (claude-code-ide-org-test--clock-in-for-real id)
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
    (claude-code-ide-org-test--clock-in-for-real id)
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

;; The two --guess-stop-time tests that stood here were retired with the
;; function on 2026-08-14 (TODO.org :ID: 7771fc63).  They asserted the
;; guess was computed correctly, which it was; what failed was the
;; premise that the clock predicts absence at all (:ID: 96a51c2f).
;; Replaced by the assertion below, which is about what the report must
;; NOT do -- the property that actually matters now.

(ert-deftest claude-code-ide-org-test-stale-report-asks-without-guessing ()
  "The stale-interval report must state the open timestamp and ask for
the stop time, never propose one. A plausible suggestion is harder to
reject than none (TODO.org :ID: 5ff5a4b8), so a guess that is wrong for
most observed gaps is worse than an honest question."
  (let* ((open (encode-time 0 0 14 15 6 2026)) ; 2026-06-15 14:00
         (findings (list (list :id "test-0001" :heading "Test heading"
                               :file "/tmp/test.org" :logbook-open open)))
         (report (claude-code-ide-org--format-stale-interval-report findings)))
    ;; States the fact it has.
    (should (string-match-p (regexp-quote "[2026-06-15 Mon 14:00]") report))
    (should (string-match-p "Test heading" report))
    ;; Asks for the one it does not have, and tells the relayer not to
    ;; invent it.
    (should (string-match-p "what time they actually stopped" report))
    (should (string-match-p "do not propose a time" report))
    ;; Carries no second, later timestamp that could read as a proposal.
    (should (= 1 (length (let ((all nil) (start 0))
                           (while (string-match "\\[20[0-9-]+ [A-Za-z]\\{3\\} [0-9:]+\\]"
                                                report start)
                             (push (match-string 0 report) all)
                             (setq start (match-end 0)))
                           all))))))

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
    (claude-code-ide-org-test--clock-in-for-real id)
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
               "#+TODO: TODO NEXT(n!) DOING(d!) WAITING(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n#+TAGS:"
               disk))
      ;; CLOCK line correctly closed with the right duration (3:45).
      (should (string-match-p
               "CLOCK: \\[2026-07-27 Mon 14:00\\]--\\[2026-07-27 Mon 17:45\\] =>  3:45"
               disk))
      ;; :SESSIONS: entry correctly closed too.
      ;; The "(recovered)" marker went with the :SESSIONS: drawer
      ;; (:ID: 9d2fcdad). The repaired CLOCK line asserted above already
      ;; carries the fact that the interval was closed after the event.
      (should-not (string-match-p "(recovered)" disk)))))

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

;;; Finding a drawer (TODO.org :ID: f42641ab) -------------------------------
;;
;; The fixture is the one the API probe used: a marker-shaped line inside
;; `#+begin_example' standing *before* the real drawer.  Three functions
;; used to carry their own copy of this search and only two looped past
;; the decoy; they now share `claude-code-ide-org--find-drawer'.

(defconst claude-code-ide-org-test--decoy-heading
  (concat "* TODO H\n"
          "#+begin_example\n"
          ":LOGBOOK:\n"
          "not a real drawer\n"
          ":END:\n"
          "#+end_example\n"
          ":LOGBOOK:\n"
          "CLOCK: [2026-08-14 Fri 10:00]--[2026-08-14 Fri 10:30] =>  0:30\n"
          ":END:\n")
  "A heading whose body holds a decoy drawer before its real one.")

(defmacro claude-code-ide-org-test--in-org (text &rest body)
  "Run BODY in a temp org buffer containing TEXT, point on the heading."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((org-inhibit-startup t))
       (insert ,text)
       (org-mode)
       (goto-char (point-min))
       ,@body)))

(ert-deftest claude-code-ide-org-test-find-drawer-skips-a-decoy ()
  "A drawer-shaped line inside #+begin_example is not a drawer, and must
not stop the search: the real drawer stands after it."
  (claude-code-ide-org-test--in-org claude-code-ide-org-test--decoy-heading
    (let ((element (claude-code-ide-org--find-drawer "LOGBOOK")))
      (should element)
      (should (org-element-type-p element 'drawer))
      ;; The one found must be the real drawer, identified by its content.
      (should (string-match-p
               "CLOCK:"
               (buffer-substring (org-element-contents-begin element)
                                 (org-element-contents-end element)))))))

(ert-deftest claude-code-ide-org-test-drawer-content-bounds-skips-a-decoy ()
  "The reader is the copy that used to give up at the first
marker-shaped line and report \"no drawer here\" for a heading that had
one — the whole of :ID: f42641ab."
  (claude-code-ide-org-test--in-org claude-code-ide-org-test--decoy-heading
    (let ((bounds (claude-code-ide-org--drawer-content-bounds "LOGBOOK")))
      (should bounds)
      (should (string-match-p "CLOCK:" (buffer-substring (nth 0 bounds)
                                                         (nth 1 bounds)))))))

(ert-deftest claude-code-ide-org-test-drawer-content-bounds-empty-drawer ()
  "An empty drawer must yield an empty-but-valid region, not (nil nil).
This is why the reader does not simply return
`org-element-contents-begin'/`-end': those are nil here, and callers do
arithmetic on the result."
  (claude-code-ide-org-test--in-org "* TODO H\n:LOGBOOK:\n:END:\n"
    (let ((bounds (claude-code-ide-org--drawer-content-bounds "LOGBOOK")))
      (should bounds)
      (should (integerp (nth 0 bounds)))
      (should (integerp (nth 1 bounds)))
      (should (= (nth 0 bounds) (nth 1 bounds)))
      (should (equal "" (buffer-substring (nth 0 bounds) (nth 1 bounds)))))))

(ert-deftest claude-code-ide-org-test-append-to-drawer-skips-a-decoy ()
  "The writer already looped past a decoy before the three searches were
unified; this pins that behaviour so the shared helper cannot regress
it."
  (claude-code-ide-org-test--in-org claude-code-ide-org-test--decoy-heading
    (claude-code-ide-org--append-to-drawer-1 "LOGBOOK" "- appended line")
    (let ((text (buffer-string)))
      ;; Landed in the real drawer, after the CLOCK line.
      (should (string-match-p "CLOCK:.*\n- appended line" text))
      ;; And not inside the example block.
      (should (string-match-p "not a real drawer\n:END:" text)))))

(ert-deftest claude-code-ide-org-test-drawer-contains-line-p-skips-a-decoy ()
  "The membership check must read the real drawer's contents, not the
decoy's — otherwise idempotency would compare against the wrong text."
  (claude-code-ide-org-test--in-org claude-code-ide-org-test--decoy-heading
    (should (claude-code-ide-org--drawer-contains-line-p
             "LOGBOOK" "CLOCK: [2026-08-14 Fri 10:00]--[2026-08-14 Fri 10:30] =>  0:30"))
    (should (not (claude-code-ide-org--drawer-contains-line-p
                  "LOGBOOK" "not a real drawer")))))

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

(ert-deftest claude-code-ide-org-test-consolidate-history-preserves-intervals-exactly ()
  "Consolidation must leave every closed CLOCK interval exactly as
recorded, including ones too short to survive the 5-minute rounding this
function used to apply. That rounding destroyed a reviewed,
human-confirmed interval minutes after apply wrote it (TODO.org :ID:
b74e0f19-5a26-4c83-9d70-8e1c5a2f6b04); the 0:01 and 0:02 intervals below
are the shape that used to vanish — the first rounded to zero and was
dropped, the second absorbed into a 5-minute block.

Consolidation's remaining job is ordering, and since :ID: af7d3687 that
order is ascending: org *inserts* CLOCK lines newest-first, so the input
below arrives reversed and is expected to come back oldest-first with
both intervals byte-identical apart from position."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             ":LOGBOOK:\n"
             "CLOCK: [2026-07-28 Tue 10:57]--[2026-07-28 Tue 10:59] =>  0:02\n"
             "CLOCK: [2026-07-28 Tue 10:53]--[2026-07-28 Tue 10:54] =>  0:01\n"
             ":END:\n"))
    (save-buffer)
    (let ((result (claude-code-ide-org-consolidate-history id)))
      ;; It reorders, so it reports doing so. Durations are left exactly
      ;; as recorded (:ID: b74e0f19) and there is no second drawer to
      ;; collapse (:ID: 9d2fcdad).
      (should (string-match-p "\\`Consolidated :LOGBOOK: on \"Test heading\"\\'" result)))
    (should (not (buffer-modified-p (get-file-buffer file))))
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      ;; Both intervals survive, unrounded and unmerged. Splitting on a
      ;; separator that occurs twice yields 3 parts.
      (should (= 3 (length (split-string disk "CLOCK:"))))
      ;; Oldest first now: the 10:53 interval leads.
      (should (string-match-p
               ":LOGBOOK:\nCLOCK: \\[2026-07-28 Tue 10:53\\]--\\[2026-07-28 Tue 10:54\\] =>  0:01\nCLOCK: \\[2026-07-28 Tue 10:57\\]--\\[2026-07-28 Tue 10:59\\] =>  0:02\n:END:"
               disk))
      ;; Running it again is a no-op, which is what makes the new order
      ;; a fixed point rather than something that flips on every pass.
      (should (string-match-p "\\`Nothing to consolidate"
                              (claude-code-ide-org-consolidate-history id)))
      ;; No drawer is created, and none is expected: consolidation writes
      ;; :LOGBOOK: and nothing else now.
      (should-not (string-match-p ":SESSIONS:" disk)))))

(ert-deftest claude-code-ide-org-test-logbook-sorts-every-shape-on-one-timeline ()
  "The shape af7d3687 asked for: one ascending timeline across all four
entry styles, not per-style groups that happen to be sorted within
themselves. A state transition at 14:10 belongs between the interval
that ended at 14:00 and the one starting at 14:20.

The continuation is the dangerous part -- a `State ... \\\\' note owns the
indented line beneath it, and any reordering that separates the two
corrupts the note. That is the loss ba8249c1 already fixed once, so this
deliberately places a note *with* a continuation between two clock lines
that must move past it."
  (let* ((text (concat
                "CLOCK: [2026-08-06 Thu 15:00]--[2026-08-06 Thu 15:45] =>  0:45\n"
                "- State \"WAITING\"       from \"DOING\"      [2026-08-06 Thu 14:10] \\\\\n"
                "  request credentials from DBA\n"
                "CLOCK: [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:15] =>  0:15\n"
                "- <2026-08-06 Thu 13:30>--<2026-08-06 Thu 14:10> design tradeoffs\n"
                "- [2026-08-06 Thu 14:20]--[2026-08-06 Thu 14:50] write unit tests\n"))
         (out (claude-code-ide-org--consolidate-logbook-text text))
         (lines (split-string out "\n" t)))
    ;; One ascending timeline: 09:00, 13:30, 14:10 (+ its continuation),
    ;; 14:20, 15:00.
    (should (string-prefix-p "CLOCK: [2026-08-06 Thu 09:00]" (nth 0 lines)))
    (should (string-prefix-p "- <2026-08-06 Thu 13:30>" (nth 1 lines)))
    (should (string-match-p "State \"WAITING\"" (nth 2 lines)))
    ;; The continuation moved with its note and stayed directly beneath it.
    (should (equal "  request credentials from DBA" (nth 3 lines)))
    (should (string-prefix-p "- [2026-08-06 Thu 14:20]" (nth 4 lines)))
    (should (string-prefix-p "CLOCK: [2026-08-06 Thu 15:00]" (nth 5 lines)))
    (should (= 6 (length lines)))
    ;; Nothing was lost: every input line is still present.
    (dolist (needle '("0:45" "0:15" "request credentials from DBA"
                      "design tradeoffs" "write unit tests" "State \"WAITING\""))
      (should (string-match-p (regexp-quote needle) out)))
    ;; And it is a fixed point -- sorting an already-sorted drawer is
    ;; identity, so consolidation cannot oscillate.
    (should (equal out (claude-code-ide-org--consolidate-logbook-text out)))))

(ert-deftest claude-code-ide-org-test-logbook-sort-reproduces-clock-template ()
  "`clock-template.org' is the shape af7d3687 named as the target, so the
strongest available check is that consolidating its drawer returns it
*byte-identical*: the documented shape is a fixed point, not merely
something close to one. It exercises all four entry styles, two notes
with continuations, and several timestamp ties in one input -- richer
than anything worth hand-writing, and it cannot drift from the doc,
because it is the doc."
  (skip-unless claude-code-ide-org-test--repo-root)
  (let ((template (expand-file-name "clock-template.org"
                                    claude-code-ide-org-test--repo-root)))
    (skip-unless (file-readable-p template))
    (with-temp-buffer
      (insert-file-contents template)
      (goto-char (point-min))
      (re-search-forward "^ *:LOGBOOK:\n")
      (let* ((beg (point))
             (end (progn (re-search-forward "^ *:END:") (match-beginning 0)))
             (body (buffer-substring-no-properties beg end)))
        (should (equal body
                       (claude-code-ide-org--consolidate-logbook-text body)))))))

(ert-deftest claude-code-ide-org-test-logbook-sort-is-stable-and-keeps-undated-lines ()
  "Entries sharing a timestamp keep the order they arrived in, so a CLOCK
line and the annotation describing the same span stay adjacent rather
than being reshuffled on every pass. Entries carrying no parseable
timestamp cannot be placed, so they are kept at the end in their original
order rather than dropped -- survival is the ba8249c1 lesson."
  (let* ((text (concat
                "- <2026-08-06 Thu 09:00>--<2026-08-06 Thu 09:15> annotation first\n"
                "CLOCK: [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:15] =>  0:15\n"
                "- a line with no timestamp at all\n"
                "- another undated line\n"))
         (out (claude-code-ide-org--consolidate-logbook-text text))
         (lines (split-string out "\n" t)))
    ;; Tie preserved: the annotation was first in, so it stays first.
    (should (string-match-p "annotation first" (nth 0 lines)))
    (should (string-prefix-p "CLOCK:" (nth 1 lines)))
    ;; Undated lines survive, at the end, in their original order.
    (should (equal "- a line with no timestamp at all" (nth 2 lines)))
    (should (equal "- another undated line" (nth 3 lines)))
    (should (= 4 (length lines)))))

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
lines) survive verbatim, alongside CLOCK lines kept exactly as recorded.
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
      ;; Open clock untouched; closed clock keeps its exact endpoints.
      (should (string-match-p "CLOCK: \\[2026-08-06 Thu 21:43\\]\\s-*$" disk))
      (should (string-match-p
               "CLOCK: \\[2026-08-06 Thu 15:44\\]--\\[2026-08-06 Thu 16:51\\] =>  1:07"
               disk))
      ;; The state-change note and its continuation line both survive.
      (should (string-match-p
               "- State \"NEXT\"       from \"TODO\"       \\[2026-08-06 Thu 12:07\\] \\\\\\\\"
               disk))
      (should (string-match-p
               "  Auto-promoted: sole remaining TODO in its sibling group\\."
               disk)))))

(ert-deftest claude-code-ide-org-test-consolidate-history-noop-when-nothing-to-do ()
  (claude-code-ide-org-test--with-heading
    (should (equal "Nothing to consolidate on \"Test heading\""
                   (claude-code-ide-org-consolidate-history id)))))

;;; Structural lint (TODO.org :ID: 3bd3402b) -------------------------------
;;
;; The heading's own caution: "Two of these assertions describe
;; conventions that are currently *unbroken*, so the lint will pass on
;; day one and prove nothing. Seed it against a deliberately broken copy
;; first." Every check below is fed a fixture that violates it, which is
;; that caution discharged mechanically rather than remembered.

(defun claude-code-ide-org-test--lint (text &optional ref-text)
  "Lint TEXT as a temp org file, returning findings as (SEVERITY . MSG).
REF-TEXT, when given, becomes a reference file: scanned for :ID:s but
not itself linted."
  (let* ((dir (file-name-as-directory (make-temp-file "lint-test" t)))
         (file (expand-file-name "TODO.org" dir))
         (ref (expand-file-name "notes.org" dir)))
    (unwind-protect
        (progn
          ;; The real files' keyword set, without which org does not
          ;; recognise MAYBE/DOING at all and a fixture using them reads
          ;; as a plain heading whose title happens to start with a word.
          (with-temp-file file
            (insert "#+TODO: TODO NEXT DOING WAITING MAYBE | DONE CANCELLED\n")
            (insert text))
          (when ref-text (with-temp-file ref (insert ref-text)))
          (claude-code-ide-org-lint (list file) (and ref-text (list ref))))
      (delete-directory dir t))))

(defun claude-code-ide-org-test--lint-matches (findings severity pattern)
  "Non-nil when FINDINGS holds a SEVERITY entry matching PATTERN."
  (seq-find (lambda (f)
              (and (eq severity (car f)) (string-match-p pattern (cdr f))))
            findings))

(ert-deftest claude-code-ide-org-test-lint-clean-file-has-no-findings ()
  "Positive control: a file obeying every convention reports nothing.
Without this the other tests could pass by the lint flagging everything.

*Reshaped 2026-08-27* (TODO.org :ID: 29439196). Level 1 is now where the
work lives, so a clean file is a level-1 task carrying :ID:, :CREATED:
and :CATEGORY: -- not a bare category heading with children."
  (should (null (claude-code-ide-org-test--lint
                 (concat "* TODO A task                                      :code:\n"
                         ":PROPERTIES:\n"
                         ":ID:       11111111-1111-1111-1111-111111111111\n"
                         ":CREATED:  [2026-08-14 Fri 10:00]\n"
                         ":CATEGORY: Tools\n"
                         ":END:\n"
                         "Body referring to [[id:11111111-1111-1111-1111-111111111111][itself]].\n")))))

(ert-deftest claude-code-ide-org-test-lint-catches-punctuation-only-title ()
  "The `* *' that swallowed 6462 lines, as a fixture.

TODO.org :ID: 95087d8f. Markdown's horizontal rule written into a
heading body: org reads the leading asterisk as a headline and `*' as
its title. The file stayed valid org and lint stayed clean for two days.

Asserted at level 3 as well, because the same typo nested is no more
deliberate and the check has no reason to care about depth."
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint "* Category\n* *\n")
           'error "no word characters"))
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint
            (concat "* Category\n** TODO A task\n:PROPERTIES:\n"
                    ":ID:       11111111-1111-1111-1111-111111111111\n"
                    ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"
                    "*** ---\n:PROPERTIES:\n"
                    ":ID:       22222222-2222-2222-2222-222222222222\n"
                    ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"))
           'error "no word characters")))

(ert-deftest claude-code-ide-org-test-lint-still-catches-a-phantom-level-1-heading ()
  "The :ID: 95087d8f incident stays caught after flattening, by a
different rule.

That heading was `* *' -- markdown's horizontal rule -- which org read as
a level-1 headline and which swallowed 6462 lines while every lint run
stayed clean. The rule written for it asked whether a level-1 heading
routed to an archive or mirrored one that did; flattening deleted the
category tier that rule was built on.

It is still caught twice over: a phantom carries no :ID:, which is an
error at level 1, and a punctuation-only title is an error at any level.
Asserting both, because either alone would let the other rot."
  (let ((findings (claude-code-ide-org-test--lint "* *\nSwallowed prose.\n")))
    (should (claude-code-ide-org-test--lint-matches findings 'error "level-1 task has no :ID:"))
    (should (claude-code-ide-org-test--lint-matches
             findings 'error "no word characters"))))


(ert-deftest claude-code-ide-org-test-lint-catches-dangling-id-link ()
  "A fabricated UUID reads as correct and fails only when followed —
this check caught four of them in one session."
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint
            (concat "* Category\n** TODO A task\n:PROPERTIES:\n"
                    ":ID:       11111111-1111-1111-1111-111111111111\n"
                    ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"
                    "See [[id:deadbeef-0000-0000-0000-000000000000][nowhere]].\n"))
           'error "resolves to nothing")))

(ert-deftest claude-code-ide-org-test-lint-ignores-literal-link-syntax ()
  "Prose in these files shows the link syntax itself; documentation is
not a dangling target."
  (should (null (claude-code-ide-org-test--lint
                 (concat "* TODO A task                                      :code:\n"
                         ":PROPERTIES:\n"
                         ":ID:       11111111-1111-1111-1111-111111111111\n"
                         ":CREATED:  [2026-08-14 Fri 10:00]\n"
                         ":CATEGORY: Tools\n:END:\n"
                         "Write links as [[id:...]] in prose.\n")))))

(ert-deftest claude-code-ide-org-test-lint-resolves-across-reference-files ()
  "A link out of the linted set resolves when the target file is given
as a reference — otherwise every cross-file link reads as dangling."
  (let ((text (concat "* TODO A task                                      :code:\n"
                      ":PROPERTIES:\n"
                      ":ID:       11111111-1111-1111-1111-111111111111\n"
                      ":CREATED:  [2026-08-14 Fri 10:00]\n"
                      ":CATEGORY: Tools\n:END:\n"
                      "See [[id:22222222-2222-2222-2222-222222222222][elsewhere]].\n"))
        (ref (concat "* TODO Over here\n:PROPERTIES:\n"
                     ":ID:       22222222-2222-2222-2222-222222222222\n"
                     ":CREATED:  [2026-08-14 Fri 10:00]\n"
                     ":CATEGORY: Tools\n:END:\n")))
    (should (claude-code-ide-org-test--lint-matches
             (claude-code-ide-org-test--lint text) 'error "resolves to nothing"))
    (should (null (claude-code-ide-org-test--lint text ref)))))

(ert-deftest claude-code-ide-org-test-lint-catches-level-4-heading ()
  "The file has exactly three levels; nothing else enforced that."
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint
            (concat "* Category\n** TODO T\n:PROPERTIES:\n"
                    ":ID:       11111111-1111-1111-1111-111111111111\n"
                    ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"
                    "*** TODO C\n:PROPERTIES:\n"
                    ":ID:       33333333-3333-3333-3333-333333333333\n"
                    ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"
                    "**** TODO Too deep\n:PROPERTIES:\n"
                    ":ID:       44444444-4444-4444-4444-444444444444\n"
                    ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"))
           'error "level-4 heading")))

(ert-deftest claude-code-ide-org-test-lint-accepts-a-well-formed-datetree ()
  "A datetree under a :DATE_TREE: category lints clean (TODO.org :ID:
e30d52d7).  Against the pre-2026-08-21 rule this fixture produced three
errors -- no :ID: on the year, no :ID: on the month, and a level-4 day
node -- which is the whole reason the structural claim recorded on :ID:
3bd3402b had to be scoped rather than simply exempted.

The fixture is literal text and never calls `org-datetree-find-date-create'.
The lint only reads structure, and going through org's own writer would
drag the 9.6-vs-9.8 org split (TODO.org :ID: 1ed7b2b4) into a test that
has nothing to do with it."
  (should (null (claude-code-ide-org-test--lint
                 (concat "* Review and planning\n"
                         ":PROPERTIES:\n"
                         ":DATE_TREE: t\n"
                         ":ARCHIVE:  DONE.org::* Review and planning\n"
                         ":END:\n"
                         "** 2026\n"
                         "*** 2026-08 August\n"
                         "**** 2026-08-21 Friday\n"
                         ":PROPERTIES:\n"
                         ":ID:       aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n"
                         ":CREATED:  [2026-08-21 Fri 09:00]\n:END:\n")))))

(ert-deftest claude-code-ide-org-test-lint-still-requires-an-id-on-the-day-node ()
  "The day node is the one heading in the tree that must stay linted: it
is what this project clocks against, every tool addresses headings by
:ID:, and without one it exists and is unreachable.  Allowing it at level
4 must not become exempting it.

This is what a cond branch matching the day node and doing nothing would
break, silently."
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint
            (concat "* Review and planning\n"
                    ":PROPERTIES:\n"
                    ":DATE_TREE: t\n"
                    ":ARCHIVE:  DONE.org::* Review and planning\n"
                    ":END:\n"
                    "** 2026\n"
                    "*** 2026-08 August\n"
                    "**** 2026-08-21 Friday\n"))
           'error "heading has no :ID:")))

(ert-deftest claude-code-ide-org-test-lint-does-not-exempt-a-task-beside-the-datetree ()
  "The exemption names org-datetree's own scaffolding, not everything
that happens to sit at its depth.  A :DATE_TREE: category holds real
tasks beside its tree -- the ritual repeater TODO.org :ID: cd1e974e
institutes is a level-2 heading under this very category, exactly where
the year node sits -- and those are ordinary work that must carry :ID:
and :CREATED:.

Fails against a depth-only implementation, which is what it is for."
  (let ((findings (claude-code-ide-org-test--lint
                   (concat "* Review and planning\n"
                           ":PROPERTIES:\n"
                           ":DATE_TREE: t\n"
                           ":ARCHIVE:  DONE.org::* Review and planning\n"
                           ":END:\n"
                           "** 2026\n"
                           "*** 2026-08 August\n"
                           "**** 2026-08-21 Friday\n"
                           ":PROPERTIES:\n"
                           ":ID:       aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n"
                           ":CREATED:  [2026-08-21 Fri 09:00]\n:END:\n"
                           "** TODO Review and plan the day\n"))))
    (should (claude-code-ide-org-test--lint-matches
             findings 'error "heading has no :ID:"))
    (should (claude-code-ide-org-test--lint-matches
             findings 'warn "heading has no :CREATED:"))))

(ert-deftest claude-code-ide-org-test-lint-catches-a-heading-below-the-day-node ()
  "Nothing is filed under a day node -- the day node is the thing time is
assigned to, which is what ruled out capturing entries beneath it.  So
the level rule keeps biting immediately below it rather than being lifted
for the whole subtree."
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint
            (concat "* Review and planning\n"
                    ":PROPERTIES:\n"
                    ":DATE_TREE: t\n"
                    ":ARCHIVE:  DONE.org::* Review and planning\n"
                    ":END:\n"
                    "** 2026\n"
                    "*** 2026-08 August\n"
                    "**** 2026-08-21 Friday\n"
                    ":PROPERTIES:\n"
                    ":ID:       aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n"
                    ":CREATED:  [2026-08-21 Fri 09:00]\n:END:\n"
                    "***** TODO Filed under the day\n"
                    ":PROPERTIES:\n"
                    ":ID:       bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\n"
                    ":CREATED:  [2026-08-21 Fri 09:00]\n:END:\n"))
           'error "level-5 heading")))

(ert-deftest claude-code-ide-org-test-lint-requires-task-metadata-at-level-1 ()
  "A level-1 heading is a task and must carry what a task carries.

*Inverted 2026-08-27* (TODO.org :ID: 29439196). This asserted the exact
opposite until then -- that a level-1 heading carrying :ID:, :CREATED:,
a keyword or tags was an error, because level 1 was the category tier.
Flattening moved the grouping onto the task as :CATEGORY:, so all four
are now expected and their *absence* is what gets reported.

:ID: errors and :CREATED: only warns, matching deeper headings: an id is
retrofittable, a creation date is not. A missing :CATEGORY: warns too --
a freshly captured heading may not have one yet, and erroring would make
capture-then-categorise impossible."
  (let ((findings (claude-code-ide-org-test--lint
                   (concat "* TODO Bare level-1 task                           :code:\n"))))
    (should (claude-code-ide-org-test--lint-matches findings 'error "level-1 task has no :ID:"))
    (should (claude-code-ide-org-test--lint-matches findings 'warn "level-1 task has no :CREATED:"))
    (should (claude-code-ide-org-test--lint-matches findings 'warn "level-1 task has no :CATEGORY:")))
  ;; And a fully-formed one is silent about all three.
  (let ((findings (claude-code-ide-org-test--lint
                   (concat "* TODO A task                                      :code:\n"
                           ":PROPERTIES:\n"
                           ":ID:       11111111-1111-1111-1111-111111111111\n"
                           ":CREATED:  [2026-08-14 Fri 10:00]\n"
                           ":CATEGORY: Tools\n:END:\n"))))
    (should-not (claude-code-ide-org-test--lint-matches findings 'error "level-1 task"))
    (should-not (claude-code-ide-org-test--lint-matches findings 'warn "level-1 task"))))

(ert-deftest claude-code-ide-org-test-lint-separates-missing-id-from-missing-created ()
  "A missing :ID: is an error — the heading is unreachable by every tool
here. A missing :CREATED: is a warning, because back-dating one on a
heading archived before the rule existed would fabricate a fact."
  (let ((findings (claude-code-ide-org-test--lint "* Category\n** TODO Bare task\n")))
    (should (claude-code-ide-org-test--lint-matches findings 'error "no :ID:"))
    (should (claude-code-ide-org-test--lint-matches findings 'warn "no :CREATED:"))))

(ert-deftest claude-code-ide-org-test-lint-catches-repeater-under-completable-ancestor ()
  "A +1m task never reaches DONE, so an epic containing one never can —
the check that caught 38b92521 silently frozen via its :BLOCKER:."
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint
            (concat "* Category\n** TODO Epic\n:PROPERTIES:\n"
                    ":ID:       11111111-1111-1111-1111-111111111111\n"
                    ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"
                    "*** TODO Monthly thing\n"
                    "SCHEDULED: <2026-08-14 Fri +1m>\n:PROPERTIES:\n"
                    ":ID:       33333333-3333-3333-3333-333333333333\n"
                    ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"))
           'error "repeater under completable ancestor")))

(ert-deftest claude-code-ide-org-test-lint-blocker-must-actually-block ()
  "Three separate ways a :BLOCKER: can look enforcing and not be: naming
an id that does not exist, naming a heading with no TODO keyword (org-
depend blocks only on an unfinished TODO), and sitting on a MAYBE
heading, where blocking is evaluated against the blocked heading's own
state."
  (let ((findings (claude-code-ide-org-test--lint
                   (concat "* Category\n"
                           "** TODO Keywordless target is a no-op\n:PROPERTIES:\n"
                           ":ID:       11111111-1111-1111-1111-111111111111\n"
                           ":CREATED:  [2026-08-14 Fri 10:00]\n"
                           ":BLOCKER:  ids(99999999-9999-9999-9999-999999999999)\n:END:\n"
                           "** No keyword here\n:PROPERTIES:\n"
                           ":ID:       99999999-9999-9999-9999-999999999999\n"
                           ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"
                           "** MAYBE Dormant\n:PROPERTIES:\n"
                           ":ID:       33333333-3333-3333-3333-333333333333\n"
                           ":CREATED:  [2026-08-14 Fri 10:00]\n"
                           ":BLOCKER:  ids(11111111-1111-1111-1111-111111111111)\n:END:\n"
                           "** TODO Names a ghost\n:PROPERTIES:\n"
                           ":ID:       44444444-4444-4444-4444-444444444444\n"
                           ":CREATED:  [2026-08-14 Fri 10:00]\n"
                           ":BLOCKER:  ids(deadbeef-0000-0000-0000-000000000000)\n:END:\n"))))
    (should (claude-code-ide-org-test--lint-matches findings 'error "keyword-less heading"))
    (should (claude-code-ide-org-test--lint-matches findings 'error "names unknown :ID:"))
    (should (claude-code-ide-org-test--lint-matches findings 'warn "MAYBE heading is dormant"))))

(ert-deftest claude-code-ide-org-test-lint-requires-a-cookie-on-containers ()
  "A heading that has acquired TODO children states its progress.

Four probes, because the interesting half of this check is what it must
*not* flag. A level-1 category has TODO children by definition and is
structure rather than a task, so the keyword gate is what keeps the
check off every category in the file."
  (let* ((props (concat ":PROPERTIES:\n:ID:       11111111-1111-1111-1111-111111111111\n"
                        ":CREATED:  [2026-08-20 Thu 10:00]\n:END:\n"))
         (kid (concat "*** TODO Kid\n:PROPERTIES:\n"
                      ":ID:       22222222-2222-2222-2222-222222222222\n"
                      ":CREATED:  [2026-08-20 Thu 10:00]\n:END:\n"))
         (with-kid (lambda (headline)
                     (claude-code-ide-org-test--lint
                      (concat "* Category\n" headline props kid)))))
    ;; Container, no cookie: flagged.
    (should (claude-code-ide-org-test--lint-matches
             (funcall with-kid "** TODO Parent\n") 'error "no statistics cookie"))
    ;; Container with a cookie: silent.
    (should-not (claude-code-ide-org-test--lint-matches
                 (funcall with-kid "** TODO [0/1] Parent\n") 'error "no statistics cookie"))
    ;; A percentage cookie counts too.
    (should-not (claude-code-ide-org-test--lint-matches
                 (funcall with-kid "** TODO [0%] Parent\n") 'error "no statistics cookie"))
    ;; A category has TODO children and no keyword of its own: silent.
    (should-not (claude-code-ide-org-test--lint-matches
                 (claude-code-ide-org-test--lint
                  (concat "* Category\n** TODO Leaf\n" props))
                 'error "no statistics cookie"))))

(ert-deftest claude-code-ide-org-test-lint-catches-a-repeated-tag ()
  "A tag written twice on one heading cannot be deliberate.

The check is only meaningful because `org-get-tags\' does not
deduplicate -- verified 2026-08-20, it returns (\"code\" \"code\") for
`:code:code:\'. Were it to dedupe, the comparison would be
unconditionally true and the test would pass while checking nothing.
Produced in the real file by a hand-edit appending a tag a headline
already carried, which org-lint does not look for."
  (let ((props (concat ":PROPERTIES:\n:ID:       11111111-1111-1111-1111-111111111111\n"
                       ":CREATED:  [2026-08-20 Thu 10:00]\n:END:\n")))
    (should (claude-code-ide-org-test--lint-matches
             (claude-code-ide-org-test--lint
              (concat "* Category\n** TODO Task :code:code:\n" props))
             'error "repeats a tag"))
    (should-not (claude-code-ide-org-test--lint-matches
                 (claude-code-ide-org-test--lint
                  (concat "* Category\n** TODO Task :code:research:\n" props))
                 'error "repeats a tag"))))

(ert-deftest claude-code-ide-org-test-lint-catches-dangling-plan-link ()
  "bin/sync-plans --check covers the archive side; nothing covered a
heading linking a plan file that is not there."
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint
            (concat "* Category\n** TODO T\n:PROPERTIES:\n"
                    ":ID:       11111111-1111-1111-1111-111111111111\n"
                    ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"
                    "[[file:~/.claude/plans/no-such-plan-98f3a.md][Plan]]\n"))
           'error "plan link points at a missing file")))

(ert-deftest claude-code-ide-org-test-lint-catches-a-heading-glued-to-prose ()
  "The malformation the lint found on its first real run, introduced
2026-08-13 in f39944f: a heading with no newline before it is not a
heading at all, so org never sees it, its :ID: is unreachable, and every
link to it dangles — while the text still *looks* like a heading."
  (let ((findings (claude-code-ide-org-test--lint
                   (concat "* Category\n"
                           "** TODO Real one\n:PROPERTIES:\n"
                           ":ID:       11111111-1111-1111-1111-111111111111\n"
                           ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"
                           "Some prose.** TODO Glued heading\n:PROPERTIES:\n"
                           ":ID:       77777777-7777-7777-7777-777777777777\n"
                           ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"
                           "Link to [[id:77777777-7777-7777-7777-777777777777][it]].\n"))))
    (should (claude-code-ide-org-test--lint-matches findings 'error "resolves to nothing"))))

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
             (insert "#+TODO: TODO NEXT(n!) DOING(d!) WAITING(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n"
                     "#+TAGS: code comms research review\n"
                     "#+ARCHIVE: DONE.org::\n"
                     "\n"
                     ;; Kept as somewhere for a heading to land beside,
                     ;; not as a capture target. `target' was required
                     ;; from 2026-08-20 (:ID: 97696fc2), but a category
                     ;; stopped being a heading on 2026-08-27, so passing
                     ;; "Scratch" as one now errors: there is nothing to
                     ;; file *under* by name. Omit the target and the
                     ;; heading is prepended to the file.
                     "* Scratch\n"))
           ,@body)
       (when (org-clocking-p) (org-clock-out))
       (let ((buf (get-file-buffer capture-file)))
         (when buf
           (with-current-buffer buf (set-buffer-modified-p nil))
           (kill-buffer buf)))
       (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-capture-writes-initial-state ()
  "`initial_state' must put the keyword on the heading at creation.

Without it a captured heading is keywordless on disk until a human
applies the queue, which makes a :BLOCKER: naming it inert -- org-depend
blocks only on an unfinished TODO keyword -- and makes bin/lint-org
error, which .githooks/pre-commit refuses. That cost the slice b36e6369
a commit on 2026-08-28 (TODO.org :ID: c74f8663).

A creation has no prior state, so writing the keyword directly hides no
transition from the review pass: `State \"TODO\" from \"\"' is noise
rather than history. Every *subsequent* transition still queues."
  (claude-code-ide-org-test--with-capture-file
    (should (string-match-p "\\`Captured: "
                            (claude-code-ide-org-capture "Task with a state" nil nil nil "NEXT")))
    (should (string-match-p "^\\* NEXT Task with a state"
                            (claude-code-ide-org-test--disk-contents capture-file)))))

(ert-deftest claude-code-ide-org-test-capture-without-initial-state-stays-keywordless ()
  "Omitting it must keep the old behaviour, which some callers want.
A heading captured as a note rather than a task has no state, and that
is the default the argument was specified to preserve."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-capture "Just a note")
    (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
      (should (string-match-p "^\\* Just a note" disk))
      ;; Explicitly not any keyword the file declares.
      (should-not (string-match-p "^\\* [A-Z]+ Just a note" disk))))
  ;; The empty string must behave as omitted rather than writing "* ".
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-capture "Empty state" nil nil nil "")
    (should (string-match-p "^\\* Empty state"
                            (claude-code-ide-org-test--disk-contents capture-file)))))

(ert-deftest claude-code-ide-org-test-capture-done-state-writes-a-closed-line ()
  "A heading born in a done state must carry CLOSED:, or it is invisible.

`org-todo\' is what normally writes that line, and `initial_state\'
deliberately bypasses it. Without this the heading is missed by every
consumer that reads CLOSED -- archive placement, `bin/lint-org\''s
threshold, and the slice incidental window -- and joins the backlog
TODO.org :ID: b7b46a26 exists to clear. Found four hours after
:ID: c74f8663 shipped, by building something that depended on the
invariant (:ID: 5d59dc77).

Capturing something already finished is legitimate -- a decision
recorded after the fact -- so the fix writes the line rather than
refusing the state."
  (dolist (kw '("DONE" "CANCELLED"))
    (claude-code-ide-org-test--with-capture-file
      (claude-code-ide-org-capture (concat "Born " kw) nil nil nil kw)
      (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
        (should (string-match-p (concat "^\\* " kw " Born " kw) disk))
        (should (string-match-p "^CLOSED: \\[" disk)))))
  ;; A live keyword must NOT get one -- that would be a false close.
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-capture "Still open" nil nil nil "NEXT")
    (should-not (string-match-p
                 "CLOSED:" (claude-code-ide-org-test--disk-contents capture-file))))
  ;; Nor a keywordless capture.
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-capture "No keyword")
    (should-not (string-match-p
                 "CLOSED:" (claude-code-ide-org-test--disk-contents capture-file)))))

(ert-deftest claude-code-ide-org-test-capture-refuses-an-unknown-initial-state ()
  "Validated against the target file's own #+TODO: line, like org_set_todo.

`bin/hooks/queue-append' drops any reply starting with \"Error:\", so
this is the only gate between a bad call and a heading carrying a
keyword org does not recognise -- which org then reads as part of the
title, invisibly and permanently."
  (claude-code-ide-org-test--with-capture-file
    (let ((result (claude-code-ide-org-capture "Task" nil nil nil "NOPE")))
      (should (string-match-p "\\`Error: \"NOPE\" is not a TODO keyword" result))
      ;; The keyword set is named, so the caller can correct itself.
      (should (string-match-p "WAITING" result)))
    (should-not (string-match-p
                 "Task" (claude-code-ide-org-test--disk-contents capture-file)))))

(ert-deftest claude-code-ide-org-test-deferred-capture-replays-initial-state ()
  "A capture that deferred must land with the keyword it was given.

The immediate path and the apply path share
`claude-code-ide-org--capture-write' precisely so a deferred capture
produces the heading it would have produced had it written through. The
keyword has to travel with the queued item to make that true, so this
drives the apply path directly rather than the tool."
  (claude-code-ide-org-test--with-capture-file
    (let ((item (list :type 'capture
                      :id "test-deferred-0001"
                      :ts (date-to-time "2026-08-31T15:00:00-0500")
                      :title "Deferred with a state"
                      :target nil
                      :tags nil
                      :to "DOING")))
      (should-not (claude-code-ide-org--review-apply-capture item))
      (should (string-match-p "^\\* DOING Deferred with a state"
                              (claude-code-ide-org-test--disk-contents capture-file))))))

(ert-deftest claude-code-ide-org-test-capture-refuses-a-leading-todo-keyword ()
  "A title starting with a TODO keyword must be refused, not written.

org parses the leading word as the heading's *state*, so the heading
silently acquires a state nobody gave it and the title loses its first
word. The result is a well-formed heading, so nothing downstream can
detect it -- the one real occurrence surfaced only because
`org_set_todo' echoed the truncated title back (TODO.org :ID: 2b2db914).

Checked for every keyword the fixture's own `#+TODO:' line declares,
both sides of the bar, since a done-state keyword parses exactly the
same way."
  (claude-code-ide-org-test--with-capture-file
    (dolist (kw '("TODO" "NEXT" "DOING" "WAITING" "MAYBE" "DONE" "CANCELLED"))
      (let ((result (claude-code-ide-org-capture
                     (concat kw " belongs to containers"))))
        (should (string-match-p "\\`Error: title begins with the TODO keyword"
                                result))
        (should (string-match-p (regexp-quote kw) result))))
    ;; Nothing may have reached the file -- a refusal that still wrote
    ;; would be the defect with an error message attached.
    (should-not (string-match-p
                 "belongs to containers"
                 (claude-code-ide-org-test--disk-contents capture-file)))))

(ert-deftest claude-code-ide-org-test-capture-allows-titles-that-merely-look-keyword-ish ()
  "The guard matches the whole first word, case-sensitively, and nothing else.

Anything stricter would refuse titles org handles perfectly well. org
only reads an exact uppercase keyword as a state, so `NEXTGEN', a
lowercase `next', and a keyword appearing later in the title are all
ordinary titles and must be captured unchanged."
  (claude-code-ide-org-test--with-capture-file
    (dolist (title '("NEXTGEN parser rewrite"
                     "next steps for the parser"
                     "Decide what NEXT means for a container"
                     "TODOs are not TODO"))
      (let ((result (claude-code-ide-org-capture title)))
        (should (string-match-p "\\`Captured: " result))))
    (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
      (should (string-match-p "NEXTGEN parser rewrite" disk))
      (should (string-match-p "next steps for the parser" disk))
      (should (string-match-p "Decide what NEXT means for a container" disk))
      ;; The heading org would have mangled is the one to check landed
      ;; whole: its first word is a superset of a keyword, not one.
      (should (string-match-p "TODOs are not TODO" disk)))))

(ert-deftest claude-code-ide-org-test-capture-creates-heading-with-id ()
  (claude-code-ide-org-test--with-capture-file
    (let ((result (claude-code-ide-org-capture "Buy stamps")))
      (should (string-match-p "\\`Captured: \"Buy stamps\" (ID: [^)]+)" result))
      (string-match "(ID: \\([^)]+\\))" result)
      (let ((returned-id (match-string 1 result))
            (disk (claude-code-ide-org-test--disk-contents capture-file)))
        ;; A real, non-empty ID landed both in the return string and on disk.
        (should (> (length returned-id) 0))
        (should (string-match-p "^\\* Buy stamps[ \t]*$" disk))
        (should (string-match-p (concat "^:ID: +" (regexp-quote returned-id) "[ \t]*$") disk))
        (should (not (buffer-modified-p (get-file-buffer capture-file))))))))

(ert-deftest claude-code-ide-org-test-capture-writes-no-todo-keyword ()
  "The heading is deliberately keyword-less: state is supplied at
ingestion so org logs the transition natively, rather than asserted live
by a tool whose every other state write is queued."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-capture "Keywordless task")
    (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
      (should (string-match-p "^\\* Keywordless task[ \t]*$" disk))
      (should-not (string-match-p "^\\* \\(TODO\\|NEXT\\|DOING\\) " disk)))))

(ert-deftest claude-code-ide-org-test-capture-writes-created-property ()
  "Formatted in elisp, not via the template's %U escape: an escape that
fails to expand leaves a literal \"%U\" and still passes a naive
is-the-property-there check."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-capture "Stamped task")
    (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
      (should (string-match-p
               "^:CREATED: +\\[[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9] [A-Z][a-z][a-z] [0-9][0-9]:[0-9][0-9]\\][ \t]*$"
               disk))
      (should-not (string-match-p "%U" disk)))))

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
      (string-match "(ID: \\([^)]+\\))" result)
      (let ((returned-id (match-string 1 result)))
        (should (org-id-find returned-id 'marker))
        (should (string-match-p
                 "\\`Queued clock_in on \"Round trip task\""
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
        (should (string-match-p (regexp-quote (concat "* " title)) disk))))))

(ert-deftest claude-code-ide-org-test-capture-refuses-a-category-title-as-target ()
  "A category title is no longer a place to file under.

*Inverted 2026-08-27* (TODO.org :ID: 29439196). Categories were level-1
headings and a title was the only handle they had; now they are
:CATEGORY: property values, so there is no heading of that name to file
beneath. Accepting one would mean nesting a task under another task,
addressed by title -- which this project forbids everywhere else, and
which the old allowance justified only by categories being exempt.

The error says what to do instead, because a bare refusal on a call that
worked yesterday teaches nothing."
  (claude-code-ide-org-test--with-capture-file
    (with-temp-file capture-file
      (insert "* TODO A task\n:PROPERTIES:\n:ID:       cat-0001\n"
              ":CATEGORY: Tooling\n:END:\n"))
    (let ((result (claude-code-ide-org-capture "Misfiled" "Tooling")))
      (should (string-match-p "\\`Error:" result))
      (should (string-match-p "not a known :ID:" result))
      (should (string-match-p "omit the target" result)))))

(ert-deftest claude-code-ide-org-test-capture-target-by-id ()
  (claude-code-ide-org-test--with-capture-file
    (with-current-buffer (find-file-noselect capture-file)
      (goto-char (point-max))
      (insert "* Parent heading\n:PROPERTIES:\n"
              ":ID:       66666666-6666-4666-8666-666666666666\n:END:\n")
      (save-buffer))
    (org-id-update-id-locations (list capture-file))
    (let ((result (claude-code-ide-org-capture
                   "Filed under an id" "66666666-6666-4666-8666-666666666666")))
      (should (string-match-p "under :ID: 66666666" result))
      (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
        (should (string-match-p "^\\*\\* Filed under an id" disk))))))

(ert-deftest claude-code-ide-org-test-capture-refuses-a-keyworded-capture-under-a-slice ()
  "A keyworded capture under a slice would mint a hybrid (:ID: dca940c1);
a keyword-less capture -- a note -- stays legal, since the container
predicate tests keywords."
  (claude-code-ide-org-test--with-capture-file
    (with-current-buffer (find-file-noselect capture-file)
      (goto-char (point-max))
      (insert "* DOING [0/0] A slice\n:PROPERTIES:\n"
              ":ID:       77777777-7777-4777-8777-777777777777\n"
              ":KIND:     slice\n:END:\n")
      (save-buffer))
    (org-id-update-id-locations (list capture-file))
    (should (string-match-p
             "\\`Error: capturing a keyworded heading here would give slice"
             (claude-code-ide-org-capture
              "A task" "77777777-7777-4777-8777-777777777777" nil nil "TODO")))
    (should (string-match-p
             "\\`Captured:"
             (claude-code-ide-org-capture
              "A note" "77777777-7777-4777-8777-777777777777")))))

(ert-deftest claude-code-ide-org-test-refile-refuses-a-keyworded-arrival-under-a-slice ()
  "Refiling a keyworded heading under a slice would mint a hybrid
(:ID: dca940c1); a keyword-less note goes through."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* DOING [0/0] A slice\n"
                    ":PROPERTIES:\n:ID:       test-0002\n:KIND:     slice\n:END:\n"
                    "* A keyword-less note\n"
                    ":PROPERTIES:\n:ID:       test-0003\n:END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (should (string-match-p "\\`Error: refiling .* would give slice"
                            (claude-code-ide-org-refile id "test-0002")))
    (should (string-match-p "\\`Refiled:"
                            (claude-code-ide-org-refile "test-0003" "test-0002")))))

(ert-deftest claude-code-ide-org-test-refile-refuses-a-keyworded-descendant-under-a-slice ()
  "The arrival side of the guard is the *subtree*, not the heading line.

A keyword-less note is only harmless under a slice if it is also
childless: one carrying a keyworded child mints exactly the hybrid
`claude-code-ide-org--container-heading-p' scans descendants to catch
(TODO.org :ID: 15847e0b)."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* DOING [0/0] A slice\n"
                    ":PROPERTIES:\n:ID:       test-0002\n:KIND:     slice\n:END:\n"
                    "* A note carrying a keyworded child\n"
                    ":PROPERTIES:\n:ID:       test-0003\n:END:\n"
                    "** TODO its keyworded child\n"
                    ":PROPERTIES:\n:ID:       test-0004\n:END:\n"
                    "* A childless note\n"
                    ":PROPERTIES:\n:ID:       test-0005\n:END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (should (string-match-p "\\`Error: refiling .* would give slice"
                            (claude-code-ide-org-refile "test-0003" "test-0002")))
    ;; The original test's negative case, kept: a note with nothing
    ;; under it carries no keyword anywhere and stays legal.
    (should (string-match-p "\\`Refiled:"
                            (claude-code-ide-org-refile "test-0005" "test-0002")))))

(ert-deftest claude-code-ide-org-test-refile-refuses-an-arrival-inside-a-slice ()
  "The target side is the *enclosing* slice, not the target heading.

`claude-code-ide-org--container-heading-p' matches a keyworded
descendant at any depth, so landing a keyworded heading under a slice's
keyword-less child hybridises the slice just as surely as landing it
directly (TODO.org :ID: 15847e0b)."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* DOING [0/0] A slice\n"
                    ":PROPERTIES:\n:ID:       test-0002\n:KIND:     slice\n:END:\n"
                    "** a note under the slice\n"
                    ":PROPERTIES:\n:ID:       test-0003\n:END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let ((reply (claude-code-ide-org-refile id "test-0003")))
      (should (string-match-p "\\`Error: refiling .* would give slice" reply))
      ;; It names the slice it would hybridise, not the heading that was
      ;; passed as the target -- which is the whole of what the ancestor
      ;; walk buys, and is invisible if the message is only checked for
      ;; being an error.
      (should (string-match-p "would give slice \"\\[0/0\\] A slice\"" reply))
      (should-not (string-match-p "a note under the slice" reply)))))

(ert-deftest claude-code-ide-org-test-capture-refuses-a-keyworded-capture-inside-a-slice ()
  "The same target-side mismatch, reached through capture (TODO.org
:ID: 32742646).

A capture creates a leaf, so only the target side can be wrong here --
there is no arriving subtree to scan."
  (claude-code-ide-org-test--with-capture-file
    (with-current-buffer (find-file-noselect capture-file)
      (goto-char (point-max))
      (insert "* DOING [0/0] A slice\n:PROPERTIES:\n"
              ":ID:       77777777-7777-4777-8777-777777777777\n"
              ":KIND:     slice\n:END:\n"
              "** a note under the slice\n:PROPERTIES:\n"
              ":ID:       88888888-8888-4888-8888-888888888888\n:END:\n")
      (save-buffer))
    (org-id-update-id-locations (list capture-file))
    (should (string-match-p
             "\\`Error: capturing a keyworded heading here would give slice \"\\[0/0\\] A slice\""
             (claude-code-ide-org-capture
              "A task" "88888888-8888-4888-8888-888888888888" nil nil "TODO")))
    ;; A keyword-less capture is a note and adds no keyword anywhere.
    (should (string-match-p
             "\\`Captured:"
             (claude-code-ide-org-capture
              "A note" "88888888-8888-4888-8888-888888888888")))))

(ert-deftest claude-code-ide-org-test-set-property-refuses-kind-slice-on-a-container ()
  "Declaring a container a slice mints a hybrid (:ID: dca940c1); a leaf
may still be declared one."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* TODO A story\n"
                    ":PROPERTIES:\n:ID:       test-0002\n:END:\n"
                    "** TODO its child\n"
                    ":PROPERTIES:\n:ID:       test-0003\n:END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (should (string-match-p "\\`Error: this heading has keyworded children"
                            (claude-code-ide-org-set-property "test-0002" "KIND" "slice")))
    ;; a leaf (the macro's own heading) may be declared a slice
    (should (string-match-p "\\`Set KIND on"
                            (claude-code-ide-org-set-property id "KIND" "slice")))))

(ert-deftest claude-code-ide-org-test-capture-unknown-target-refuses ()
  "Better to error than to file it somewhere the caller did not ask for:
a caller that named a destination and silently got a different one is
worse off than one that got an error."
  (claude-code-ide-org-test--with-capture-file
    (let ((result (claude-code-ide-org-capture "Nowhere task" "No Such Category")))
      (should (string-prefix-p "Error:" result))
      (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
        (should-not (string-match-p "Nowhere task" disk))))))

(ert-deftest claude-code-ide-org-test-capture-without-a-target-lands-at-top ()
  "Omitting the target prepends at the top of the capture file.

*Inverted 2026-08-27* (TODO.org :ID: 29439196). This asserted that a
targetless capture was REFUSED, because appending at the end of TODO.org
would have produced a level-1 heading and level 1 was the category tier
-- a heading violating the convention on three counts. Flattening made
level 1 exactly where a task belongs, so the shape the guard existed to
prevent is now the shape a capture should produce.

Prepend rather than append, which is the other half: with no category
heading to file under, recency is the ordering that remains."
  (claude-code-ide-org-test--with-capture-file
    (with-temp-file capture-file (insert "* TODO Already here\n"))
    (let ((result (claude-code-ide-org-capture "Fresh capture")))
      (should (string-match-p "\\`Captured:" result)))
    (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
      (should (string-match-p "^\\* Fresh capture" disk))
      ;; Above what was already there.
      (should (< (string-match "Fresh capture" disk)
                 (string-match "Already here" disk))))))

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
          ;; No target: since TODO.org :ID: 29439196 that is legal again
          ;; and lands at the top of whichever file capture resolves to,
          ;; which is exactly what this test is about. The heading it
          ;; used to need to name is gone with the category tier.
          (with-temp-file notes-file (insert "* Inbox\n"))
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

;;; claude-code-ide-org-outline ----------------------------------------------

(ert-deftest claude-code-ide-org-test-outline-reports-keyword-and-title ()
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline)))
      (should (string-match-p "TODO Test heading" result)))))

(ert-deftest claude-code-ide-org-test-outline-emits-full-id ()
  "IDs must not be truncated: every other tool takes a full :ID:, so a
shortened index would force a second lookup on every use."
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline)))
      (should (string-match-p (regexp-quote (format "{%s}" id)) result)))))

(ert-deftest claude-code-ide-org-test-outline-indents-by-level ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "** TODO Child heading\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline)))
      ;; A category header now leads each group, and members sit one
    ;; level in under it -- the same shape the level-1 category
    ;; headings used to give, from :CATEGORY: instead of position
    ;; (TODO.org :ID: 29439196). The fixture heading carries none,
    ;; so it groups under the explicit uncategorised header rather
    ;; than being dropped.
    (should (string-match-p "^(no :CATEGORY:)$" result))
    (should (string-match-p "^  TODO Test heading" result))
      (should (string-match-p "^    TODO Child heading" result)))))

(ert-deftest claude-code-ide-org-test-outline-active-only-drops-finished ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* DONE Finished heading\n* CANCELLED Abandoned heading\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (all (claude-code-ide-org-outline nil nil nil))
           (active (claude-code-ide-org-outline nil nil "true")))
      (should (string-match-p "Finished heading" all))
      (should (string-match-p "Abandoned heading" all))
      (should-not (string-match-p "Finished heading" active))
      (should-not (string-match-p "Abandoned heading" active))
      (should (string-match-p "Test heading" active)))))

(ert-deftest claude-code-ide-org-test-outline-max-depth-caps-level ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "** TODO Child heading\n*** TODO Grandchild heading\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline nil "2" nil)))
      (should (string-match-p "Test heading" result))
      (should (string-match-p "Child heading" result))
      (should-not (string-match-p "Grandchild heading" result)))))

(ert-deftest claude-code-ide-org-test-outline-scope-by-id-limits-to-subtree ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "** TODO Child heading\n* TODO Unrelated sibling\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline id)))
      (should (string-match-p "Test heading" result))
      (should (string-match-p "Child heading" result))
      (should-not (string-match-p "Unrelated sibling" result)))))

(ert-deftest claude-code-ide-org-test-id-scan-includes-declared-archives ()
  "A tracked file's archive is scanned for ids, and the path is resolved
against the file's TRUE directory.

TODO.org :ID: 020d3688. `org-agenda-files' is a scan of `org-directory',
which in this checkout holds a symlink to TODO.org and nothing else -- so
DONE.org was invisible and no id in it resolved. The truename part is not
incidental: resolving the archive against the *symlink's* directory finds
nothing, which is precisely how the gap stayed silent."
  (claude-code-ide-org-test--with-heading
    (with-temp-file archive-file
      (insert "* Done\n** DONE An archived heading\n"
              ":PROPERTIES:\n:ID:       aaaa0001-1111-4111-8111-111111111111\n:END:\n"))
    ;; The fixture file already declares #+ARCHIVE: DONE.org::.
    (let ((claude-code-ide-org-query-files (list file)))
      (should (member (file-truename archive-file)
                      (mapcar #'file-truename
                              (claude-code-ide-org--id-scannable-files))))
      ;; Resolvable through org's own index, which is what expansion
      ;; consults since 2026-08-27.
      (should (org-id-find-id-in-file "aaaa0001-1111-4111-8111-111111111111"
                                      archive-file)))))

(ert-deftest claude-code-ide-org-test-id-scan-resolves-archive-through-a-symlink ()
  "The archive path resolves against the tracked file's TRUE directory.

This is the condition that kept TODO.org :ID: 020d3688 silent for weeks
and that a same-directory fixture cannot reproduce. In the real checkout
`org-agenda-files' names `~/org/claude-code-ide-org/TODO.org', a symlink
into the repo; resolving `DONE.org' against the *link's* directory finds
nothing, so the archive was simply absent and every id in it failed to
resolve -- with no error anywhere, because an unreadable file and an
undeclared one look identical from there.

So the fixture builds the same shape: a link in one directory pointing at
a file in another, with the archive beside the *target*."
  (claude-code-ide-org-test--with-heading
    (with-temp-file archive-file
      (insert "* Done\n** DONE Archived via a link\n"
              ":PROPERTIES:\n:ID:       bbbb0001-1111-4111-8111-111111111111\n:END:\n"))
    (let* ((linkdir (file-name-as-directory (make-temp-file "linkdir" t)))
           (link (expand-file-name "TODO.org" linkdir)))
      (unwind-protect
          (progn
            (make-symbolic-link file link)
            (let ((claude-code-ide-org-query-files (list link)))
              (should (org-id-find-id-in-file
                       "bbbb0001-1111-4111-8111-111111111111" archive-file))))
        (delete-directory linkdir t)))))

(ert-deftest claude-code-ide-org-test-id-link-resolves-into-the-archive ()
  "A link naming an archived heading expands rather than being refused.

The defect this closes was hit twice in one session by `org_amend'
refusing a correct prefix -- which teaches a writer to stop using the
convention rather than to fix anything."
  (claude-code-ide-org-test--with-heading
    (with-temp-file archive-file
      (insert "* Done\n** DONE An archived heading\n"
              ":PROPERTIES:\n:ID:       aaaa0002-4444-4444-8444-444444444444\n:END:\n"))
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-resolve-id-links
                    "See [[id:aaaa0002][aaaa0002]].")))
      (should (car result))
      (should (string-match-p "id:aaaa0002-4444-4444-8444-444444444444" (cdr result))))))

(ert-deftest claude-code-ide-org-test-id-scan-still-refuses-an-unknown-prefix ()
  "Widening the scan must not turn the check into a rubber stamp: a
prefix matching nothing anywhere is still refused, naming it."
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-resolve-id-links
                    "See [[id:deadbeef][deadbeef]].")))
      (should-not (car result))
      (should (string-match-p "deadbeef (matches no heading)" (cdr result))))))

(ert-deftest claude-code-ide-org-test-outline-expands-a-scoped-slice ()
  "Scoped to a slice, the outline lists its members.

TODO.org :ID: 8183fc7c: it used to return a single line for two dozen
members. That is a wrong answer rather than a missing feature -- a slice
IS structure, and this tool is advertised as the way to see structure
without opening the file.

Members render as references, not children: a slice may name one task
inside another story, so indentation would assert a containment that
does not exist."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* TODO A referent                                                   :code:\n"
            ":PROPERTIES:\n:ID:       test-0002\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find id 'marker)
      (org-entry-put nil "KIND" "slice")
      (org-end-of-meta-data t)
      (insert "- [ ] [[id:test-0002][test-0002]] TODO A referent\n")
      (save-buffer))
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline id)))
      (should (string-match-p "-> \\[ \\] TODO A referent" result))
      (should (string-match-p "{test-0002}" result))
      ;; A reference marker, not indentation-as-containment.
      (should-not (string-match-p "^  TODO A referent" result)))))

(ert-deftest claude-code-ide-org-test-outline-slice-shows-dropped-members ()
  "A member whose checkbox cookie was deleted still appears, as (dropped).

This is why the expansion is not simply the `:BLOCKER:' list. The
conventions deliberately exclude a cookie-less member from the blocker
set -- blocking on a deferred member would hold the slice open forever
for work it explicitly decided not to do -- so a blocker-derived view
loses the record of having considered and dropped something. That record
is the one thing the conventions say a list must not lose."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* CANCELLED A dropped referent                                      :code:\n"
            ":PROPERTIES:\n:ID:       test-0003\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find id 'marker)
      (org-entry-put nil "KIND" "slice")
      (org-end-of-meta-data t)
      ;; No checkbox at all -- the cookie was deleted.
      (insert "- [[id:test-0003][test-0003]] CANCELLED A dropped referent\n")
      (save-buffer))
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline id)))
      (should (string-match-p "-> (dropped) CANCELLED A dropped referent" result)))))

(ert-deftest claude-code-ide-org-test-outline-does-not-expand-slices-file-wide ()
  "Only the scoped call expands. In a whole-file outline every member
already has a line where it lives and the statistics cookie reports the
size, so expanding would print each member twice."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* TODO A referent                                                   :code:\n"
            ":PROPERTIES:\n:ID:       test-0002\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find id 'marker)
      (org-entry-put nil "KIND" "slice")
      (org-end-of-meta-data t)
      (insert "- [ ] [[id:test-0002][test-0002]] TODO A referent\n")
      (save-buffer))
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline file)))
      (should (string-match-p "A referent" result))
      (should-not (string-match-p "->" result)))))

(ert-deftest claude-code-ide-org-test-outline-marks-blocked-when-blocker-open ()
  "A :BLOCKER: naming an unfinished heading is a real block."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* TODO Blocker heading\n:PROPERTIES:\n"
            ":ID:       11111111-1111-4111-8111-111111111111\n:END:\n"
            "* TODO Blocked heading\n:PROPERTIES:\n"
            ":BLOCKER:  ids(11111111-1111-4111-8111-111111111111)\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline)))
      ;; The id is named, not merely flagged (TODO.org :ID: 8183fc7c):
      ;; a bare marker sends the reader off to find out what blocks it,
      ;; which defeats an index that exists to answer without opening
      ;; the file. Asserting the prefix specifically -- a bare-marker
      ;; match would still pass against the old format.
      (should (string-match-p "Blocked heading.*\\[blocked: 11111111\\]" result))
      (should-not (string-match-p "Test heading.*\\[blocked" result)))))

(ert-deftest claude-code-ide-org-test-outline-unmarks-satisfied-blocker ()
  "The regression this replaced: :BLOCKER: is a durable declaration, not a
flag org clears, so keying the marker on the property's mere presence
marks a heading blocked forever.  Measured on the real TODO.org the day
it shipped, all 10 markers were false."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* DONE Finished blocker\n:PROPERTIES:\n"
            ":ID:       22222222-2222-4222-8222-222222222222\n:END:\n"
            "* TODO Formerly blocked\n:PROPERTIES:\n"
            ":BLOCKER:  ids(22222222-2222-4222-8222-222222222222)\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline)))
      (should (string-match-p "Formerly blocked" result))
      (should-not (string-match-p "Formerly blocked.*\\[blocked" result)))))

(ert-deftest claude-code-ide-org-test-outline-scoped-resolves-blocker-outside-scope ()
  "Scoping to an :ID: narrows the buffer, and a blocker living outside
that narrowing is usually in the *same* buffer -- so resolving it has to
widen first.  Without that, `org-id-find' hands back the narrowed
buffer, `goto-char' is clamped to the accessible region, and
`org-get-todo-state' reads the scoped heading itself.  A DONE blocker
then answers `open' and the heading reads [blocked] forever.

Asserts the *scoped* call deliberately.  The unscoped equivalent above
passes against the unfixed code, because nothing narrows there -- which
is exactly why the defect survived a suite that already covered
satisfied blockers."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* DONE Finished blocker\n:PROPERTIES:\n"
            ":ID:       33333333-3333-4333-8333-333333333333\n:END:\n"
            "* MAYBE Formerly blocked\n:PROPERTIES:\n"
            ":ID:       44444444-4444-4444-8444-444444444444\n"
            ":BLOCKER:  ids(33333333-3333-4333-8333-333333333333)\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline
                    "44444444-4444-4444-8444-444444444444")))
      (should (string-match-p "Formerly blocked" result))
      (should-not (string-match-p "\\[blocked" result)))))

(ert-deftest claude-code-ide-org-test-outline-cancelled-blocker-counts-as-finished ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* CANCELLED Abandoned blocker\n:PROPERTIES:\n"
            ":ID:       33333333-3333-4333-8333-333333333333\n:END:\n"
            "* TODO Depends on abandoned\n:PROPERTIES:\n"
            ":BLOCKER:  ids(33333333-3333-4333-8333-333333333333)\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline)))
      (should-not (string-match-p "Depends on abandoned.*\\[blocked" result)))))

(ert-deftest claude-code-ide-org-test-outline-unresolvable-blocker-is-flagged-distinctly ()
  "Unresolvable is not satisfied.  A dangling id, and a form naming no
ids at all, both get [blocked?] rather than being silently dropped."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* TODO Dangling blocker\n:PROPERTIES:\n"
            ":BLOCKER:  ids(44444444-4444-4444-8444-444444444444)\n:END:\n"
            "* TODO Sibling-form blocker\n:PROPERTIES:\n"
            ":BLOCKER:  previous-sibling\n:END:\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline)))
      ;; An unresolvable id is NAMED -- that is the id you have to go
      ;; and fix, and the old bare marker withheld exactly it. A form
      ;; naming no ids has nothing to name, so it stays bare.
      (should (string-match-p "Dangling blocker.*\\[blocked\\?: 44444444\\]" result))
      (should (string-match-p "Sibling-form blocker.*\\[blocked\\?\\]" result))
      (should-not (string-match-p "Sibling-form blocker.*\\[blocked\\?:" result)))))

(ert-deftest claude-code-ide-org-test-outline-reads-bare-id-blocker ()
  "TODO.org contains one :BLOCKER: written as a bare id with no ids()
wrapper.  org-depend would not honour it, but the index should see it
rather than report the heading as dependency-free."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* TODO Bare blocker target\n:PROPERTIES:\n"
            ":ID:       55555555-5555-4555-8555-555555555555\n:END:\n"
            "* TODO Bare-form dependent\n:PROPERTIES:\n"
            ":BLOCKER:  55555555-5555-4555-8555-555555555555\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline)))
      (should (string-match-p "Bare-form dependent.*\\[blocked: 55555555\\]" result)))))

(ert-deftest claude-code-ide-org-test-outline-includes-tags ()
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* TODO Tagged heading                                          :code:review:\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline)))
      (should (string-match-p "Tagged heading  :code:review:" result)))))

(ert-deftest claude-code-ide-org-test-outline-unreadable-file-returns-error-string ()
  "Never signal to the MCP layer: a bad scope comes back as a string."
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline "/nonexistent/nope.org")))
      (should (string-prefix-p "Error:" result)))))

(ert-deftest claude-code-ide-org-test-outline-does-not-modify-buffer ()
  "The whole tool is read-only; org-map-entries must leave the buffer
untouched, since it runs against files the user may have open."
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-query-files (list file)))
      (save-buffer)
      (set-buffer-modified-p nil)
      (claude-code-ide-org-outline)
      (should-not (buffer-modified-p (get-file-buffer file))))))

(ert-deftest claude-code-ide-org-test-outline-returns-plain-string ()
  "`org-get-heading' returns text carrying the buffer's properties, and
concat propagates them to the whole result, so the index would reach the
MCP layer as a propertized string.

The buffer text is deliberately propertized first.  Under `emacs --batch
-Q' no font-lock runs, so a scratch org file yields clean strings and the
assertion below passes whether or not the code strips properties -- an
inert test that looks like a passing one.  That is the same
fixture-versus-production gap that produced the `#+TODO:'-marker scare
(TODO.org :ID: 720b2dcf-6af1-45f3-96a7-aa841e5651e1) and the
content-block escape (:ID: 5e2a1c04-7b3f-4d21-9c88-2f6e0a91b7d3);
propertizing by hand is what makes this one measure anything.  Confirmed
to fail against the unstripped version."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-query-files (list file)))
      (with-current-buffer (get-file-buffer file)
        (put-text-property (point-min) (point-max) 'font-lock-face 'bold))
      (let ((result (claude-code-ide-org-outline)))
        (should (equal result (substring-no-properties result)))
        (should-not (text-properties-at 0 result))))))

(ert-deftest claude-code-ide-org-test-outline-junk-max-depth-is-no-limit ()
  "string-to-number yields 0 for junk, which must read as \"no limit\"
rather than filtering everything away."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "** TODO Child heading\n")
    (save-buffer)
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-outline nil "not-a-number" nil)))
      (should (string-match-p "Test heading" result))
      (should (string-match-p "Child heading" result)))))

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
      ;; Sequence order is TODO NEXT DOING WAITING MAYBE | DONE CANCELLED,
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

;;; claude-code-ide-org-body ------------------------------------------------

(defmacro claude-code-ide-org-test--with-story (&rest body)
  "Fixture whose heading has a :PLAN: drawer, a body, and one child."
  (declare (indent 0))
  `(claude-code-ide-org-test--with-heading
     (goto-char (point-max))
     (insert (concat
              ":PLAN:\n"
              "Superseded design reasoning a reader is told to skip.\n"
              ":END:\n"
              "Own body prose.\n"
              "\n"
              "** TODO Child heading\n"
              ":PROPERTIES:\n:ID:       test-0002\n:END:\n"
              "Child body prose.\n"))
     (save-buffer)
     (org-id-update-id-locations (list file))
     ,@body))

(ert-deftest claude-code-ide-org-test-body-returns-the-heading-whole ()
  "The heading line, its drawers and its body — filtering nothing.

Including :PLAN:. Suppressing it would be the first filtering decision
this tool makes, which is the thing the design avoids: that a reader
normally skips that drawer is the caller's judgement, not the tool's
(TODO.org :ID: a0028a4e)."
  (claude-code-ide-org-test--with-story
    (let ((text (claude-code-ide-org-body id)))
      (should (string-match-p "\\`\\* TODO Test heading" text))
      (should (string-match-p ":PROPERTIES:" text))
      (should (string-match-p ":PLAN:" text))
      (should (string-match-p "Superseded design reasoning" text))
      (should (string-match-p "Own body prose" text)))))

(ert-deftest claude-code-ide-org-test-body-stops-before-the-first-child ()
  "Own body by default; the whole subtree only when asked.

For a leaf the two are identical, so a fixture with a child is the only
one that can tell them apart — and this boundary is the part that can
regress silently."
  (claude-code-ide-org-test--with-story
    (let ((own (claude-code-ide-org-body id))
          (all (claude-code-ide-org-body id "true")))
      (should-not (string-match-p "Child heading" own))
      (should-not (string-match-p "Child body prose" own))
      (should (string-match-p "Child heading" all))
      (should (string-match-p "Child body prose" all))
      ;; The subtree is a superset, not a different rendering.
      (should (string-match-p "Own body prose" all)))))

(ert-deftest claude-code-ide-org-test-body-accepts-an-id-prefix ()
  "Scoping matches org_outline's: a full :ID: or an 8-character prefix.

Uses the known-ids fixture rather than the story one, because prefix
expansion runs over an index of *tracked* files and a bare temp file is
not one. What this pins is that org_body routes through
`claude-code-ide-org--id-find' rather than calling `org-id-find'
directly -- the distinction that once left fourteen call sites accepting
a prefix and one not."
  (claude-code-ide-org-test--with-known-ids
    (let ((text (claude-code-ide-org-body "29439196")))
      (should (string-match-p "\\* TODO Second" text))
      (should-not (string-match-p "TODO First" text)))))

(ert-deftest claude-code-ide-org-test-body-unresolvable-id-names-the-right-failure ()
  "An id that resolves to nothing must say so, not report a missing file.
Same reasoning as org_outline's scope error (TODO.org :ID: 2d9eeebd):
naming the wrong failure sent a reader looking for a file."
  (claude-code-ide-org-test--with-story
    (let ((result (claude-code-ide-org-body "99999999")))
      (should (string-match-p "\\`Error: :ID: .* resolves to no heading" result))
      (should-not (string-match-p "file" (downcase result)))))
  (claude-code-ide-org-test--with-story
    (should (string-match-p "\\`Error: no :ID: given"
                            (claude-code-ide-org-body "")))))

(ert-deftest claude-code-ide-org-test-body-does-not-touch-the-buffer ()
  "A read tool must leave the buffer unmodified and unnarrowed.
`--subtree-text-at-point' promises this and the own-body path must keep
the promise too, since it moves point to the heading to measure."
  (claude-code-ide-org-test--with-story
    (with-current-buffer (find-file-noselect file) (set-buffer-modified-p nil))
    (claude-code-ide-org-body id)
    (claude-code-ide-org-body id "true")
    (with-current-buffer (find-file-noselect file)
      (should-not (buffer-modified-p))
      (should-not (buffer-narrowed-p)))))

;;; claude-code-ide-org-clock-report -----------------------------------------

;; A clocktable's own #+CAPTION: carries a wall-clock timestamp, so
;; (string-match-p "1:00" report) also matches the caption at 01:00,
;; 11:00 and 21:00 -- three minutes a day, on an assertion that means to
;; be about a duration in the table (TODO.org :ID: 5a5e87c9). Every
;; duration assertion below goes through one of these two rather than
;; matching the whole report.

(defun claude-code-ide-org-test--report-total (report)
  "The *Total time* cell of REPORT, as a string like \"1:00\".
Covers both table shapes: the id-scoped `| *Total time* |' and the
file-list `| ALL *Total time* |'. Signals rather than returning nil
when there is no such row, so a report that never built cannot be
read as a mere duration mismatch."
  (if (string-match "\\*Total time\\*[^|]*|[^*|]*\\*\\([0-9]+:[0-9][0-9]\\)\\*" report)
      (match-string 1 report)
    (error "No *Total time* row in report: %S" report)))

(defun claude-code-ide-org-test--report-body (report)
  "REPORT with its #+CAPTION: line removed, for negative matches."
  (replace-regexp-in-string "^#\\+CAPTION:.*\n?" "" report))

(defmacro claude-code-ide-org-test--at-time (time &rest body)
  "Run BODY with the current time pinned to TIME.
Rebinding `current-time' alone is not enough: `:block \"today\"'
resolves through `org-clock-special-range', which reaches the clock as
`(decode-time nil)', so both have to move together. Lets a
today/yesterday fixture be written as fixed dates rather than as
arithmetic on the wall clock (TODO.org :ID: c31b6c76).

The clocktable's own #+CAPTION: is *not* pinned by this -- org builds it
with `format-time-string' and no TIME argument, so it is read in C.
Assert on durations through `claude-code-ide-org-test--report-total'
rather than against the whole report."
  (declare (indent 1) (debug (form body)))
  `(let ((claude-code-ide-org-test--now ,time)
         (claude-code-ide-org-test--real-decode (symbol-function 'decode-time)))
     (cl-letf (((symbol-function 'current-time)
                (lambda () claude-code-ide-org-test--now))
               ((symbol-function 'decode-time)
                (lambda (&optional tm &rest rest)
                  (apply claude-code-ide-org-test--real-decode
                         (or tm claude-code-ide-org-test--now) rest))))
       ,@body)))

(ert-deftest claude-code-ide-org-test-clock-report-assertions-ignore-the-caption ()
  "The caption's own timestamp must not satisfy a duration assertion.
Pinned against a crafted report rather than the real clock: org
builds the caption with `format-time-string' and no TIME argument
\(org-clock.el, `org-dblock-write:clocktable'), so the timestamp is
read in C and cannot be stubbed from Lisp."
  (let ((report (concat
                 "#+CAPTION: Clock summary at [2026-08-31 Mon 11:00]\n"
                 "| Headline     | Time   |\n"
                 "|--------------+--------|\n"
                 "| *Total time* | *0:00* |\n")))
    ;; The shape the assertions used to have. It is fooled, which is the
    ;; whole defect -- a green suite could not catch it because the
    ;; failing assertion was the negative one.
    (should (string-match-p "1:00" report))
    ;; The shape they have now. Neither helper can see the caption.
    (should (equal "0:00" (claude-code-ide-org-test--report-total report)))
    (should (not (string-match-p
                  "1:00" (claude-code-ide-org-test--report-body report))))))

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
      (should (equal "1:00" (claude-code-ide-org-test--report-total result)))
      (should (not (string-match-p "Other heading" result)))
      (should (not (string-match-p
                    "2:00" (claude-code-ide-org-test--report-body result)))))
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
      (should (equal "3:00" (claude-code-ide-org-test--report-total result))))))

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
      (should (equal "1:00" (claude-code-ide-org-test--report-total result))))
    ;; A range that excludes the entry entirely must report zero time.
    (let* ((claude-code-ide-org-query-files (list file))
           (result (claude-code-ide-org-clock-report
                    nil nil "[2026-08-01 Sat 00:00]" "[2026-08-02 Sun 00:00]")))
      (should (equal "0:00" (claude-code-ide-org-test--report-total result)))
      (should (not (string-match-p
                    "1:00" (claude-code-ide-org-test--report-body result)))))))

(ert-deftest claude-code-ide-org-test-clock-report-block-today ()
  "The :block param must reach `org-clock-special-range' correctly —
proven with a same-day CLOCK entry pinned to whole-minute boundaries
(so duration arithmetic can\'t be thrown off by stray seconds) and
:block \"today\", vs. a CLOCK entry from an earlier day, which
:block \"today\" must exclude.

Both the fixture and \"today\" are pinned to 2026-07-27, and \"now\" is
pinned to 23:16 on that date — the hour, and the very minute, at which
this test used to fail. The fixture was previously built as \"now, seconds
zeroed\" plus one hour, so after 23:00 it crossed midnight and `today\'
saw only the part before it: the table read *0:44* and the positive
assertion failed, every day, for the last hour of the day (TODO.org
:ID: c31b6c76). A fixed date removes the dependence on when the suite
runs rather than narrowing the window in which it breaks."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat
             ":LOGBOOK:\n"
             "CLOCK: [2026-07-27 Mon 09:00]--[2026-07-27 Mon 10:00] =>  1:00\n"
             ":END:\n"))
    (save-buffer)
    (claude-code-ide-org-test--at-time (encode-time 0 16 23 27 7 2026)
      (let ((result (claude-code-ide-org-clock-report id "today")))
        (should (equal "1:00" (claude-code-ide-org-test--report-total result)))))
    ;; Same entry moved to the day before: `today\' must now exclude it.
    (with-current-buffer (get-file-buffer file)
      (goto-char (point-min))
      (re-search-forward "CLOCK: \\[[^]]+\\]--\\[[^]]+\\] =>  1:00")
      (replace-match
       "CLOCK: [2026-07-26 Sun 09:00]--[2026-07-26 Sun 10:00] =>  1:00")
      (save-buffer))
    (claude-code-ide-org-test--at-time (encode-time 0 16 23 27 7 2026)
      (let ((result (claude-code-ide-org-clock-report id "today")))
        (should (equal "0:00" (claude-code-ide-org-test--report-total result)))
        (should (not (string-match-p
                      "1:00" (claude-code-ide-org-test--report-body result))))))))

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
      (should (equal "1:00" (claude-code-ide-org-test--report-total result))))))

;;; claude-code-ide-org-log-background-plan --------------------------------

(ert-deftest claude-code-ide-org-test-log-background-plan-inserts-link ()
  (claude-code-ide-org-test--with-heading
    (let ((result (claude-code-ide-org-log-background-plan
                   id "~/.claude/plans/warm-marinating-puddle.md" "session-A-bg1")))
      (should (string-match-p "\\`Logged background plan for \"Test heading\"\\.\\'" result)))
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p
               "\\[\\[file:~/.claude/plans/warm-marinating-puddle.md\\]\\[Plan\\]\\]"
               disk))
      ;; The "Background-planned (session ...)" entry went with the
      ;; :SESSIONS: drawer (TODO.org :ID: 9d2fcdad). SESSION-ID is still
      ;; accepted and deliberately unrecorded; asserting the drawer's
      ;; absence keeps that a decision rather than a regression.
      (should-not (string-match-p ":SESSIONS:" disk)))))

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
    (should (not (string-match-p ":LOGBOOK:" (claude-code-ide-org-test--disk-contents file))))))

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

(ert-deftest claude-code-ide-org-test-statusline-reads-the-queue-over-the-clock ()
  "The statusline reports the heading the *queue* names, even when a live
clock is running on a different one (TODO.org :ID: 290b6fc5).

The clock is deliberately pointed elsewhere: if the queue were ignored,
this test would report \"Other heading\" and pass a laxer assertion. It is
the disagreement between the two sources that makes the test mean
anything, since agreeing sources cannot distinguish which was read."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org-test--with-heading
      (goto-char (point-max))
      (insert "* TODO Other heading\n:PROPERTIES:\n:ID:       test-0002\n:END:\n")
      (save-buffer)
      (org-id-update-id-locations (list file))
      (claude-code-ide-org-test--clock-in-for-real "test-0002")
      (apply #'claude-code-ide-org-test--queue-write "sess-a"
             (list (claude-code-ide-org-test--queue-event
                    "2026-08-18T09:00:00-0500" "todo" id "DOING")
                   (claude-code-ide-org-test--queue-event
                    "2026-08-18T09:00:01-0500" "resume")))
      (let ((result (claude-code-ide-org--statusline-task-string)))
        (should (string-match-p "Test heading" result))
        (should-not (string-match-p "Other heading" result))))))

(ert-deftest claude-code-ide-org-test-statusline-running-state-follows-guideposts ()
  "The running/paused label comes from the newest guidepost, not from
`org-clocking-p'.  A trailing `resume' means mid-turn; a trailing `pause'
means waiting on a human."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org-test--with-heading
      (apply #'claude-code-ide-org-test--queue-write "sess-a"
             (list (claude-code-ide-org-test--queue-event
                    "2026-08-18T09:00:00-0500" "todo" id "DOING")
                   (claude-code-ide-org-test--queue-event
                    "2026-08-18T09:00:01-0500" "resume")))
      (should (string-match-p "clocked in"
                              (claude-code-ide-org--statusline-task-string)))
      (apply #'claude-code-ide-org-test--queue-write "sess-a"
             (list (claude-code-ide-org-test--queue-event
                    "2026-08-18T09:05:00-0500" "pause")))
      (should (string-match-p "clocked out"
                              (claude-code-ide-org--statusline-task-string))))))

(ert-deftest claude-code-ide-org-test-statusline-falls-back-when-queue-id-is-unresolvable ()
  "A queue naming a heading that no longer resolves must fall through to
the clock, not blank the line.  The queue having an opinion is not the
same as that opinion being usable -- an archived or deleted heading is
exactly the case, and it was the defect in this function's first draft."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org-test--with-heading
      (claude-code-ide-org-test--clock-in-for-real id)
      (apply #'claude-code-ide-org-test--queue-write "sess-a"
             (list (claude-code-ide-org-test--queue-event
                    "2026-08-18T09:00:00-0500" "todo" "no-such-id" "DOING")
                   (claude-code-ide-org-test--queue-event
                    "2026-08-18T09:00:01-0500" "resume")))
      (should (string-match-p "Test heading"
                              (claude-code-ide-org--statusline-task-string))))))

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

(ert-deftest claude-code-ide-org-test-clock-out-id-is-inherited-not-reported ()
  "org_clock_out reports no :ID: at all now, and does not need to: the
two tests this replaces pinned the \"(id: ...)\" suffix
`bin/hooks/queue-append' used to sed out of the reply, which was the
only way a heading-less `clock_out' could name its heading.  Ingestion
answers it instead, from the session's own stream -- which is strictly
better, because it cannot be fooled by whatever a human happens to be
clocking at the time."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org-test--queue-write
     "sess-a"
     (claude-code-ide-org-test--queue-event
      "2026-08-07T09:00:00-0500" "clock_in" "id-a")
     ;; A null-id clock_out, exactly as the cut-over wrapper produces.
     (json-encode '((ts . "2026-08-07T09:20:00-0500") (kind . "clock_out")
                    (id . nil) (session_id . "sess-a") (source . "org_clock_out"))))
    (let ((groups (claude-code-ide-org--queue-events-by-id)))
      (should (= 1 (length groups)))
      (should (equal "id-a" (car (car groups))))
      (should (= 2 (length (cdr (car groups))))))))

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

(ert-deftest claude-code-ide-org-test-queue-dismissed-events-are-filtered ()
  "A dismissed event drops out of the pending set exactly as an applied
one does. This is the exit an item that will never apply has otherwise
never had -- the `dead-beef' phantom clock reappeared at every review
because skipping is how a human *defers*, not how they refuse."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:00-0500" "clock_in" "id-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:05:00-0500" "pause")))
    (should (= 2 (length (claude-code-ide-org--queue-events))))
    (claude-code-ide-org--queue-mark-dismissed
     "sess-a" '("2026-08-07T09:00:00-0500") "unresolvable :ID:, will never apply")
    (let ((remaining (claude-code-ide-org--queue-events)))
      (should (equal (mapcar (lambda (e) (plist-get e :ts-string)) remaining)
                     '("2026-08-07T09:05:00-0500"))))))

(ert-deftest claude-code-ide-org-test-queue-applied-and-dismissed-do-not-clobber ()
  "The regression that matters. Both facts share one file, so a writer
that serialized only its own key would erase the other -- and the
symptom, dismissed items quietly reappearing, reads as \"dismissal does
not work\" rather than \"apply clobbered it\". Asserted in both orders,
since either writer could be the one that forgets."
  (claude-code-ide-org-test--with-queue
    ;; Dismiss first, then apply something else.
    (claude-code-ide-org--queue-mark-dismissed
     "sess-a" '("2026-08-07T09:00:00-0500") "pre-cutover, already applied live")
    (claude-code-ide-org--queue-mark-applied "sess-a" '("2026-08-07T09:05:00-0500"))
    (should (gethash "2026-08-07T09:00:00-0500"
                     (claude-code-ide-org--queue-dismissed "sess-a")))
    (should (gethash "2026-08-07T09:05:00-0500"
                     (claude-code-ide-org--queue-applied "sess-a")))
    ;; And the reverse order, on a fresh session.
    (claude-code-ide-org--queue-mark-applied "sess-b" '("2026-08-07T10:00:00-0500"))
    (claude-code-ide-org--queue-mark-dismissed
     "sess-b" '("2026-08-07T10:05:00-0500") "never applying this one")
    (should (gethash "2026-08-07T10:00:00-0500"
                     (claude-code-ide-org--queue-applied "sess-b")))
    (should (gethash "2026-08-07T10:05:00-0500"
                     (claude-code-ide-org--queue-dismissed "sess-b")))))

(ert-deftest claude-code-ide-org-test-queue-applied-records-the-pass-time ()
  "Each consumed event carries the time of the pass that consumed it,
round-tripping through the file (TODO.org :ID: 21c91613).

The field exists so \"un-apply the pass of 17:17\" is a filter rather
than the archaeology the 2026-08-24 recovery actually required."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org--queue-mark-applied
     "sess-a" '("2026-08-07T09:00:00-0500" "2026-08-07T09:05:00-0500")
     "2026-08-07T17:17:00-0500")
    (let ((applied (claude-code-ide-org--queue-applied "sess-a")))
      (should (equal "2026-08-07T17:17:00-0500"
                     (gethash "2026-08-07T09:00:00-0500" applied)))
      (should (equal "2026-08-07T17:17:00-0500"
                     (gethash "2026-08-07T09:05:00-0500" applied))))
    ;; A later pass stamps only its own events, and does not disturb the
    ;; first pass's.  This is what makes the two separable at all.
    (claude-code-ide-org--queue-mark-applied
     "sess-a" '("2026-08-07T09:10:00-0500") "2026-08-07T18:40:00-0500")
    (let ((applied (claude-code-ide-org--queue-applied "sess-a")))
      (should (equal "2026-08-07T17:17:00-0500"
                     (gethash "2026-08-07T09:00:00-0500" applied)))
      (should (equal "2026-08-07T18:40:00-0500"
                     (gethash "2026-08-07T09:10:00-0500" applied))))
    ;; Re-marking an already-consumed event keeps the original stamp: the
    ;; event was consumed once, by the pass named.
    (claude-code-ide-org--queue-mark-applied
     "sess-a" '("2026-08-07T09:00:00-0500") "2026-08-07T19:00:00-0500")
    (should (equal "2026-08-07T17:17:00-0500"
                   (gethash "2026-08-07T09:00:00-0500"
                            (claude-code-ide-org--queue-applied "sess-a"))))))

(ert-deftest claude-code-ide-org-test-queue-applied-stamps-one-pass-once ()
  "Every event a single apply consumes carries the *same* stamp, even
across sessions.

The unit to undo is a pass, not an event.  A `now' taken per session --
or per event -- would differ across one batch and make \"un-apply the
pass of 17:17\" a range query over values nobody chose.

*The clock is stubbed rather than read*, and that is what makes this
test discriminate.  The stamps carry second resolution, so a real
per-session `now' would agree with a per-pass one whenever the batch
takes under a second -- which is always, in a test.  Counting the calls
asserts the mechanism instead of a coincidence: one `format-time-string'
for the whole pass, however many sessions it touches."
  (claude-code-ide-org-test--with-queue
    (let ((calls 0))
      (cl-letf (((symbol-function 'format-time-string)
                 (lambda (&rest args)
                   (setq calls (1+ calls))
                   (format "stamp-%d" calls))))
        (claude-code-ide-org--review-record-applied
         (list (list :events (list (list :ts-string "2026-08-07T09:00:00-0500"
                                         :session-id "sess-a")
                                   (list :ts-string "2026-08-07T09:05:00-0500"
                                         :session-id "sess-a")))
               (list :events (list (list :ts-string "2026-08-07T10:00:00-0500"
                                         :session-id "sess-b"))))))
      (should (= 1 calls)))
    (should (equal '("stamp-1" "stamp-1" "stamp-1")
                   (list (gethash "2026-08-07T09:00:00-0500"
                                  (claude-code-ide-org--queue-applied "sess-a"))
                         (gethash "2026-08-07T09:05:00-0500"
                                  (claude-code-ide-org--queue-applied "sess-a"))
                         (gethash "2026-08-07T10:00:00-0500"
                                  (claude-code-ide-org--queue-applied "sess-b")))))
    ;; And the real path writes the queue's own timestamp format, so a
    ;; stamp and an event `ts' are comparable without conversion.
    (claude-code-ide-org--review-record-applied
     (list (list :events (list (list :ts-string "2026-08-07T11:00:00-0500"
                                     :session-id "sess-c")))))
    (should (string-match-p
             "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}[-+][0-9]\\{4\\}\\'"
             (gethash "2026-08-07T11:00:00-0500"
                      (claude-code-ide-org--queue-applied "sess-c"))))))

(ert-deftest claude-code-ide-org-test-queue-applied-reads-the-legacy-array ()
  "Every watermark file written before :ID: 21c91613 holds `applied' as a
bare array of `ts' strings.  Those keep reading, and upgrade in place on
the next write without losing entries or dismissals.

A legacy entry's apply time is the empty string, never a fabricated one.
Same ethos as the retired stale-clock guess (:ID: 7771fc63): a plausible
wrong timestamp survives being read back as fact, and an absent one does
not."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org--atomic-write
     (claude-code-ide-org--queue-watermark-file "sess-a")
     ;; `intern' rather than a literal: Elisp has no `|...|' symbol
     ;; escaping, so a bare timestamp key written in source is a symbol
     ;; whose name contains the pipes, and they reach the JSON.
     (json-encode
      (list (cons 'applied (list "2026-08-07T09:00:00-0500"
                                 "2026-08-07T09:05:00-0500"))
            (cons 'dismissed
                  (list (cons (intern "2026-08-07T08:00:00-0500")
                              "phantom clock"))))))
    (let ((applied (claude-code-ide-org--queue-applied "sess-a")))
      (should (= 2 (hash-table-count applied)))
      (should (equal "" (gethash "2026-08-07T09:00:00-0500" applied)))
      (should (equal "" (gethash "2026-08-07T09:05:00-0500" applied))))
    ;; The upgrade: a new pass rewrites the file wholesale, so the legacy
    ;; entries survive as object keys with their empty stamps intact, the
    ;; new one carries a real stamp, and the dismissal is untouched.
    (claude-code-ide-org--queue-mark-applied
     "sess-a" '("2026-08-07T09:10:00-0500") "2026-08-07T17:17:00-0500")
    (let ((text (claude-code-ide-org-test--disk-contents
                 (claude-code-ide-org--queue-watermark-file "sess-a"))))
      (should (string-match-p "\"applied\":{" text))
      (should (string-match-p "\"2026-08-07T09:00:00-0500\":\"\"" text)))
    (let ((applied (claude-code-ide-org--queue-applied "sess-a")))
      (should (= 3 (hash-table-count applied)))
      (should (equal "" (gethash "2026-08-07T09:00:00-0500" applied)))
      (should (equal "2026-08-07T17:17:00-0500"
                     (gethash "2026-08-07T09:10:00-0500" applied))))
    (should (equal "phantom clock"
                   (gethash "2026-08-07T08:00:00-0500"
                            (claude-code-ide-org--queue-dismissed "sess-a"))))))

(ert-deftest claude-code-ide-org-test-queue-dismissal-preserves-apply-times ()
  "A dismissal after an apply must not flatten the apply times.

The sharp edge of making `applied' a map: `--queue-mark-dismissed'
round-trips `--queue-applied''s return straight back into the writer, so
a reader that normalized values away would silently erase every stamp
the first time anything was dismissed -- and the ledger would look
perfectly well-formed afterwards."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org--queue-mark-applied
     "sess-a" '("2026-08-07T09:00:00-0500") "2026-08-07T17:17:00-0500")
    (claude-code-ide-org--queue-mark-dismissed
     "sess-a" '("2026-08-07T09:05:00-0500") "never applying this one")
    (should (equal "2026-08-07T17:17:00-0500"
                   (gethash "2026-08-07T09:00:00-0500"
                            (claude-code-ide-org--queue-applied "sess-a"))))
    (should (equal "never applying this one"
                   (gethash "2026-08-07T09:05:00-0500"
                            (claude-code-ide-org--queue-dismissed "sess-a"))))))

(ert-deftest claude-code-ide-org-test-queue-dismissal-reason-round-trips ()
  "The reason is the point of a map rather than a set: \"already applied
live pre-cutover\" and \"this event should never have existed\" want
different treatment at any later audit."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org--queue-mark-dismissed
     "sess-a" '("2026-08-07T09:00:00-0500") "phantom clock, :ID: never resolved")
    (should (equal "phantom clock, :ID: never resolved"
                   (gethash "2026-08-07T09:00:00-0500"
                            (claude-code-ide-org--queue-dismissed "sess-a"))))
    ;; A second dismissal accumulates rather than replacing the first.
    (claude-code-ide-org--queue-mark-dismissed
     "sess-a" '("2026-08-07T09:05:00-0500") "pre-cutover no-op")
    (should (equal "phantom clock, :ID: never resolved"
                   (gethash "2026-08-07T09:00:00-0500"
                            (claude-code-ide-org--queue-dismissed "sess-a"))))
    (should (equal "pre-cutover no-op"
                   (gethash "2026-08-07T09:05:00-0500"
                            (claude-code-ide-org--queue-dismissed "sess-a"))))))

(ert-deftest claude-code-ide-org-test-queue-dismissal-is-per-event-not-a-prefix ()
  "Dismissal is a set, for the same reason the applied state is: review
is per-item and non-contiguous, so retiring a middle event must leave
both its neighbours pending."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:00:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:05:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-07T09:10:00-0500" "pause")))
    (claude-code-ide-org--queue-mark-dismissed
     "sess-a" '("2026-08-07T09:05:00-0500") "middle one only")
    (should (equal (mapcar (lambda (e) (plist-get e :ts-string))
                           (claude-code-ide-org--queue-events))
                   '("2026-08-07T09:00:00-0500" "2026-08-07T09:10:00-0500")))))

(ert-deftest claude-code-ide-org-test-queue-watermark-without-dismissed-key-reads ()
  "Every watermark file on disk today carries only `applied'. Those must
keep reading correctly, with an empty dismissed set, rather than needing
a migration step."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org--atomic-write
     (claude-code-ide-org--queue-watermark-file "sess-a")
     (json-encode '((applied . ("2026-08-07T09:00:00-0500")))))
    (should (gethash "2026-08-07T09:00:00-0500"
                     (claude-code-ide-org--queue-applied "sess-a")))
    (should (= 0 (hash-table-count
                  (claude-code-ide-org--queue-dismissed "sess-a"))))
    ;; And a dismissal added on top preserves the pre-existing applied set.
    (claude-code-ide-org--queue-mark-dismissed
     "sess-a" '("2026-08-07T09:05:00-0500") "added after the fact")
    (should (gethash "2026-08-07T09:00:00-0500"
                     (claude-code-ide-org--queue-applied "sess-a")))
    (should (gethash "2026-08-07T09:05:00-0500"
                     (claude-code-ide-org--queue-dismissed "sess-a")))))

(ert-deftest claude-code-ide-org-test-queue-watermark-empty-sets-are-not-null ()
  "An empty set is written as `{}', never `null'.

Asserted on the bytes, because the round-trip cannot catch this: Elisp
spells the empty list, the empty object and JSON null all as nil, so
this reader accepts `null' happily and every in-process test still
passes.  No other JSON stack is that forgiving -- `d.get(\"applied\",
{})' does not fall back when the key is present holding null, which
crashed a real inspection script on a real watermark file.  Dismissing
before anything is applied is the case that produces it.

`applied' is an object rather than an array as of :ID: 21c91613, since
each entry now carries the time of the pass that consumed it."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org--queue-mark-dismissed
     "sess-a" '("2026-08-07T09:00:00-0500") "never applying this")
    (let ((text (claude-code-ide-org-test--disk-contents
                 (claude-code-ide-org--queue-watermark-file "sess-a"))))
      (should (string-match-p "\"applied\":{}" text))
      (should-not (string-match-p "null" text)))
    ;; ...and the mirror case: applied with nothing dismissed.
    (claude-code-ide-org--queue-mark-applied "sess-b" '("2026-08-07T10:00:00-0500"))
    (let ((text (claude-code-ide-org-test--disk-contents
                 (claude-code-ide-org--queue-watermark-file "sess-b"))))
      (should (string-match-p "\"dismissed\":{}" text))
      (should-not (string-match-p "null" text)))))

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

(ert-deftest claude-code-ide-org-test-aggregate-guideposts-never-splits-inside-a-turn ()
  "A `resume' -> `pause' gap is a turn running, and never splits however
long it is (TODO.org :ID: 226ed53b).

Guideposts mark turn *boundaries*, so a single long turn emits only its
own two.  Clustering blind to `:kind' put them in different clusters and
collapsed 69 minutes of continuous work into two zero-width points -- and
the closing `pause' was then absorbed into the next cluster, describing a
turn it had nothing to do with.

The three cases are asserted together because the rule is a *pair* of
claims and either alone is satisfiable by a wrong implementation: gating
on the other adjacency direction would pass the first and fail the second."
  (let ((t0 (date-to-time "2026-08-18T09:00:00-0500")))
    ;; 1. resume -> pause, 69 min: one span, not two points.
    (let ((spans (claude-code-ide-org--aggregate-guideposts
                  (list (list :ts t0 :kind "resume")
                        (list :ts (time-add t0 (* 69 60)) :kind "pause")))))
      (should (= 1 (length spans)))
      (should (= (* 69 60.0)
                 (float-time (time-subtract (cdar spans) (caar spans))))))
    ;; 2. pause -> resume, same 69 min: still splits. This is the gap the
    ;;    1200 s threshold was actually measured on.
    (should (= 2 (length (claude-code-ide-org--aggregate-guideposts
                          (list (list :ts t0 :kind "pause")
                                (list :ts (time-add t0 (* 69 60)) :kind "resume"))))))
    ;; 3. a missing :kind stays splittable -- the bare-:ts fixtures rely on it.
    (should (= 2 (length (claude-code-ide-org--aggregate-guideposts
                          (list (list :ts t0)
                                (list :ts (time-add t0 (* 69 60))))))))))

(ert-deftest claude-code-ide-org-test-aggregate-guideposts-does-not-round ()
  "Spans keep their exact endpoints, and consolidation now keeps them too.

This test once asserted the opposite of its second half: that the same
2-minute interval, handed to `consolidate-history', collapsed to nothing
— the contrast being the point. That contrast is gone, because the
rounding was retired after it destroyed a reviewed interval in the field
(TODO.org :ID: b74e0f19-5a26-4c83-9d70-8e1c5a2f6b04). Kept, inverted,
because a short interval surviving *both* paths is now the invariant."
  (let* ((events (mapcar (lambda (ts) (list :ts (date-to-time ts) :kind "pause"))
                         '("2026-08-06T22:43:00-0500" "2026-08-06T22:45:00-0500")))
         (spans (claude-code-ide-org--aggregate-guideposts events)))
    (should (= 1 (length spans)))
    (should (equal (format-time-string "%H:%M" (car (car spans))) "22:43"))
    (should (equal (format-time-string "%H:%M" (cdr (car spans))) "22:45"))
    ;; The same interval through consolidation: unchanged, not erased.
    (should (equal
             "CLOCK: [2026-08-06 Thu 22:43]--[2026-08-06 Thu 22:45] =>  0:02"
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
        ;; Inactive: every queue-derived span is agent activity and
        ;; must stay out of org-agenda (TODO.org :ID: b8e6007a).
        (should (string-match-p "- \\[2026-08-06 [A-Za-z]+ 09:00\\]--\\[2026-08-06 [A-Za-z]+ 09:15\\] clarify backend schema design"
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

(defun claude-code-ide-org-test--interleaved-agent-lines (first-out second-out)
  "Two concurrent subagents' events, sharing one session_id.
FIRST-OUT and SECOND-OUT name which agent clocks out first, so a caller
can run both completion orders. Mirrors the real 2026-08-12 capture:
each agent clocks in on its own heading, `org_clock_out' carries no id,
and a human pause/resume lands between them."
  (let ((in-a (claude-code-ide-org-test--queue-event
               "2026-08-12T17:40:01-0500" "clock_in" "id-a" nil "sess-a"
               "agent a work" "agent-aaaa" "general-purpose"))
        (in-b (claude-code-ide-org-test--queue-event
               "2026-08-12T17:40:20-0500" "clock_in" "id-b" nil "sess-a"
               "agent b work" "agent-bbbb" "general-purpose"))
        (pause (claude-code-ide-org-test--queue-event
                "2026-08-12T17:40:26-0500" "pause" nil nil "sess-a"))
        (out-a (claude-code-ide-org-test--queue-event
                "2026-08-12T17:42:20-0500" "clock_out" nil nil "sess-a"
                "agent a done" "agent-aaaa" "general-purpose"))
        (out-b (claude-code-ide-org-test--queue-event
                "2026-08-12T17:43:58-0500" "clock_out" nil nil "sess-a"
                "agent b done" "agent-bbbb" "general-purpose")))
    ;; Swap the timestamps' owners rather than the order, so both
    ;; variants keep the same chronology and differ only in who finishes.
    (list in-a in-b pause
          (if (eq first-out 'a) out-a out-b)
          (if (eq second-out 'b) out-b out-a))))

(ert-deftest claude-code-ide-org-test-narrowing-keeps-the-remainder ()
  "Narrowing a span re-scopes its events and offers the rest immediately.

Regression for TODO.org :ID: ffe65444. --review-apply marks every event
in :events consumed, so before this an item edited down to part of its
span still swallowed the whole original: a 54-minute span truncated to
23 minutes lost 32 minutes that never came back."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "todo" "id-a" "DOING" "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:05:00-0500" "resume" nil nil "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:10:00-0500" "pause" nil nil "sess-a")
                 ;; Inside the gap threshold, so all four cluster into
                 ;; ONE span -- otherwise they arrive already split and
                 ;; narrowing has nothing to exclude.
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:20:00-0500" "resume" nil nil "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:25:00-0500" "pause" nil nil "sess-a")))
    (claude-code-ide-org-test--with-review-buffer
        (claude-code-ide-org--review-items-from-queue)
      (let* ((items claude-code-ide-org--review-items)
             (span (seq-find (lambda (i) (plist-get i :unassigned)) items)))
        (should span)
        ;; Point must be on the span for edit-interval to act on it.
        (claude-code-ide-org-test--goto-nth-item (seq-position items span))
        (let ((before (length (plist-get span :events))))
          (should (> before 2))
          ;; Narrow to just the first cluster.
          (cl-letf (((symbol-function 'read-string)
                     (lambda (prompt &optional initial &rest _)
                       (if (string-prefix-p "Start" prompt)
                           "[2026-08-13 Thu 09:05]"
                         "[2026-08-13 Thu 09:10]"))))
            (claude-code-ide-org-review-edit-interval))
          ;; The edited item keeps only the events it still spans...
          (should (< (length (plist-get span :events)) before))
          ;; ...and the excluded ones come back as their own item, now,
          ;; without waiting for a refresh.
          (let ((remainder (seq-find
                            (lambda (i)
                              (and (not (eq i span))
                                   (equal "09:20" (format-time-string
                                                   "%H:%M" (plist-get i :start)))))
                            claude-code-ide-org--review-items)))
            (should remainder)
            (should-not (plist-get remainder :marked))
            ;; Every original event is still accounted for somewhere.
            (should (equal before
                           (+ (length (plist-get span :events))
                              (length (plist-get remainder :events)))))))))))

(ert-deftest claude-code-ide-org-test-no-zero-width-remainder ()
  "A single leftover guidepost is not offered as a zero-width remainder.

Reported from use 2026-08-13 after widening a span's start: the stray
event clustered into a 0-minute span whose only possible answer was `d'.
On the main path a lone guidepost is real evidence and worth offering;
as a remainder it is an artifact of where the human drew the line.

Critically, the event must still be CONSERVED -- belonging to no item
means it is never marked applied, so it returns on the next build."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "todo" "id-a" "DOING" "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:05:00-0500" "resume" nil nil "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:10:00-0500" "pause" nil nil "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:15:00-0500" "resume" nil nil "sess-a")))
    (claude-code-ide-org-test--with-review-buffer
        (claude-code-ide-org--review-items-from-queue)
      (let* ((items claude-code-ide-org--review-items)
             (span (seq-find (lambda (i) (plist-get i :unassigned)) items)))
        (should span)
        (claude-code-ide-org-test--goto-nth-item (seq-position items span))
        ;; Narrow so exactly ONE event (09:15) falls outside.
        (cl-letf (((symbol-function 'read-string)
                   (lambda (prompt &optional _initial &rest _)
                     (if (string-prefix-p "Start" prompt)
                         "[2026-08-13 Thu 09:05]"
                       "[2026-08-13 Thu 09:10]"))))
          (claude-code-ide-org-review-edit-interval))
        ;; No zero-width item was added.
        ;; Scoped to clock items: a state item has no :start/:end, and
        ;; `time-equal-p' reads nil as "now" for both, so an unscoped
        ;; check reports every state item as zero-width.
        (should-not (seq-find (lambda (i)
                                (and (not (eq i span))
                                     (eq (plist-get i :type) 'clock)
                                     (time-equal-p (plist-get i :start)
                                                   (plist-get i :end))))
                              claude-code-ide-org--review-items))
        ;; And the stray event is in no item at all, so it stays pending.
        (should-not (seq-find
                     (lambda (i)
                       (seq-find (lambda (e)
                                   (equal "09:15" (format-time-string
                                                   "%H:%M" (plist-get e :ts))))
                                 (plist-get i :events)))
                     claude-code-ide-org--review-items))))))

(ert-deftest claude-code-ide-org-test-remainder-never-outlives-a-human-endpoint ()
  "A remainder may never extend past the endpoint the human just set.

Narrowing to a slice INSIDE a turn leaves that turn's `resume' and
`pause' on opposite sides of the new window. Clustered together they
form one span bridging it -- and since clustering became kind-aware a
`resume' -> `pause' adjacency is exactly what refuses to split at any
gap -- so the remainder offered back strictly CONTAINS the interval just
confirmed. The same minutes twice, with the leftover looking like the
more complete of the two.

Neither existing narrowing test sees this: both assert on event counts,
which are conserved either way, and both narrow to a boundary that
leaves the leftovers all on one side. This one straddles."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "todo" "id-a" "DOING" "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "resume" nil nil "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:02:00-0500" "pause" nil nil "sess-a")
                 ;; A 30-minute turn. Longer than the gap threshold, and
                 ;; kept whole by the resume->pause rule -- which is what
                 ;; puts a splittable-looking pair either side of the
                 ;; window narrowed to below.
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:05:00-0500" "resume" nil nil "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:35:00-0500" "pause" nil nil "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:40:00-0500" "resume" nil nil "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:42:00-0500" "pause" nil nil "sess-a")))
    (claude-code-ide-org-test--with-review-buffer
        (claude-code-ide-org--review-items-from-queue)
      (let* ((items claude-code-ide-org--review-items)
             (span (seq-find (lambda (i) (plist-get i :unassigned)) items))
             (from (date-to-time "2026-08-13T09:10:00-0500"))
             (to (date-to-time "2026-08-13T09:20:00-0500")))
        (should span)
        (should (= 6 (length (plist-get span :events))))
        (claude-code-ide-org-test--goto-nth-item (seq-position items span))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (prompt &optional _initial &rest _)
                     (if (string-prefix-p "Start" prompt)
                         "[2026-08-13 Thu 09:10]"
                       "[2026-08-13 Thu 09:20]"))))
          (claude-code-ide-org-review-edit-interval))
        (let ((remainders (seq-filter
                           (lambda (i) (and (not (eq i span))
                                            (eq 'clock (plist-get i :type))))
                           claude-code-ide-org--review-items)))
          ;; Both sides come back, so nothing was quietly dropped either.
          (should (= 2 (length remainders)))
          (dolist (r remainders)
            ;; Each lies wholly on one side of the confirmed window.
            (should (or (not (time-less-p from (plist-get r :end)))
                        (not (time-less-p (plist-get r :start) to))))))))))

(ert-deftest claude-code-ide-org-test-unbracketed-span-annotation-carries-a-label ()
  "A reconstructed span writes a labelled annotation, never a bare one.

Regression for TODO.org :ID: c97b3564: one apply pass on 2026-08-13 wrote
17 bare `- <ts>--<ts>' lines. Suppressing the line was rejected because
the ACTIVE timestamps are what reach org-agenda, so the label is
synthesised instead and carries provenance -- reconstructed and
confirmed, not clocked live."
  (let ((accepted (list :type 'clock :id "id-a"
                        :start (date-to-time "2026-08-13T09:00:00-0500")
                        :end (date-to-time "2026-08-13T09:30:00-0500")
                        :note nil :agent nil :suggested t
                        :unassigned t :origin 'unbracketed))
        (chosen (list :type 'clock :id "id-a"
                      :start (date-to-time "2026-08-13T09:00:00-0500")
                      :end (date-to-time "2026-08-13T09:30:00-0500")
                      :note nil :agent nil :suggested t
                      :unassigned nil :assigned t :origin 'unbracketed))
        (bracketed (list :type 'clock :id "id-a"
                         :start (date-to-time "2026-08-13T09:00:00-0500")
                         :end (date-to-time "2026-08-13T09:30:00-0500")
                         :note nil :agent nil :suggested t)))
    ;; Both reconstructed shapes get a label, and the labels differ --
    ;; accepting a suggestion is not the same act as choosing a heading.
    (should (string-match-p "accepted at review"
                            (claude-code-ide-org--review-format-annotation accepted)))
    (should (string-match-p "assigned at review"
                            (claude-code-ide-org--review-format-annotation chosen)))
    ;; An ordinary bracketed span with no note is left exactly as before:
    ;; this fix must not invent provenance for intervals that had a
    ;; clock_in and simply carried no note.
    (should-not (string-match-p "review"
                                (claude-code-ide-org--review-format-annotation bracketed)))
    ;; A real note always wins over the synthesised one.
    (should (string-match-p "real label"
                            (claude-code-ide-org--review-format-annotation
                             (plist-put (copy-sequence accepted) :note "real label"))))))

(ert-deftest claude-code-ide-org-test-apply-consolidates-the-drawer ()
  "Apply leaves the heading's drawer on one ascending timeline.

TODO.org :ID: 12e0adac. org inserts CLOCK lines newest-first while notes
land in insertion order, so a drawer drifts out of order as soon as
anything is added. Applying an older interval after a newer one used to
leave them inverted."
  (claude-code-ide-org-test--with-heading
    ;; OLDER first, then newer. org inserts each CLOCK line at the TOP
    ;; of the drawer, so this is the order that leaves it inverted --
    ;; the reverse ordering happens to come out ascending by accident,
    ;; which made the first version of this test pass without the fix.
    (dolist (spec '(("09:00" "09:15") ("11:00" "11:30")))
      (should-not (claude-code-ide-org--review-apply-item
                   (list :type 'clock :id id
                         :start (date-to-time (concat "2026-08-06T" (car spec) ":00-0500"))
                         :end (date-to-time (concat "2026-08-06T" (cadr spec) ":00-0500"))
                         :agent nil :suggested nil :events nil))))
    (let* ((logbook (claude-code-ide-org-test--logbook file))
           (clocks (seq-filter (lambda (l) (string-match-p "CLOCK:" l))
                               (split-string logbook "\n" t))))
      (should (equal 2 (length clocks)))
      ;; Oldest first.
      (should (string-match-p "09:00" (nth 0 clocks)))
      (should (string-match-p "11:00" (nth 1 clocks))))))

(ert-deftest claude-code-ide-org-test-apply-consolidation-is-optional ()
  "With the defcustom nil, apply leaves the drawer exactly as org built it."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-consolidate-on-apply nil))
      (dolist (spec '(("09:00" "09:15") ("11:00" "11:30")))
        (should-not (claude-code-ide-org--review-apply-item
                     (list :type 'clock :id id
                           :start (date-to-time (concat "2026-08-06T" (car spec) ":00-0500"))
                           :end (date-to-time (concat "2026-08-06T" (cadr spec) ":00-0500"))
                           :agent nil :suggested nil :events nil)))))
    (let ((clocks (seq-filter (lambda (l) (string-match-p "CLOCK:" l))
                              (split-string (claude-code-ide-org-test--logbook file) "\n" t))))
      (should (equal 2 (length clocks)))
      ;; org's own order, untouched: the last-inserted line is on top,
      ;; so the drawer reads newest-first.
      (should (string-match-p "11:00" (nth 0 clocks)))
      (should (string-match-p "09:00" (nth 1 clocks))))))

(ert-deftest claude-code-ide-org-test-apply-clock-is-idempotent ()
  "Applying the same interval twice writes one CLOCK line, not two.

Regression for TODO.org :ID: 78f485a8. Without this, reprocessing an
archived queue file silently doubles recorded time -- silently being the
problem, since a duplicated CLOCK line is indistinguishable from a
legitimate one."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'clock :id id
                      :start (date-to-time "2026-08-06T09:00:00-0500")
                      :end (date-to-time "2026-08-06T09:15:00-0500")
                      :note "clarify backend schema design"
                      :agent nil :suggested nil :events nil)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let ((disk (claude-code-ide-org-test--disk-contents file)))
        (should (equal 1 (cl-count-if (lambda (l) (string-match-p "CLOCK:" l))
                                      (split-string disk "\n"))))
        ;; The annotation must not double either -- it is the other
        ;; non-idempotent write path.
        (should (equal 1 (cl-count-if
                          (lambda (l) (string-match-p "clarify backend schema design" l))
                          (split-string disk "\n"))))))))

(ert-deftest claude-code-ide-org-test-apply-clock-still-writes-distinct-intervals ()
  "Idempotency must not swallow a genuinely different interval.
Two intervals on one heading that merely share a start are two real
intervals, and both must land."
  (claude-code-ide-org-test--with-heading
    (dolist (spec '(("09:00" "09:15") ("09:00" "09:45") ("10:00" "10:05")))
      (should-not (claude-code-ide-org--review-apply-item
                   (list :type 'clock :id id
                         :start (date-to-time (concat "2026-08-06T" (car spec) ":00-0500"))
                         :end (date-to-time (concat "2026-08-06T" (cadr spec) ":00-0500"))
                         :agent nil :suggested nil :events nil))))
    (should (equal 3 (cl-count-if (lambda (l) (string-match-p "CLOCK:" l))
                                  (split-string (claude-code-ide-org-test--disk-contents file)
                                                "\n"))))))

(defun claude-code-ide-org-test--guidepost (hhmm kind)
  "Return a guidepost event plist at HHMM on 2026-08-06, of KIND."
  (list :ts (date-to-time (format "2026-08-06T%s-0500" hhmm)) :kind kind))

(defconst claude-code-ide-org-test--two-run-span
  '(("09:00:00" "resume") ("09:10:00" "pause")   ; run A, 10 min
    ("09:20:00" "resume") ("09:25:00" "pause")   ; run B, 5 min
    ("09:26:00" "resume") ("09:31:00" "pause"))  ; 60s idle: merges into B
  "Guideposts for one span whose work is 21 minutes across two runs.
The span reads 09:00--09:31, i.e. 31 minutes, which is the overcount
this whole change is about: 10 minutes of idle between the runs is the
human thinking, and the 60 seconds before the last turn is below the
floor and stays absorbed.")

(defun claude-code-ide-org-test--two-run-events ()
  (mapcar (lambda (spec)
            (claude-code-ide-org-test--guidepost (car spec) (cadr spec)))
          claude-code-ide-org-test--two-run-span))

(ert-deftest claude-code-ide-org-test-work-runs-merge-below-the-floor ()
  "Idle shorter than the floor is absorbed; idle at or above it splits.

The boundary is asserted from both sides on purpose. `Shorter than' is
the documented rule, so 120s of idle must split and 119s must not --
a test that only checked a comfortably-large gap would pass on `<=' too,
and the two disagree on exactly the value the defcustom names."
  (let ((claude-code-ide-org-span-idle-floor 120))
    ;; 60s of idle: one run spanning both turns.
    (let ((runs (claude-code-ide-org--span-work-runs
                 (list (claude-code-ide-org-test--guidepost "09:00:00" "resume")
                       (claude-code-ide-org-test--guidepost "09:05:00" "pause")
                       (claude-code-ide-org-test--guidepost "09:06:00" "resume")
                       (claude-code-ide-org-test--guidepost "09:10:00" "pause")))))
      (should (= 1 (length runs)))
      (should (equal "09:00" (format-time-string "%H:%M" (car (nth 0 runs)))))
      (should (equal "09:10" (format-time-string "%H:%M" (cdr (nth 0 runs))))))
    ;; 119s: still merged.
    (should (= 1 (length (claude-code-ide-org--span-work-runs
                          (list (claude-code-ide-org-test--guidepost "09:00:00" "resume")
                                (claude-code-ide-org-test--guidepost "09:05:00" "pause")
                                (claude-code-ide-org-test--guidepost "09:06:59" "resume")
                                (claude-code-ide-org-test--guidepost "09:10:00" "pause"))))))
    ;; Exactly 120s: split.
    (should (= 2 (length (claude-code-ide-org--span-work-runs
                          (list (claude-code-ide-org-test--guidepost "09:00:00" "resume")
                                (claude-code-ide-org-test--guidepost "09:05:00" "pause")
                                (claude-code-ide-org-test--guidepost "09:07:00" "resume")
                                (claude-code-ide-org-test--guidepost "09:10:00" "pause"))))))))

(ert-deftest claude-code-ide-org-test-work-runs-count-only-turns ()
  "Only a `resume' -> `pause' adjacency is work.

Three silences in one fixture, because an implementation that got any
one of them wrong would still satisfy the others: the idle between two
turns is not work, an unpaired `resume' -> `resume' contributes nothing
\(TODO.org :ID: 09c134c4 owns that question, not this function), and a
turn too short to render a distinct minute is *promoted to one minute*
rather than dropped (TODO.org :ID: 31c6ac39, 2026-08-24 -- it was
dropped until then). A sub-minute turn is work that happened; org's
minute precision is the only reason it cannot be shown exactly, and
recording it as 0:01 is a rounding error where discarding it is a false
statement that nothing occurred."
  (let ((claude-code-ide-org-span-idle-floor 120))
    ;; resume, resume, pause: only the second resume pairs.
    (let ((runs (claude-code-ide-org--span-work-runs
                 (list (claude-code-ide-org-test--guidepost "09:00:00" "resume")
                       (claude-code-ide-org-test--guidepost "09:04:00" "resume")
                       (claude-code-ide-org-test--guidepost "09:10:00" "pause")))))
      (should (= 1 (length runs)))
      (should (equal "09:04" (format-time-string "%H:%M" (car (nth 0 runs))))))
    ;; A span with no pause at all writes nothing.
    (should-not (claude-code-ide-org--span-work-runs
                 (list (claude-code-ide-org-test--guidepost "09:00:00" "resume")
                       (claude-code-ide-org-test--guidepost "09:04:00" "resume"))))
    ;; A sub-minute turn, isolated by more than the floor on both sides,
    ;; survives the merge and is now PROMOTED to one minute rather than
    ;; dropped: 30 seconds of work happened, and the only reason it
    ;; cannot be shown exactly is org's minute precision.
    (let ((runs (claude-code-ide-org--span-work-runs
                 (list (claude-code-ide-org-test--guidepost "09:00:00" "resume")
                       (claude-code-ide-org-test--guidepost "09:05:00" "pause")
                       (claude-code-ide-org-test--guidepost "09:10:10" "resume")
                       (claude-code-ide-org-test--guidepost "09:10:40" "pause")))))
      (should (= 2 (length runs)))
      (should (equal "09:05" (format-time-string "%H:%M" (cdr (nth 0 runs)))))
      (should (= 60 (float-time (time-subtract (cdr (nth 1 runs)) (car (nth 1 runs)))))))
    ;; 34 seconds is the case that a duration-only promotion missed:
    ;; `round' takes 34/60 to 1, so it does not read as zero, yet it
    ;; still renders [09:10]--[09:10] and would be dropped for that.
    (let ((runs (claude-code-ide-org--span-work-runs
                 (list (claude-code-ide-org-test--guidepost "09:10:03" "resume")
                       (claude-code-ide-org-test--guidepost "09:10:37" "pause")))))
      (should (= 1 (length runs)))
      (should (= 60 (float-time (time-subtract (cdr (car runs)) (car (car runs)))))))
    ;; A zero-width point is NOT promoted: nothing was observed there,
    ;; and inventing a minute from one timestamp is the class of guess
    ;; :ID: 7771fc63 retired.
    (should-not (claude-code-ide-org--span-work-runs
                 (list (claude-code-ide-org-test--guidepost "09:00:00" "resume")
                       (claude-code-ide-org-test--guidepost "09:00:00" "pause"))))))

(ert-deftest claude-code-ide-org-test-apply-writes-one-line-per-run ()
  "Apply writes a CLOCK line per run of work, not one across the span.

Regression for TODO.org :ID: 226ed53b, measured at 39.10 h recorded
against 21.59 h of turns over the post-cutover corpus. Asserted on the
DURATIONS, not the line count alone: two lines that between them still
covered 09:00--09:31 would satisfy a count-only test while recording
exactly the idle this exists to stop recording."
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-span-idle-floor 120)
           (events (claude-code-ide-org-test--two-run-events))
           (item (list :type 'clock :id id
                       :start (plist-get (car events) :ts)
                       :end (plist-get (car (last events)) :ts)
                       :note "two-run span" :agent nil :suggested t
                       :events events)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let* ((disk (claude-code-ide-org-test--disk-contents file))
             (lines (split-string disk "\n"))
             (clocks (seq-filter (lambda (l) (string-match-p "CLOCK:" l)) lines)))
        (should (= 2 (length clocks)))
        (should (string-match-p "09:00\\]--\\[2026-08-06 [A-Za-z]+ 09:10\\] =>  0:10"
                                (nth 0 clocks)))
        (should (string-match-p "09:20\\]--\\[2026-08-06 [A-Za-z]+ 09:31\\] =>  0:11"
                                (nth 1 clocks)))
        ;; Nothing spans the idle between them.
        (should-not (string-match-p "09:00\\]--\\[2026-08-06 [A-Za-z]+ 09:31" disk))
        ;; One annotation per line, at that line's own endpoints, and
        ;; each sitting directly under the CLOCK line it describes.
        ;; Adjacency is not decoration: `--consolidate-logbook-text'
        ;; sorts every drawer entry by its first timestamp, so a pair
        ;; that did not share one would be scattered by the very tidy-up
        ;; apply runs on its way out.
        (should (= 2 (cl-count-if (lambda (l) (string-match-p "^- \\[" l)) lines)))
        (should (equal
                 '("CLOCK: [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:10] =>  0:10"
                   "- [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:10] two-run span"
                   "CLOCK: [2026-08-06 Thu 09:20]--[2026-08-06 Thu 09:31] =>  0:11"
                   "- [2026-08-06 Thu 09:20]--[2026-08-06 Thu 09:31] two-run span")
                 (mapcar #'string-trim
                         (seq-filter (lambda (l)
                                       (string-match-p "\\`[ \t]*\\(CLOCK:\\|- \\[\\)" l))
                                     lines))))))))

(ert-deftest claude-code-ide-org-test-apply-writes-confirmed-endpoints-whole ()
  "A confirmed interval writes ONE line, at exactly the endpoints set.

`claude-code-ide-org-review-edit-interval' sets `:suggested' nil to mean
`a human drew these', and apply's standing claim is that it writes
exactly those endpoints. Run-splitting a confirmed interval would
substitute the reconstruction the human had just corrected -- the events
here are the same ones that split into two runs above, so an
implementation that ignored `:suggested' would visibly write two lines."
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-span-idle-floor 120)
           (events (claude-code-ide-org-test--two-run-events))
           (item (list :type 'clock :id id
                       :start (date-to-time "2026-08-06T09:02:00-0500")
                       :end (date-to-time "2026-08-06T09:29:00-0500")
                       :note "confirmed by hand" :agent nil :suggested nil
                       :events events)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let ((disk (claude-code-ide-org-test--disk-contents file)))
        (should (= 1 (cl-count-if (lambda (l) (string-match-p "CLOCK:" l))
                                  (split-string disk "\n"))))
        (should (string-match-p "09:02\\]--\\[2026-08-06 [A-Za-z]+ 09:29\\] =>  0:27" disk))))))

(ert-deftest claude-code-ide-org-test-apply-per-run-idempotency ()
  "Replaying a split span writes nothing the second time.

The idempotency key had to move with the split: `--logbook-has-interval-p'
was checked against the ITEM's endpoints, which a split span no longer
writes, so every line would have been duplicated on replay. Partial
failure makes this the normal path rather than an exotic one -- the
`unwind-protect' in the writer cancels mid-item, so the human retries."
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-span-idle-floor 120)
           (events (claude-code-ide-org-test--two-run-events))
           (item (list :type 'clock :id id
                       :start (plist-get (car events) :ts)
                       :end (plist-get (car (last events)) :ts)
                       :note "two-run span" :agent nil :suggested t
                       :events events)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let ((lines (split-string (claude-code-ide-org-test--disk-contents file) "\n")))
        (should (= 2 (cl-count-if (lambda (l) (string-match-p "CLOCK:" l)) lines)))
        (should (= 2 (cl-count-if (lambda (l) (string-match-p "^- \\[" l)) lines)))))))

(ert-deftest claude-code-ide-org-test-span-with-no-run-is-annotated-only ()
  "A span whose guideposts pair into no turn still leaves its evidence.
No CLOCK line, because no interval was observed -- but the annotation
lands, so the span does not silently vanish from the drawer."
  (claude-code-ide-org-test--with-heading
    (let* ((events (list (claude-code-ide-org-test--guidepost "09:00:00" "resume")
                         (claude-code-ide-org-test--guidepost "09:04:00" "resume")))
           (item (list :type 'clock :id id
                       :start (plist-get (car events) :ts)
                       :end (plist-get (cadr events) :ts)
                       :note "unpaired" :agent nil :suggested t :events events)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let ((disk (claude-code-ide-org-test--disk-contents file)))
        (should-not (string-match-p "CLOCK:" disk))
        (should (string-match-p "09:00\\]--\\[2026-08-06 [A-Za-z]+ 09:04\\] unpaired" disk))))))

(ert-deftest claude-code-ide-org-test-review-line-states-evidence-not-a-prediction ()
  "The review line states three observed quantities and predicts nothing.

Envelope, runs, turns. It used to say `writes 0:21 in 2\', a claim about
what apply would do that this code cannot keep: the figure is computed
before `--subtract-intervals\' runs (TODO.org :ID: 98c302e0). It also
had to name the envelope, because the displayed range reads as the
record and is not -- the median span writes about 46% of what it shows
(:ID: 44cef181) -- and to give every count a unit, since `in 2\' alone
let the two numbers look interchangeable.

An item with no backing kinds still says nothing extra."
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-span-idle-floor 120)
           (events (claude-code-ide-org-test--two-run-events))
           (split (list :type 'clock :id id
                        :start (plist-get (car events) :ts)
                        :end (plist-get (car (last events)) :ts)
                        :note "two-run span" :agent nil :suggested t
                        :events events))
           (bare (list :type 'clock :id id
                       :start (plist-get (car events) :ts)
                       :end (plist-get (car (last events)) :ts)
                       :note "no events" :agent nil :suggested t :events nil)))
      ;; 09:00--09:31 displayed, 21 minutes over two lines written.
      (should (string-match-p "09:00\\]--\\[2026-08-06 [A-Za-z]+ 09:31\\]"
                              (claude-code-ide-org--review-describe split)))
      (should (string-match-p "0:31 span, 0:21 in 2 runs, 3 turns"
                              (claude-code-ide-org--review-describe split)))
      ;; No prediction verb anywhere on the line -- that is the decision,
      ;; not an incidental wording change.
      (should-not (string-match-p "writes" (claude-code-ide-org--review-describe split)))
      (should-not (string-match-p "span," (claude-code-ide-org--review-describe bare)))
      (should-not (string-match-p
                   "span,"
                   (claude-code-ide-org--review-describe
                    (plist-put (copy-sequence split) :suggested nil)))))))

(ert-deftest claude-code-ide-org-test-no-op-span-says-why-it-is-a-no-op ()
  "An item that can only be dismissed must say which kind it is.

TODO.org :ID: 31f766ab: at org's minute precision a real 28-second turn
and a lone guidepost both render `[15:20]--[15:20]', so the human is
asked to decide about two quite different things that look identical.
Three reasons, asserted together because an implementation that
collapsed any two of them would still satisfy the others.

Measured over the corpus, per session: 4 such items in 57 spans, evenly
split between the first two kinds."
  (let ((claude-code-ide-org-span-idle-floor 120))
    ;; A real short turn no longer reads as a no-op at all: since the
    ;; one-minute floor (:ID: 31c6ac39) it yields one run of 0:01 -- and
    ;; the line reads "0:00 span, 0:01 in 1 run, 1 turn", which looks
    ;; contradictory and is not: the envelope is 11 seconds and rounds to
    ;; zero, while the floor lifts the run to a minute. That the floor is
    ;; now visible is a gain, not a wart. This used to
    ;; assert "writes nothing (11s of turns, none crossing a minute)",
    ;; and that reason is now unreachable by construction -- the branch
    ;; survives only as a guard that says so.
    (let* ((events (list (claude-code-ide-org-test--guidepost "09:00:14" "resume")
                         (claude-code-ide-org-test--guidepost "09:00:25" "pause")))
           (item (list :type 'clock :id "id-a" :suggested t :events events
                       :start (plist-get (car events) :ts)
                       :end (plist-get (cadr events) :ts))))
      (should-not (string-match-p "no runs"
                                  (claude-code-ide-org--review-written-summary item))))
    ;; The trailing in-flight span: one guidepost, start = end.
    (let* ((events (list (claude-code-ide-org-test--guidepost "09:00:14" "resume")))
           (item (list :type 'clock :id "id-a" :suggested t :events events
                       :start (plist-get (car events) :ts)
                       :end (plist-get (car events) :ts))))
      (should (equal "0:00 span, no runs, 0 turns (a single point, not an interval)"
                     (claude-code-ide-org--review-written-summary item))))
    ;; Guideposts spanning real time, but never a resume then a pause.
    (let* ((events (list (claude-code-ide-org-test--guidepost "09:00:00" "resume")
                         (claude-code-ide-org-test--guidepost "09:08:00" "resume")))
           (item (list :type 'clock :id "id-a" :suggested t :events events
                       :start (plist-get (car events) :ts)
                       :end (plist-get (cadr events) :ts))))
      (should (equal "0:08 span, no runs, 0 turns (no completed turn in it)"
                     (claude-code-ide-org--review-written-summary item))))
    ;; And a span that DOES write keeps saying so -- the reason must not
    ;; leak onto items that are not no-ops.
    (let ((item (list :type 'clock :id "id-a" :suggested t
                      :events (claude-code-ide-org-test--two-run-events)
                      :start (date-to-time "2026-08-06T09:00:00-0500")
                      :end (date-to-time "2026-08-06T09:31:00-0500"))))
      (should (equal "0:31 span, 0:21 in 2 runs, 3 turns"
                     (claude-code-ide-org--review-written-summary item))))))

(ert-deftest claude-code-ide-org-test-historical-guideposts-span-the-archive ()
  "History must include archived queues, or the oldest lines lose their
evidence.

`--queue-session-ids' calls `directory-files' non-recursively, so an
archived session is invisible to `--queue-events' even with
INCLUDE-CONSUMED. That matters precisely because archiving takes the
*oldest* sessions first: a recompute reading only live queues finds no
evidence for the oldest CLOCK lines and shrinks them toward zero, with
nothing to indicate anything went missing. Measured on the real queue,
the difference was 41 drawers against 44.

Asserted against `--queue-events' in the same fixture, so the test
states the gap rather than merely covering the fix."
  (claude-code-ide-org-test--with-queue
    (let ((archive (expand-file-name "archive" claude-code-ide-org-queue-directory)))
      (make-directory archive t)
      (claude-code-ide-org-test--queue-write
       "sess-live"
       (claude-code-ide-org-test--queue-event
        "2026-08-13T09:00:00-0500" "resume" nil nil "sess-live"))
      ;; An archived session, written straight into the subdirectory the
      ;; way `claude-code-ide-org-archive-drained-queues' leaves it.
      (with-temp-file (expand-file-name "sess-old.jsonl" archive)
        (insert (claude-code-ide-org-test--queue-event
                 "2026-08-12T09:00:00-0500" "resume" nil nil "sess-old")
                "\n"
                (claude-code-ide-org-test--queue-event
                 "2026-08-12T09:30:00-0500" "pause" nil nil "sess-old")
                "\n"))
      (let ((hist (claude-code-ide-org--queue-historical-guideposts)))
        (should (= 3 (length hist)))
        ;; Oldest first, and the archived pair is present.
        (should (equal "2026-08-12" (format-time-string "%Y-%m-%d" (plist-get (car hist) :ts))))
        (should (= 2 (length (seq-filter
                              (lambda (e) (equal "sess-old" (plist-get e :session-id)))
                              hist)))))
      ;; The path this replaced sees only the live file -- that IS the bug.
      (should (= 1 (length (claude-code-ide-org--queue-events nil t)))))))

(ert-deftest claude-code-ide-org-test-busy-intervals-unions-concurrent-turns ()
  "Overlapping turns are one stretch of busy time, not two.

TODO.org :ID: 7d739afd, stated by the user: [10:00]--[10:20] plus
[10:10]--[10:30] is 30 minutes, not 40. The depth counter gives that
directly -- 1, 2, 1, 0 -- and closes exactly once.

The same fixture pins the failure that motivated abandoning per-session
pairing (:ID: 9202b39d): pairing these four events by adjacency finds
only the inner resume->pause and reports 10 minutes, so the two methods
disagree on the same input in both directions."
  (let ((evs (list (claude-code-ide-org-test--guidepost "10:00:00" "resume")
                   (claude-code-ide-org-test--guidepost "10:10:00" "resume")
                   (claude-code-ide-org-test--guidepost "10:20:00" "pause")
                   (claude-code-ide-org-test--guidepost "10:30:00" "pause"))))
    (let ((busy (claude-code-ide-org--busy-intervals evs)))
      (should (= 1 (length busy)))
      (should (equal "10:00" (format-time-string "%H:%M" (car (car busy)))))
      (should (equal "10:30" (format-time-string "%H:%M" (cdr (car busy))))))
    ;; The method it replaced, on the identical input, loses 20 minutes.
    (should (= 1 (length (claude-code-ide-org--span-work-runs evs))))
    (should (equal "10:10" (format-time-string
                            "%H:%M" (car (car (claude-code-ide-org--span-work-runs evs))))))))

(ert-deftest claude-code-ide-org-test-busy-intervals-edge-cases ()
  "Depth clamps at zero, and an unclosed turn is bounded, never invented.

A stream opening on a `pause' is the background-job case (:ID: 9202b39d):
the matching `resume' is in the launching session's file. Without the
clamp the depth would go to -1 and the next `resume' would bring it back
to 0 without ever opening an interval, silently losing that turn."
  ;; Leading pause: clamped, and the later turn still registers.
  (let ((busy (claude-code-ide-org--busy-intervals
               (list (claude-code-ide-org-test--guidepost "10:00:00" "pause")
                     (claude-code-ide-org-test--guidepost "10:10:00" "resume")
                     (claude-code-ide-org-test--guidepost "10:20:00" "pause")))))
    (should (= 1 (length busy)))
    (should (equal "10:10" (format-time-string "%H:%M" (car (car busy))))))
  ;; Unmatched resume closes at BOUND...
  (let ((busy (claude-code-ide-org--busy-intervals
               (list (claude-code-ide-org-test--guidepost "10:00:00" "resume"))
               (date-to-time "2026-08-06T10:05:00-0500"))))
    (should (= 1 (length busy)))
    (should (equal "10:05" (format-time-string "%H:%M" (cdr (car busy))))))
  ;; ...and is dropped entirely with no bound to close it at.
  (should-not (claude-code-ide-org--busy-intervals
               (list (claude-code-ide-org-test--guidepost "10:00:00" "resume")))))

(defconst claude-code-ide-org-test--recompute-since
  (date-to-time "2026-08-06T00:00:00-0500"))

(ert-deftest claude-code-ide-org-test-recompute-splits-and-shrinks-a-line ()
  "A recorded line becomes one line per busy interval, idle removed.

The drawer here records 09:00--09:31 as 0:31 straight through, which is
what apply used to write. The guideposts say two turns totalling 21
minutes with 10 minutes of idle between them, so the line becomes two,
and each keeps a copy of the annotation at its own endpoints -- the
adjacency `--consolidate-logbook-text' sorts on."
  (let* ((guideposts (claude-code-ide-org-test--two-run-events))
         (text (concat "CLOCK: [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:31] =>  0:31\n"
                       "- [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:31] two-run span\n"))
         (new (claude-code-ide-org--recompute-logbook-text
               text guideposts claude-code-ide-org-test--recompute-since))
         (lines (split-string new "\n" t)))
    (should (equal '("CLOCK: [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:10] =>  0:10"
                     "- [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:10] two-run span"
                     "CLOCK: [2026-08-06 Thu 09:20]--[2026-08-06 Thu 09:31] =>  0:11"
                     "- [2026-08-06 Thu 09:20]--[2026-08-06 Thu 09:31] two-run span")
                   lines))
    ;; Idempotent: the rewritten windows reproduce themselves exactly.
    (should (equal new (claude-code-ide-org--recompute-logbook-text
                        new guideposts claude-code-ide-org-test--recompute-since)))))

(ert-deftest claude-code-ide-org-test-idle-floor-promotes-both-shapes-of-zero ()
  "Two different intervals would each write a line no one should read,
and neither condition catches the other -- so both must be recognised,
and since 2026-08-24 both are *promoted* rather than dropped.

50 seconds inside one minute renders `[09:00]--[09:00]' -- degenerate
endpoints -- but rounds to `=>  0:01'. 20 seconds across a minute
boundary renders `[08:14]--[08:15]' -- perfectly ordinary endpoints --
but rounds to `=>  0:00'.

Testing only the endpoints was the first version of the drop, and it
wrote nine `0:00' lines into the real org files during the 507754ba
recompute; they were caught by reading the diff, not by the suite.
Testing only the duration was the first version of the *promotion*, and
it left a 34-second run to be dropped while promoting an 11-second one.
The invariant that outlived both: whatever comes out of this function,
no interval may render as nothing (TODO.org :ID: 31c6ac39)."
  (let ((claude-code-ide-org-span-idle-floor 120)
        (fmt "[%Y-%m-%d %a %H:%M]"))
    (dolist (case (list (cons "2026-08-06T09:00:05-0500" "2026-08-06T09:00:55-0500")
                        (cons "2026-08-06T08:14:50-0500" "2026-08-06T08:15:10-0500")
                        (cons "2026-08-06T08:14:00-0500" "2026-08-06T08:15:00-0500")))
      (let ((out (claude-code-ide-org--apply-idle-floor
                  (list (cons (date-to-time (car case)) (date-to-time (cdr case)))))))
        ;; Every positive interval now survives ...
        (should (= 1 (length out)))
        ;; ... and none of them renders as nothing, which is the whole
        ;; guarantee the old drop existed to provide.
        (should-not (claude-code-ide-org--renders-as-nothing-p (car out) fmt))))
    ;; A zero-width interval is still dropped: nothing was observed, and
    ;; promoting it would invent a minute from a single timestamp.
    (should-not (claude-code-ide-org--apply-idle-floor
                 (list (let ((tm (date-to-time "2026-08-06T09:00:05-0500")))
                         (cons tm tm)))))))

(ert-deftest claude-code-ide-org-test-minimum-interval-defaults-to-no-op ()
  "Naming the write floor must not move it.

`claude-code-ide-org-span-minimum-interval\' was added to give the
second floor a name, not to change what gets written -- so at its
default every interval that survived before still survives.  100
seconds is the probe because it is shorter than the value the September
review is expected to pick (120) and longer than anything the two
rendering conditions already remove, so it can only be dropped by this
variable being non-zero by accident."
  (let ((claude-code-ide-org-span-idle-floor 120)
        (interval (list (cons (date-to-time "2026-08-06T09:00:20-0500")
                              (date-to-time "2026-08-06T09:02:00-0500")))))
    (should (= 0 claude-code-ide-org-span-minimum-interval))
    (should (= 1 (length (claude-code-ide-org--apply-idle-floor interval))))))

(ert-deftest claude-code-ide-org-test-minimum-interval-drops-short-runs ()
  "Set, the floor drops a short run -- and only a short one.

Three probes, because a filter that drops everything would pass a test
that only checked the first.  Strictly less than, matching
`claude-code-ide-org-span-idle-floor\': a run of exactly the floor
survives, so both variables read the same way at their boundary."
  (let ((claude-code-ide-org-span-idle-floor 120)
        (claude-code-ide-org-span-minimum-interval 120))
    ;; 100s: under the floor, dropped.
    (should-not (claude-code-ide-org--apply-idle-floor
                 (list (cons (date-to-time "2026-08-06T09:00:20-0500")
                             (date-to-time "2026-08-06T09:02:00-0500")))))
    ;; Exactly 120s: strictly-less means this survives.
    (should (= 1 (length (claude-code-ide-org--apply-idle-floor
                          (list (cons (date-to-time "2026-08-06T09:00:00-0500")
                                      (date-to-time "2026-08-06T09:02:00-0500")))))))
    ;; 155s: comfortably over, survives.
    (should (= 1 (length (claude-code-ide-org--apply-idle-floor
                          (list (cons (date-to-time "2026-08-06T09:00:00-0500")
                                      (date-to-time "2026-08-06T09:02:35-0500")))))))))

(ert-deftest claude-code-ide-org-test-recompute-drops-zero-keeps-annotation ()
  "A line with no busy time loses its CLOCK line and keeps its note.

`=>  0:00' claims an interval that was never observed, which this code
refuses everywhere else -- but the annotation carries the heading
attribution, which no guidepost does and which a review pass is the only
thing that ever supplied. So the evidence survives and the false
duration goes."
  (let* ((guideposts (list (claude-code-ide-org-test--guidepost "09:00:00" "pause")
                           (claude-code-ide-org-test--guidepost "09:20:00" "resume")))
         (text (concat "CLOCK: [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:20] =>  0:20\n"
                       "- [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:20] idle only\n"))
         (new (claude-code-ide-org--recompute-logbook-text
               text guideposts claude-code-ide-org-test--recompute-since)))
    (should-not (string-match-p "CLOCK:" new))
    (should (string-match-p "- \\[2026-08-06 Thu 09:00\\]--\\[2026-08-06 Thu 09:20\\] idle only" new))))

(ert-deftest claude-code-ide-org-test-recompute-leaves-what-it-cannot-verify ()
  "Two things are passed through untouched, for opposite reasons.

A line with no recoverable guideposts is left whole: absence in the
queue is not evidence the work did not happen -- a subagent's paired
clock_in/clock_out is authoritative and emits no guideposts at all.
A line before SINCE is left whole because there is no queue behind it to
recompute from. Zeroing either would be the worst available bug here:
silent, plausible, and in the direction that looks like a fix."
  (let* ((guideposts (claude-code-ide-org-test--two-run-events))
         ;; No events anywhere near it, and after SINCE.
         (orphan "CLOCK: [2026-08-06 Thu 22:00]--[2026-08-06 Thu 22:30] =>  0:30\n")
         ;; Squarely inside the guideposts' window, but before SINCE.
         (ancient "CLOCK: [2026-08-05 Wed 09:00]--[2026-08-05 Wed 09:31] =>  0:31\n"))
    (should (equal (string-trim orphan)
                   (string-trim (claude-code-ide-org--recompute-logbook-text
                                 orphan guideposts
                                 claude-code-ide-org-test--recompute-since))))
    (should (equal (string-trim ancient)
                   (string-trim (claude-code-ide-org--recompute-logbook-text
                                 ancient guideposts
                                 (date-to-time "2026-08-06T00:00:00-0500")))))))

(ert-deftest claude-code-ide-org-test-recompute-window-reaches-past-the-minute ()
  "The window runs to END + 60s, because org truncates CLOCK endpoints.

A line reading `[09:10]' can be closed by a guidepost at 09:10:30, which
a window stopping at the recorded minute would exclude.

*Asserted on whether the line survives, not on its total, and the
distinction is the whole test.*  This originally pinned the `=>' figure:
a turn of 09:00:00--09:10:50 was said to round to `0:11' where a bounded
close gave `0:10'.  That stopped discriminating on 2026-08-21, when
`claude-code-ide-org--clock-minutes' began truncating both endpoints the
way org does -- any guidepost inside the 60-second extension truncates to
the same minute as END by construction, so it can never move the total.
Verified by removing the extension: the old fixture produced a
byte-identical result either way.

What the extension still decides is *membership*, which is visible one
level up.  A lone `pause' at 09:10:30 is inside the extended window and
outside the plain one, and the two paths diverge completely: included, it
makes the span queue-known and yields no busy interval, so the CLOCK line
is dropped; excluded, `inside' is nil and the line is left whole.
Removing the extension turns the empty string back into the original
line, which no rounding coincidence can imitate."
  (let* ((guideposts (list (claude-code-ide-org-test--guidepost "09:10:30" "pause")))
         (text "CLOCK: [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:10] =>  0:10\n")
         (new (claude-code-ide-org--recompute-logbook-text
               text guideposts claude-code-ide-org-test--recompute-since)))
    (should (equal "" new))))

(ert-deftest claude-code-ide-org-test-clock-total-agrees-with-its-own-timestamps ()
  "A CLOCK line's `=>' total must equal its two printed timestamps.

The invariant `claude-code-ide-org--clock-minutes' exists to hold.  It
was broken for every interval whose seconds straddled a minute boundary:
56 of the 353 CLOCK lines standing on 2026-08-21 disagreed with their own
timestamps, 35 printing a minute less than their stamps imply and 21 a
minute more.  Nothing surfaced it, because a clocktable recomputes from
the timestamps and never reads the `=>' field -- so `org_clock_report'
quietly disagreed with the drawer a human was reading.

Both directions are probed, since rounding is only wrong on one side of
each boundary and a fix truncating just one endpoint would pass half of
this."
  ;; 149s: raw rounding says 2, the stamps [10:19]--[10:22] say 3.
  (should (= 3 (claude-code-ide-org--clock-minutes
                (date-to-time "2026-08-20T10:19:49-0500")
                (date-to-time "2026-08-20T10:22:18-0500"))))
  ;; 650s: raw rounding says 11, the stamps [09:00]--[09:10] say 10.
  (should (= 10 (claude-code-ide-org--clock-minutes
                 (date-to-time "2026-08-06T09:00:00-0500")
                 (date-to-time "2026-08-06T09:10:50-0500"))))
  ;; And the formatted line says the same thing the helper does.
  (should (string-match-p
           "10:19\\]--\\[2026-08-20 Thu 10:22\\] =>  0:03"
           (claude-code-ide-org--format-clock-line
            (date-to-time "2026-08-20T10:19:49-0500")
            (date-to-time "2026-08-20T10:22:18-0500")))))

(ert-deftest claude-code-ide-org-test-preview-matches-what-org-will-write ()
  "The run total the line reports must be what apply really writes.

Apply goes through native `org-clock-in'/`org-clock-out', so org computes
each duration from minute-truncated stamps.  The preview summed raw
seconds and rounded once, disagreeing on 25.5% of runs across the corpus
-- 11.9% low, 13.6% high.

Two runs, deliberately.  Each straddles a boundary, and summing their raw
seconds before rounding pools the remainders into a minute org never
writes, since org writes each line separately: 149s + 149s = 298s rounds
to 5, while org writes 3 + 3 = 6."
  (let* ((events (list (claude-code-ide-org-test--guidepost "10:19:49" "resume")
                       (claude-code-ide-org-test--guidepost "10:22:18" "pause")
                       (claude-code-ide-org-test--guidepost "10:30:49" "resume")
                       (claude-code-ide-org-test--guidepost "10:33:18" "pause")))
         ;; Carries :start/:end as a real item does; the envelope clause
         ;; is omitted only for a malformed one.
         (item (list :suggested t :events events
                     :start (plist-get (car events) :ts)
                     :end (plist-get (car (last events)) :ts))))
    (should (equal "0:14 span, 0:06 in 2 runs, 2 turns"
                   (claude-code-ide-org--review-written-summary item)))))


(ert-deftest claude-code-ide-org-test-pending-groups-unassigned-without-an-error ()
  "An unassigned span must not be grouped under an error message.

TODO.org :ID: 98700ea3. An unassigned span carries `:id' nil until a
human presses `a' -- routine, not a fault -- but the grouping code
resolved that id to build a title, and `--at-id' *returns* its failure
as a string rather than signalling, so `Error: no org heading found with
:ID: \"nil\"' stood where a heading title belongs.

The same shape as :ID: c2132d3f, which fixed it for the review buffer
and left this path uncovered. Asserted three ways because a `cond' that
collapsed any two of them would still satisfy the others: an unassigned
group says so, a resolvable id shows its title, and an unresolvable one
says it is unresolvable -- and none of them contains \"Error:\"."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--with-queue
      (apply #'claude-code-ide-org-test--queue-write "sess-a"
             (list (claude-code-ide-org-test--queue-event
                    "2026-08-13T09:05:00-0500" "resume" nil nil "sess-a")
                   (claude-code-ide-org-test--queue-event
                    "2026-08-13T09:10:00-0500" "pause" nil nil "sess-a")
                   ;; A real heading, so a resolvable group appears too.
                   (claude-code-ide-org-test--queue-event
                    "2026-08-13T09:20:00-0500" "todo" id "DOING" "sess-a")
                   ;; And one that resolves to nothing.
                   (claude-code-ide-org-test--queue-event
                    "2026-08-13T09:30:00-0500" "todo"
                    "00000000-dead-beef-0000-000000000000" "WAITING" "sess-a")))
      (let ((report (claude-code-ide-org-pending-updates))
            ;; `string-match-p' honours `case-fold-search', which defaults
            ;; to t. Without this the group assertion below matches the
            ;; ITEM line's "UNASSIGNED -- press `a'..." instead, and passes
            ;; whatever the group heading says -- verifying nothing. Caught
            ;; by mutating the branch away and watching the test still pass.
            (case-fold-search nil))
        ;; Anchored on the opening paren, which only the group line has.
        (should (string-match-p "\n(unassigned -- press" report))
        (should (string-match-p "Test heading" report))
        (should (string-match-p "\n(unresolvable :ID:)" report))
        ;; The whole point: no failure message rendered as a title.
        (should-not (string-match-p "Error: no org heading found" report))))))

(ert-deftest claude-code-ide-org-test-subtract-intervals-splits-and-clears ()
  "Subtraction is the union rule one level up, not a skip.

TODO.org :ID: dadc08cf. A run straddling an already-recorded interval
comes back as the two pieces outside it -- skipping the whole run would
discard real agent time outside the human's clock, which is the
undercount the union rule (:ID: 7d739afd) rejects in the other
direction."
  (let* ((run (cons (date-to-time "2026-08-06T10:00:00-0500")
                    (date-to-time "2026-08-06T11:00:00-0500")))
         (fmt (lambda (i) (concat (format-time-string "%H:%M" (car i)) "-"
                                  (format-time-string "%H:%M" (cdr i)))))
         (sub (lambda (from to)
                (mapcar fmt (claude-code-ide-org--subtract-intervals
                             (list run)
                             (list (cons (date-to-time (concat "2026-08-06T" from "-0500"))
                                         (date-to-time (concat "2026-08-06T" to "-0500")))))))))
    ;; Straddled: two pieces, not zero.
    (should (equal '("10:00-10:20" "10:40-11:00") (funcall sub "10:20:00" "10:40:00")))
    ;; Wholly covered: nothing left -- this is how a replay writes nothing.
    (should-not (funcall sub "09:00:00" "12:00:00"))
    ;; Overlapping one end: the uncovered remainder only.
    (should (equal '("10:30-11:00") (funcall sub "09:00:00" "10:30:00")))
    ;; Disjoint: untouched.
    (should (equal '("10:00-11:00") (funcall sub "12:00:00" "13:00:00")))))

(ert-deftest claude-code-ide-org-test-apply-yields-to-a-hand-clocked-interval ()
  "Apply must not double count against a CLOCK line the human wrote.

TODO.org :ID: 226ed53b's original incident: a drawer claimed 3:59 for a
session spanning 3:22, because a trigger-opened clock and a queue-derived
span covered the same period on the same heading. 2(b) made the written
lines shorter, not non-overlapping, so the overcount survived it -- which
is why re-enabling the auto-clock-in trigger waited on this.

Here the human clocked 09:00--09:30 by hand and the agent's run is
09:00--09:10, wholly inside it. Nothing new may be written, and the
drawer must still total 30 minutes rather than 40."
  (claude-code-ide-org-test--with-heading
    ;; A bare human CLOCK line, the shape :ID: 4f8500e6 describes.
    (claude-code-ide-org--at-id
     id (lambda ()
          (claude-code-ide-org--append-to-drawer
           "LOGBOOK" (claude-code-ide-org--format-clock-line
                      (date-to-time "2026-08-06T09:00:00-0500")
                      (date-to-time "2026-08-06T09:30:00-0500")))
          (save-buffer)))
    (should-not (claude-code-ide-org--review-apply-item
                 (list :type 'clock :id id
                       :start (date-to-time "2026-08-06T09:00:00-0500")
                       :end (date-to-time "2026-08-06T09:10:00-0500")
                       :note "agent run inside the human's clock"
                       :agent nil :suggested nil :events nil)))
    (let ((clocks (seq-filter
                   (lambda (l) (string-match-p "CLOCK:" l))
                   (split-string (claude-code-ide-org-test--disk-contents file) "\n"))))
      (should (= 1 (length clocks)))
      (should (string-match-p "=>  0:30" (car clocks))))))

(ert-deftest claude-code-ide-org-test-apply-tolerates-an-already-true-state ()
  "Applying a transition the heading already satisfies is success.

TODO.org :ID: cc0c17a7 was filed claiming the opposite -- that such an
event reaches apply and fails there. Probing it showed apply returns nil
and writes nothing, so the claim was wrong and the heading is corrected.

It works by omission rather than by intent, which is why this test
exists: `org-todo' on a no-op never calls `org-add-log-setup', so
`org-log-note-marker' stays nil and `--review-apply-state's note block is
skipped entirely. Nothing declares that tolerance, so nothing currently
stops a later change to the note handling from turning a harmless no-op
into a refusal -- and the event would then be stuck in the queue with no
way to satisfy it, since the state it asks for is already true.

Asserted three ways: the apply reports success, so its events are marked
consumed and it leaves the queue; the keyword is untouched; and no State
line is written, because org has no transition to record and inventing
one would date a change that never happened.

Adjacent to, and not a duplicate of,
`claude-code-ide-org-test-review-no-op-transition-writes-nothing-elsewhere':
that one guards the same no-op against writing a stale note onto a
*different* heading (:ID: 3d93021d). It never asserts that apply
*succeeds*, which is the part that decides whether the event can ever
leave the queue."
  (claude-code-ide-org-test--with-heading
    (should-not (claude-code-ide-org--review-apply-item
                 (list :type 'state :id id :ts (date-to-time "2026-08-06T09:00:00-0500")
                       :from "TODO" :to "TODO" :note "already there" :events nil)))
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker)
                            (org-get-todo-state))))
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should-not (string-match-p "State +\"TODO\" +from +\"TODO\"" disk))
      (should-not (string-match-p "already there" disk)))))

(ert-deftest claude-code-ide-org-test-drained-requires-idle-and-no-items ()
  "Both clauses of the drained predicate are load-bearing."
  (claude-code-ide-org-test--with-queue
    ;; A file with a pending todo yields an item: not drained, however old.
    (apply #'claude-code-ide-org-test--queue-write "sess-live"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "todo" "id-a" "DOING" "sess-live")))
    ;; A lone clock_out yields no item: it is not a guidepost, so no span
    ;; clusters from it, and there is no clock_in to pair it with. Note a
    ;; lone PAUSE would not do -- since 3d0487f4 that clusters into a
    ;; zero-width unassigned span, which IS an item.
    (apply #'claude-code-ide-org-test--queue-write "sess-quiet"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "clock_out" nil nil "sess-quiet")))
    (let ((claude-code-ide-org-queue-idle-seconds 0))
      (should-not (claude-code-ide-org--queue-file-drained-p "sess-live"))
      (should (claude-code-ide-org--queue-file-drained-p "sess-quiet")))
    ;; Same files, but nothing counts as idle: the quiet one is no longer
    ;; drained, because archiving it could split a live session's stream.
    (let ((claude-code-ide-org-queue-idle-seconds 86400))
      (should-not (claude-code-ide-org--queue-file-drained-p "sess-quiet")))))

(ert-deftest claude-code-ide-org-test-archive-and-restore-round-trip ()
  "Archiving moves both files and hides them from the reader; restoring
brings them back. With IGNORE-WATERMARK the sidecar stays archived."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-old"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "pause" nil nil "sess-old")))
    (claude-code-ide-org--queue-mark-applied "sess-old" '("2026-08-13T09:00:00-0500"))
    (let ((claude-code-ide-org-queue-idle-seconds 0))
      (should (equal '("sess-old")
                     (plist-get (claude-code-ide-org-archive-drained-queues) :moved))))
    ;; Invisible to the reader, and both files moved.
    (should-not (member "sess-old" (claude-code-ide-org--queue-session-ids)))
    (should-not (file-exists-p (claude-code-ide-org--queue-file "sess-old")))
    (should-not (file-exists-p (claude-code-ide-org--queue-watermark-file "sess-old")))
    ;; Restore, honouring the watermark.
    (claude-code-ide-org-restore-queue "sess-old")
    (should (member "sess-old" (claude-code-ide-org--queue-session-ids)))
    (should (file-exists-p (claude-code-ide-org--queue-watermark-file "sess-old")))
    ;; Archive again, then restore ignoring the watermark.
    (let ((claude-code-ide-org-queue-idle-seconds 0))
      (claude-code-ide-org-archive-drained-queues))
    (claude-code-ide-org-restore-queue "sess-old" t)
    (should (file-exists-p (claude-code-ide-org--queue-file "sess-old")))
    (should-not (file-exists-p (claude-code-ide-org--queue-watermark-file "sess-old")))))

(ert-deftest claude-code-ide-org-test-archive-reports-every-session-once ()
  "Every session appears in exactly one of :moved or :skipped.

Regression for a destructive-`nreverse' bug: the function reversed the
same list twice, once for the message and once for the return value, so
the message read correctly while :moved was silently truncated -- four
sessions reported as one. Found live only because :moved and :skipped
stopped summing to the number of files on disk."
  (claude-code-ide-org-test--with-queue
    ;; Three drainable, two held by a pending todo.
    (dolist (sid '("drain-1" "drain-2" "drain-3"))
      (apply #'claude-code-ide-org-test--queue-write sid
             (list (claude-code-ide-org-test--queue-event
                    "2026-08-13T09:00:00-0500" "clock_out" nil nil sid))))
    (dolist (sid '("busy-1" "busy-2"))
      (apply #'claude-code-ide-org-test--queue-write sid
             (list (claude-code-ide-org-test--queue-event
                    "2026-08-13T09:00:00-0500" "todo" "id-a" "DOING" sid))))
    (let* ((claude-code-ide-org-queue-idle-seconds 0)
           (all (claude-code-ide-org--queue-session-ids))
           (r (claude-code-ide-org-archive-drained-queues t)))
      (should (equal 5 (length all)))
      (should (equal 3 (length (plist-get r :moved))))
      (should (equal 2 (length (plist-get r :skipped))))
      ;; The partition is exact: no session lost, none double-counted.
      (should (equal (sort (copy-sequence all) #'string<)
                     (sort (append (plist-get r :moved) (plist-get r :skipped))
                           #'string<))))))

(ert-deftest claude-code-ide-org-test-archive-dry-run-moves-nothing ()
  "A dry run reports what it would move and moves nothing."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-old"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "clock_out" nil nil "sess-old")))
    (let ((claude-code-ide-org-queue-idle-seconds 0))
      (should (equal '("sess-old")
                     (plist-get (claude-code-ide-org-archive-drained-queues t) :moved))))
    (should (file-exists-p (claude-code-ide-org--queue-file "sess-old")))
    (should (member "sess-old" (claude-code-ide-org--queue-session-ids)))))

(ert-deftest claude-code-ide-org-test-activity-range-ignores-prose-examples ()
  "A CLOCK line quoted as prose in a body must not break the scan.

Found live 2026-08-13. Heading bodies in this repo quote CLOCK lines as
documentation, e.g. `: input:  CLOCK: [12:46]--[12:47] =>  0:01'. A
loose pattern captured `12:46', which `--parse-org-timestamp' rejects by
SIGNALLING -- so one documentation example aborted the scan for the
whole heading and the result read as \"never clocked\"."
  (with-temp-buffer
    (insert "* TODO Subject\n"
            ":PROPERTIES:\n:ID:       range-0001\n:END:\n"
            ":LOGBOOK:\n"
            "CLOCK: [2026-08-06 Thu 09:00]--[2026-08-06 Thu 09:30] =>  0:30\n"
            ":END:\n"
            "Prose that quotes a clock line as an example:\n"
            ": input:  CLOCK: [12:46]--[12:47] =>  0:01\n")
    (org-mode)
    (goto-char (point-min))
    (let ((range (claude-code-ide-org--heading-activity-range)))
      (should range)
      (should (equal "2026-08-06" (format-time-string "%Y-%m-%d" (car range))))
      (should (equal "09:30" (format-time-string "%H:%M" (cdr range)))))))

;;; Permission blocks (TODO.org :ID: f4e628ce) -----------------------------

(defun claude-code-ide-org-test--ev (offset kind &optional tool-use-id)
  "A queue event OFFSET seconds after a fixed base, for block tests."
  (list :kind kind
        :tool-use-id tool-use-id
        :ts (time-add (date-to-time "2026-08-11T13:55:00-0500") offset)))

(ert-deftest claude-code-ide-org-test-block-intervals-pair-by-position ()
  "Blocks pair by position, since `PermissionRequest' carries no
`tool_use_id' to pair on and prompts serialise so none is needed
(TODO.org :ID: f4e628ce, 2026-08-14)."
  (let* ((events (list (claude-code-ide-org-test--ev 0 "block_start")
                       (claude-code-ide-org-test--ev 10 "block_end")
                       (claude-code-ide-org-test--ev 30 "block_start")
                       (claude-code-ide-org-test--ev 60 "block_end")))
         (ivs (claude-code-ide-org--block-intervals events)))
    (should (= 2 (length ivs)))
    (should (= 10 (float-time (time-subtract (cdr (nth 0 ivs)) (car (nth 0 ivs))))))
    (should (= 30 (float-time (time-subtract (cdr (nth 1 ivs)) (car (nth 1 ivs))))))))

(ert-deftest claude-code-ide-org-test-block-intervals-pair-without-tool-use-id ()
  "The regression that started this: a real `PermissionRequest' has no
`tool_use_id', so events carrying nil must still pair. The previous
implementation keyed on that field and silently produced nothing, which
is exactly how the feature stayed inert through three green suites."
  (let ((ivs (claude-code-ide-org--block-intervals
              (list (claude-code-ide-org-test--ev 0 "block_start" nil)
                    (claude-code-ide-org-test--ev 345 "block_end" nil)))))
    (should (= 1 (length ivs)))
    (should (= 345 (float-time (time-subtract (cdar ivs) (caar ivs)))))))

(ert-deftest claude-code-ide-org-test-block-intervals-later-start-wins ()
  "Two starts with no end between them cannot happen while prompts
serialise, but that rests on one trial rather than a guarantee. If it
does happen the later start wins and the earlier is dropped -- losing a
block rather than inventing one, per :ID: 7771fc63."
  (let ((ivs (claude-code-ide-org--block-intervals
              (list (claude-code-ide-org-test--ev 0 "block_start")
                    (claude-code-ide-org-test--ev 10 "block_start")
                    (claude-code-ide-org-test--ev 20 "block_end")))))
    (should (= 1 (length ivs)))
    (should (= 10 (float-time (time-subtract (cdar ivs) (caar ivs)))))))

(ert-deftest claude-code-ide-org-test-block-intervals-sorts-before-pairing ()
  "Pairing is positional, so order is load-bearing: an out-of-order
fixture must be sorted rather than paired as given."
  (let ((ivs (claude-code-ide-org--block-intervals
              (list (claude-code-ide-org-test--ev 60 "block_end")
                    (claude-code-ide-org-test--ev 0 "block_start")))))
    (should (= 1 (length ivs)))
    (should (= 60 (float-time (time-subtract (cdar ivs) (caar ivs)))))))

(ert-deftest claude-code-ide-org-test-block-intervals-drop-unmatched-start ()
  "An unmatched `block_start' is dropped, never extended to the last
event. It means the session died between the prompt and the tool
finishing, and choosing an end would invent the one number nobody knows
— the class of guess :ID: 7771fc63 retired."
  (should (null (claude-code-ide-org--block-intervals
                 (list (claude-code-ide-org-test--ev 0 "block_start" "toolu_A")
                       (claude-code-ide-org-test--ev 60 "pause")))))
  ;; And an end with no start is ignored rather than pairing with
  ;; whatever came before it.
  (should (null (claude-code-ide-org--block-intervals
                 (list (claude-code-ide-org-test--ev 0 "resume")
                       (claude-code-ide-org-test--ev 60 "block_end" "toolu_A"))))))

(ert-deftest claude-code-ide-org-test-block-splits-below-the-gap-threshold ()
  "Where the block machinery actually earns its keep: a wait *shorter*
than the gap threshold.

The first version of this test used the measured 2026-08-11 case -- a
54m11s block -- and passed with the block logic disabled entirely,
because a 54-minute hole already exceeds the 1200s threshold and the
ordinary gap rule splits it unaided. A test that passes without the
feature tests nothing, and that fixture would have shipped a
non-discriminating suite for the one behaviour this task exists to add.

A 10-minute permission wait is the discriminating case: under the
threshold, so nothing else can see it, and long enough to matter. No
guidepost falls inside a block by construction -- neither Stop nor
UserPromptSubmit fires while a turn is stalled -- so the block markers
are the only evidence the wait happened at all."
  (let* ((events (list (claude-code-ide-org-test--ev 0 "resume")
                       (claude-code-ide-org-test--ev 120 "block_start" "toolu_A")
                       (claude-code-ide-org-test--ev 720 "block_end" "toolu_A")
                       (claude-code-ide-org-test--ev 900 "pause")))
         (spans (claude-code-ide-org--aggregate-guideposts events 1200)))
    (should (= 2 (length spans)))
    ;; Work up to the moment the prompt appeared.
    (should (= 120 (float-time (time-subtract (cdr (nth 0 spans))
                                              (car (nth 0 spans))))))
    ;; And from the moment it was answered.
    (should (= 180 (float-time (time-subtract (cdr (nth 1 spans))
                                              (car (nth 1 spans))))))))

(ert-deftest claude-code-ide-org-test-block-threshold-alone-would-not-split ()
  "The other half of the discrimination: the very same guideposts, with
the block events removed, cluster into ONE span. This is what pins the
feature -- if the gap rule could reach this case, the block logic would
be dead weight."
  (let ((spans (claude-code-ide-org--aggregate-guideposts
                (list (claude-code-ide-org-test--ev 0 "resume")
                      (claude-code-ide-org-test--ev 900 "pause"))
                1200)))
    (should (= 1 (length spans)))
    (should (= 900 (float-time (time-subtract (cdr (car spans))
                                              (car (car spans))))))))

(ert-deftest claude-code-ide-org-test-block-does-not-split-an-unblocked-run ()
  "Discriminator: with no block events, the same guideposts cluster into
one span exactly as before. Without this the split test would pass for a
function that split everything."
  (let ((spans (claude-code-ide-org--aggregate-guideposts
                (list (claude-code-ide-org-test--ev 0 "resume")
                      (claude-code-ide-org-test--ev 60 "pause")
                      (claude-code-ide-org-test--ev 3471 "pause"))
                1200)))
    ;; 3471s from the second to the third exceeds 1200s, so the ordinary
    ;; threshold still splits — one span of 60s and one zero-width.
    (should (= 2 (length spans)))
    (should (= 60 (float-time (time-subtract (cdr (nth 0 spans))
                                             (car (nth 0 spans))))))))

(ert-deftest claude-code-ide-org-test-block-events-survive-the-parser ()
  "The kinds must be registered: `--parse-queue-line' drops any line
whose `kind' it does not know, so an unregistered block kind would make
the whole feature silently inert."
  (let ((parsed (claude-code-ide-org--queue-parse-line
                 (json-encode '((ts . "2026-08-11T13:56:00-0500")
                                (kind . "block_start")
                                (tool_use_id . "toolu_A")
                                (id . nil)
                                (session_id . "sess-a"))))))
    (should parsed)
    (should (equal "block_start" (plist-get parsed :kind)))
    (should (equal "toolu_A" (plist-get parsed :tool-use-id)))
    ;; A block names no heading, whatever the blocked tool's input said.
    (should (null (plist-get parsed :id)))))

(ert-deftest claude-code-ide-org-test-unbracketed-guideposts-become-spans ()
  "Guideposts outside any clock_in/clock_out bracket produce review items.

Regression for TODO.org :ID: 3d0487f4. `--review-items-from-queue' used
to skip the nil-keyed group wholesale, so these timestamps sat on disk
unusable: 316 of them, 14.6 hours, against 3.6 hours actually recorded."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:20:00-0500" "pause")))
    (let* ((items (claude-code-ide-org--review-items-from-queue))
           (spans (seq-filter (lambda (i) (plist-get i :unassigned)) items)))
      (should (equal 1 (length spans)))
      (should (equal 1200 (round (float-time
                                  (time-subtract (plist-get (car spans) :end)
                                                 (plist-get (car spans) :start))))))
      ;; Both guideposts are carried, so applying consumes them.
      (should (equal 2 (length (plist-get (car spans) :events)))))))

(ert-deftest claude-code-ide-org-test-unassigned-span-suggests-active-heading ()
  "An unassigned span suggests the heading most recently set DOING.

The suggestion prefers an active state over any other: a DOING or
DOING transition asserts work is happening there in a way TODO or
DONE does not."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T08:00:00-0500" "todo" "id-old" "DONE")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T08:30:00-0500" "todo" "id-active" "DOING")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:10:00-0500" "pause")))
    (let ((span (seq-find (lambda (i) (plist-get i :unassigned))
                          (claude-code-ide-org--review-items-from-queue))))
      (should span)
      (should (equal "id-active" (plist-get span :id))))))

(ert-deftest claude-code-ide-org-test-suggestion-releases-a-finished-heading ()
  "A heading that has left DOING stops being suggested.

Without this the guess latches on the last DOING forever. Measured live
2026-08-13: three spans across eight hours all suggested a heading that
had gone CANCELLED before the earliest of them began."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T08:00:00-0500" "todo" "id-done" "DOING")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T08:30:00-0500" "todo" "id-done" "CANCELLED")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:10:00-0500" "pause")))
    (let ((span (seq-find (lambda (i) (plist-get i :unassigned))
                          (claude-code-ide-org--review-items-from-queue))))
      (should span)
      ;; Nil, not `id-done'. This assertion used to read
      ;; `(should (equal "id-done" ...))' with a comment conceding "it
      ;; may still fall back to naming that heading" -- so the test named
      ;; "releases a finished heading" in fact pinned the heading *not*
      ;; being released, and passed for months while the bug it was named
      ;; for was live. The fallback it tolerated is gone (:ID: f4e628ce's
      ;; sibling defect, fixed 2026-08-14); nobody said what was being
      ;; worked on after 08:30, so the honest answer is that nobody knows.
      (should (null (plist-get span :id))))))

(ert-deftest claude-code-ide-org-test-suggestion-not-resurrected-by-closing-another ()
  "The 2026-08-14 shape, which no test covered: after the last working
heading is closed, *closing a different heading* must not make that one
the answer either.

The fallback returned the most recent `todo' of any state, so a
`CANCELLED' on id-b -- an event that asserts work has stopped -- promoted
id-b to the suggestion and held it there. Three spans across two hours
were offered for a heading cancelled before the first of them, and the
window it covered was documentation and planning that entered no heading
at all, which is exactly when nobody has said what is being worked on."
  (let* ((base (date-to-time "2026-08-14T14:00:00-0500"))
         (events (list (list :kind "todo" :id "id-a" :state "DOING" :ts base)
                       (list :kind "todo" :id "id-a" :state "DONE"
                             :ts (time-add base 600))
                       (list :kind "todo" :id "id-b" :state "CANCELLED"
                             :ts (time-add base 1200)))))
    (should (equal "id-a" (claude-code-ide-org--review-suggest-heading
                           (time-add base 300) events)))
    (should (null (claude-code-ide-org--review-suggest-heading
                   (time-add base 900) events)))
    ;; And still nil after id-b's CANCELLED, which is the event that used
    ;; to do the resurrecting.
    (should (null (claude-code-ide-org--review-suggest-heading
                   (time-add base 1800) events)))))

(ert-deftest claude-code-ide-org-test-suggestion-prefers-the-later-active-heading ()
  "When one heading finishes and another starts, the running one wins."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T08:00:00-0500" "todo" "id-first" "DOING")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T08:30:00-0500" "todo" "id-first" "DONE")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T08:40:00-0500" "todo" "id-second" "DOING")
                 ;; A bookkeeping transition on a third heading after the
                 ;; running one started must not displace it.
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T08:50:00-0500" "todo" "id-noise" "NEXT")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:10:00-0500" "pause")))
    (let ((span (seq-find (lambda (i) (plist-get i :unassigned))
                          (claude-code-ide-org--review-items-from-queue))))
      (should span)
      (should (equal "id-second" (plist-get span :id))))))

(ert-deftest claude-code-ide-org-test-unassigned-span-suggests-nothing-when-nothing-precedes ()
  "With no todo event before it, a span carries no suggestion and cannot
be marked -- applying it could only write the interval nowhere."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:10:00-0500" "pause")
                 ;; A later todo must NOT be suggested backwards in time.
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T11:00:00-0500" "todo" "id-later" "DOING")))
    (let ((span (seq-find (lambda (i) (plist-get i :unassigned))
                          (claude-code-ide-org--review-items-from-queue))))
      (should span)
      (should-not (plist-get span :id))
      (should-not (claude-code-ide-org--review-markable-p span)))))

(ert-deftest claude-code-ide-org-test-assigned-span-is-markable ()
  "Once a span carries a heading it marks like any other item."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T08:30:00-0500" "todo" "id-active" "DOING")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:10:00-0500" "pause")))
    (let ((span (seq-find (lambda (i) (plist-get i :unassigned))
                          (claude-code-ide-org--review-items-from-queue))))
      ;; Assert the span exists before asserting anything about it: with
      ;; no span, `seq-find' yields nil and `--review-markable-p' answers
      ;; truthily about nothing, so the test would pass against code that
      ;; produces no spans at all.
      (should span)
      (should (plist-get span :id))
      (should (claude-code-ide-org--review-markable-p span)))))

(ert-deftest claude-code-ide-org-test-bracketed-guideposts-are-not-unassigned ()
  "Guideposts inside a clock_in/clock_out bracket keep their heading and
are not re-offered as unassigned -- otherwise the same time would be
proposed twice."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:00:00-0500" "clock_in" "id-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:05:00-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:15:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T09:20:00-0500" "clock_out")
                 ;; An unbracketed pair well after the bracket closes, so
                 ;; the test distinguishes "bracketed ones are excluded"
                 ;; from "no spans are produced at all" -- without this it
                 ;; passes against code that never makes spans.
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T11:00:00-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-13T11:10:00-0500" "pause")))
    (let* ((items (claude-code-ide-org--review-items-from-queue))
           (spans (seq-filter (lambda (i) (plist-get i :unassigned)) items)))
      ;; Exactly one, and it is the unbracketed one.
      (should (equal 1 (length spans)))
      (should (equal "11:00" (format-time-string "%H:%M" (plist-get (car spans) :start))))
      (should (seq-find (lambda (i) (equal (plist-get i :id) "id-a")) items)))))

(ert-deftest claude-code-ide-org-test-queue-attributes-concurrent-agents-separately ()
  "Two concurrent subagents each get their own interval, in either
completion order.

Regression for TODO.org :ID: 0d789b68. Subagents share their parent's
session_id, and `org_clock_out' names no heading, so a session-wide
`current' let them clobber each other: one agent's clock_out fell into
the nil bucket and produced NO review item, while the other paired
correctly only because the agents happened to finish LIFO."
  (dolist (order '((a b) (b a)))
    (claude-code-ide-org-test--with-queue
      (apply #'claude-code-ide-org-test--queue-write "sess-a"
             (claude-code-ide-org-test--interleaved-agent-lines
              (car order) (cadr order)))
      (let* ((items (claude-code-ide-org--review-items-from-queue))
             (clocks (seq-filter (lambda (i) (eq (plist-get i :type) 'clock)) items))
             (agent-clocks (seq-filter (lambda (i) (plist-get i :agent)) clocks)))
        ;; Both agents get an interval -- neither is lost.
        (should (equal 2 (length agent-clocks)))
        ;; And each is on its OWN heading, not the other's.
        (should (equal "id-a"
                       (plist-get (seq-find (lambda (i) (equal (plist-get i :agent) "agent-aaaa"))
                                            agent-clocks)
                                  :id)))
        (should (equal "id-b"
                       (plist-get (seq-find (lambda (i) (equal (plist-get i :agent) "agent-bbbb"))
                                            agent-clocks)
                                  :id)))))))

(ert-deftest claude-code-ide-org-test-queue-guideposts-ignore-subagent-lanes ()
  "A human pause/resume attributes to the main session's heading, not to
whatever a background subagent happened to clock in on.

Guideposts carry no agent_id -- the hook fires in the parent's turn --
so they belong to the main lane. Before per-lane tracking, a subagent's
clock_in captured every following guidepost."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-12T17:00:00-0500" "clock_in" "id-human" nil "sess-a" "human work")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-12T17:40:20-0500" "clock_in" "id-agent" nil "sess-a"
                  "agent work" "agent-bbbb" "general-purpose")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-12T17:41:00-0500" "pause" nil nil "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-12T17:42:00-0500" "resume" nil nil "sess-a")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-12T17:43:58-0500" "clock_out" nil nil "sess-a"
                  "agent done" "agent-bbbb" "general-purpose")))
    (let* ((groups (claude-code-ide-org--queue-events-by-id))
           (agent-group (cdr (assoc "id-agent" groups)))
           (human-group (cdr (assoc "id-human" groups))))
      ;; The agent's group holds only its own two clock events.
      (should (equal '("clock_in" "clock_out")
                     (mapcar (lambda (e) (plist-get e :kind)) agent-group)))
      ;; The guideposts stayed with the human's heading.
      (should (member "pause" (mapcar (lambda (e) (plist-get e :kind)) human-group)))
      (should (member "resume" (mapcar (lambda (e) (plist-get e :kind)) human-group))))))

(ert-deftest claude-code-ide-org-test-review-failed-clock-out-writes-no-interval ()
  "A failing `org-clock-out' must leave NO interval behind, not a
fabricated one.

Regression for TODO.org :ID: 803314aa. Before the `unwind-protect', a
signal from `org-clock-out' left the clock running; the next clock
item's defensive close then shut it at *now*, writing a duration nobody
observed -- measured at 9:56 for an intended 0:30, and carrying no
annotation, because this item's `--append-to-drawer' never ran. The
failed item's events are not marked applied, so writing nothing leaves
the interval pending for a later pass, which is the correct outcome."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* TODO Second heading                                              :code:\n"
                    ":PROPERTIES:\n"
                    ":ID:       test-0002\n"
                    ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let* ((items (list (list :type 'clock :id id
                              :start (date-to-time "2026-08-06T09:00:00-0500")
                              :end (date-to-time "2026-08-06T09:30:00-0500")
                              :note "its clock-out will signal"
                              :agent nil :suggested nil :events nil)
                        (list :type 'clock :id "test-0002"
                              :start (date-to-time "2026-08-06T11:00:00-0500")
                              :end (date-to-time "2026-08-06T11:15:00-0500")
                              :note "proceeds and saves"
                              :agent nil :suggested nil :events nil)))
           (real-clock-out (symbol-function 'org-clock-out))
           (calls 0)
           result)
      (cl-letf (((symbol-function 'org-clock-out)
                 (lambda (&rest args)
                   (setq calls (1+ calls))
                   (if (= calls 1)
                       (error "simulated org-clock-out failure")
                     (apply real-clock-out args)))))
        (setq result (claude-code-ide-org--review-apply items)))
      ;; The second item still applies; the first is reported failed.
      (should (equal 1 (plist-get result :applied)))
      (should (plist-get result :errors))
      (let ((disk (claude-code-ide-org-test--disk-contents file)))
        ;; Exactly one CLOCK line on disk -- the second item's. The
        ;; failed item contributes nothing at all.
        (should (equal 1 (cl-count-if (lambda (l) (string-match-p "CLOCK:" l))
                                      (split-string disk "\n"))))
        (should (string-match-p
                 "CLOCK: \\[2026-08-06 [A-Za-z]+ 11:00\\]--\\[2026-08-06 [A-Za-z]+ 11:15\\] =>  0:15"
                 disk))
        ;; And specifically no interval starting at the failed item's start.
        (should-not (string-match-p "CLOCK: \\[2026-08-06 [A-Za-z]+ 09:00\\]" disk))))))

(ert-deftest claude-code-ide-org-test-review-state-header-survives-trigger-hooks ()
  "Applying a transition that also fires `org-trigger-hook' must still
write the applied heading's own `State' header.

Reproduction attempt for TODO.org :ID: 7387f97c. The trigger hooks run a
*nested* `org-todo' (config.el:1899, :1933) at the end of the outer one.
A single-heading fixture never fires them, which is why every other
apply test passes; the real TODO.org has siblings, so they fire on
nearly every transition."
  (claude-code-ide-org-test--with-heading
    ;; Both headings must sit inside a container: since TODO.org
    ;; :ID: 62b65ad0 a top-level NEXT demotes nothing, so a top-level
    ;; fixture would no longer fire the trigger this test needs.
    (claude-code-ide-org-test--add-child
     file (concat "** NEXT Child B                                                    :code:\n"
                  ":PROPERTIES:\n:ID:       test-0002\n:END:\n"
                  "** TODO Child C                                                    :code:\n"
                  ":PROPERTIES:\n:ID:       test-0003\n:END:\n"))
    (let ((item (list :type 'state :id "test-0003"
                      :ts (date-to-time "2026-08-12T19:00:00-0500")
                      :from "TODO" :to "NEXT"
                      :note "applied while a sibling was NEXT"
                      :events nil)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let ((disk (claude-code-ide-org-test--disk-contents file)))
        ;; The demote trigger must have fired -- otherwise this test is
        ;; not exercising the condition it exists to exercise.
        (should (string-match-p "Auto-demoted" disk))
        ;; And the applied heading still gets its own native header.
        (should (string-match-p
                 "- State \"NEXT\" +from \"TODO\" +\\[2026-08-12 [A-Za-z]+ 19:00\\]"
                 disk))))))

(ert-deftest claude-code-ide-org-test-review-applies-state-with-native-header ()
  "An applied transition writes org's full native `State' header, not a
headless note.

Regression for TODO.org :ID: 7387f97c. `org-todo' only logs when its
internal `dolog' is set, which comes from `org-todo-log-states'; this
project's `#+TODO:' line carries no `(t!)' markers and `org-log-done' is
nil, so no setup ran and the header was silently omitted while the note
text still reached the drawer. Seven live transitions were written that
way on 2026-08-12 before anyone noticed, because the defect is invisible
in a rendered outline and only shows in a diff."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'state :id id
                      :ts (date-to-time "2026-08-12T19:00:00-0500")
                      :from "TODO" :to "DONE"
                      :note "shipped and verified"
                      :events nil)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (let ((logbook (claude-code-ide-org-test--logbook file)))
        ;; The header itself: keyword, from-state and timestamp all present.
        (should (string-match-p
                 "- State \"DONE\" +from \"TODO\" +\\[2026-08-12 [A-Za-z]+ 19:00\\]"
                 logbook))
        ;; The note survives as a continuation of that header, not alone.
        (should (string-match-p "\\\\\\\\\n +shipped and verified" logbook))
        ;; And it is genuinely inside the drawer.
        (should-not (string-empty-p logbook))))))

(ert-deftest claude-code-ide-org-test-review-state-header-without-note ()
  "A transition carrying no note still gets a bare `State' header.
The note is optional; the header is not."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'state :id id
                      :ts (date-to-time "2026-08-12T19:05:00-0500")
                      :from "TODO" :to "NEXT"
                      :note nil :events nil)))
      (should-not (claude-code-ide-org--review-apply-item item))
      (should (string-match-p
               "- State \"NEXT\" +from \"TODO\" +\\[2026-08-12 [A-Za-z]+ 19:05\\]"
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
        (should (string-match-p "- \\[2026-08-07 [A-Za-z]+ 12:27\\]--\\[2026-08-07 [A-Za-z]+ 12:27\\]" text))
        ;; And never active, which would publish agent activity to the
        ;; agenda -- TODO.org :ID: b8e6007a.
        (should-not (string-match-p "<2026-08-07" text))
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
writing a `State \"MAYBE\" from \"DOING\"' line that looks correct
(TODO.org :ID: f9f61c04-150b-4ee7-96c9-582cf2bda95a)."
  (claude-code-ide-org-test--with-heading
    ;; Reality has moved on to DOING; the queued event still says NEXT.
    (claude-code-ide-org-test--set-todo-for-real id "DOING")
    (let* ((before (claude-code-ide-org-test--disk-contents file))
           (item (list :type 'state :id id
                       :ts (date-to-time "2026-08-07T11:51:00-0500")
                       :from "NEXT" :to "MAYBE" :events nil))
           (result (claude-code-ide-org--review-apply-item item)))
      (should (stringp result))
      (should (string-match-p "refused stale NEXT -> MAYBE" result))
      (should (string-match-p "heading is now DOING" result))
      ;; Nothing reached the file: same keyword, no new log line.
      (should (equal "DOING" (org-with-point-at (org-id-find id 'marker)
                               (org-get-todo-state))))
      (should (equal before (claude-code-ide-org-test--disk-contents file)))
      (should-not (string-match-p "State \"MAYBE\""
                                  (claude-code-ide-org-test--disk-contents file)))
      ;; And it is visibly flagged, so a human sees it before deciding.
      (should (string-prefix-p "! " (claude-code-ide-org--review-describe item)))
      (should (string-match-p "NEXT -> MAYBE"
                              (claude-code-ide-org--review-describe item)))
      ;; Explicitly confirmed, the same item applies -- the human is the
      ;; validation step, so an override must exist and must be deliberate.
      (plist-put item :stale-confirmed t)
      (should-not (claude-code-ide-org--review-apply-item item))
      (should (equal "MAYBE" (org-with-point-at (org-id-find id 'marker)
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
                      :from nil :to "WAITING" :events nil)))
      (should-not (claude-code-ide-org--review-state-stale-p item))
      (should-not (claude-code-ide-org--review-apply-item item))
      (should (equal "WAITING" (org-with-point-at (org-id-find id 'marker)
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

(ert-deftest claude-code-ide-org-test-review-chain-applies-in-one-batch ()
  "The shape verified on the live queue 2026-08-11: 47c027d2 queued a
three-link chain whose events all carried `from: TODO', because
`org_set_todo' reads `from' off a file that nothing moves until apply
moves it. Every link must apply in one pass, and org must derive each
written `from' from reality, so the resulting history is a real chain
rather than three transitions all claiming to start at TODO."
  (claude-code-ide-org-test--with-heading
    (let* ((mk (lambda (from to at)
                 (list :type 'state :id id :from from :to to
                       :ts (date-to-time (format "2026-08-11T%s-0500" at))
                       :events nil)))
           (items (list (funcall mk "TODO" "NEXT" "20:55:00")
                        (funcall mk "TODO" "DOING" "20:59:00")
                        (funcall mk "TODO" "DONE" "21:03:00")))
           (result (claude-code-ide-org--review-apply items)))
      (should (= 3 (plist-get result :applied)))
      (should-not (plist-get result :errors))
      (should (equal "DONE" (org-with-point-at (org-id-find id 'marker)
                              (org-get-todo-state))))
      (let ((text (claude-code-ide-org-test--disk-contents file)))
        (should (string-match-p "State \"NEXT\"\\s-+from \"TODO\"" text))
        (should (string-match-p "State \"DOING\"\\s-+from \"NEXT\"" text))
        (should (string-match-p "State \"DONE\"\\s-+from \"DOING\"" text))
        ;; The whole point: no link claims to have started where the
        ;; queue said, only where reality said.
        (should-not (string-match-p "State \"DONE\"\\s-+from \"TODO\"" text))))))

(ert-deftest claude-code-ide-org-test-review-batch-still-refuses-genuine-staleness ()
  "Understanding chains must not blunt the guard. An item whose heading
moved out of band -- a hand-edit, another session -- is still refused
while a chain in the same batch applies, so the flag keeps meaning
\"something happened that this batch cannot account for\".

A third sibling exists only to keep
`claude-code-ide-org--trigger-auto-promote-sole-todo' out of the way:
with just two, moving one to WAITING leaves the other the sole TODO of its
group and org promotes it to NEXT behind the test's back, which is that
rule working correctly and would make this test assert the wrong thing."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* TODO Other heading                                               :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"
                     "* TODO Third heading                                               :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0003\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    ;; Out of band, and nothing in the batch explains it.
    (claude-code-ide-org-test--set-todo-for-real "test-0002" "WAITING")
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker)
                            (org-get-todo-state))))
    (let* ((items (list (list :type 'state :id id :from "TODO" :to "DOING"
                              :ts (date-to-time "2026-08-11T20:59:00-0500")
                              :events nil)
                        (list :type 'state :id "test-0002" :from "TODO" :to "DONE"
                              :ts (date-to-time "2026-08-11T21:00:00-0500")
                              :events nil)
                        (list :type 'state :id id :from "TODO" :to "DONE"
                              :ts (date-to-time "2026-08-11T21:03:00-0500")
                              :events nil)))
           (result (claude-code-ide-org--review-apply items)))
      ;; The two chain links land; the out-of-band one is refused.
      (should (= 2 (plist-get result :applied)))
      (should (= 1 (length (plist-get result :errors))))
      (should (string-match-p "refused stale TODO -> DONE"
                              (car (plist-get result :errors))))
      (should (equal "DONE" (org-with-point-at (org-id-find id 'marker)
                              (org-get-todo-state))))
      (should (equal "WAITING" (org-with-point-at (org-id-find "test-0002" 'marker)
                              (org-get-todo-state)))))))

(ert-deftest claude-code-ide-org-test-review-chain-does-not-render-stale ()
  "A chain must not be flagged in the buffer either. Unmarked, the
projection collapses to the file and both links read clean; marking the
first is what accounts for the second, and it must stay clean rather
than lighting up the moment its predecessor is marked. A flag that fires
on nearly every chain trains the reader to confirm without reading."
  (claude-code-ide-org-test--with-heading
    (let* ((first (list :type 'state :id id :from "TODO" :to "DOING"
                        :ts (date-to-time "2026-08-11T20:59:00-0500") :events nil))
           (second (list :type 'state :id id :from "TODO" :to "DONE"
                         :ts (date-to-time "2026-08-11T21:03:00-0500") :events nil))
           (items (list first second)))
      ;; Nothing marked.
      (claude-code-ide-org--review-projected-staleness
       items (lambda (item) (plist-get item :marked)))
      (should (string-prefix-p "  " (claude-code-ide-org--review-describe first)))
      (should (string-prefix-p "  " (claude-code-ide-org--review-describe second)))
      ;; First marked: the second is now explained by the batch, not stale.
      (plist-put first :marked t)
      (claude-code-ide-org--review-projected-staleness
       items (lambda (item) (plist-get item :marked)))
      (should (string-prefix-p "  " (claude-code-ide-org--review-describe second)))
      ;; But a transition this batch cannot account for still is.
      (let ((alien (list :type 'state :id id :from "WAITING" :to "DONE"
                         :ts (date-to-time "2026-08-11T21:05:00-0500") :events nil)))
        (claude-code-ide-org--review-projected-staleness
         (list first alien) (lambda (item) (plist-get item :marked)))
        (should (string-prefix-p "! " (claude-code-ide-org--review-describe alien)))))))

(ert-deftest claude-code-ide-org-test-queue-parses-the-from-field ()
  "The reader carries `from' through from the JSONL, and tolerates its
absence on older events."
  (let ((with-from (claude-code-ide-org--queue-parse-line
                    "{\"ts\":\"2026-08-07T11:51:00-0500\",\"kind\":\"todo\",\"id\":\"x\",\"state\":\"MAYBE\",\"from\":\"NEXT\"}"))
        (without (claude-code-ide-org--queue-parse-line
                  "{\"ts\":\"2026-08-07T11:51:00-0500\",\"kind\":\"todo\",\"id\":\"x\",\"state\":\"MAYBE\"}")))
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
  ;; Both halves bind the trigger ON explicitly rather than leaning on
  ;; the default (`claude-code-ide-org-auto-clock-in-on-doing', t today,
  ;; nil for the day between 2026-08-18 and 2026-08-19). A guard against
  ;; a trigger that never fires would assert nothing, so the binding pins
  ;; the guard under the setting that actually exercises it -- and keeps
  ;; the test honest if the default is ever reversed again.
  ;;
  ;; Without the guard: a stray clock at now.
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-auto-clock-in-on-doing t)
          (ts (date-to-time "2026-08-06T09:00:00-0500")))
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
   (let ((claude-code-ide-org-auto-clock-in-on-doing t))
    (should-not (claude-code-ide-org--review-apply-item
                 (list :type 'state :id id
                       :ts (date-to-time "2026-08-06T09:00:00-0500")
                       :to "DOING" :note "this note must survive" :events nil)))
    (should-not (org-clocking-p))
    (let ((text (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "this note must survive" text))
      (should-not (string-match-p "CLOCK:" text))))))

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
    (claude-code-ide-org-test--clock-in-for-real id)
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

(defmacro claude-code-ide-org-test--with-attention-target (&rest body)
  "Run BODY with `file' bound to an org file holding the meta-work category,
and the review-attention machinery pointed at it."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "ccio-attn" t)))
          (file (expand-file-name "TODO.org" dir))
          (org-id-locations-file (expand-file-name ".org-id-locations" dir))
          (org-id-locations (make-hash-table :test 'equal))
          (org-id-files nil)
          (org-clock-persist nil)
          (org-clock-history nil)
          (claude-code-ide-org-capture-file file)
          (claude-code-ide-org--review-attention-marker nil))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "#+TODO: TODO | DONE\n\n* Review and planning\n"
                     ":PROPERTIES:\n:DATE_TREE: t\n:END:\n\n"))
           ,@body)
       (when (org-clocking-p) (ignore-errors (org-clock-out)))
       (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-review-attention-clocks-natively ()
  "The pass is clocked against its own heading, not the queue.

TODO.org :ID: 961f15b6.  Human attention and agent activity are
different quantities; the queue exists for concurrent agent sessions,
and a human inside an interactive Emacs command has none of those
constraints.  So this writes org's own clock directly, and the heading
is created on first use under the meta-work category."
  (claude-code-ide-org-test--with-attention-target
    (should-not (claude-code-ide-org--review-attention-target))
    (should (claude-code-ide-org-review-attention-start))
    (should claude-code-ide-org--review-attention-marker)
    (should (org-clocking-p))
    ;; Second call inside the same pass does not open a second clock.
    (should-not (claude-code-ide-org-review-attention-start))
    (should (claude-code-ide-org-review-attention-stop "done thinking"))
    (should-not (org-clocking-p))
    (should-not claude-code-ide-org--review-attention-marker)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "^\\*\\* Review attention$" disk))
      ;; A real CLOCK line, and -- measured, not assumed -- inactive,
      ;; because org-clock-in cannot write anything else.
      (should (string-match-p "CLOCK: \\[[0-9]" disk))
      ;; The annotation beside it IS active, which is the half that can
      ;; be and the half the agenda absorbs.
      (should (string-match-p "^- <[0-9][^>]*>--<[0-9][^>]*> done thinking$" disk)))))

(ert-deftest claude-code-ide-org-test-review-attention-leaves-the-category-intact ()
  "Creating the heading must not disturb the category's own drawer.

The regression that matters, and it is not hypothetical: the first
version inserted at headline+1, which is the category's `:PROPERTIES:'
line, wedging the new heading between the category and its drawer so
that it *inherited* `:DATE_TREE:' and `:ARCHIVE:'.  On the real file
that cost the category its archive routing and made
`org-datetree-find-date-create' build a second datetree nested inside
the new heading -- eleven lint errors, on the first real invocation.

Asserted on the category's properties rather than on the heading's
position, because position is what was wrong and inheritance is what it
broke."
  (claude-code-ide-org-test--with-attention-target
    (claude-code-ide-org-review-attention-start)
    (claude-code-ide-org-review-attention-stop)
    ;; Asserted on the raw text of each drawer, because what broke was
    ;; *ownership* -- which drawer the properties physically sit in.
    ;; `org-entry-get' with inheritance is the wrong instrument here: a
    ;; child of a `:DATE_TREE:' category inherits it legitimately, so
    ;; that check reports "t" whether the file is sound or wrecked.
    (let* ((disk (claude-code-ide-org-test--disk-contents file))
           (cat (substring disk (string-match "^\\* Review and planning$" disk)))
           (cat-head (substring cat 0 (string-match "^\\*\\* " cat)))
           (attn (substring disk (string-match "^\\*\\* Review attention$" disk))))
      ;; The category kept its own structural properties...
      (should (string-match-p ":DATE_TREE: t" cat-head))
      ;; ...and they are NOT in the attention heading's drawer.
      (should-not (string-match-p ":DATE_TREE:" attn))
      (should-not (string-match-p ":ARCHIVE:" attn))
      (should (string-match-p ":ID: " attn)))))

(ert-deftest claude-code-ide-org-test-review-attention-stops-on-bury ()
  "Burying the review buffer ends the pass -- `q' never kills it.

This is the case a naive `kill-buffer-hook' implementation misses
entirely: `q' is `special-mode's `quit-window', which *buries*, so the
buffer stays alive and the clock would run until the buffer was next
killed explicitly, which in practice is never.  The failure would
present as a clock running all night."
  (claude-code-ide-org-test--with-attention-target
    (claude-code-ide-org-review-attention-start)
    (should (org-clocking-p))
    (with-temp-buffer
      (claude-code-ide-org-review-mode)
      ;; Call the advice's trigger the way `q' would, from a buffer in
      ;; the review mode.
      (claude-code-ide-org--review-attention-on-quit))
    (should-not (org-clocking-p))
    (should (string-match-p "buffer buried"
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-review-attention-ignores-other-buffers ()
  "Quitting any other `special-mode' buffer must not stop the clock.

The advice is on `quit-window', which every such buffer uses, so
without the mode guard reading `M-x describe-key' mid-pass would end
the pass."
  (claude-code-ide-org-test--with-attention-target
    (claude-code-ide-org-review-attention-start)
    (should (org-clocking-p))
    (with-temp-buffer
      (special-mode)
      (claude-code-ide-org--review-attention-on-quit))
    (should (org-clocking-p))
    (claude-code-ide-org-review-attention-stop)))

(ert-deftest claude-code-ide-org-test-review-attention-can-be-disabled ()
  "Setting the heading to nil disables the whole mechanism."
  (claude-code-ide-org-test--with-attention-target
    (let ((claude-code-ide-org-review-attention-heading nil))
      (should-not (claude-code-ide-org-review-attention-start))
      (should-not (org-clocking-p)))))

(ert-deftest claude-code-ide-org-test-review-apply-reports-unresolvable-id ()
  "A bad :ID: is reported, not thrown, and does not count as applied."
  (claude-code-ide-org-test--with-heading
    (let ((result (claude-code-ide-org--review-apply
                   (list (list :type 'state :id "no-such-id"
                               :ts (current-time) :to "DOING" :events nil)))))
      (should (= 0 (plist-get result :applied)))
      (should (= 1 (length (plist-get result :errors))))
      (should (string-match-p "\\`Error:" (car (plist-get result :errors)))))))

(ert-deftest claude-code-ide-org-test-review-read-only-buffers-are-detected ()
  "The read-only pre-flight names the buffer apply would write to --
resolved by :ID: like apply itself, so an open-but-irrelevant buffer and
an :ID: that resolves to nothing both contribute nothing."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'state :id id :ts (current-time) :to "DOING")))
      (should-not (claude-code-ide-org--review-read-only-buffers (list item)))
      (with-current-buffer (get-file-buffer file) (read-only-mode 1))
      (should (equal (list (get-file-buffer file))
                     (claude-code-ide-org--review-read-only-buffers (list item))))
      ;; Two items on the same heading are one buffer, not two prompts.
      (should (= 1 (length (claude-code-ide-org--review-read-only-buffers
                            (list item item)))))
      (should-not (claude-code-ide-org--review-read-only-buffers
                   (list (list :type 'state :id "no-such-id"))))
      (with-current-buffer (get-file-buffer file) (read-only-mode -1)))))

(ert-deftest claude-code-ide-org-test-review-ensure-writable-honors-the-answer ()
  "Yes clears read-only; no signals before anything is applied and leaves
the buffer read-only, so the marks it protects are still there to keep."
  (claude-code-ide-org-test--with-heading
    (let ((items (list (list :type 'state :id id :ts (current-time) :to "DOING"))))
      (with-current-buffer (get-file-buffer file) (read-only-mode 1))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (should-error (claude-code-ide-org--review-ensure-writable items)
                      :type 'user-error))
      (should (buffer-local-value 'buffer-read-only (get-file-buffer file)))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (claude-code-ide-org--review-ensure-writable items))
      (should-not (buffer-local-value 'buffer-read-only (get-file-buffer file)))
      ;; Nothing to ask about is not a prompt with no answer.
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "Should not have been asked"))))
        (claude-code-ide-org--review-ensure-writable items)))))

(ert-deftest claude-code-ide-org-test-review-apply-keeps-marks-when-read-only-declined ()
  "Declining the read-only offer applies nothing and keeps every
decision: the mark, and the stale confirmation that took a prompt to
get.  Before this check each item failed separately with
`buffer-read-only' and the follow-up refresh discarded the lot."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'state :id id :ts (current-time) :to "DOING"
                      :from "NEXT" :marked t :stale-confirmed t :events nil)))
      (with-current-buffer (get-file-buffer file) (read-only-mode 1))
      (unwind-protect
          (with-current-buffer (get-buffer-create "*org-review-test*")
            (claude-code-ide-org-review-mode)
            (setq claude-code-ide-org--review-items (list item))
            (claude-code-ide-org--review-render)
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
              (should-error (claude-code-ide-org-review-apply) :type 'user-error))
            (should (equal (list item) claude-code-ide-org--review-items))
            (should (plist-get (car claude-code-ide-org--review-items) :marked))
            (should (plist-get (car claude-code-ide-org--review-items)
                               :stale-confirmed))
            ;; And the file is untouched: the heading still reads TODO
            ;; (the #+TODO: line mentions DOING, so match the heading).
            (should (string-match-p
                     "^\\* TODO Test heading"
                     (claude-code-ide-org-test--disk-contents file))))
        (kill-buffer "*org-review-test*")
        (with-current-buffer (get-file-buffer file) (read-only-mode -1))))))

(ert-deftest claude-code-ide-org-test-pending-updates-summarizes-proposals ()
  "The read-only counterpart to the review command: it must report the
same items, grouped by heading, without applying anything."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--with-queue
      (let ((before (claude-code-ide-org-test--disk-contents file)))
        (apply #'claude-code-ide-org-test--queue-write "sess-a"
               (list (claude-code-ide-org-test--queue-event
                      "2026-08-07T09:00:00-0500" "todo" id "DOING" nil "start it")))
        (let ((out (claude-code-ide-org-pending-updates)))
          (should (string-match-p "1 pending item" out))
          (should (string-match-p "1 heading" out))
          (should (string-match-p "Test heading" out))
          (should (string-match-p "DOING" out))
          (should (string-match-p "start it" out))
          ;; Read-only: the file is untouched and the item is still pending.
          (should (equal before (claude-code-ide-org-test--disk-contents file)))
          (should (= 1 (length (claude-code-ide-org--review-items-from-queue)))))))))

(ert-deftest claude-code-ide-org-test-pending-updates-distinguishes-items-from-events ()
  "Queue lines and proposals are different quantities, and conflating
them would report a permanent backlog that does not exist: clock and
guidepost events are attribution scaffolding that nothing ever consumes."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--with-queue
      ;; A clock_in with no pairing and no guideposts yields no item.
      (claude-code-ide-org-test--queue-write
       "sess-a" (claude-code-ide-org-test--queue-event
                 "2026-08-07T09:00:00-0500" "clock_in" id))
      (should (= 0 (length (claude-code-ide-org--review-items-from-queue))))
      (let ((out (claude-code-ide-org-pending-updates)))
        (should (string-match-p "Nothing pending" out))
        ;; ...but it says so without pretending the queue is empty.
        (should (string-match-p "1 queue event" out))
        (should (string-match-p "not a backlog" out))))))

(ert-deftest claude-code-ide-org-test-pending-updates-scopes-and-never-signals ()
  "SESSION-ID narrows the report, and the tool returns an error string
rather than signalling -- every other tool here holds that contract, and
an MCP call that throws is worse than one that explains."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--with-queue
      (claude-code-ide-org-test--queue-write
       "sess-a" (claude-code-ide-org-test--queue-event
                 "2026-08-07T09:00:00-0500" "todo" id "DOING" "sess-a" "in a"))
      (claude-code-ide-org-test--queue-write
       "sess-b" (claude-code-ide-org-test--queue-event
                 "2026-08-07T09:05:00-0500" "todo" id "WAITING" "sess-b" "in b"))
      (should (string-match-p "in a" (claude-code-ide-org-pending-updates "sess-a")))
      (should-not (string-match-p "in b" (claude-code-ide-org-pending-updates "sess-a")))
      ;; An empty string means "no scope", not a session literally named "".
      (should (string-match-p "2 pending item" (claude-code-ide-org-pending-updates "")))
      ;; A failure inside is reported, not thrown.
      (cl-letf (((symbol-function 'claude-code-ide-org--review-items-from-queue)
                 (lambda (&rest _) (error "Boom"))))
        (let ((out (claude-code-ide-org-pending-updates)))
          (should (string-prefix-p "Error: " out)))))))

(defmacro claude-code-ide-org-test--with-review-buffer (items &rest body)
  "Render ITEMS in a scratch review buffer and run BODY there."
  (declare (indent 1))
  `(unwind-protect
       (with-current-buffer (get-buffer-create "*org-review-test*")
         (claude-code-ide-org-review-mode)
         (setq claude-code-ide-org--review-items ,items)
         (claude-code-ide-org--review-render)
         ,@body)
     (kill-buffer "*org-review-test*")))

(defun claude-code-ide-org-test--goto-nth-item (n)
  "Put point on the Nth (0-based) item line of a review buffer."
  (goto-char (point-min))
  (let ((seen -1))
    (while (and (not (eobp))
                (progn (when (claude-code-ide-org--review-item-at-point)
                         (setq seen (1+ seen)))
                       (< seen n)))
      (forward-line 1))))

(ert-deftest claude-code-ide-org-test-review-refusal-names-what-the-line-is ()
  "A refusal must distinguish the four ways a line can carry no item.

\"No review item on this line\" is true of a group heading, an evidence
line, the key legend and a blank line alike -- four situations with four
different next moves. The buffer already tells them apart to draw them,
and threw that away on the way out, which is the shape TODO.org
:ID: 6cc71c36 names."
  (claude-code-ide-org-test--with-review-buffer
      (list (list :type 'state :id "test-0001" :from "TODO" :to "DOING"
                  :ts (date-to-time "2026-08-31T09:00:00-0500") :events nil))
    ;; The group heading sits directly above the first item line.
    (claude-code-ide-org-test--goto-nth-item 0)
    (forward-line -1)
    (should-not (claude-code-ide-org--review-item-at-point))
    (should (string-match-p "\\`That is a heading"
                            (claude-code-ide-org--review-no-item-message)))
    ;; A blank line is a different answer, not the same one.
    (goto-char (point-min))
    (forward-line 2)
    (should (string-match-p "\\`Blank line"
                            (claude-code-ide-org--review-no-item-message)))))

(ert-deftest claude-code-ide-org-test-review-wrong-type-refusal-names-the-type ()
  "Refusing `e' or `a' must say what the item IS, not only what it isn't.
The plist carries the type; the message dropped it."
  (claude-code-ide-org-test--with-review-buffer
      (list (list :type 'state :id "test-0001" :from "TODO" :to "DOING"
                  :ts (date-to-time "2026-08-31T09:00:00-0500") :events nil))
    (claude-code-ide-org-test--goto-nth-item 0)
    (dolist (probe (list #'claude-code-ide-org-review-edit-interval
                         #'claude-code-ide-org-review-assign))
      (let ((msg (condition-case err (progn (funcall probe) nil)
                   (user-error (error-message-string err)))))
        (should msg)
        (should (string-match-p "this is a state item" msg))))))

(ert-deftest claude-code-ide-org-test-review-apply-with-nothing-marked-says-how-many-pend ()
  "\"Nothing marked\" is the same sentence whether the buffer is empty or
full, and the two want opposite next moves. The count is already known."
  ;; A *clock* item: state items arrive auto-marked since :ID: b6e229c7,
  ;; so they cannot demonstrate an unmarked buffer. A span is not
  ;; auto-marked, deliberately -- it is not mechanical.
  (claude-code-ide-org-test--with-review-buffer
      (list (list :type 'clock :id "test-0001"
                  :start (date-to-time "2026-08-31T09:00:00-0500")
                  :end (date-to-time "2026-08-31T09:15:00-0500")
                  :suggested t :agent nil :events nil))
    (let ((msg (condition-case err
                   (progn (claude-code-ide-org-review-apply) nil)
                 (user-error (error-message-string err)))))
      (should msg)
      (should (string-match-p "1 item(s) are pending" msg))))
  (claude-code-ide-org-test--with-review-buffer nil
    (let ((msg (condition-case err
                   (progn (claude-code-ide-org-review-apply) nil)
                 (user-error (error-message-string err)))))
      (should msg)
      (should (string-match-p "Nothing pending" msg)))))

(defmacro claude-code-ide-org-test--with-slice-window (&rest body)
  "A slice created mid-window, one member and two non-members closed in it.
One further heading is closed *before* the window opens, so a test can
tell a window bound from a blanket scan."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "ccio-slicewin" t)))
          (file (expand-file-name "TODO.org" dir))
          (claude-code-ide-org-query-files (list file))
          (org-id-locations-file (expand-file-name ".org-id-locations" dir))
          (org-id-locations (make-hash-table :test 'equal))
          (org-id-files nil))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert
              "#+TODO: TODO NEXT DOING | DONE CANCELLED\n"
              "* TODO [1/1] A slice\n:PROPERTIES:\n"
              ":ID:       slice-001\n:KIND:     slice\n"
              ":CREATED:  [2026-08-20 Thu 09:00]\n:END:\n"
              ;; A slice with no CLOCK anywhere has not been worked, and
              ;; `--slice-incidental-ids' gives it no window at all
              ;; (TODO.org :ID: 42ba0a80). These tests are about a slice
              ;; that *was* worked, so it carries one, opening when it
              ;; was created -- which leaves every window bound below
              ;; exactly where it was.
              ":LOGBOOK:\n"
              "CLOCK: [2026-08-20 Thu 09:00]--[2026-08-20 Thu 09:30] =>  0:30\n"
              ":END:\n\n"
              "- [X] [[id:member-01][member-01]] DONE A planned member\n\n"
              "* DONE A planned member\nCLOSED: [2026-08-21 Fri 10:00]\n"
              ":PROPERTIES:\n:ID:       member-01\n:END:\n"
              "* DONE Incidental one\nCLOSED: [2026-08-21 Fri 11:00]\n"
              ":PROPERTIES:\n:ID:       incid-001\n:END:\n"
              "* DONE Incidental two\nCLOSED: [2026-08-22 Sat 12:00]\n"
              ":PROPERTIES:\n:ID:       incid-002\n:END:\n"
              "* DONE Closed before the slice existed\nCLOSED: [2026-08-19 Wed 08:00]\n"
              ":PROPERTIES:\n:ID:       before-01\n:END:\n"))
           ,@body)
       (let ((buf (get-file-buffer file)))
         (when buf (with-current-buffer buf (set-buffer-modified-p nil))
               (kill-buffer buf)))
       (delete-directory dir t))))

(defun claude-code-ide-org-test--slice-body (file)
  "The slice heading's own body text in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (goto-char (point-min))
    (re-search-forward "^\\* TODO .*A slice")
    (buffer-substring-no-properties
     (line-beginning-position)
     (save-excursion (outline-next-heading) (point)))))

(ert-deftest claude-code-ide-org-test-slice-renders-an-incidental-section ()
  "The incidental list is generated below the members, with cookies.

Cookies kept on incidental items and the denominator grows: `[n/m]'
says what closed between :CREATED: and :CLOSED:, a claim about a bounded
window rather than about plan fidelity (TODO.org :ID: 0086614a)."
  (claude-code-ide-org-test--with-slice-window
    (claude-code-ide-org-refresh-slice "slice-001")
    (let ((body (claude-code-ide-org-test--slice-body file)))
      (should (string-match-p "^Incidental:$" body))
      ;; `--short-id' truncates to eight characters -- meaningful for a
      ;; real UUID, and it clips this fixture's nine-character ids.
      (should (string-match-p "\\[X\\] \\[\\[id:incid-001\\]\\[incid-00\\]\\] DONE Incidental one" body))
      (should (string-match-p "\\[X\\] \\[\\[id:incid-002\\]\\[incid-00\\]\\] DONE Incidental two" body))
      ;; The planned member is untouched and still above the lead.
      (should (< (string-match "A planned member" body)
                 (string-match "Incidental:" body)))
      ;; Closed before the window opened: absent.
      (should-not (string-match-p "before-01" body))
      ;; Denominator grew to cover all three checkboxes.
      (should (string-match-p "\\[3/3\\]" body)))))

(ert-deftest claude-code-ide-org-test-cancelled-incidental-gets-no-checkbox ()
  "A CANCELLED incidental must render without a box, as a member does.

Caught on the first live run. Defaulting to `[ ]' is wrong twice over:
an unchecked box inflates the denominator forever, and it reads as a
live cookie -- so `--slice-blocker-ids' pulls the incidental into the
:BLOCKER:, which is exactly the failure TODO.org :ID: 0086614a feared,
arriving through CANCELLED rather than DONE."
  (claude-code-ide-org-test--with-slice-window
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (re-search-forward "^\\* DONE Incidental two")
      (org-back-to-heading t)
      (org-todo "CANCELLED")
      (save-buffer))
    (claude-code-ide-org-refresh-slice "slice-001")
    (let ((body (claude-code-ide-org-test--slice-body file)))
      (should (string-match-p "- \\[\\[id:incid-002" body))
      (should-not (string-match-p "\\[ \\] \\[\\[id:incid-002" body))
      ;; Denominator counts only the two that carry cookies.
      (should (string-match-p "\\[2/2\\]" body))
      ;; And it stays out of the blocker.
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-min))
        (re-search-forward "^\\* TODO .*A slice")
        (should-not (string-match-p
                     "incid-002" (or (org-entry-get nil "BLOCKER") "")))))))

(ert-deftest claude-code-ide-org-test-slice-incidental-section-is-regenerated-not-appended ()
  "Refreshing twice must not stack two sections, since the list is derived."
  (claude-code-ide-org-test--with-slice-window
    (claude-code-ide-org-refresh-slice "slice-001")
    (claude-code-ide-org-refresh-slice "slice-001")
    (let* ((body (claude-code-ide-org-test--slice-body file))
           (n 0) (pos 0))
      (while (string-match "^Incidental:$" body pos)
        (setq n (1+ n) pos (match-end 0)))
      (should (= 1 n))
      ;; And exactly one line per incidental, not two.
      (setq n 0 pos 0)
      (while (string-match "incid-001" body pos)
        (setq n (1+ n) pos (match-end 0)))
      (should (= 1 n)))))

(ert-deftest claude-code-ide-org-test-slice-incidental-rewrite-spares-trailing-prose ()
  "The region is bounded: prose written below the list survives a refresh.

This is the assertion that matters most here. A body-region rewrite is
the class of edit this repo has two corruptions on record from, which is
why `org_wrap_plan' and `org_divide' exist as tools rather than as
hand-rolled edits."
  (claude-code-ide-org-test--with-slice-window
    (claude-code-ide-org-refresh-slice "slice-001")
    ;; Add prose after the generated list, then refresh again.
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO .*A slice")
      (goto-char (save-excursion (outline-next-heading) (point)))
      (forward-line -1)
      (insert "\nA sentence a human wrote below the list.\n")
      (save-buffer))
    (claude-code-ide-org-refresh-slice "slice-001")
    (let ((body (claude-code-ide-org-test--slice-body file)))
      (should (string-match-p "A sentence a human wrote below the list." body))
      ;; And the list is still there, once.
      (should (string-match-p "^Incidental:$" body))
      (should (string-match-p "incid-001" body)))))

(ert-deftest claude-code-ide-org-test-slice-incidental-rewrite-spares-a-trailing-list ()
  "A LIST written below the section survives too, not only prose.

The sibling test above passes on a bare bullet bound, because a sentence
is not a list item.  This is the case that bound got wrong: the section
is written at the END of the slice\'s body, so a hand-written list lands
directly beneath it and inside the region -- and the refresh that
deleted it runs unattended, as `claude-code-ide-org--review-settle-slices\'
after every apply.  Nobody would have been present to see it go."
  (claude-code-ide-org-test--with-slice-window
    (claude-code-ide-org-refresh-slice "slice-001")
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO .*A slice")
      (goto-char (save-excursion (outline-next-heading) (point)))
      (forward-line -1)
      (insert "\n- see also [[id:elsewhere-9][elsewhere]]\n- and a second bullet\n")
      (save-buffer))
    (claude-code-ide-org-refresh-slice "slice-001")
    (let ((body (claude-code-ide-org-test--slice-body file)))
      (should (string-match-p "see also \\[\\[id:elsewhere-9\\]" body))
      (should (string-match-p "and a second bullet" body))
      ;; The generated section is still correct and singular.
      (should (string-match-p "^Incidental:$" body))
      (should (string-match-p "incid-001" body)))))

(ert-deftest claude-code-ide-org-test-slice-incidental-drop-spares-a-trailing-list ()
  "Removing the section when the window empties must not take the list with it.

The delete-only branch uses the same bound, so it had the same defect --
and worse, since it leaves nothing behind to make the loss visible."
  (claude-code-ide-org-test--with-slice-window
    (claude-code-ide-org-refresh-slice "slice-001")
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO .*A slice")
      (goto-char (save-excursion (outline-next-heading) (point)))
      (forward-line -1)
      (insert "\n- a bullet the human keeps\n")
      ;; Narrow the window so the section is dropped rather than rewritten.
      (org-back-to-heading t)
      (org-entry-put nil "CREATED" "[2026-08-25 Mon 09:00]")
      (save-buffer))
    (claude-code-ide-org-refresh-slice "slice-001")
    (let ((body (claude-code-ide-org-test--slice-body file)))
      (should-not (string-match-p "^Incidental:$" body))
      (should (string-match-p "a bullet the human keeps" body)))))

(ert-deftest claude-code-ide-org-test-slice-with-no-incidentals-writes-no-lead ()
  "An empty `Incidental:' lead states nothing and must not be written.
And an existing one is removed when the window empties, or it would be
regenerated forever."
  (claude-code-ide-org-test--with-slice-window
    ;; Narrow the window to before anything closed.
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO .*A slice")
      (org-back-to-heading t)
      (org-entry-put nil "CREATED" "[2026-08-25 Mon 09:00]")
      (save-buffer))
    (claude-code-ide-org-refresh-slice "slice-001")
    (should-not (string-match-p "^Incidental:$"
                                (claude-code-ide-org-test--slice-body file)))))

(defmacro claude-code-ide-org-test--with-forgotten-fixture (&rest body)
  "A git repo with an open slice naming one member, and a second heading."
  (declare (indent 0))
  `(claude-code-ide-org-test--with-git-repo
     (with-temp-file org
       (insert
        "#+TODO: TODO NEXT DOING | DONE CANCELLED\n"
        "* TODO [0/1] A slice\n:PROPERTIES:\n"
        ":ID:       aaaaaaaa-0000-0000-0000-000000000000\n"
        ":KIND:     slice\n:CREATED:  [2026-08-01 Sat 09:00]\n:END:\n\n"
        "- [ ] [[id:bbbbbbbb-0000-0000-0000-000000000000][bbbbbbbb]] TODO A member\n\n"
        "* TODO A member\n:PROPERTIES:\n"
        ":ID:       bbbbbbbb-0000-0000-0000-000000000000\n:END:\n"
        "* TODO Not in the slice\n:PROPERTIES:\n"
        ":ID:       cccccccc-0000-0000-0000-000000000000\n:END:\n"))
     (claude-code-ide-org-test--git-commit dir "seed" "2026-08-01T09:00:00-0500")
     ,@body))

(defmacro claude-code-ide-org-test--with-unsorted-file (&rest body)
  "A file whose level-1 headings are out of :CREATED: order, plus an anchor.
The `#+' header lines matter: without them point cannot sit before the
first heading and `org-sort-entries' signals \"Nothing to sort\"."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "ccio-sort" t)))
          (file (expand-file-name "TODO.org" dir))
          (claude-code-ide-org-capture-file file))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "#+TITLE: t\n#+TODO: TODO | DONE\n\n"
                     "* TODO Oldest\n:PROPERTIES:\n:ID: s-1\n"
                     ":CREATED:  [2026-08-01 Sat 09:00]\n:END:\n"
                     "* TODO Newest\n:PROPERTIES:\n:ID: s-3\n"
                     ":CREATED:  [2026-08-20 Thu 09:00]\n:END:\n"
                     "* Review and planning\n:PROPERTIES:\n:ID: s-anchor\n"
                     ":DATE_TREE: t\n:END:\n"
                     "* TODO Middle\n:PROPERTIES:\n:ID: s-2\n"
                     ":CREATED:  [2026-08-10 Mon 09:00]\n:END:\n"))
           ,@body)
       (let ((buf (get-file-buffer file)))
         (when buf (with-current-buffer buf (set-buffer-modified-p nil))
               (kill-buffer buf)))
       (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-sort-by-created-is-newest-first ()
  "Level-1 headings end up newest-first, subtrees intact.
One call, and org owns the comparator (TODO.org :ID: 5f1068f9)."
  (claude-code-ide-org-test--with-unsorted-file
    (claude-code-ide-org-sort-by-created file)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (< (string-match "Newest" disk) (string-match "Middle" disk)))
      (should (< (string-match "Middle" disk) (string-match "Oldest" disk))))))

(ert-deftest claude-code-ide-org-test-sort-puts-the-undated-anchor-last ()
  "The datetree anchor sorts last because it carries no :CREATED:.

Measured rather than assumed: org places an undated entry last under
`?R'. That it is last by an *absence* is the approach's one real
objection, which bin/lint-org answers with an assertion rather than a
fabricated timestamp."
  (claude-code-ide-org-test--with-unsorted-file
    (claude-code-ide-org-sort-by-created file)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (< (string-match "Oldest" disk)
                 (string-match "Review and planning" disk))))))

(ert-deftest claude-code-ide-org-test-sort-by-created-is-idempotent ()
  "A second sort moves nothing, which is what lets it join the ceremony.
The count must say so too: it is reported by *position*, because a set
difference is always empty after a sort and once read \"0 moved\" over a
9290-line reordering."
  (claude-code-ide-org-test--with-unsorted-file
    (let ((first (claude-code-ide-org-sort-by-created file)))
      ;; All four: Oldest/Newest/anchor/Middle becomes
      ;; Newest/Middle/Oldest/anchor, so every position changes.
      (should (string-match-p "4 moved" first)))
    (let ((once (claude-code-ide-org-test--disk-contents file))
          (second (claude-code-ide-org-sort-by-created file)))
      (should (string-match-p "0 moved" second))
      (should (equal once (claude-code-ide-org-test--disk-contents file))))))

(ert-deftest claude-code-ide-org-test-sort-keeps-subtrees-with-their-parents ()
  "A child must travel with its heading, or sorting silently reparents work."
  (claude-code-ide-org-test--with-unsorted-file
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO Oldest$")
      (end-of-line)
      (insert "\n** TODO A child of Oldest\n")
      (save-buffer))
    (claude-code-ide-org-sort-by-created file)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      ;; The child sits directly after its parent, not stranded elsewhere.
      (should (string-match-p "\\* TODO Oldest\n\\*\\* TODO A child of Oldest" disk)))))

(ert-deftest claude-code-ide-org-test-backfill-from-git-fills-and-marks ()
  "A heading with no logged close gets one from git, marked as derived.

The marker is why this is allowed to exist. Nothing mechanical is misled
by an approximate CLOSED: -- the three consumers use it as a placement
key, a threshold and a presence test -- but a human cannot otherwise
tell a derived date from a measured one, and TODO.org :ID: 7771fc63 is
the standing finding that a plausible value is harder to reject than an
absent one (TODO.org :ID: b7b46a26)."
  (skip-unless (executable-find "git"))
  (claude-code-ide-org-test--with-git-repo
    (with-temp-file org
      (insert "#+TODO: TODO | DONE\n"
              "* DONE Finished long ago\n:PROPERTIES:\n:ID:       zzzz-0001\n:END:\n"))
    (claude-code-ide-org-test--git-commit dir "close it" "2026-08-05T09:00:00-0500")
    (let ((summary (claude-code-ide-org-backfill-closed-from-git org)))
      (should (string-match-p "1 filled from git" summary)))
    (let ((disk (claude-code-ide-org-test--disk-contents org)))
      (should (string-match-p "^CLOSED: \\[2026-08-05" disk))
      (should (string-match-p ":CLOSED_SOURCE: git" disk)))))

(ert-deftest claude-code-ide-org-test-backfill-from-git-is-idempotent ()
  "A heading that already has CLOSED: is left alone, whatever its source.
Otherwise a second run would overwrite a *measured* close with an
upper bound -- the one outcome that would make the file worse."
  (skip-unless (executable-find "git"))
  (claude-code-ide-org-test--with-git-repo
    (with-temp-file org
      (insert "#+TODO: TODO | DONE\n"
              "* DONE Already dated\nCLOSED: [2026-08-01 Sat 10:00]\n"
              ":PROPERTIES:\n:ID:       zzzz-0002\n:END:\n"))
    (claude-code-ide-org-test--git-commit dir "seed" "2026-08-05T09:00:00-0500")
    (let ((summary (claude-code-ide-org-backfill-closed-from-git org)))
      (should (string-match-p "0 filled from git" summary))
      (should (string-match-p "1 already had CLOSED:" summary)))
    (let ((disk (claude-code-ide-org-test--disk-contents org)))
      ;; The measured value survives, and no marker is added to it.
      (should (string-match-p "CLOSED: \\[2026-08-01 Sat 10:00\\]" disk))
      (should-not (string-match-p "CLOSED_SOURCE" disk)))))

(ert-deftest claude-code-ide-org-test-backfill-from-git-dry-run-writes-nothing ()
  "The dry run reports what the real run would do and writes nothing.
Identical reports are what make a dry run worth trusting."
  (skip-unless (executable-find "git"))
  (claude-code-ide-org-test--with-git-repo
    (with-temp-file org
      (insert "#+TODO: TODO | DONE\n"
              "* DONE Finished long ago\n:PROPERTIES:\n:ID:       zzzz-0003\n:END:\n"))
    (claude-code-ide-org-test--git-commit dir "close it" "2026-08-05T09:00:00-0500")
    (let ((dry (claude-code-ide-org-backfill-closed-from-git org t)))
      (should (string-match-p "1 filled from git" dry))
      (should (string-match-p "dry run" dry)))
    (should-not (string-match-p
                 "CLOSED:" (claude-code-ide-org-test--disk-contents org)))
    ;; And the *buffer* is untouched, not merely unsaved. A dry run that
    ;; edits without saving leaves a dirty buffer a human can save by
    ;; accident, and makes the file read as busy to
    ;; `claude-code-ide-org--file-busy-p'. Checking disk alone passes
    ;; against that, which a mutation showed.
    (should-not (buffer-modified-p (find-file-noselect org)))))

(ert-deftest claude-code-ide-org-test-forgotten-detects-a-subject-id ()
  "A commit whose *subject* names a non-member is reported.

Detects; never adds. Membership is what a slice declares, so a mechanism
that swept in every heading touched would produce a backlog wearing a
slice's clothes (TODO.org :ID: c60a1c53)."
  (skip-unless (executable-find "git"))
  (claude-code-ide-org-test--with-forgotten-fixture
    (with-temp-file (expand-file-name "f.txt" dir) (insert "x"))
    ;; Both ids in subjects, so the member exclusion is actually
    ;; exercised. Without a commit naming the member, `should-not' below
    ;; passes whether or not the exclusion exists -- the vacuous shape a
    ;; mutation caught here.
    (claude-code-ide-org-test--git-commit
     dir "Build the thing: cccccccc" "2026-08-05T09:00:00-0500")
    (with-temp-file (expand-file-name "g.txt" dir) (insert "y"))
    (claude-code-ide-org-test--git-commit
     dir "Work the member: bbbbbbbb" "2026-08-06T09:00:00-0500")
    (with-temp-file (expand-file-name "h.txt" dir) (insert "z"))
    (claude-code-ide-org-test--git-commit
     dir "Add something to aaaaaaaa" "2026-08-07T09:00:00-0500")
    (let ((ids (claude-code-ide-org--slice-forgotten-ids)))
      (should (member "cccccccc-0000-0000-0000-000000000000" ids))
      ;; A declared member is not forgotten -- that is the whole point.
      (should-not (member "bbbbbbbb-0000-0000-0000-000000000000" ids))
      ;; Nor is the slice itself. Commit subjects cite it constantly,
      ;; and a slice never lists itself as a member, so without this it
      ;; reports itself forever -- which is exactly what the first live
      ;; run returned.
      (should-not (member "aaaaaaaa-0000-0000-0000-000000000000" ids)))))

(ert-deftest claude-code-ide-org-test-forgotten-ignores-body-mentions ()
  "An id in a commit *body* is a cross-reference, not a claim.

Measured when this was designed: the body scan returned 27 candidates
and the subject scan 3. A report that lists 27 things stops being read."
  (skip-unless (executable-find "git"))
  (claude-code-ide-org-test--with-forgotten-fixture
    (with-temp-file (expand-file-name "f.txt" dir) (insert "x"))
    (claude-code-ide-org-test--git-commit
     dir "Unrelated subject\n\nCross-reference to cccccccc in the body."
     "2026-08-05T09:00:00-0500")
    (should-not (member "cccccccc-0000-0000-0000-000000000000"
                        (claude-code-ide-org--slice-forgotten-ids)))))

(ert-deftest claude-code-ide-org-test-forgotten-ignores-tokens-that-are-not-ids ()
  "An 8-hex token that prefixes no heading is a commit SHA, not an id.
Without this filter the scan reports abbreviated SHAs, which this
project's subjects carry."
  (skip-unless (executable-find "git"))
  (claude-code-ide-org-test--with-forgotten-fixture
    (with-temp-file (expand-file-name "f.txt" dir) (insert "x"))
    (claude-code-ide-org-test--git-commit
     dir "Revert deadbeef and move on" "2026-08-05T09:00:00-0500")
    (should-not (claude-code-ide-org--slice-forgotten-ids))))

(ert-deftest claude-code-ide-org-test-forgotten-is-silent-with-no-open-slice ()
  "With no slice open, \"no slice claims it\" is simply true.
A report that fires on a true and unactionable fact is the prompt
fatigue this project keeps designing against."
  (skip-unless (executable-find "git"))
  (claude-code-ide-org-test--with-forgotten-fixture
    (with-current-buffer (find-file-noselect org)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO \\[0/1\\] A slice")
      (org-back-to-heading t)
      (org-todo "DONE")
      (save-buffer))
    (with-temp-file (expand-file-name "f.txt" dir) (insert "x"))
    (claude-code-ide-org-test--git-commit
     dir "Build the thing: cccccccc" "2026-08-05T09:00:00-0500")
    (should-not (claude-code-ide-org--slice-forgotten-ids))))

(ert-deftest claude-code-ide-org-test-slice-incidentals-are-the-strict-window ()
  "Everything closed in the slice's window that it does not already name.

The rule needs no opinion, which is the point: a curated list would take
a judgement per heading, and a judgement re-made differently each time is
what this project keeps getting wrong. Derived, so it cannot drift
(TODO.org :ID: 0086614a)."
  (claude-code-ide-org-test--with-slice-window
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO \\[1/1\\] A slice")
      (let ((ids (claude-code-ide-org--slice-incidental-ids)))
        (should (member "incid-001" ids))
        (should (member "incid-002" ids))
        ;; A declared member is not incidental -- that is the whole split.
        (should-not (member "member-01" ids))
        ;; Nor is the slice itself, which closes inside its own window.
        (should-not (member "slice-001" ids))
        ;; And the window has a lower bound: this one closed the day before.
        (should-not (member "before-01" ids))))))

(ert-deftest claude-code-ide-org-test-another-slices-members-are-not-incidental ()
  "Work another slice declares is planned, not incidental to this one.

Another slice\='s checklist is planned work -- planned elsewhere, but
planned -- so listing it here asserts something false about who planned
it.  Measured 2026-09-01: 21 of `f9fe9fac\='s 26 incidentals were
`b36e6369\='s declared members (TODO.org :ID: 5bfc1d38)."
  (claude-code-ide-org-test--with-slice-window
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      ;; A second slice, worked in the same window, declaring incid-001.
      (insert "\n* TODO [0/1] Another slice\n:PROPERTIES:\n"
              ":ID:       slice-002\n:KIND:     slice\n"
              ":CREATED:  [2026-08-20 Thu 09:00]\n:END:\n"
              ":LOGBOOK:\n"
              "CLOCK: [2026-08-20 Thu 09:00]--[2026-08-20 Thu 09:30] =>  0:30\n"
              ":END:\n\n"
              "- [X] [[id:incid-001][incid-001]] DONE Claimed by the other slice\n")
      (save-buffer)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO \\[1/1\\] A slice")
      (let ((ids (claude-code-ide-org--slice-incidental-ids)))
        ;; Declared next door, so not incidental here.
        (should-not (member "incid-001" ids))
        ;; Declared by nobody, so still incidental here -- without this
        ;; the test would pass on a function that returned nil.
        (should (member "incid-002" ids))))))

(ert-deftest claude-code-ide-org-test-a-cancelled-slices-claim-does-not-hold ()
  "A CANCELLED slice\='s declarations stop speaking for anything.

A DONE slice\='s claim stays true as history -- it did plan that work.  A
cancelled plan was abandoned, so work closed in someone else\='s window
really is incidental to them (TODO.org :ID: 5bfc1d38)."
  (claude-code-ide-org-test--with-slice-window
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (insert "\n* CANCELLED [0/1] An abandoned slice\n:PROPERTIES:\n"
              ":ID:       slice-003\n:KIND:     slice\n"
              ":CREATED:  [2026-08-20 Thu 09:00]\n:END:\n\n"
              "- [X] [[id:incid-001][incid-001]] DONE Claimed by a dead plan\n")
      (save-buffer)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO \\[1/1\\] A slice")
      (should (member "incid-001" (claude-code-ide-org--slice-incidental-ids))))))

(ert-deftest claude-code-ide-org-test-cross-slice-exclusion-is-reported ()
  "The exclusion is named, not applied silently.

A derived list that quietly shrinks is as wrong as one that quietly
grows, and only one of them is visible."
  (claude-code-ide-org-test--with-slice-window
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (insert "\n* TODO [0/1] Another slice\n:PROPERTIES:\n"
              ":ID:       slice-002\n:KIND:     slice\n"
              ":CREATED:  [2026-08-20 Thu 09:00]\n:END:\n\n"
              "- [X] [[id:incid-001][incid-001]] DONE Claimed by the other slice\n")
      (save-buffer)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO \\[1/1\\] A slice")
      (let ((claude-code-ide-org--incidentals-claimed-elsewhere nil))
        (claude-code-ide-org--slice-incidental-ids)
        (should (member "incid-001"
                        claude-code-ide-org--incidentals-claimed-elsewhere))))))

(ert-deftest claude-code-ide-org-test-slice-never-worked-has-no-incidentals ()
  "A slice nobody has started accrues nothing, however long ago it was written.

The left edge is first work, not `:CREATED:'.  Composing a slice while
its predecessor still runs is normal here, and created-to-now then means
\"everything anyone closed since I was written down\": measured
2026-09-01, `f9fe9fac' had zero CLOCK lines and listed 26 incidentals,
21 of them another slice's declared members, and its cookie read 26/28
(TODO.org :ID: 42ba0a80)."
  (claude-code-ide-org-test--with-slice-window
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO \\[1/1\\] A slice")
      (org-back-to-heading t)
      ;; Same fixture, minus the evidence of work. Everything closed in
      ;; the window is still there; only the clock is gone.
      (let ((lim (save-excursion (org-end-of-subtree t t))))
        (save-excursion
          (when (re-search-forward "^[ \t]*CLOCK:.*\n" lim t)
            (replace-match ""))))
      (should-not (claude-code-ide-org--slice-incidental-ids))
      ;; And the guard is the clock, not some other property of the
      ;; fixture: put one back and the window returns.
      (save-excursion
        (org-back-to-heading t)
        (forward-line 1)
        (re-search-forward "^:END:$")
        (insert "\n:LOGBOOK:\nCLOCK: [2026-08-20 Thu 09:00]--"
                "[2026-08-20 Thu 09:30] =>  0:30\n:END:"))
      (should (member "incid-001" (claude-code-ide-org--slice-incidental-ids))))))

(ert-deftest claude-code-ide-org-test-slice-incidental-window-is-bounded-by-close ()
  "A closed slice's window ends at its own CLOSED:, not at today.
Otherwise a finished slice would keep absorbing later work as incidental
-- the same reason `refresh-slice' refuses to touch a closed slice at
all: a record must not be rewritten by things that happened after it."
  (claude-code-ide-org-test--with-slice-window
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (re-search-forward "^\\* TODO \\[1/1\\] A slice")
      (org-back-to-heading t)
      ;; `org-entry-put' refuses CLOSED outright -- it is a planning
      ;; line, not a property -- so it goes in through org's own API.
      (org-add-planning-info
       'closed (org-time-string-to-time "[2026-08-21 Fri 23:00]"))
      (let ((ids (claude-code-ide-org--slice-incidental-ids)))
        (should (member "incid-001" ids))
        ;; Closed the day after the slice: outside the window.
        (should-not (member "incid-002" ids))))))

(ert-deftest claude-code-ide-org-test-stranded-single-point-span-is-dropped ()
  "A lone guidepost with later events behind it must not become an item.

It renders `[13:03]--[13:03]\', writes nothing, and can only ever be
answered `d\' -- and because a later event exists it can never grow, so
the question has exactly one possible answer and is asked on every pass
forever. Measured 2026-08-31: four such items, three of them permanent,
re-offered across every apply that day (TODO.org :ID: 355fa608)."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org-test--queue-write
     "sess-a"
     ;; A lone resume, then a bracketed pair well after it. The lone one
     ;; is stranded: events exist later, so its cluster can never grow.
     (claude-code-ide-org-test--queue-event "2026-08-11T09:00:00-0500" "resume")
     (claude-code-ide-org-test--queue-event "2026-08-11T13:00:00-0500" "resume")
     (claude-code-ide-org-test--queue-event "2026-08-11T13:10:00-0500" "pause"))
    (let* ((items (claude-code-ide-org--review-items-from-queue "sess-a"))
           (points (seq-filter
                    (lambda (i)
                      (and (eq (plist-get i :type) 'clock)
                           (time-equal-p (plist-get i :start)
                                         (plist-get i :end))))
                    items)))
      (should-not points)
      ;; The real span is untouched -- this drops degenerate items, not
      ;; the guideposts around them.
      (should (seq-find (lambda (i) (eq (plist-get i :type) 'clock)) items)))))

(ert-deftest claude-code-ide-org-test-trailing-single-point-span-is-kept ()
  "The newest single point is still offered, and that is the whole split.

:ID: 31f766ab rejected suppression because hiding an in-flight span
needs a liveness signal -- queue mtime plus an idle threshold -- so a
crashed session's last span would vanish for an hour. That objection is
real and applies only to the *trailing* span. \"Is there a later
event\" is an exact property of the stream, so the trailing case keeps
being asked about while the stranded case stops."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org-test--queue-write
     "sess-a"
     (claude-code-ide-org-test--queue-event "2026-08-11T09:00:00-0500" "resume")
     (claude-code-ide-org-test--queue-event "2026-08-11T09:10:00-0500" "pause")
     ;; Newest event in the queue, alone: still in flight.
     (claude-code-ide-org-test--queue-event "2026-08-11T13:00:00-0500" "resume"))
    (let* ((items (claude-code-ide-org--review-items-from-queue "sess-a"))
           (points (seq-filter
                    (lambda (i)
                      (and (eq (plist-get i :type) 'clock)
                           (time-equal-p (plist-get i :start)
                                         (plist-get i :end))))
                    items)))
      (should (= 1 (length points))))))

(ert-deftest claude-code-ide-org-test-state-items-arrive-auto-marked ()
  "A non-stale state item carries no judgement, so it arrives selected.

Staleness is the *only* judgement a state item carries; everything else
about it is mechanical, so arriving unmarked costs a keystroke and buys
nothing. A stale one stays unmarked, exactly as `M\' already refuses it.
A span is not auto-marked at all -- it carries an interval a human may
want to edit and, when unassigned, a heading only they can choose
(TODO.org :ID: b6e229c7)."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--set-todo-for-real id "DOING")
    (let ((fresh (list :type 'state :id id :from "DOING" :to "DONE"
                       :ts (current-time) :events nil))
          (stale (list :type 'state :id id :from "TODO" :to "WAITING"
                       :ts (current-time) :events nil))
          (span (list :type 'clock :id id :suggested t :agent nil :events nil
                      :start (current-time) :end (current-time))))
      (claude-code-ide-org-test--with-review-buffer (list fresh stale span)
        (should (plist-get fresh :marked))
        (should (plist-get fresh :auto-marked))
        (should-not (plist-get stale :marked))
        (should-not (plist-get span :marked))))))

(ert-deftest claude-code-ide-org-test-auto-mark-does-not-fight-an-unmark ()
  "Auto-marking happens once per item, never once per render.

Marks redraw on every keystroke, so re-deciding at render time would
make `u\' impossible -- the mark would return on the redraw that follows
it. Found by the existing mark tests when this shipped, which is what
they are for."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'state :id id :from "TODO" :to "DOING"
                      :ts (current-time) :events nil)))
      (claude-code-ide-org-test--with-review-buffer (list item)
        (should (plist-get item :marked))
        (claude-code-ide-org-test--goto-nth-item 0)
        (claude-code-ide-org-review-unmark)
        (should-not (plist-get item :marked))
        ;; Still unmarked after a further redraw.
        (claude-code-ide-org--review-render)
        (should-not (plist-get item :marked))))))

(ert-deftest claude-code-ide-org-test-an-auto-mark-is-not-judgement-g-must-ask-about ()
  "`g\' must not prompt merely because items arrived pre-marked.

Counting an auto-mark as judgement would make the confirmation fire on
every refresh, turning :ID: 8d0716fe's guard into the decoration it was
written to avoid. A mark the human actually made still counts, and
touching the line by hand converts it."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'state :id id :from "TODO" :to "DOING"
                      :ts (current-time) :events nil)))
      (claude-code-ide-org-test--with-review-buffer (list item)
        (should (plist-get item :marked))
        (should-not (claude-code-ide-org--review-judgement-summary (list item)))
        ;; A hand mark makes the line the human's.
        (claude-code-ide-org-test--goto-nth-item 0)
        (claude-code-ide-org-review-mark)
        (should (string-match-p
                 "1 marked"
                 (claude-code-ide-org--review-judgement-summary (list item))))))))

(ert-deftest claude-code-ide-org-test-refresh-asks-before-discarding-judgement ()
  "`g\' must not silently discard unapplied decisions.

Reported from live use: \"I have a tendency to hit `g\' when I mean `x\'
and I lose all of my review work.\" The two are adjacent in intent and on
the keyboard, and one is destructive. Declining must leave the items
exactly as they were (TODO.org :ID: 8d0716fe)."
  (claude-code-ide-org-test--with-review-buffer
      (list (list :type 'state :id "test-0001" :from "TODO" :to "DOING"
                  :ts (date-to-time "2026-08-31T09:00:00-0500")
                  :marked t :events nil))
    (let ((asked nil))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (prompt) (setq asked prompt) nil)))
        (should-error (claude-code-ide-org-review-refresh) :type 'user-error))
      (should asked)
      ;; Names what is at stake -- a bare "are you sure?" does not tell a
      ;; human whether to care.
      (should (string-match-p "1 marked" asked))
      ;; Declining changes nothing.
      (should (= 1 (length claude-code-ide-org--review-items)))
      (should (plist-get (car claude-code-ide-org--review-items) :marked)))))

(ert-deftest claude-code-ide-org-test-refresh-stays-instant-with-nothing-to-lose ()
  "No prompt when there is no judgement to discard.
A confirmation on every `g\' trains the reflex that dismisses it, which
is how a guard becomes decoration."
  (claude-code-ide-org-test--with-review-buffer
      (list (list :type 'state :id "test-0001" :from "TODO" :to "DOING"
                  :ts (date-to-time "2026-08-31T09:00:00-0500") :events nil))
    (let ((asked nil))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (_) (setq asked t) t))
                ((symbol-function 'claude-code-ide-org--review-items-from-queue)
                 (lambda () nil)))
        (claude-code-ide-org-review-refresh))
      (should-not asked))))

(ert-deftest claude-code-ide-org-test-refresh-counts-all-four-kinds-of-judgement ()
  "Marks, assignments, notes and edited intervals all count.

Two of the four needed a flag adding, for the same reason: :start, :end
and :note all exist on a span straight from the queue, so their presence
proves nothing about whether a human touched them."
  (should-not (claude-code-ide-org--review-judgement-summary
               (list (list :type 'clock :id "a"))))
  (let ((summary (claude-code-ide-org--review-judgement-summary
                  (list (list :type 'clock :id "a" :marked t)
                        (list :type 'clock :id "b" :assigned t)
                        (list :type 'clock :id "c" :note-edited t)
                        (list :type 'clock :id "d" :edited t)))))
    (should (string-match-p "1 marked" summary))
    (should (string-match-p "1 assigned" summary))
    (should (string-match-p "1 note" summary))
    (should (string-match-p "1 edited interval" summary))))

(ert-deftest claude-code-ide-org-test-a-queued-note-is-not-judgement-g-must-ask-about ()
  "A note that came from the queue must not make `g\' prompt.

`:note\' is populated by `claude-code-ide-org--review-items-from-queue\':
a clock span takes the `clock_in\' event\'s own note as its label, and a
capture item takes the event\'s note verbatim.  Both are ordinary tool
usage, so counting the field made the confirmation fire on a buffer
nobody had touched -- the same failure `:auto-marked\' prevents one
field over.  Typing `N\' is what turns a note into judgement."
  (should-not (claude-code-ide-org--review-judgement-summary
               (list (list :type 'clock :id "a" :note "root-cause the spans")
                     (list :type 'capture :id "b" :note "PR8 review finding"))))
  (should (string-match-p
           "1 note"
           (claude-code-ide-org--review-judgement-summary
            (list (list :type 'clock :id "a" :note "root-cause the spans"
                        :note-edited t))))))

(ert-deftest claude-code-ide-org-test-edit-note-flags-the-item-as-edited ()
  "`N\' must leave a flag `g\' can see, since the note field alone proves nothing."
  (claude-code-ide-org-test--with-review-buffer
      (list (list :type 'clock :id "test-0001"
                  :start (date-to-time "2026-08-31T09:00:00-0500")
                  :end (date-to-time "2026-08-31T09:15:00-0500")
                  :note "queued label" :suggested t :agent nil :events nil))
    (let ((item (car claude-code-ide-org--review-items)))
      (should-not (plist-get item :note-edited))
      (claude-code-ide-org-test--goto-nth-item 0)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) "what it actually turned out to be")))
        (claude-code-ide-org-review-edit-note))
      (should (equal "what it actually turned out to be" (plist-get item :note)))
      (should (plist-get item :note-edited))
      (should (string-match-p
               "1 note"
               (claude-code-ide-org--review-judgement-summary
                claude-code-ide-org--review-items))))))

(ert-deftest claude-code-ide-org-test-edit-interval-flags-the-item-as-edited ()
  "`e\' must leave a flag `g\' can see, or the fourth kind is invisible."
  (claude-code-ide-org-test--with-review-buffer
      (list (list :type 'clock :id "test-0001"
                  :start (date-to-time "2026-08-31T09:00:00-0500")
                  :end (date-to-time "2026-08-31T09:15:00-0500")
                  :suggested t :agent nil :events nil))
    (claude-code-ide-org-test--goto-nth-item 0)
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &optional initial &rest _)
                 (if (string-prefix-p "Start" prompt)
                     "[2026-08-31 Sun 09:00]"
                   "[2026-08-31 Sun 09:20]"))))
      (claude-code-ide-org-review-edit-interval))
    (should (plist-get (car claude-code-ide-org--review-items) :edited))))

(ert-deftest claude-code-ide-org-test-undo-refresh-restores-the-discarded-list ()
  "The slip costs a decision, not a keystroke, so it must be recoverable.
An assignment or an edited interval has to be *made* again; stashing the
list is strictly better than only asking, and the two compose."
  (claude-code-ide-org-test--with-review-buffer
      (list (list :type 'state :id "test-0001" :from "TODO" :to "DOING"
                  :ts (date-to-time "2026-08-31T09:00:00-0500")
                  :marked t :events nil))
    (let ((claude-code-ide-org--review-stash nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t))
                ((symbol-function 'claude-code-ide-org--review-items-from-queue)
                 (lambda () nil)))
        (claude-code-ide-org-review-refresh))
      (should-not claude-code-ide-org--review-items)
      (claude-code-ide-org-review-undo-refresh)
      (should (= 1 (length claude-code-ide-org--review-items)))
      (should (plist-get (car claude-code-ide-org--review-items) :marked))
      ;; And a second undo has nothing left to give, rather than
      ;; restoring the same list twice.
      (should-error (claude-code-ide-org-review-undo-refresh)
                    :type 'user-error))))

(ert-deftest claude-code-ide-org-test-apply-skips-a-state-event-that-became-a-no-op ()
  "Two events asserting the same target: the second must write nothing.

Post-cutover nothing moves an org file until apply moves it, so every
`org_set_todo\' in a batch reads `from\' off an unmoved file. The second
event then finds the projection already at its own target -- it is not a
no-op at queue time and becomes one before it is applied, which is why
:ID: cc0c17a7\'s queue-side refusal cannot reach it. Measured 2026-08-28:
4 of 463 State lines in the corpus are self-transitions
(TODO.org :ID: 05c71d99).

The heading must end at DOING with exactly one State line, not two."
  (claude-code-ide-org-test--with-heading
    (let ((items (list (list :type 'state :id id :from "TODO" :to "DOING"
                             :ts (date-to-time "2026-08-31T09:00:00-0500")
                             :events nil)
                       (list :type 'state :id id :from "TODO" :to "DOING"
                             :ts (date-to-time "2026-08-31T09:05:00-0500")
                             :events nil))))
      (claude-code-ide-org--review-projected-staleness items)
      ;; The first is neither stale nor redundant; the second is
      ;; redundant and emphatically NOT stale -- its `from\' matches
      ;; reality perfectly, which is exactly why it sails through the
      ;; staleness guard.
      (should-not (plist-get (nth 0 items) :redundant))
      (should (plist-get (nth 1 items) :redundant))
      (should-not (claude-code-ide-org--review-state-stale-p (nth 1 items)))
      (should-not (claude-code-ide-org--review-apply-item (nth 0 items)))
      ;; Skipped, and reported as success so the events are consumed and
      ;; the item does not return every pass.
      (should-not (claude-code-ide-org--review-apply-item (nth 1 items)))
      (let ((disk (claude-code-ide-org-test--disk-contents file)))
        (should (string-match-p "^\\* DOING Test heading" disk))
        (should (= 1 (length (seq-filter
                              (lambda (l) (string-match-p "State .*DOING" l))
                              (split-string disk "\n")))))))))

(ert-deftest claude-code-ide-org-test-review-line-says-a-no-op-is-a-no-op ()
  "A skipped event must say so rather than vanishing.

Dropping it silently is defensible -- nothing was lost -- but a queued
event that disappears without trace is the shape this project has
repeatedly regretted. It carries no `!\': nothing is wrong, which is the
whole difference from a stale item."
  (claude-code-ide-org-test--with-heading
    (let ((items (list (list :type 'state :id id :from "TODO" :to "DOING"
                             :ts (date-to-time "2026-08-31T09:00:00-0500")
                             :events nil)
                       (list :type 'state :id id :from "TODO" :to "DOING"
                             :ts (date-to-time "2026-08-31T09:05:00-0500")
                             :events nil))))
      (claude-code-ide-org--review-projected-staleness items)
      (let ((line (claude-code-ide-org--review-describe (nth 1 items))))
        (should (string-match-p "no-op, heading is already there" line))
        (should-not (string-match-p "STALE" line))
        (should-not (string-prefix-p "! " line))))))

(ert-deftest claude-code-ide-org-test-review-assign-keeps-point-on-the-item ()
  "Assigning leaves point on the line it just assigned, because the next
thing a human does is mark it (TODO.org :ID: a2509a61).  It advanced
until 2026-08-28, under a rule generalised from `m'/`u' -- \"advance when
the command answers the line question\" -- which put `a' in the advancing
set even though assigning makes a line *markable* rather than finishing
it.

Restoring by identity rather than line number is load-bearing here:
assigning removes the evidence lines an unassigned span carries, so the
buffer is shorter afterwards and the old line number points elsewhere.

Assigns the *middle of three* deliberately, and both parts of that
matter.  Asserting on the first item would also pass against the older
bug where re-rendering dumped point at the top (:ID: 9e80a32d), since
for the first item those outcomes are the same line.  Asserting on the
*last* item would pass against the advancing code too, because advancing
from the last item has nowhere to go and stays put -- measured, not
assumed: with the advance restored, a two-item version of this test went
green.  From the middle of three, staying, advancing and jumping to the
top are three distinct lines."
  (claude-code-ide-org-test--with-heading
    (let ((review (get-buffer-create "*org-review-assign-test*"))
          (first (list :type 'clock :id nil :unassigned t :suggested t
                       :start (claude-code-ide-org-test--t "09:00")
                       :end (claude-code-ide-org-test--t "09:30") :events nil))
          (second (list :type 'clock :id nil :unassigned t :suggested t
                        :start (claude-code-ide-org-test--t "11:00")
                        :end (claude-code-ide-org-test--t "11:30") :events nil))
          (third (list :type 'clock :id nil :unassigned t :suggested t
                       :start (claude-code-ide-org-test--t "13:00")
                       :end (claude-code-ide-org-test--t "13:30") :events nil)))
      (org-id-update-id-locations (list file))
      (unwind-protect
          (with-current-buffer review
            (claude-code-ide-org-review-mode)
            (setq claude-code-ide-org--review-items (list first second third))
            (claude-code-ide-org--review-render)
            (claude-code-ide-org-test--goto-nth-item 1)
            (let ((claude-code-ide-org-query-files (list file)))
              ;; Take the first candidate from the collection `assign'
              ;; actually builds, rather than recomputing it: this asserts
              ;; against what the command offers, not against a parallel
              ;; construction that could drift from it.
              ;;
              ;; Read through `all-completions' rather than `caar'. The
              ;; collection is a function now, so that it can carry
              ;; `display-sort-function' metadata and stop Vertico
              ;; re-sorting the ranking away (:ID: 85702dba) -- and
              ;; `all-completions' is the accessor that works whichever
              ;; representation is in use, so this stub does not have to
              ;; be revisited if it changes again.
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt collection &rest _)
                           (should collection)
                           (car (all-completions "" collection nil)))))
                (claude-code-ide-org-review-assign)))
            ;; Still on the span just assigned: not advanced past it, and
            ;; not thrown to the top of the buffer either.
            (should (eq (claude-code-ide-org--review-item-at-point) second)))
        (kill-buffer review)))))

(ert-deftest claude-code-ide-org-test-review-apply-keeps-unapplied-decisions ()
  "Applying some items used to rebuild the whole list from the queue,
discarding every decision on the items it did *not* apply -- assignments,
edited intervals, notes, and confirmations of staleness.

The shape is nastier than it sounds: the rebuild happens only when apply
*succeeds*, so the better things go the more is lost, which is the
opposite of where anyone's guard is up.

Asserts survivors by identity.  A rebuild yields fresh plists equal in
every visible field and empty of the decision, so an `equal' test would
pass against the unfixed code."
  (claude-code-ide-org-test--with-heading
    (let* ((review (get-buffer-create "*org-review-apply-keep-test*"))
           (to-apply (list :type 'state :id id :ts (current-time)
                           :from "TODO" :to "DOING" :marked t :events nil))
           (decided (list :type 'clock :id id :assigned t :unassigned nil
                          :note "a note the human wrote"
                          :start (claude-code-ide-org-test--t "09:00")
                          :end (claude-code-ide-org-test--t "09:30")
                          :events nil)))
      (unwind-protect
          (with-current-buffer review
            (claude-code-ide-org-review-mode)
            (setq claude-code-ide-org--review-items (list to-apply decided))
            (claude-code-ide-org--review-render)
            (claude-code-ide-org-review-apply)
            ;; The applied item is gone from the list...
            (should-not (memq to-apply claude-code-ide-org--review-items))
            ;; ...and the untouched one survives *as itself*, decision intact.
            (should (memq decided claude-code-ide-org--review-items))
            (should (plist-get decided :assigned))
            (should (equal (plist-get decided :note) "a note the human wrote")))
        (kill-buffer review)))))

(ert-deftest claude-code-ide-org-test-review-apply-keeps-marks-on-failures ()
  "A partial apply must leave the failures marked.  The rebuild cleared
every mark, so retrying an item that failed for a transient reason meant
marking it again -- and worse, a stale transition you had deliberately
confirmed asked for confirmation a second time, because
`:stale-confirmed' lives on the item and a rebuilt item has none.

Covers the *partial* case specifically: the existing coverage is for
nothing applying at all, which never took the discarding branch."
  (claude-code-ide-org-test--with-heading
    (let* ((review (get-buffer-create "*org-review-apply-fail-test*"))
           (ok (list :type 'state :id id :ts (current-time)
                     :from "TODO" :to "DOING" :marked t :events nil))
           ;; Refused as stale: by the time this is reached the heading is
           ;; DOING, so a transition claiming to come from MAYBE cannot be
           ;; trusted and is left for the human to confirm.
           (stale (list :type 'state :id id :ts (current-time)
                        :from "MAYBE" :to "DONE" :marked t :events nil)))
      (unwind-protect
          (with-current-buffer review
            (claude-code-ide-org-review-mode)
            (setq claude-code-ide-org--review-items (list ok stale))
            (claude-code-ide-org--review-render)
            (claude-code-ide-org-review-apply)
            (should-not (memq ok claude-code-ide-org--review-items))
            (should (memq stale claude-code-ide-org--review-items))
            (should (plist-get stale :marked)))
        (kill-buffer review)))))

(ert-deftest claude-code-ide-org-test-review-dismiss-keeps-unapplied-assignments ()
  "Dismissing used to end in `review-refresh', which rebuilds the item
list from the queue -- discarding every unapplied decision in the
session while appearing to act on one line.  Assignments are judgement,
not selection: unlike a mark they cannot be redone cheaply, and nothing
warned.

Asserts the surviving item by identity *and* that its assignment is
still on it, because a rebuild would produce a fresh plist for the same
queue events -- equal in content, empty of the decision."
  (claude-code-ide-org-test--with-heading
    (let* ((review (get-buffer-create "*org-review-dismiss-test*"))
           (assigned (list :type 'clock :id id :assigned t :unassigned nil
                           :start (claude-code-ide-org-test--t "09:00")
                           :end (claude-code-ide-org-test--t "09:30")
                           :events nil))
           (doomed (list :type 'state :id id :ts (current-time)
                         :from "TODO" :to "DOING"
                         :events (list (list :ts-string "2026-08-15T09:00:00-0500"
                                             :session-id "sess-x")))))
      (unwind-protect
          (with-current-buffer review
            (claude-code-ide-org-review-mode)
            (setq claude-code-ide-org--review-items (list doomed assigned))
            (claude-code-ide-org--review-render)
            (claude-code-ide-org-test--goto-nth-item 0)
            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "obsolete"))
                      ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                      ((symbol-function 'claude-code-ide-org--queue-mark-dismissed)
                       (lambda (&rest _) t)))
              (claude-code-ide-org-review-dismiss))
            ;; The dismissed item is gone...
            (should-not (memq doomed claude-code-ide-org--review-items))
            ;; ...and the assignment made earlier in the session survives,
            ;; as the very same object rather than a rebuilt equivalent.
            (should (memq assigned claude-code-ide-org--review-items))
            (should (plist-get assigned :assigned))
            (should (equal (plist-get assigned :id) id)))
        (kill-buffer review)))))

(ert-deftest claude-code-ide-org-test-review-goto-item-survives-a-height-change ()
  "`--review-goto-item' locates by identity, so it still finds an item
after the buffer changes height.  A line-number restore cannot: this is
the case that made assigning different from marking."
  (let ((review (get-buffer-create "*org-review-goto-test*"))
        (a (list :type 'state :id nil :ts (current-time)
                 :from "TODO" :to "DOING" :events nil))
        (b (list :type 'state :id nil :ts (current-time)
                 :from "TODO" :to "NEXT" :events nil)))
    (unwind-protect
        (with-current-buffer review
          (claude-code-ide-org-review-mode)
          (setq claude-code-ide-org--review-items (list a b))
          (claude-code-ide-org--review-render)
          (should (claude-code-ide-org--review-goto-item b))
          (let ((line-of-b (line-number-at-pos)))
            ;; Shorten the buffer above B, then look again.
            (setq claude-code-ide-org--review-items (list b))
            (claude-code-ide-org--review-render)
            (should (claude-code-ide-org--review-goto-item b))
            (should (eq (claude-code-ide-org--review-item-at-point) b))
            (should-not (= line-of-b (line-number-at-pos))))
          ;; An item no longer present leaves point at the top and says so.
          (should-not (claude-code-ide-org--review-goto-item a))
          (should (= (point) (point-min))))
      (kill-buffer review))))

(ert-deftest claude-code-ide-org-test-review-mark-advances-to-next-item ()
  "Marking advances, dired-style. Without it, marking a run of items is
`m n m n m' -- the single biggest complaint after the first real by-hand
apply. Advancing must land on an *item*, never a blank or group-heading
line, or the next keystroke reports \"No review item on this line\"."
  (claude-code-ide-org-test--with-heading
    (let ((a (list :type 'state :id id :ts (current-time) :from "TODO" :to "DOING" :events nil))
          (b (list :type 'state :id id :ts (current-time) :from "TODO" :to "WAITING" :events nil)))
      (claude-code-ide-org-test--with-review-buffer (list a b)
        (claude-code-ide-org-test--goto-nth-item 0)
        (claude-code-ide-org-review-mark)
        (should (plist-get a :marked))
        ;; Landed on the second item, not a blank line.
        (should (eq b (claude-code-ide-org--review-item-at-point)))
        ;; Marking the last one must not run off the end.
        (claude-code-ide-org-review-mark)
        (should (plist-get b :marked))
        (should (eq b (claude-code-ide-org--review-item-at-point)))
        ;; Unmark advances too, per dired.
        (claude-code-ide-org-test--goto-nth-item 0)
        (claude-code-ide-org-review-unmark)
        (should-not (plist-get a :marked))
        (should (eq b (claude-code-ide-org--review-item-at-point)))))))

(ert-deftest claude-code-ide-org-test-review-bulk-marks-skip-stale ()
  "Bulk marking must not pop a confirmation per stale item -- that is the
prompt fatigue 6b1e73c4 argued against. Stale items are skipped and
counted; unmarking is never refused, since it asks nothing."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--set-todo-for-real id "DOING")
    (let ((ok (list :type 'clock :id id
                    :start (current-time) :end (current-time)
                    :note "fine" :agent nil :suggested t :events nil))
          (stale (list :type 'state :id id :ts (current-time)
                       :from "TODO" :to "WAITING" :events nil)))
      (should (claude-code-ide-org--review-state-stale-p stale))
      (claude-code-ide-org-test--with-review-buffer (list ok stale)
        (claude-code-ide-org-review-mark-all)
        (should (plist-get ok :marked))
        (should-not (plist-get stale :marked))
        ;; Confirmed explicitly, it becomes markable in bulk.
        (plist-put stale :stale-confirmed t)
        (claude-code-ide-org-review-mark-all)
        (should (plist-get stale :marked))
        ;; Unmark-all clears everything regardless.
        (claude-code-ide-org-review-unmark-all)
        (should-not (plist-get ok :marked))
        (should-not (plist-get stale :marked))
        ;; Invert brings both back, since both are now markable.
        (claude-code-ide-org-review-toggle-all)
        (should (plist-get ok :marked))
        (should (plist-get stale :marked))))))

(ert-deftest claude-code-ide-org-test-bulk-marks-are-the-humans-not-automatic ()
  "`M\', `U\' and `t\' must clear `:auto-marked\', as `m\'/`u\' do.

A state item arrives pre-marked and flagged, so `g\' stays silent.  Once
a human touches the mark -- in bulk or one at a time -- it is theirs, and
the two paths must agree about that or a mark made with `M\' reads as
auto-made and `--review-judgement-summary\' skips it."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'state :id id :from "TODO" :to "DOING"
                      :ts (current-time) :events nil)))
      (claude-code-ide-org-test--with-review-buffer (list item)
        ;; Arrives auto-marked, so nothing to ask about.
        (should (plist-get item :marked))
        (should (plist-get item :auto-marked))
        (should-not (claude-code-ide-org--review-judgement-summary (list item)))
        ;; `U\' is a hand gesture even though it leaves no mark.
        (claude-code-ide-org-review-unmark-all)
        (should-not (plist-get item :auto-marked))
        ;; `M\' now leaves a mark that counts.
        (claude-code-ide-org-review-mark-all)
        (should (plist-get item :marked))
        (should-not (plist-get item :auto-marked))
        (should (string-match-p
                 "1 marked"
                 (claude-code-ide-org--review-judgement-summary (list item))))))))

(ert-deftest claude-code-ide-org-test-a-refused-bulk-mark-leaves-the-item-alone ()
  "An item `M\' declines must keep the state it arrived with.

The clearing belongs on the branch that sets `:marked\', not above the
`if\': a stale item is skipped precisely because nobody has decided it,
so recording a decision on it would be the opposite of what the refusal
means."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--set-todo-for-real id "DOING")
    (let ((stale (list :type 'state :id id :ts (current-time)
                       :from "TODO" :to "WAITING" :events nil)))
      (should (claude-code-ide-org--review-state-stale-p stale))
      (claude-code-ide-org-test--with-review-buffer (list stale)
        (plist-put stale :auto-marked 'untouched)
        (claude-code-ide-org-review-mark-all)
        (should-not (plist-get stale :marked))
        (should (eq 'untouched (plist-get stale :auto-marked)))))))

(ert-deftest claude-code-ide-org-test-review-edit-note-reaches-the-file ()
  "The note is the half a human is best placed to fix: Claude wrote it
before doing the work. Editing it must change what actually lands, not
just what the buffer shows."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'state :id id :ts (current-time)
                      :from "TODO" :to "DOING" :note "guessed beforehand"
                      :marked t :events nil)))
      (claude-code-ide-org-test--with-review-buffer (list item)
        (claude-code-ide-org-test--goto-nth-item 0)
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _) "what it actually was")))
          (claude-code-ide-org-review-edit-note))
        (should (equal "what it actually was" (plist-get item :note)))
        (should (string-match-p "what it actually was" (buffer-string))))
      (should-not (claude-code-ide-org--review-apply-item item))
      (should (string-match-p "what it actually was"
                              (claude-code-ide-org-test--disk-contents file))))))

(ert-deftest claude-code-ide-org-test-review-clock-line-shows-the-note-once ()
  "Regression for TODO.org :ID: e3f70e61: the clock line printed its note
twice, because `--review-format-annotation' already ends with it and
`--review-describe' appended it again."
  (claude-code-ide-org-test--with-heading
    (let* ((note "negative test, bogus id must not enqueue")
           (item (list :type 'clock :id id
                       :start (date-to-time "2026-08-11T15:12:00-0500")
                       :end (date-to-time "2026-08-11T15:16:00-0500")
                       :note note :agent nil :suggested t :events nil))
           (line (claude-code-ide-org--review-describe item))
           (count 0)
           (start 0))
      (while (string-match (regexp-quote note) line start)
        (setq count (1+ count) start (match-end 0)))
      (should (= 1 count)))))

(ert-deftest claude-code-ide-org-test-review-unresolvable-id-renders-unescaped ()
  "An unresolvable :ID: renders as its 8-character prefix followed by
`(unresolved)', and never as escaped elisp.

The escaping half is the original e3f70e61 concern and is unchanged:
reported as leaking `\\\"' and a dangling backslash, reproduced clean on
2026-08-12, pinned since so a future `%S' cannot reintroduce it.

The title half changed deliberately on 2026-08-17 (TODO.org :ID:
c2132d3f). This used to assert that `--at-id's error string -- \"no org
heading found with :ID: ...\" -- appeared as the group heading, on the
grounds that it was display text rather than escaped elisp. That was
true and beside the point: a `cond' clause of the form `((--at-id ...))'
yields its own test, and `--at-id' *returns* its error rather than
signalling, so the message landed where a title belongs and the
`(t last-id)' fallback under it was unreachable. Rendering an error
message as a heading was never intended, only unexamined."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--with-review-buffer
        (list (list :type 'clock :id "00000000-dead-beef-0000-000000000000"
                    :start (current-time) :end (current-time)
                    :note "bogus" :agent nil :suggested t :events nil))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "00000000  (unresolved)" text))
        (should-not (string-match-p "no org heading found" text))
        (should-not (string-match-p "\\\\" text))))))

(ert-deftest claude-code-ide-org-test-review-group-heading-leads-with-id-prefix ()
  "The group heading leads with the 8-character :ID: prefix, then the
title (TODO.org :ID: c2132d3f).

Prefix-first rather than a trailing `{id}' is not a style preference:
`--short-id' returns exactly 8 characters for any real UUID, so leading
with it puts every id in one column and every title in a second, whereas
a trailing form can never line up because title lengths vary.  Asserted
as an anchored prefix for that reason -- a test that merely looked for
the id *somewhere* in the line would pass on the trailing form this
replaced."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--with-review-buffer
        (list (list :type 'clock :id id
                    :start (current-time) :end (current-time)
                    :note "real heading" :agent nil :suggested t :events nil))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p
                 (concat "^" (regexp-quote (claude-code-ide-org--short-id id))
                         "  Test heading")
                 text))))))

(ert-deftest claude-code-ide-org-test-id-health-separates-missing-from-misfiled ()
  "`--id-health' must distinguish an id whose heading no longer exists
anywhere from one that exists in a different file than the one recorded.
They are different defects with different fixes, and `org-id-find' cannot
tell them apart because both return nil -- which is why the file-scan
earns its place over a per-id sweep (TODO.org :ID: 8e969114).

Both counts are asserted in one fixture on purpose: a implementation that
lumped them together would still satisfy either assertion alone."
  (claude-code-ide-org-test--with-heading
    (with-temp-file archive-file
      (insert "* DONE Archived one\n:PROPERTIES:\n:ID:       test-0002\n:END:\n"
              "* DONE Archived two\n:PROPERTIES:\n:ID:       test-0003\n:END:\n"))
    ;; Correct entry -- and what causes archive-file to be scanned at all,
    ;; since only files named as values in org-id-locations are read.
    (org-id-add-location "test-0002" archive-file)
    ;; Exists, but in archive-file rather than the file recorded here.
    (org-id-add-location "test-0003" file)
    ;; Exists in no known file.
    (org-id-add-location "test-ghost" file)
    (let ((health (claude-code-ide-org--id-health)))
      (should (= 1 (plist-get health :misfiled)))
      (should (= 1 (plist-get health :missing))))))

(ert-deftest claude-code-ide-org-test-review-id-health-line-is-silent-when-clean ()
  "The report says nothing when everything resolves.

A line reading \"0 unresolvable\" on every pass is noise that trains the
eye to skip the line that matters -- the same self-limiting reasoning as
`claude-code-ide-org-write-session-start-report'.  Asserted rather than
left to intent, because \"prints a zero\" is the natural thing for the
next person to add."
  (claude-code-ide-org-test--with-heading
    (with-temp-buffer
      (setq claude-code-ide-org--review-id-health (list :missing 0 :misfiled 0))
      (should-not (claude-code-ide-org--review-id-health-line))
      (setq claude-code-ide-org--review-id-health (list :missing 2 :misfiled 1))
      (let ((line (claude-code-ide-org--review-id-health-line)))
        (should line)
        (should (string-match-p "3 org-id entries stale" line))
        (should (string-match-p "2 headings gone" line))
        (should (string-match-p "1 in another file" line))
        (should (string-match-p "org-id-update-id-locations" line))))))

(ert-deftest claude-code-ide-org-test-review-apply-restores-read-only ()
  "The flag the user set is theirs, and apply borrows it rather than
taking it.  Clearing it and walking away silently disables the guard
against their own stray keystrokes, and they only find out by noticing
(TODO.org :ID: c8a97d9d-8b13-4b6a-a8b9-1a3f24b5e00b)."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--with-queue
      (let ((item (list :type 'state :id id :ts (current-time) :to "DOING"
                        :from "TODO" :marked t :events nil)))
        (with-current-buffer (get-file-buffer file) (read-only-mode 1))
        (unwind-protect
            (with-current-buffer (get-buffer-create "*org-review-test*")
              (claude-code-ide-org-review-mode)
              (setq claude-code-ide-org--review-items (list item))
              (claude-code-ide-org--review-render)
              (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
                (claude-code-ide-org-review-apply))
              ;; The write really happened...
              (should (string-match-p
                       "^\\* DOING Test heading"
                       (claude-code-ide-org-test--disk-contents file)))
              ;; ...and the guard is back on.
              (should (buffer-local-value 'buffer-read-only
                                          (get-file-buffer file))))
          (kill-buffer "*org-review-test*")
          (with-current-buffer (get-file-buffer file) (read-only-mode -1)))))))

(ert-deftest claude-code-ide-org-test-review-apply-restores-read-only-on-error ()
  "The failure window is the whole objection c8a97d9d raised against
clear-then-restore, so it must actually be closed: an error thrown
mid-apply still puts the flag back.  And a buffer the user had already
made writable is left writable -- restoring means putting back what this
command changed, not imposing read-only on a buffer that never had it."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--with-queue
      (let ((item (list :type 'state :id id :ts (current-time) :to "DOING"
                        :from "TODO" :marked t :events nil)))
        (with-current-buffer (get-file-buffer file) (read-only-mode 1))
        (unwind-protect
            (with-current-buffer (get-buffer-create "*org-review-test*")
              (claude-code-ide-org-review-mode)
              (setq claude-code-ide-org--review-items (list item))
              (claude-code-ide-org--review-render)
              (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                        ((symbol-function 'claude-code-ide-org--review-apply)
                         (lambda (&rest _) (error "Boom, mid-apply"))))
                (should-error (claude-code-ide-org-review-apply)))
              (should (buffer-local-value 'buffer-read-only
                                          (get-file-buffer file))))
          (kill-buffer "*org-review-test*")
          (with-current-buffer (get-file-buffer file) (read-only-mode -1))))
      ;; Never read-only to begin with: nothing was borrowed, so nothing
      ;; is put back and the buffer stays as the user left it.
      (let ((item (list :type 'state :id id :ts (current-time) :to "WAITING"
                        :from "DOING" :marked t :events nil)))
        (should-not (buffer-local-value 'buffer-read-only (get-file-buffer file)))
        (unwind-protect
            (with-current-buffer (get-buffer-create "*org-review-test*")
              (claude-code-ide-org-review-mode)
              (setq claude-code-ide-org--review-items (list item))
              (claude-code-ide-org--review-render)
              (cl-letf (((symbol-function 'y-or-n-p)
                         (lambda (&rest _) (error "Should not have been asked"))))
                (claude-code-ide-org-review-apply))
              (should-not (buffer-local-value 'buffer-read-only
                                              (get-file-buffer file))))
          (kill-buffer "*org-review-test*"))))))

(ert-deftest claude-code-ide-org-test-review-apply-keeps-marks-when-nothing-applied ()
  "A run where every item failed does not refresh, so the marks survive a
failure the human had no chance to react to.  A run that applied
something still refreshes, which is what consumes the applied items."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--with-queue
      (unwind-protect
          (with-current-buffer (get-buffer-create "*org-review-test*")
            (claude-code-ide-org-review-mode)
            (setq claude-code-ide-org--review-items
                  (list (list :type 'state :id "no-such-id" :ts (current-time)
                              :to "DOING" :marked t :events nil)))
            (claude-code-ide-org--review-render)
            (claude-code-ide-org-review-apply)
            (should (= 1 (length claude-code-ide-org--review-items)))
            (should (plist-get (car claude-code-ide-org--review-items) :marked))
            ;; Now one that succeeds: the refresh runs and rebuilds from the
            ;; (empty) queue, so the applied item is gone rather than marked.
            (setq claude-code-ide-org--review-items
                  (list (list :type 'state :id id :ts (current-time)
                              :to "DOING" :marked t :events nil)))
            (claude-code-ide-org--review-render)
            (claude-code-ide-org-review-apply)
            (should-not claude-code-ide-org--review-items)
            (should (string-match-p
                     "DOING" (claude-code-ide-org-test--disk-contents file))))
        (kill-buffer "*org-review-test*")))))

;;; Span evidence ------------------------------------------------------------

(defun claude-code-ide-org-test--git (dir &rest args)
  "Run git in DIR with ARGS, signalling with its output when it fails."
  (with-temp-buffer
    (let ((status (apply #'call-process "git" nil t nil "-C" dir args)))
      (unless (eql status 0)
        (error "git %S failed: %s" args (buffer-string))))))

(defun claude-code-ide-org-test--git-commit (dir message iso)
  "Commit everything in DIR as MESSAGE, dated ISO.

Both date variables are set: `--since'/`--until' filter on the committer
date, and leaving the author date to drift would make the fixture
describe a different repository than the one the query sees.  Identity
and signing are forced per-command so the test does not depend on the
machine's git configuration."
  (claude-code-ide-org-test--git dir "add" "-A")
  (let ((process-environment (append (list (concat "GIT_AUTHOR_DATE=" iso)
                                           (concat "GIT_COMMITTER_DATE=" iso))
                                     process-environment)))
    (claude-code-ide-org-test--git dir
                                   "-c" "user.email=test@example.com"
                                   "-c" "user.name=Test"
                                   "-c" "commit.gpgsign=false"
                                   "commit" "-q" "-m" message)))

(defmacro claude-code-ide-org-test--with-git-repo (&rest body)
  "Run BODY in a fresh git repo holding one tracked org file.

Binds `dir' to the repository and `org' to the org file inside it, and
points `claude-code-ide-org-query-files' at that file -- which is how
`claude-code-ide-org--git-roots' is meant to find the repository at all."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "cciorg-git" t)))
          (org (expand-file-name "TODO.org" dir))
          (claude-code-ide-org-query-files (list org)))
     (unwind-protect
         (progn
           (with-temp-file org (insert "* Notes\n"))
           (claude-code-ide-org-test--git dir "init" "-q")
           ,@body)
       (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-span-evidence-finds-commits-in-the-window ()
  "The core of 5ff5a4b8: a commit inside the span's window is evidence,
one hours later is not.  Both halves matter -- a query that returned the
whole log would look like it worked on the fixture with one commit."
  (skip-unless (executable-find "git"))
  (claude-code-ide-org-test--with-git-repo
    (with-temp-file org (insert "* Notes\n\ninside\n"))
    (claude-code-ide-org-test--git-commit dir "the commit that concluded it"
                                          "2026-08-13T15:34:00-0500")
    (with-temp-file org (insert "* Notes\n\nlater\n"))
    (claude-code-ide-org-test--git-commit dir "unrelated later work"
                                          "2026-08-13T16:30:00-0500")
    (let ((rows (claude-code-ide-org--commits-in-window
                 (date-to-time "2026-08-13T15:30:00-0500")
                 (date-to-time "2026-08-13T15:35:00-0500"))))
      (should (= 1 (length rows)))
      (should (string-match-p "the commit that concluded it" (cdr (car rows))))
      (should (string-match-p "^commit " (cdr (car rows)))))))

(ert-deftest claude-code-ide-org-test-span-evidence-extends-past-the-span-end ()
  "The asymmetry is the whole finding: a commit marks when work was
*finished*, so the commit that concludes a span lands just after it.  A
window that stopped at the span's end would miss exactly the commit the
feature exists to show."
  (skip-unless (executable-find "git"))
  (claude-code-ide-org-test--with-git-repo
    (with-temp-file org (insert "* Notes\n\nwork\n"))
    (claude-code-ide-org-test--git-commit dir "landed just after the span"
                                          "2026-08-13T15:36:00-0500")
    (let* ((start (date-to-time "2026-08-13T15:30:00-0500"))
           (end (date-to-time "2026-08-13T15:34:00-0500"))
           (claude-code-ide-org-span-evidence-slack 300)
           (lines (claude-code-ide-org--span-evidence start end)))
      (should (= 1 (length lines)))
      (should (string-match-p "15:36  commit .*landed just after the span"
                              (car lines)))
      ;; ...and the slack is a window, not an open end.
      (let ((claude-code-ide-org-span-evidence-slack 0))
        (should-not (claude-code-ide-org--span-evidence start end))))))

(ert-deftest claude-code-ide-org-test-span-evidence-finds-heading-creations ()
  "A `:CREATED:' stamp inside the window is the strongest evidence there
is -- a heading written during that time names what was being thought
about.  Read as a property, so a heading whose *body* quotes a timestamp
contributes nothing."
  (let* ((dir (file-name-as-directory (make-temp-file "cciorg-created" t)))
         (file (expand-file-name "TODO.org" dir))
         (claude-code-ide-org-query-files (list file))
         (org-id-locations-file (expand-file-name ".org-id-locations" dir))
         (org-id-locations (make-hash-table :test 'equal))
         (org-agenda-files nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+TODO: TODO | DONE\n\n"
                    "* TODO Written during the span\n"
                    ":PROPERTIES:\n:ID: aaaa\n"
                    ":CREATED:  [2026-08-13 Thu 15:33]\n:END:\n\n"
                    "Body quoting [2026-08-13 Thu 15:32] as prose.\n\n"
                    "* TODO Written the day before\n"
                    ":PROPERTIES:\n:ID: bbbb\n"
                    ":CREATED:  [2026-08-12 Wed 15:33]\n:END:\n"))
          (let ((rows (claude-code-ide-org--creations-in-window
                       (date-to-time "2026-08-13T15:30:00-0500")
                       (date-to-time "2026-08-13T15:35:00-0500"))))
            (should (= 1 (length rows)))
            (should (equal (cdr (car rows)) "created Written during the span"))))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-review-shows-evidence-only-for-unassigned-spans ()
  "An unassigned span is the item that poses a question, so it is the
only one that gets an answer drawn under it.  An assigned span has
already been answered and a state item has no window to look in."
  (let ((start (current-time)))
    (cl-letf (((symbol-function 'claude-code-ide-org--span-evidence)
               (lambda (&rest _) (list "15:33  created Some heading"))))
      (claude-code-ide-org-test--with-review-buffer
          (list (list :type 'clock :id nil :start start :end start
                      :unassigned t :note "unassigned" :events nil)
                (list :type 'clock :id "cccc" :start start :end start
                      :note "assigned" :suggested t :events nil)
                (list :type 'state :id "cccc" :ts start :to "DOING"
                      :from "TODO" :events nil))
        (let ((text (buffer-substring-no-properties (point-min) (point-max)))
              (n 0)
              (pos 0))
          (while (string-match "created Some heading" text pos)
            (setq n (1+ n)
                  pos (match-end 0)))
          (should (= n 1)))))))

(ert-deftest claude-code-ide-org-test-review-evidence-lines-are-not-items ()
  "Evidence must not become something `m' can mark or `n' can land on.
Left unpropertized it behaves exactly as the group headings do; carrying
the item property it would silently double the item count and let a
human mark the same span twice."
  (let ((start (current-time)))
    (cl-letf (((symbol-function 'claude-code-ide-org--span-evidence)
               (lambda (&rest _) (list "15:33  created Some heading"))))
      (claude-code-ide-org-test--with-review-buffer
          (list (list :type 'clock :id nil :start start :end start
                      :unassigned t :note "unassigned" :events nil)
                (list :type 'state :id "cccc" :ts start :to "DOING"
                      :from "TODO" :events nil))
        (goto-char (point-min))
        (should (re-search-forward "created Some heading" nil t))
        (beginning-of-line)
        (should-not (claude-code-ide-org--review-item-at-point))
        ;; And stepping forward from the span steps over the evidence onto
        ;; the next real item.
        (claude-code-ide-org-test--goto-nth-item 0)
        (claude-code-ide-org--review-forward-item)
        (should (eq 'state (plist-get (claude-code-ide-org--review-item-at-point)
                                      :type)))))))

(ert-deftest claude-code-ide-org-test-review-evidence-is-computed-once-per-window ()
  "`claude-code-ide-org--review-render' runs on every mark keystroke, and
the evidence costs a `git log' plus a walk of every tracked heading.
Recomputing per keystroke is what would make marking a run of items feel
broken.  Keyed on the window, so narrowing a span really does re-read."
  (let* ((start (current-time))
         (calls 0))
    (cl-letf (((symbol-function 'claude-code-ide-org--span-evidence)
               (lambda (&rest _) (setq calls (1+ calls)) (list "15:33  x"))))
      (claude-code-ide-org-test--with-review-buffer
          (list (list :type 'clock :id nil :start start :end start
                      :unassigned t :note "unassigned" :events nil))
        (claude-code-ide-org--review-render)
        (claude-code-ide-org--review-render)
        (should (= 1 calls))
        ;; A different window is a different question.
        (plist-put (car claude-code-ide-org--review-items)
                   :end (time-add start 60))
        (claude-code-ide-org--review-render)
        (should (= 2 calls))))))

(ert-deftest claude-code-ide-org-test-span-evidence-caps-its-output ()
  "A span that swept up thirty commits has stopped answering the question
the evidence exists to answer, so the overflow is reported as a count
rather than drawn.  Silently trimming would be the one outcome that
misleads."
  (let ((claude-code-ide-org-span-evidence-limit 3)
        (start (current-time)))
    (cl-letf (((symbol-function 'claude-code-ide-org--commits-in-window)
               (lambda (&rest _)
                 (let (rows)
                   (dotimes (i 5)
                     (push (cons (time-add start i) (format "commit  %d" i)) rows))
                   rows)))
              ((symbol-function 'claude-code-ide-org--creations-in-window)
               (lambda (&rest _) nil)))
      (let ((lines (claude-code-ide-org--span-evidence start start)))
        (should (= 4 (length lines)))
        (should (string-match-p "\\.\\.\\. 2 more in this window"
                                (car (last lines))))))))

(defmacro claude-code-ide-org-test--with-stub-evidence (times &rest body)
  "Run BODY with the evidence sources stubbed to fire at TIMES.
TIMES is a list of (TIME . DESCRIPTION); no git and no org files are
touched, so gap arithmetic is tested on its own terms."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'claude-code-ide-org--commits-in-window)
              (lambda (&rest _) ,times))
             ((symbol-function 'claude-code-ide-org--creations-in-window)
              (lambda (&rest _) nil)))
     ,@body))

(ert-deftest claude-code-ide-org-test-suggestion-brackets-on-an-unknown-keyword ()
  "The bracket must fire for a keyword nobody has invented yet.  While it
named the six non-working keywords explicitly, adding a seventh to
`#+TODO:' -- REVIEW is under discussion on c954f650 -- would have left
the guess latching on that heading forever, and failing by latching is
the failure mode hardest to notice.

Observed through the function's own answer.  This used to need a second
heading, because the cleared answer fell through to the most recent
`todo' of any state and the only way to see the clear fire was to watch
it name id-b instead.  That fallback is gone (2026-08-14), so the clear
is now observable directly: id-a stops being named and nothing replaces
it.  id-b is kept in the fixture anyway -- a later `TODO' event must not
resurrect a heading as the answer either, which the fallback would have
done."
  (let* ((base (date-to-time "2026-08-14T09:00:00-0500"))
         (events (list (list :kind "todo" :id "id-a" :state "DOING" :ts base)
                       (list :kind "todo" :id "id-a" :state "REVIEW"
                             :ts (time-add base 60))
                       (list :kind "todo" :id "id-b" :state "TODO"
                             :ts (time-add base 120)))))
    ;; While id-a is DOING it is the answer, whatever else has happened.
    (should (equal "id-a" (claude-code-ide-org--review-suggest-heading
                           (time-add base 30) events)))
    ;; Once it reaches REVIEW -- a keyword this code has never heard of --
    ;; it stops being the answer, and id-b's plain TODO does not become
    ;; one: only DOING asserts that work is happening.
    (should (null (claude-code-ide-org--review-suggest-heading
                   (time-add base 180) events)))))

(ert-deftest claude-code-ide-org-test-span-gaps-report-unattested-stretches ()
  "The real 17:18-17:32 case: commits at +4m and +8m leave a 6m tail with
nothing in it.  The two 4m stretches are below the threshold and stay
quiet -- a gap has to outlast the ordinary pause between a thought and
its commit before it means anything."
  (let* ((start (date-to-time "2026-08-13T17:18:00-0500"))
         (end (time-add start (* 14 60)))
         (claude-code-ide-org-span-evidence-gap 300))
    (claude-code-ide-org-test--with-stub-evidence
        (list (cons (time-add start (* 4 60)) "commit  aaa first")
              (cons (time-add start (* 8 60)) "commit  bbb second"))
      (let ((lines (claude-code-ide-org--span-evidence start end)))
        (should (= 3 (length lines)))
        (should (string-match-p "first" (nth 0 lines)))
        (should (string-match-p "second" (nth 1 lines)))
        ;; The gap renders last, after the evidence line it starts from.
        (should (string-match-p "(nothing for 6m, 17:26-17:32)" (nth 2 lines)))))))

(ert-deftest claude-code-ide-org-test-span-with-no-evidence-says-so ()
  "The case that matters most.  An evidence-free span used to render no
lines at all, which made \"nothing was found here\" look exactly like
\"nobody looked\" -- and the first real use of this feature was a batch
applied without critical evaluation.

The line must therefore always appear.  What it says changed 2026-08-24
(TODO.org :ID: a279216c): a gap covering the whole span no longer prints
the span's own two timestamps back at the reader, one line under the
line already showing them.  The absence stays visible; only the
duplication goes."
  (let* ((start (date-to-time "2026-08-13T17:18:00-0500"))
         (end (time-add start (* 14 60)))
         (claude-code-ide-org-span-evidence-gap 300))
    (claude-code-ide-org-test--with-stub-evidence nil
      (let ((lines (claude-code-ide-org--span-evidence start end)))
        (should (= 1 (length lines)))
        (should (string-match-p "(no evidence found in this window)" (car lines)))
        ;; The redundant restatement is what was removed, and it must
        ;; stay removed: these are the span's own endpoints.
        (should-not (string-match-p "17:18-17:32" (car lines)))))))

(ert-deftest claude-code-ide-org-test-span-gaps-ignore-the-slack-window ()
  "A commit after the span concluded it rather than filled it, so it
closes no gap.  Measuring gaps against the window instead of the span
would silently absolve exactly the spans with nothing in them."
  (let* ((start (date-to-time "2026-08-13T17:18:00-0500"))
         (end (time-add start (* 10 60)))
         (claude-code-ide-org-span-evidence-gap 300)
         (claude-code-ide-org-span-evidence-slack 300))
    (claude-code-ide-org-test--with-stub-evidence
        (list (cons (time-add end 120) "commit  ccc just after"))
      (let ((lines (claude-code-ide-org--span-evidence start end)))
        (should (= 2 (length lines)))
        ;; The gap covers the whole span, so it says only that, and
        ;; comes first...
        (should (string-match-p "(no evidence found in this window)" (nth 0 lines)))
        ;; ...and the slack commit is still shown, just not credited.
        (should (string-match-p "just after" (nth 1 lines)))))))

(ert-deftest claude-code-ide-org-test-span-gaps-respect-the-threshold ()
  "Below the threshold nothing is reported, or every span would carry
gap lines and the signal would be back to noise."
  (let* ((start (date-to-time "2026-08-13T17:18:00-0500"))
         (end (time-add start (* 4 60))))
    (claude-code-ide-org-test--with-stub-evidence nil
      (let ((claude-code-ide-org-span-evidence-gap 300))
        (should-not (claude-code-ide-org--span-evidence start end)))
      (let ((claude-code-ide-org-span-evidence-gap 120))
        (should (= 1 (length (claude-code-ide-org--span-evidence start end))))))))

(ert-deftest claude-code-ide-org-test-span-evidence-degrades-rather-than-signals ()
  "Display code degrades, it does not signal -- half a review buffer is
worse than no evidence.  Everything here reaches out to the world (git,
org-id, other people's files), so the failure has to be contained at the
render boundary rather than at each call site."
  (let ((start (current-time)))
    (cl-letf (((symbol-function 'claude-code-ide-org--span-evidence)
               (lambda (&rest _) (error "git exploded"))))
      (claude-code-ide-org-test--with-review-buffer
          (list (list :type 'clock :id nil :start start :end start
                      :unassigned t :note "unassigned" :events nil))
        (should (string-match-p
                 "span"
                 (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest claude-code-ide-org-test-git-roots-follows-the-symlink ()
  "`~/org/claude-code-ide-org/TODO.org' is a symlink into the repo, so
walking up from the symlink's own directory finds no .git at all.  The
truename is what makes the query land in the right repository."
  (skip-unless (executable-find "git"))
  (claude-code-ide-org-test--with-git-repo
    (let* ((link-dir (file-name-as-directory (make-temp-file "cciorg-link" t)))
           (link (expand-file-name "TODO.org" link-dir))
           (claude-code-ide-org-query-files (list link)))
      (unwind-protect
          (progn
            (make-symbolic-link org link)
            (should (equal (claude-code-ide-org--git-roots)
                           (list (file-truename dir)))))
        (delete-directory link-dir t)))))
;;; Capture/amend write-through and queueing ---------------------------------

(defun claude-code-ide-org-test--capture-line (ts id title &optional target tags note)
  "Return one encoded `capture' queue line, as bin/hooks/queue-append writes it."
  (json-encode `((ts . ,ts) (kind . "capture") (id . ,id) (state . nil)
                 (from . nil) (note . ,note) (title . ,title)
                 (target . ,target) (tags . ,tags) (text . nil)
                 (session_id . "sess-a") (agent_id . nil) (agent_type . nil)
                 (source . "mcp__emacs-tools__org_capture"))))

(defun claude-code-ide-org-test--amend-line (ts id text &optional note)
  "Return one encoded `amend' queue line, as bin/hooks/queue-append writes it."
  (json-encode `((ts . ,ts) (kind . "amend") (id . ,id) (state . nil)
                 (from . nil) (note . ,note) (title . nil) (target . nil)
                 (tags . nil) (text . ,text)
                 (session_id . "sess-a") (agent_id . nil) (agent_type . nil)
                 (source . "mcp__emacs-tools__org_amend"))))

(defun claude-code-ide-org-test--make-busy (file)
  "Leave FILE's buffer modified, the way a half-finished human edit does."
  (with-current-buffer (find-file-noselect file)
    (goto-char (point-max))
    (insert "\n")
    (should (buffer-modified-p))))

(ert-deftest claude-code-ide-org-test-capture-writes-through-when-free ()
  "The common case has to stay immediate: an open, unmodified buffer is
not busy.  A gate that treated any live buffer as contention would defer
every capture in normal use, which is the behaviour change nobody asked
for (TODO.org :ID: b5f94b88)."
  (claude-code-ide-org-test--with-capture-file
    ;; Buffer exists and is clean -- the distinction under test.
    (find-file-noselect capture-file)
    (let ((result (claude-code-ide-org-capture "Immediate task")))
      (should (string-prefix-p claude-code-ide-org--reply-captured result))
      (should (string-match-p "^\\* Immediate task[ \t]*$"
                              (claude-code-ide-org-test--disk-contents capture-file))))))

(ert-deftest claude-code-ide-org-test-capture-defers-when-busy ()
  "With unsaved human edits in the buffer, capture queues instead of
writing -- and writes *nothing*, which is the half that matters.  A
reply that says queued while the heading also landed is the
double-apply this gate exists to prevent."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-test--make-busy capture-file)
    (let ((result (claude-code-ide-org-capture "Deferred task")))
      (should (string-prefix-p claude-code-ide-org--reply-queued-capture result))
      ;; The id is still minted and reported, so the caller can act on it.
      (should (string-match "(ID: \\([^)]+\\))" result))
      (should (> (length (match-string 1 result)) 0))
      (should-not (string-match-p "Deferred task"
                                  (claude-code-ide-org-test--disk-contents capture-file))))))

(ert-deftest claude-code-ide-org-test-deferred-capture-applies-with-its-own-id-and-time ()
  "Both halves come from the *event*: the pre-minted :ID:, so a caller
already told that id keeps being right, and the :CREATED: stamp, so the
heading records when it was thought of rather than when a human got
round to reviewing it."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-test--with-queue
      (let* ((ts "2026-01-15T09:14:00-0500")
             (expected-created
              (format-time-string "[%Y-%m-%d %a %H:%M]"
                                  (claude-code-ide-org--parse-iso8601 ts))))
        (claude-code-ide-org-test--queue-write
         "sess-a" (claude-code-ide-org-test--capture-line
                   ts "cap-id-1" "Queued heading" nil "code,research"))
        (let ((items (claude-code-ide-org--review-items-from-queue)))
          (should (= 1 (length items)))
          (should (eq 'capture (plist-get (car items) :type)))
          (should-not (claude-code-ide-org--review-apply-item (car items))))
        (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
          (should (string-match-p "^\\* Queued heading +:code:research:$" disk))
          (should (string-match-p "^:ID: +cap-id-1[ \t]*$" disk))
          (should (string-match-p (concat "^:CREATED: +" (regexp-quote expected-created))
                                  disk))
          ;; ...and emphatically not stamped at apply time.
          (should-not (string-match-p
                       (regexp-quote (format-time-string "[%Y-%m-%d %a"))
                       disk)))))))

(ert-deftest claude-code-ide-org-test-set-todo-tolerates-a-pending-capture ()
  "The silent-drop regression.  A deferred capture's heading does not
exist, so `org_set_todo' would answer `Error: unknown id' -- and
bin/hooks/queue-append drops any event whose reply starts with `Error:',
losing the state with nothing to show for it."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-test--with-queue
      (claude-code-ide-org-test--queue-write
       "sess-a" (claude-code-ide-org-test--capture-line
                 "2026-01-15T09:14:00-0500" "cap-id-2" "Not written yet"))
      (let ((reply (claude-code-ide-org-set-todo "cap-id-2" "DOING")))
        (should (string-prefix-p "Queued todo -> DOING (was none)" reply))
        (should (string-match-p "Not written yet" reply)))
      ;; clock_in takes the same path.
      (should (string-prefix-p
               "Queued clock_in" (claude-code-ide-org-clock-in "cap-id-2")))
      ;; A genuinely unknown id still errors -- the tolerance is narrow.
      (should (string-prefix-p "Error:" (claude-code-ide-org-set-todo "no-such-id" "DOING")))
      ;; ...and so does a keyword the target file does not declare.
      (should (string-prefix-p "Error:" (claude-code-ide-org-set-todo "cap-id-2" "BOGUS"))))))

(ert-deftest claude-code-ide-org-test-amend-names-a-pending-capture ()
  "Amending a queued capture refuses by name, not as an unknown id.

TODO.org :ID: 798bb7a1. `org_set_todo' and `org_clock_in' have tolerated
a pending capture since the silent-drop regression; `org_amend' did not,
so it answered \"no org heading found\" for an :ID: that `org_capture'
had returned seconds earlier. True, and useless -- it reads as a typo.

Amend genuinely cannot proceed, since there is no body to write into, so
this stays a refusal. What changes is that the refusal says which one it
is and what unblocks it. Hit live on 2026-08-27 while filing a heading
about having failed to file things."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-test--with-queue
      (claude-code-ide-org-test--queue-write
       "sess-a" (claude-code-ide-org-test--capture-line
                 "2026-01-15T09:14:00-0500" "cap-id-3" "Not written yet"))
      (let ((reply (claude-code-ide-org-amend "cap-id-3" "some prose")))
        (should (string-prefix-p "Error:" reply))
        (should (string-match-p "Not written yet" reply))
        (should (string-match-p "queued this session" reply))
        (should (string-match-p "Apply the queue" reply))
        ;; NOT the generic message, which is what sent a reader hunting.
        (should-not (string-match-p "no org heading found" reply)))
      ;; The tolerance stays narrow: an unknown id still reports plainly.
      (let ((reply (claude-code-ide-org-amend "no-such-id" "some prose")))
        (should (string-prefix-p "Error:" reply))
        (should-not (string-match-p "queued this session" reply))))))

(ert-deftest claude-code-ide-org-test-refresh-slice-names-unrendered-members ()
  "A member it cannot render is reported, with its id.

TODO.org :ID: 798bb7a1. `refresh-slice' skipped a member whose referent
carries no keyword -- a capture or `todo' event still queued -- and said
only \"0 member lines rewritten\", leaving the placeholder text standing
as though it were the referent's real title. That is the \"a slice line
disagrees with its referent\" failure the conventions exist to prevent,
arriving through a door they do not describe.

Counted rather than repaired: the honest rendering of a heading whose
keyword has not landed is not something this function can invent. Named
rather than counted, because \"1 skipped\" sends a reader hunting through
a 27-member list."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* TODO A real referent\n:PROPERTIES:\n"
            ":ID:       aaa11111-1111-4111-8111-111111111111\n:END:\n"
            "* A keywordless referent\n:PROPERTIES:\n"
            ":ID:       bbb22222-2222-4222-8222-222222222222\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (org-with-point-at (org-id-find id 'marker)
      (org-entry-put nil "KIND" "slice")
      (org-end-of-meta-data t)
      (insert "- [ ] [[id:aaa11111-1111-4111-8111-111111111111][aaa11111]] placeholder\n"
              "- [ ] [[id:bbb22222-2222-4222-8222-222222222222][bbb22222]] placeholder\n")
      (save-buffer))
    (let* ((claude-code-ide-org-query-files (list file))
           (summary (claude-code-ide-org-refresh-slice)))
      ;; The one with a keyword rendered.
      (should (string-match-p "1 member line rewritten" summary))
      ;; The one without is named, with the reason and the remedy.
      (should (string-match-p "1 member left unrendered" summary))
      (should (string-match-p "bbb22222" summary))
      (should (string-match-p "keywordless on disk" summary))
      (should-not (string-match-p "aaa11111" summary)))))

(ert-deftest claude-code-ide-org-test-capture-then-todo-apply-in-one-batch ()
  "A capture at T0 and a todo at T1 on the same id are one dependency
chain.  The todo must not render STALE -- the heading it names is
unresolved rather than moved -- and applying the pair in order must
leave a heading that exists and holds the state."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-test--with-queue
      (claude-code-ide-org-test--queue-write
       "sess-a"
       (claude-code-ide-org-test--capture-line
        "2026-01-15T09:14:00-0500" "cap-id-3" "Chained heading")
       (json-encode '((ts . "2026-01-15T09:15:00-0500") (kind . "todo")
                      (id . "cap-id-3") (state . "DOING") (from . "none")
                      (note . "starting") (session_id . "sess-a")
                      (agent_id . nil) (agent_type . nil) (source . "todo"))))
      (let ((items (claude-code-ide-org--review-items-from-queue)))
        (should (= 2 (length items)))
        (should (eq 'capture (plist-get (nth 0 items) :type)))
        (should (eq 'state (plist-get (nth 1 items) :type)))
        (claude-code-ide-org--review-projected-staleness items)
        (should-not (claude-code-ide-org--review-state-stale-p (nth 1 items)))
        (let ((result (claude-code-ide-org--review-apply items)))
          (should (= 2 (plist-get result :applied)))
          (should-not (plist-get result :errors))))
      (should (string-match-p "^\\* DOING Chained heading"
                              (claude-code-ide-org-test--disk-contents capture-file))))))

(ert-deftest claude-code-ide-org-test-capture-refuses-a-vanished-target ()
  "Resolution failure leaves the item pending rather than filing the
heading somewhere nobody chose.  A capture can easily outlive the
heading it was filed under, and a confidently-wrong destination is the
exact failure this architecture exists to prevent."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-test--with-queue
      (claude-code-ide-org-test--queue-write
       "sess-a" (claude-code-ide-org-test--capture-line
                 "2026-01-15T09:14:00-0500" "cap-id-4" "Orphan"
                 "No Such Category"))
      (let* ((items (claude-code-ide-org--review-items-from-queue))
             (result (claude-code-ide-org--review-apply items)))
        (should (= 0 (plist-get result :applied)))
        (should (= 1 (length (plist-get result :errors))))
        (should (string-prefix-p "Error:" (car (plist-get result :errors)))))
      (should-not (string-match-p "Orphan"
                                  (claude-code-ide-org-test--disk-contents capture-file)))
      ;; Still pending, so the human can retarget or dismiss it.
      (should (= 1 (length (claude-code-ide-org--review-items-from-queue)))))))

(ert-deftest claude-code-ide-org-test-amend-appends-at-the-body-end ()
  "The text belongs to the heading it names: after its drawers, before
its first child.  Landing inside :PROPERTIES: or :LOGBOOK: would corrupt
them, and landing under the child would attribute the prose to the wrong
heading while looking perfectly fine."
  (claude-code-ide-org-test--with-capture-file
    (with-temp-file capture-file
      (insert "#+TODO: TODO | DONE\n\n"
              "* Parent\n:PROPERTIES:\n:ID: parent-1\n:END:\n"
              ":LOGBOOK:\n- note\n:END:\n\n"
              "Existing body.\n\n"
              "** Child\n:PROPERTIES:\n:ID: child-1\n:END:\n\nChild body.\n"))
    (org-id-update-id-locations (list capture-file))
    (should (string-prefix-p claude-code-ide-org--reply-amended
                             (claude-code-ide-org-amend "parent-1" "Appended prose.")))
    (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
      ;; Between the existing body and the child, in that order.
      (should (string-match-p
               "Existing body\\.\n+Appended prose\\.\n+\\*\\* Child" disk))
      ;; And nowhere near the drawers.
      (should-not (string-match-p ":LOGBOOK:\n- note\nAppended" disk)))))

(ert-deftest claude-code-ide-org-test-amend-replace-rewrites-only-prose ()
  "Revision replaces the body's prose and cannot reach a drawer.

TODO.org :ID: 3063c3e5.  This is the whole safety case for offering a
destructive operation at all: `--heading-body-bounds' begins after
`org-end-of-meta-data', which skips every leading drawer, so
:PROPERTIES:, :LOGBOOK: and :PLAN: are outside the writable region by
construction rather than by care.  A finished heading can therefore be
revised without endangering the plan it was wrapped with."
  (claude-code-ide-org-test--with-capture-file
    (with-temp-file capture-file
      (insert "#+TODO: TODO | DONE\n\n"
              "* Parent\n:PROPERTIES:\n:ID: parent-1\n:END:\n"
              ":LOGBOOK:\n- note\n:END:\n"
              ":PLAN:\nthe original plan\n:END:\n\n"
              "Old body line one.\nOld body line two.\n\n"
              "** Child\n:PROPERTIES:\n:ID: child-1\n:END:\n\nChild body.\n"))
    (org-id-update-id-locations (list capture-file))
    (should (string-prefix-p
             "Revised: "
             (claude-code-ide-org-amend "parent-1" "The outcome, first." nil t)))
    (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
      ;; The prose is replaced, not appended to.
      (should (string-match-p "The outcome, first\\." disk))
      (should-not (string-match-p "Old body line one" disk))
      (should-not (string-match-p "Old body line two" disk))
      ;; Every drawer survives verbatim.
      (should (string-match-p ":PROPERTIES:\n:ID: parent-1\n:END:" disk))
      (should (string-match-p ":LOGBOOK:\n- note\n:END:" disk))
      (should (string-match-p ":PLAN:\nthe original plan\n:END:" disk))
      ;; The blank line separating the last drawer from the prose
      ;; survives.  This is what pins the replacement to BEG rather than
      ;; OPEN: deleting from OPEN keeps every drawer intact -- so the
      ;; safety assertions above still pass -- and silently butts the new
      ;; prose against `:END:'.  A break-it-on-a-copy pass found that the
      ;; drawer checks alone could not tell the two apart.
      (should (string-match-p ":PLAN:\nthe original plan\n:END:\n\nThe outcome, first\\." disk))
      ;; And the child is untouched, as with an append.
      (should (string-match-p "\\*\\* Child" disk))
      (should (string-match-p "Child body\\." disk)))))

(ert-deftest claude-code-ide-org-test-amend-replace-appends-when-there-is-no-body ()
  "Revising a heading with no body yet degrades to an append and says so.

`--heading-body-bounds' returns nil when there is nothing there, and a
revision that silently did nothing would be the worst of the three
possible behaviours -- the caller would believe the text had landed."
  (claude-code-ide-org-test--with-capture-file
    (with-temp-file capture-file
      (insert "#+TODO: TODO | DONE\n\n"
              "* Bare\n:PROPERTIES:\n:ID: bare-1\n:END:\n"))
    (org-id-update-id-locations (list capture-file))
    (let ((reply (claude-code-ide-org-amend "bare-1" "First prose." nil t)))
      (should (string-match-p "had no body" reply)))
    (should (string-match-p "First prose\\."
                            (claude-code-ide-org-test--disk-contents capture-file)))))

(ert-deftest claude-code-ide-org-test-amend-replace-defers-when-busy ()
  "Revision defers on unsaved changes exactly as an append does.

It *must*: racing a human's unsaved edits is the one case where
replacing a body destroys work git has never seen, so the queue gate is
load-bearing here in a way it merely is prudent for an append."
  (claude-code-ide-org-test--with-capture-file
    (with-temp-file capture-file
      (insert "#+TODO: TODO | DONE\n\n"
              "* Parent\n:PROPERTIES:\n:ID: parent-1\n:END:\n\nOld body.\n"))
    (org-id-update-id-locations (list capture-file))
    (let ((buf (find-file-noselect capture-file)))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (goto-char (point-max))
              (insert "\nthe human is mid-sentence"))   ; unsaved
            (let ((reply (claude-code-ide-org-amend "parent-1" "New body." nil t)))
              (should (string-prefix-p claude-code-ide-org--reply-queued-amend reply))
              (should (string-match-p "replacing the body" reply)))
            ;; Nothing was written: the old body survives on disk.
            (should (string-match-p
                     "Old body\\."
                     (claude-code-ide-org-test--disk-contents capture-file))))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest claude-code-ide-org-test-amend-defers-when-busy ()
  "Same gate as capture, and the same load-bearing half: nothing is
written when it defers."
  (claude-code-ide-org-test--with-capture-file
    (with-temp-file capture-file
      (insert "#+TODO: TODO | DONE\n\n* Parent\n:PROPERTIES:\n:ID: parent-2\n:END:\n\nBody.\n"))
    (org-id-update-id-locations (list capture-file))
    (claude-code-ide-org-test--make-busy capture-file)
    (let ((reply (claude-code-ide-org-amend "parent-2" "line one\nline two")))
      (should (string-prefix-p claude-code-ide-org--reply-queued-amend reply))
      (should (string-match-p "2 lines" reply)))
    (should-not (string-match-p "line one"
                                (claude-code-ide-org-test--disk-contents capture-file)))))

(ert-deftest claude-code-ide-org-test-amend-applies-from-the-queue ()
  "The deferred amendment reaches the same place the immediate one would."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-test--with-queue
      (with-temp-file capture-file
        (insert "#+TODO: TODO | DONE\n\n* Parent\n:PROPERTIES:\n:ID: parent-3\n:END:\n\nBody.\n"))
      (org-id-update-id-locations (list capture-file))
      (claude-code-ide-org-test--queue-write
       "sess-a" (claude-code-ide-org-test--amend-line
                 "2026-01-15T09:14:00-0500" "parent-3" "Queued prose."))
      (let ((items (claude-code-ide-org--review-items-from-queue)))
        (should (= 1 (length items)))
        (should (eq 'amend (plist-get (car items) :type)))
        (should-not (claude-code-ide-org--review-apply-item (car items))))
      (should (string-match-p "Body\\.\n+Queued prose\\."
                              (claude-code-ide-org-test--disk-contents capture-file))))))

(ert-deftest claude-code-ide-org-test-review-renders-capture-and-amend ()
  "Both need a line a human can decide from: a capture names where it
will land and flags a target that no longer resolves, an amend names the
*title* of what it will change so a body that has moved on is visible."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-test--with-review-buffer
        (list (list :type 'capture :id "cap-a" :ts (current-time)
                    :title "New thing" :target nil :note "why" :events nil)
              (list :type 'capture :id "cap-b" :ts (current-time)
                    :title "Orphan" :target "No Such Category" :events nil)
              (list :type 'amend :id "nope" :ts (current-time)
                    :text "a\nb\nc" :note "why" :events nil))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "capture \"New thing\" +-> top of file" text))
        (should (string-match-p "! capture \"Orphan\" +-> No Such Category (UNRESOLVED)" text))
        (should (string-match-p "amend +\"(unknown heading)\" +(3 lines)" text))))))

;;; Assignment candidates (TODO.org :ID: 0d055205, :ID: 49cbe319) ------------

(defun claude-code-ide-org-test--t (hhmm)
  "A time on 2026-08-15 at HHMM, e.g. \"14:31\"."
  (org-time-string-to-time (format "[2026-08-15 Sat %s]" hhmm)))

(ert-deftest claude-code-ide-org-test-heading-bracket-spans-created-and-clocks ()
  "The bracket is [CREATED..latest activity], not [earliest clock..latest
clock].  A heading created during a span but not yet clocked has no clock
range at all, and that is exactly the heading most likely to be the
answer -- work first, heading afterwards."
  (let ((created (claude-code-ide-org-test--t "09:00"))
        (range (cons (claude-code-ide-org-test--t "11:00")
                     (claude-code-ide-org-test--t "12:00"))))
    (let ((b (claude-code-ide-org--heading-bracket range created)))
      (should (equal (format-time-string "%H:%M" (car b)) "09:00"))
      (should (equal (format-time-string "%H:%M" (cdr b)) "12:00")))
    ;; Never clocked: the bracket collapses onto :CREATED: rather than
    ;; vanishing, so the heading still has a position to be ranked by.
    (let ((b (claude-code-ide-org--heading-bracket nil created)))
      (should (equal (format-time-string "%H:%M" (car b)) "09:00"))
      (should (equal (format-time-string "%H:%M" (cdr b)) "09:00")))
    (should-not (claude-code-ide-org--heading-bracket nil nil))))

(ert-deftest claude-code-ide-org-test-interval-gap-is-zero-on-overlap ()
  "Overlap is the strongest possible signal and must dominate: a heading
clocked *inside* the span scores 0 and nothing can beat it."
  (should (= 0 (claude-code-ide-org--interval-gap
                (claude-code-ide-org-test--t "10:00") (claude-code-ide-org-test--t "11:00")
                (claude-code-ide-org-test--t "10:30") (claude-code-ide-org-test--t "12:00"))))
  ;; Disjoint: the gap is to the nearest endpoint, in seconds, and is
  ;; symmetric -- which side is later must not change the answer.
  (should (= 1800 (claude-code-ide-org--interval-gap
                   (claude-code-ide-org-test--t "10:00") (claude-code-ide-org-test--t "11:00")
                   (claude-code-ide-org-test--t "11:30") (claude-code-ide-org-test--t "12:00"))))
  (should (= 1800 (claude-code-ide-org--interval-gap
                   (claude-code-ide-org-test--t "11:30") (claude-code-ide-org-test--t "12:00")
                   (claude-code-ide-org-test--t "10:00") (claude-code-ide-org-test--t "11:00")))))

(ert-deftest claude-code-ide-org-test-assign-offers-heading-created-after-the-span ()
  "The regression: a heading created after the span ended was excluded
outright as a `hard impossibility'.  It is the normal case -- the work
happens, then the heading is written -- and this project's own convention
mandates writing one when a task is described, which is during or after."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* TODO Written afterwards\n:PROPERTIES:\n"
            ":ID:       55555555-5555-4555-8555-555555555555\n"
            ":CREATED:  [2026-08-15 Sat 16:00]\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let* ((claude-code-ide-org-query-files (list file))
           (cands (claude-code-ide-org--assign-candidates
                   (claude-code-ide-org-test--t "09:19")
                   (claude-code-ide-org-test--t "09:20"))))
      (should (cl-find "55555555-5555-4555-8555-555555555555" cands
                       :key #'cdr :test #'equal)))))

(ert-deftest claude-code-ide-org-test-assign-ranks-nearest-bracket-first ()
  "49cbe319: rank by proximity of the heading's bracket to the span, not
by creation recency.  The heading clocked *during* the span must beat one
created more recently but hours away -- creation recency ranked those the
wrong way round."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* TODO Clocked during the span\n:PROPERTIES:\n"
            ":ID:       66666666-6666-4666-8666-666666666666\n"
            ":CREATED:  [2026-08-15 Sat 09:00]\n:END:\n"
            ":LOGBOOK:\n"
            "CLOCK: [2026-08-15 Sat 14:35]--[2026-08-15 Sat 14:50] =>  0:15\n"
            ":END:\n"
            "* TODO Created later but far away\n:PROPERTIES:\n"
            ":ID:       77777777-7777-4777-8777-777777777777\n"
            ":CREATED:  [2026-08-15 Sat 19:00]\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let* ((claude-code-ide-org-query-files (list file))
           (cands (claude-code-ide-org--assign-candidates
                   (claude-code-ide-org-test--t "14:31")
                   (claude-code-ide-org-test--t "15:31")))
           (ids (mapcar #'cdr cands)))
      (should (< (cl-position "66666666-6666-4666-8666-666666666666" ids :test #'equal)
                 (cl-position "77777777-7777-4777-8777-777777777777" ids :test #'equal))))))

(ert-deftest claude-code-ide-org-test-ordered-collection-declares-identity-sort ()
  "The assignment prompt's candidates are sorted best-first before they are
handed to `completing-read', and a bare alist carries no completion
metadata -- so Vertico re-sorts by history, then string length, then
alphabetically, discarding the ranking entirely (TODO.org :ID: 85702dba).

Two assertions, because either alone would pass on a broken
implementation: the metadata must declare `identity' sorting, *and* the
collection must still complete normally rather than having been traded
away for the metadata."
  (let* ((candidates '(("first candidate"  . "id-1")
                       ("z second"         . "id-2")
                       ("aaa third"        . "id-3")))
         (coll (claude-code-ide-org--ordered-collection candidates))
         (md (funcall coll "" nil 'metadata)))
    (should (eq 'metadata (car md)))
    (should (eq #'identity (cdr (assq 'display-sort-function (cdr md)))))
    (should (eq #'identity (cdr (assq 'cycle-sort-function (cdr md)))))
    ;; Still a working collection: order preserved, and it completes.
    (should (equal '("first candidate" "z second" "aaa third")
                   (all-completions "" coll nil)))
    (should (equal '("z second") (all-completions "z" coll nil)))))

(ert-deftest claude-code-ide-org-test-assign-candidates-lead-with-the-id-prefix ()
  "Every candidate row starts with the 8-character :ID: prefix.

Not reachability -- the id was perfectly reachable trailing in braces.
It is that every other place the reader meets an id puts it first, so
the eye arrives expecting a prefix and found a title (TODO.org
:ID: 46e4ce2b; the convention is :ID: c2132d3f). `--short-id' is exactly
eight characters for any real UUID, so leading with it puts every id in
one column, which a trailing `{id}' cannot do because titles vary in
length."
  ;; Not the known-ids fixture: it leaves its ids unknown to org on
  ;; purpose, so `--assign-candidates' -- which walks
  ;; `org-id-locations' -- returns nothing there.
  (claude-code-ide-org-test--with-heading
    (let* ((start (date-to-time "2026-08-17T09:00:00-0500"))
           (claude-code-ide-org-query-files (list file))
           (cands (claude-code-ide-org--assign-candidates
                   start (time-add start 600))))
      (should cands)
      (dolist (cand cands)
        ;; Eight characters, then two spaces, before anything else.
        (should (string-match-p "\\`[^ ]\\{8\\}  " (car cand))))
      ;; And the id is no longer trailing in braces.
      (should-not (string-match-p "{[^}]+}" (mapconcat #'car cands "\n"))))))

(ert-deftest claude-code-ide-org-test-assign-candidates-day-node-row-keeps-its-column ()
  "The one row with no :ID: must not put a truncated title in the id column.

The meta-work category is offered by title, because a category carries
no :ID: by convention. This heading's body was explicit that whatever
prefix format is chosen has to leave that row readable rather than
showing eight characters of title where every other row shows an id."
  (claude-code-ide-org-test--with-datetree
    (let* ((start (date-to-time "2026-08-17T09:00:00-0500"))
           (row (car (car (claude-code-ide-org--assign-candidates
                           start (time-add start 600))))))
      (should (string-match-p "meta-work" row))
      ;; A same-width placeholder, not the title's first eight characters.
      (should (string-prefix-p "--------  " row))
      (should-not (string-prefix-p "(the day" row)))))

(ert-deftest claude-code-ide-org-test-assign-candidates-tolerates-unresolvable-id ()
  "An `org-id' entry whose heading no longer exists must not drag org
calls into the caller's buffer.  `org-with-point-at' does not switch
buffers when handed nil -- its expansion calls `set-buffer' only under
`(markerp ...)', then falls through to `(goto-char (or nil (point)))' --
so the body runs wherever point already was.  From the review buffer that
is `*org-review*', a non-Org buffer, where `org-get-heading' and
`org-entry-get' warn through org-element instead of signalling.  One pass
on 2026-08-17 produced 45 such warnings from 22 unresolvable IDs.

Asserts on `display-warning' rather than on the returned candidates on
purpose: the unguarded path drops the ghost candidate too, so the warning
is the *only* observable difference between fixed and broken."
  (claude-code-ide-org-test--with-heading
    ;; An id org-id knows about, whose heading is not in the file.
    (org-id-add-location "99999999-9999-4999-8999-999999999999" file)
    (let* ((claude-code-ide-org-query-files (list file))
           warned)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (&rest args) (push args warned))))
        (with-temp-buffer
          (fundamental-mode)
          (claude-code-ide-org--assign-candidates
           (claude-code-ide-org-test--t "09:19")
           (claude-code-ide-org-test--t "09:20"))))
      (should (null warned)))))

(ert-deftest claude-code-ide-org-test-activity-range-uses-times-on-the-reference-day ()
  "Day resolution is useless in the case it is most used: every candidate
touched today reads the same against a span that is also today."
  (let ((range (cons (claude-code-ide-org-test--t "09:12")
                     (claude-code-ide-org-test--t "15:31")))
        (created (claude-code-ide-org-test--t "09:12")))
    (should (string-match-p "09:12\\.\\.15:31"
                            (claude-code-ide-org--format-activity-range
                             range created (claude-code-ide-org-test--t "14:00"))))
    ;; No reference, or a reference on another day, stays on dates.
    (should (string-match-p "08-15"
                            (claude-code-ide-org--format-activity-range
                             range created nil)))))

;;; RET from the review buffer -----------------------------------------------

(ert-deftest claude-code-ide-org-test-review-goto-keeps-the-review-buffer-visible ()
  "RET must not displace the list it is helping you read.  The org file
is normally already open in another window -- that is how the review
command gets invoked -- so the jump reuses that window, leaves the review
buffer showing, and selects the org buffer at the heading."
  (claude-code-ide-org-test--with-heading
    (let ((org-buffer (find-file-noselect file))
          (review (get-buffer-create "*org-review-test*")))
      (unwind-protect
          (progn
            (with-current-buffer review
              (claude-code-ide-org-review-mode)
              (setq claude-code-ide-org--review-items
                    (list (list :type 'state :id id :ts (current-time)
                                :from "TODO" :to "DOING" :events nil)))
              (claude-code-ide-org--review-render))
            ;; The layout the complaint describes: review here, org there.
            (delete-other-windows)
            (let ((other (split-window)))
              (set-window-buffer other org-buffer)
              (set-window-buffer (selected-window) review)
              (with-current-buffer review
                (claude-code-ide-org-test--goto-nth-item 0)
                (claude-code-ide-org-review-goto))
              ;; The review buffer is still on screen...
              (should (get-buffer-window review))
              ;; ...the org buffer's existing window was reused rather than
              ;; a third one made...
              (should (eq (selected-window) other))
              ;; ...and that window is showing the heading.  Asserted
              ;; against the *window*, not `current-buffer': the enclosing
              ;; `with-current-buffer' restores what was current on exit, so
              ;; a `current-buffer' assertion here can pass on whatever the
              ;; fixture happened to leave behind rather than on the jump.
              (should (eq (window-buffer other) org-buffer))
              (with-selected-window other
                (should (equal id (org-entry-get nil "ID"))))))
        (kill-buffer review)
        (delete-other-windows)))))

(ert-deftest claude-code-ide-org-test-show-logbook-opens-only-its-own ()
  "RET jumps to a heading so its intervals can be compared against the
review item, and those live in the :LOGBOOK: drawer -- which
`org-fold-show-context' leaves closed.  Bounded to the heading's own
body: a parent with no drawer must not open its first child's, which
would look like it worked while showing the wrong intervals."
  ;; A file of its own, not the shared fixture's: rewriting a file the
  ;; fixture already has open makes `find-file-noselect' prompt about the
  ;; on-disk change, and a prompt in batch dies with "Error reading from
  ;; stdin" rather than anything that names the cause.
  (let* ((dir (file-name-as-directory (make-temp-file "cciorg-fold" t)))
         (path (expand-file-name "fold.org" dir)))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "#+TODO: TODO | DONE\n\n"
                    "* Parent without a drawer\n:PROPERTIES:\n:ID: p-1\n:END:\n\n"
                    "** Child with one\n:PROPERTIES:\n:ID: c-1\n:END:\n"
                    ":LOGBOOK:\nCLOCK: [2026-08-12 Wed 17:40]--[2026-08-12 Wed 17:42] =>  0:02\n:END:\n"))
          (with-current-buffer (find-file-noselect path)
            (org-fold-hide-drawer-all)
      ;; On the parent: nothing to open, and the child's stays shut.
      (goto-char (point-min))
      (re-search-forward "^\\* Parent")
      (claude-code-ide-org--show-logbook)
      (goto-char (point-min))
      (should (re-search-forward "^:LOGBOOK:" nil t))
      (should (org-fold-folded-p (line-beginning-position 2)))
      ;; On the child that owns it, it opens.
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Child")
      (claude-code-ide-org--show-logbook)
            (goto-char (point-min))
            (should (re-search-forward "^:LOGBOOK:" nil t))
            (should-not (org-fold-folded-p (line-beginning-position 2)))
            (set-buffer-modified-p nil)
            (kill-buffer)))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-review-goto-unfolds-the-logbook ()
  "The wiring, not just the helper.  Asserting `--show-logbook' works in
isolation leaves the call site untested -- removing it from
`claude-code-ide-org-review-goto' broke no test at all until this
existed.  RET is only useful if it lands on the intervals."
  (let* ((dir (file-name-as-directory (make-temp-file "cciorg-goto-fold" t)))
         (path (expand-file-name "g.org" dir))
         (org-id-locations (make-hash-table :test 'equal))
         (org-id-locations-file (expand-file-name ".org-id-locations" dir))
         (review (get-buffer-create "*org-review-fold-test*")))
    (unwind-protect
        (progn
          (with-temp-file path
            (insert "#+TODO: TODO | DONE\n\n* Target\n:PROPERTIES:\n:ID: g-1\n:END:\n"
                    ":LOGBOOK:\nCLOCK: [2026-08-12 Wed 17:40]--[2026-08-12 Wed 17:42] =>  0:02\n:END:\n"))
          (puthash "g-1" path org-id-locations)
          (with-current-buffer (find-file-noselect path) (org-fold-hide-drawer-all))
          (with-current-buffer review
            (claude-code-ide-org-review-mode)
            (setq claude-code-ide-org--review-items
                  (list (list :type 'state :id "g-1" :ts (current-time)
                              :from "TODO" :to "DOING" :events nil)))
            (claude-code-ide-org--review-render)
            (claude-code-ide-org-test--goto-nth-item 0)
            (claude-code-ide-org-review-goto))
          (with-current-buffer (find-file-noselect path)
            (goto-char (point-min))
            (should (re-search-forward "^:LOGBOOK:" nil t))
            (should-not (org-fold-folded-p (line-beginning-position 2)))))
      (let ((b (find-buffer-visiting path)))
        (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
      (kill-buffer review)
      (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-review-goto-pushes-the-mark-ring ()
  "Reusing the org window would otherwise silently discard wherever the
human was reading when they ran the review, so the old position goes on
org's own mark ring and `org-mark-ring-goto' brings it back."
  (claude-code-ide-org-test--with-heading
    (let ((org-buffer (find-file-noselect file))
          (review (get-buffer-create "*org-review-test*")))
      (unwind-protect
          (progn
            (with-current-buffer review
              (claude-code-ide-org-review-mode)
              (setq claude-code-ide-org--review-items
                    (list (list :type 'state :id id :ts (current-time)
                                :from "TODO" :to "DOING" :events nil)))
              (claude-code-ide-org--review-render))
            (delete-other-windows)
            (let ((other (split-window)))
              (set-window-buffer other org-buffer)
              (set-window-buffer (selected-window) review)
              ;; Park point somewhere identifiable in the org window.
              (with-selected-window other (goto-char (point-min)))
              (with-current-buffer review
                (claude-code-ide-org-test--goto-nth-item 0)
                (claude-code-ide-org-review-goto))
              (with-selected-window other
                (should (> (point) (point-min)))
                ;; `last-command' must differ from `this-command' or org
                ;; takes its "called several times in succession, walk the
                ;; ring" branch and lands on an unset marker.  In batch both
                ;; are nil, so they collide and every call looks like a
                ;; repeat -- an artifact of running headless, not of the
                ;; jump under test.
                (let ((last-command 'not-a-repeat))
                  (org-mark-ring-goto 1))
                (should (= (point) (point-min))))))
        (kill-buffer review)
        (delete-other-windows)))))

(ert-deftest claude-code-ide-org-test-review-goto-explains-what-it-cannot-reach ()
  "An unassigned span names no heading and a capture names one that apply
has not written yet.  Both are ordinary states of the queue, so each gets
an answer that says what to do rather than a bare \"cannot find entry\"."
  (claude-code-ide-org-test--with-review-buffer
      (list (list :type 'clock :id nil :start (current-time) :end (current-time)
                  :unassigned t :events nil)
            (list :type 'capture :id "not-written-yet" :ts (current-time)
                  :title "Pending" :events nil))
    ;; Matched without the quote characters: `user-error' formats through
    ;; `format-message', which turns `a' into curly ‘a’, so an assertion
    ;; written the way the source spells it fails on the rendering.
    (claude-code-ide-org-test--goto-nth-item 0)
    (should (string-match-p
             "not assigned to a heading yet"
             (cadr (should-error (claude-code-ide-org-review-goto) :type 'user-error))))
    (claude-code-ide-org-test--goto-nth-item 1)
    (should (string-match-p
             "capture is still pending"
             (cadr (should-error (claude-code-ide-org-review-goto) :type 'user-error))))))

(defmacro claude-code-ide-org-test--with-attention-file (text &rest body)
  "Write TEXT to a real temp .org file, point `claude-code-ide-org-query-files'
at it, and run BODY.  A real file rather than a temp buffer because
`claude-code-ide-org--attention-headings-context' scans via
`find-file-noselect' over `claude-code-ide-org--tracked-files'."
  (declare (indent 1))
  `(let* ((file (make-temp-file "claude-code-ide-org-attention" nil ".org"))
          (claude-code-ide-org-query-files (list file))
          (org-inhibit-startup t))
     (unwind-protect
         (progn (write-region ,text nil file nil 'silent) ,@body)
       (when (find-buffer-visiting file) (kill-buffer (find-buffer-visiting file)))
       (delete-file file))))

(defun claude-code-ide-org-test--attention-line (id lines)
  "Return the line in LINES naming ID, or nil."
  (seq-find (lambda (l) (string-match-p (regexp-quote id) l)) lines))

(ert-deftest claude-code-ide-org-test-attention-keys-on-queue-divergence ()
  "The session-start report compares the file against the queue, not against
the clock (TODO.org :ID: e0904e93).  The three cases that must be told apart
are all live states of this repo's own queue, and the old clock-keyed
predicate collapsed them: it reported every DOING leaf identically and said
nothing at all about a heading whose DOING was still queued."
  (claude-code-ide-org-test--with-queue
    (let* ((now (current-time))
           (stamp (lambda (time) (format-time-string "%Y-%m-%dT%H:%M:%S%z" time)))
           (long-ago (time-subtract now (days-to-time 3))))
      (claude-code-ide-org-test--queue-write
       "sess-a"
       ;; behind: file still DOING, queue has already moved it on
       (claude-code-ide-org-test--queue-event
        (funcall stamp now) "todo" "id-behind" "DONE" "sess-a")
       ;; ahead: queue says DOING, file carries no keyword at all
       (claude-code-ide-org-test--queue-event
        (funcall stamp now) "todo" "id-ahead" "DOING" "sess-a")
       ;; agreeing: file DOING, queue active today on the same heading
       (claude-code-ide-org-test--queue-event
        (funcall stamp now) "clock_in" "id-agree" nil "sess-a")
       ;; abandoned: file DOING, queue silent since before today
       (claude-code-ide-org-test--queue-event
        (funcall stamp long-ago) "clock_in" "id-stale" nil "sess-a"))
      (claude-code-ide-org-test--with-attention-file
          (concat "#+TODO: TODO NEXT DOING WAITING | DONE CANCELLED\n"
                  "* DOING Behind\n:PROPERTIES:\n:ID: id-behind\n:END:\n"
                  "* Ahead\n:PROPERTIES:\n:ID: id-ahead\n:END:\n"
                  "* DOING Agreeing\n:PROPERTIES:\n:ID: id-agree\n:END:\n"
                  "* DOING Abandoned\n:PROPERTIES:\n:ID: id-stale\n:END:\n")
        (let ((lines (claude-code-ide-org--attention-headings-context)))
          ;; 1. File behind the queue.
          (should (string-match-p
                   "queued -> DONE, not yet applied"
                   (or (claude-code-ide-org-test--attention-line "id-behind" lines) "")))
          ;; 2. Queue ahead of the file -- the case the old predicate could
          ;; not express at all, since the heading is not DOING in the file.
          (should (string-match-p
                   "queued DOING, not yet applied"
                   (or (claude-code-ide-org-test--attention-line "id-ahead" lines) "")))
          ;; 3. The silence that makes the report worth reading. Under the
          ;; old clock-keyed predicate this line was always emitted, which
          ;; is exactly why the report stopped discriminating.
          (should-not (claude-code-ide-org-test--attention-line "id-agree" lines))
          ;; 4. Genuinely walked away from.
          (should (string-match-p
                   "nothing queued since"
                   (or (claude-code-ide-org-test--attention-line "id-stale" lines) "")))
          ;; 5. The retired vocabulary must not come back: nothing holds a
          ;; live clock outside a review pass, so "clocked" can only mislead.
          (should-not (string-match-p "clocked" (mapconcat #'identity lines "\n"))))))))

(ert-deftest claude-code-ide-org-test-suggest-heading-refuses-a-container ()
  "A container is never itself the work, so it must never be suggested for a
span however active it looks (TODO.org :ID: 62c6b1be).  The leaf and the
container here are put into DOING by identical events at the identical time,
so nothing but container-ness can explain a different answer -- and the leaf
must still be suggested, or the assertion would pass on a function that had
simply stopped working."
  (let* ((file (make-temp-file "claude-code-ide-org-suggest" nil ".org"))
         (org-inhibit-startup t)
         (now (current-time))
         (earlier (time-subtract now 600)))
    (unwind-protect
        (progn
          (write-region
           (concat "#+TODO: TODO DOING | DONE\n"
                   "* DOING Container\n:PROPERTIES:\n:ID: sug-container\n:END:\n"
                   "** TODO A child that makes it one\n"
                   ":PROPERTIES:\n:ID: sug-child\n:END:\n"
                   "* DOING Leaf\n:PROPERTIES:\n:ID: sug-leaf\n:END:\n")
           nil file nil 'silent)
          (org-id-update-id-locations (list file))
          (let ((events (list (list :kind "todo" :id "sug-container"
                                    :state "DOING" :ts earlier)))
                (leaf-events (list (list :kind "todo" :id "sug-leaf"
                                         :state "DOING" :ts earlier))))
            ;; The leaf is suggested: the function still works.
            (should (equal "sug-leaf"
                           (claude-code-ide-org--review-suggest-heading
                            now leaf-events)))
            ;; The container, identically active, is refused.
            (should-not (claude-code-ide-org--review-suggest-heading
                         now events))))
      (when (find-buffer-visiting file) (kill-buffer (find-buffer-visiting file)))
      (delete-file file))))

;;; Explicit clock brackets as authoritative attribution (TODO.org :ID: eaeeb4ee)
;;
;; Before 2026-08-22 a main-lane `clock_in'/`clock_out' pair produced no
;; review item of its own.  Duration came only from clustering pause/resume
;; guideposts, and guideposts are *turn boundaries* -- so a bracket opened
;; and closed inside a single turn contained none and vanished entirely.
;; Measured on the 2026-08-21 queue: four headings, fifteen minutes, no
;; item, while an hour of their work was offered as one unassigned span
;; and landed on an unrelated heading.

(defun claude-code-ide-org-test--clock-items (&optional session)
  "Every `clock' review item from the queue, oldest first."
  (seq-filter (lambda (i) (eq (plist-get i :type) 'clock))
              (claude-code-ide-org--review-items-from-queue session)))

(defun claude-code-ide-org-test--written-seconds (item)
  "Total seconds ITEM's runs would write as CLOCK lines."
  (apply #'+ (mapcar (lambda (r) (float-time (time-subtract (cdr r) (car r))))
                     (claude-code-ide-org--review-intervals-to-write item))))

(ert-deftest claude-code-ide-org-test-bracket-without-guideposts-still-yields-an-item ()
  "A bracket opened and closed inside one turn produces an item covering it.

This is the whole of :ID: eaeeb4ee.  There is deliberately *no*
pause/resume anywhere between the `clock_in' and the `clock_out', which
is what a single uninterrupted turn looks like and what the old code
could not see: it filtered to guideposts, found none, clustered nothing,
and emitted nothing at all.  The heading's own note has to survive too,
since the note is the thing that makes the attribution certain rather
than guessed."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:07:10-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:07:36-0500" "clock_in" "id-a" nil nil
                  "guard auto-promote against containers")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:16:20-0500" "clock_out" nil nil nil "shipped")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:24:41-0500" "pause")))
    (let* ((items (claude-code-ide-org-test--clock-items))
           (bracket (seq-find (lambda (i) (equal (plist-get i :id) "id-a")) items)))
      (should bracket)
      (should (equal (plist-get bracket :origin) 'bracketed))
      (should (equal (plist-get bracket :note)
                     "guard auto-promote against containers"))
      ;; 13:07:36 to 13:16:20 is 8m44s, and all of it is work: the turn
      ;; never stopped, which is exactly why no guidepost fell inside.
      (should (= 524 (claude-code-ide-org-test--written-seconds bracket))))))

(ert-deftest claude-code-ide-org-test-bracket-subtracts-a-permission-block ()
  "A permission wait inside a bracket splits it and is not written.

Discriminating twice over.  The block is 111 seconds -- *under* the
120-second `claude-code-ide-org-span-idle-floor' -- so a run-splitter
that produced two runs and then let the floor merge them back would
report the same single interval as one that never split at all.  And the
block events reach the item only because the span filter now admits
them; while it admitted `pause'/`resume' alone,
`claude-code-ide-org--block-intervals' was handed a list it had already
been filtered out of and returned nil on every production call."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:07:36-0500" "clock_in" "id-a" nil nil "work")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:11:01-0500" "block_start")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:12:52-0500" "block_end")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:16:20-0500" "clock_out")))
    (let* ((bracket (car (claude-code-ide-org-test--clock-items)))
           (runs (claude-code-ide-org--review-intervals-to-write bracket)))
      (should (= 2 (length runs)))
      ;; 8m44s of bracket less the 1m51s nobody was working.
      (should (= 413 (claude-code-ide-org-test--written-seconds bracket))))))

(ert-deftest claude-code-ide-org-test-bracket-recovers-its-own-edges ()
  "The bracket's endpoints are run boundaries, so the edges are not lost.

`clock_in' -> `pause' is the opening stretch of work and `resume' ->
`clock_out' the closing one.  Both fell outside every span before, because
the guidepost filter dropped the two `clock_*' events and the first and
last runs had nothing to pair against.  Written as one assertion because
the rule is symmetric and half of it passing is not the rule."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-21T14:53:42-0500" "clock_in" "id-a" nil nil "review")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T14:54:44-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T15:41:17-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T15:42:08-0500" "clock_out")))
    (let* ((bracket (car (claude-code-ide-org-test--clock-items)))
           (runs (claude-code-ide-org--review-intervals-to-write bracket)))
      (should (= 2 (length runs)))
      ;; The leading 62s and the trailing 51s, and *not* the 46m33s of
      ;; human thinking between the pause and the resume.
      (should (= 113 (claude-code-ide-org-test--written-seconds bracket))))))

(ert-deftest claude-code-ide-org-test-subagent-bracket-stays-authoritative ()
  "A subagent's own interval is still written whole, not run-split.

The counterweight to the three tests above, and the reason the main-lane
change could not simply be `treat every bracket alike'.  A subagent runs
unattended, so there is no human idle inside its bracket to subtract --
`:suggested' nil is what records that and what stops apply re-deriving
runs from guideposts that belong to the parent session anyway.  Without
this assertion the fix would have quietly converted every subagent
interval into a reconstruction."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-21T09:00:00-0500" "clock_in" "id-a" nil nil
                  "delegated work" "agent-1" "general-purpose")
                 ;; A parent-session pause lands inside the agent's
                 ;; bracket; it must not subdivide it.
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T09:10:00-0500" "pause")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T09:30:00-0500" "clock_out" nil nil nil nil
                  "agent-1" "general-purpose")))
    (let ((bracket (seq-find (lambda (i) (plist-get i :agent))
                             (claude-code-ide-org-test--clock-items))))
      (should bracket)
      (should-not (plist-get bracket :suggested))
      (should (= 1 (length (claude-code-ide-org--review-intervals-to-write bracket))))
      (should (= 1800 (claude-code-ide-org-test--written-seconds bracket))))))

(ert-deftest claude-code-ide-org-test-unassigned-span-excludes-bracketed-minutes ()
  "An unassigned span is partitioned by the brackets inside it.

The double-count this fix would otherwise mint, and it is not
hypothetical: on 2026-08-21 the `resume' before the first `clock_in' and
the `pause' after the last `clock_out' are *adjacent* in the orphan
stream, because everything between them is bracketed and attributed
elsewhere.  A `resume' -> `pause' adjacency never splits however long the
gap, so the span would have straddled all four brackets and offered
their minutes a second time -- against headings chosen by guesswork,
while the brackets that named them correctly sat right there."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:07:10-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:07:36-0500" "clock_in" "id-a" nil nil "work")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:16:20-0500" "clock_out")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T13:24:41-0500" "pause")))
    (let ((unassigned (seq-filter (lambda (i) (plist-get i :unassigned))
                                  (claude-code-ide-org-test--clock-items))))
      ;; Whatever is offered unassigned, none of it may be the bracket's
      ;; own 13:07:36--13:16:20.
      (dolist (item unassigned)
        (should (zerop (claude-code-ide-org-test--written-seconds item)))))))

(ert-deftest claude-code-ide-org-test-each-bracket-carries-its-own-note ()
  "Two brackets on one heading get two labels, not the first one twice.

The old code took the label from the first `clock_in' note anywhere in
the heading's events, so a heading picked up twice in a session -- which
is ordinary, not exotic -- had both intervals described by the earlier
piece of work.  Observed on the real queue for `cc0c17a7', clocked on
two different days with two different notes."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-21T09:00:00-0500" "clock_in" "id-a" nil nil "first piece")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T09:20:00-0500" "clock_out")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T14:00:00-0500" "clock_in" "id-a" nil nil "second piece")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T14:20:00-0500" "clock_out")))
    (should (equal (mapcar (lambda (i) (plist-get i :note))
                           (claude-code-ide-org-test--clock-items))
                   '("first piece" "second piece")))))

(ert-deftest claude-code-ide-org-test-unmatched-clock-in-leaves-the-residue-span ()
  "An open bracket is not consumed, and its guideposts still cluster.

`claude-code-ide-org--lane-clock-pairs' drops an unmatched `clock_in'
rather than inventing an end for it -- the class of guess :ID: 7771fc63
retired.  That must not cost the work its item: the guideposts after it
are attributed to the heading by lane tracking and have to keep reaching
review through the residue path, which is the only reason that path
still exists."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (claude-code-ide-org-test--queue-event
                  "2026-08-21T09:00:00-0500" "clock_in" "id-a" nil nil "still going")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T09:01:00-0500" "resume")
                 (claude-code-ide-org-test--queue-event
                  "2026-08-21T09:11:00-0500" "pause")))
    (let ((items (claude-code-ide-org-test--clock-items)))
      (should (= 1 (length items)))
      (should (equal (plist-get (car items) :id) "id-a"))
      (should-not (eq (plist-get (car items) :origin) 'bracketed))
      (should (= 600 (claude-code-ide-org-test--written-seconds (car items)))))))

;;; :PLAN: drawer wrapping (TODO.org :ID: 3063c3e5)

(defun claude-code-ide-org-test--body-of (id)
  "Return heading ID's raw text from the heading line to its next heading."
  (claude-code-ide-org--at-id
   id (lambda ()
        (buffer-substring-no-properties
         (line-beginning-position)
         (save-excursion (outline-next-heading)
                         (if (eobp) (point-max) (point)))))))

(ert-deftest claude-code-ide-org-test-wrap-plan-wraps-a-whole-body ()
  "The completion transition: a purely prospective body goes in whole.

Asserts the drawer opens *after* the existing metadata drawers rather
than before them, since the point of the layout is that :PLAN: sits
beside :PROPERTIES: and :LOGBOOK: and a folded heading shows neither."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "\nMotivation for the thing.\n\nA second paragraph.\n")
    (save-buffer)
    (let ((result (claude-code-ide-org-wrap-plan id)))
      (should (string-match-p "Text preserved: yes" result)))
    (let ((text (claude-code-ide-org-test--body-of id)))
      ;; :PLAN: abuts the property drawer's :END:, with the blank line
      ;; that separated prose from metadata now inside the drawer.
      (should (string-match-p ":END:\n:PLAN:\n\nMotivation for the thing" text))
      (should (string-match-p "A second paragraph\\.\n:END:" text)))))

(ert-deftest claude-code-ide-org-test-wrap-plan-splits-at-a-seam ()
  "The retroactive case: only the text above the seam is wrapped.

A body written before the convention existed generally holds both
halves, and wrapping it whole would bury the debrief inside a drawer
readers are told to skip -- the exact inversion the convention exists to
prevent.  So the debrief must remain in the body, outside :PLAN:."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "\nThe plan was to do it this way.\n\n"
            "*Outcome.* It went differently.\n")
    (save-buffer)
    (claude-code-ide-org-wrap-plan id "*Outcome.*")
    (let ((text (claude-code-ide-org-test--body-of id)))
      (should (string-match-p ":PLAN:\n\nThe plan was to do it this way" text))
      (should (string-match-p "this way\\.\n\n:END:\n\\*Outcome\\.\\*" text))
      ;; The debrief is outside the drawer, which is the whole point.
      (should-not (string-match-p ":PLAN:\\(.\\|\n\\)*Outcome\\(.\\|\n\\)*:END:" text)))))

(ert-deftest claude-code-ide-org-test-wrap-plan-ignores-bold-prose-lines ()
  "A body line starting with `*' is prose, and must not end the body.

This is the recorded corruption, not a hypothetical: a `startswith(\"*\")'
next-heading test matched a bold prose line and orphaned 117 lines, and
`bin/lint-org' reported 0 errors because the damage is prose-level under
a well-formed heading.  The body here opens with such a line, so a
wrapper using that test closes the drawer immediately and strands
everything below it.

Also pins the boundary at the far end: the *real* next heading and its
content must be untouched."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "\n*Scope, as stated:* one ordering across every entry style.\n\n"
            "*Why this is not a quick sort:* three line shapes.\n\n"
            "*Outcome.* Done as specified.\n"
            "** A real child heading\nChild body.\n")
    (save-buffer)
    (let ((result (claude-code-ide-org-wrap-plan id "*Outcome.*")))
      (should (string-match-p "Text preserved: yes" result)))
    (let ((text (claude-code-ide-org-test--body-of id)))
      ;; Both bold prose lines are inside the drawer; neither ended it.
      (should (string-match-p ":PLAN:\n\n\\*Scope" text))
      (should (string-match-p "three line shapes\\.\n\n:END:" text))
      (should (string-match-p ":END:\n\\*Outcome\\.\\* Done as specified" text)))
    ;; The child heading kept its own body, outside everything.
    (should (string-match-p
             "^\\*\\* A real child heading\nChild body\\.\n"
             (claude-code-ide-org--at-id
              id (lambda () (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest claude-code-ide-org-test-wrap-plan-stops-at-the-first-child ()
  "A parent's body ends at its first child, not at the end of its subtree.

Without this the drawer would swallow every descendant heading, which is
a structural corruption rather than a prose one -- and the only one of
these failures `bin/lint-org' would actually catch."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "\nParent body.\n** Child\nChild body.\n")
    (save-buffer)
    (claude-code-ide-org-wrap-plan id)
    (let ((text (claude-code-ide-org-test--body-of id)))
      (should (string-match-p ":PLAN:\n\nParent body\\.\n:END:" text))
      (should-not (string-match-p "Child" text)))))

(ert-deftest claude-code-ide-org-test-wrap-plan-refuses-rather-than-guesses ()
  "Every refusal path, because each one silently succeeding is a corruption.

A second wrap would nest drawers; an absent or ambiguous seam would put
the split in a place nobody chose.  The seam decides which half of a
body becomes invisible to ordinary reading, so guessing it is the one
mistake here that no later reader will catch."
  (claude-code-ide-org-test--with-heading
    ;; No body at all.
    (should (string-match-p "no body to wrap" (claude-code-ide-org-wrap-plan id)))
    (goto-char (point-max))
    (insert "\nA line.\nA repeated marker.\nA repeated marker.\n")
    (save-buffer)
    (should (string-match-p "not found"
                            (claude-code-ide-org-wrap-plan id "nowhere in the body")))
    (should (string-match-p "appears 2 times"
                            (claude-code-ide-org-wrap-plan id "A repeated marker")))
    ;; None of those refusals may have written anything.  A seam on the
    ;; first body line is deliberately NOT in this list any more -- it is
    ;; an answer, not an ambiguity; see the empty-drawer test below.
    (should-not (string-match-p ":PLAN:" (claude-code-ide-org-test--body-of id)))
    ;; A successful wrap, then a second attempt on the same heading.
    (claude-code-ide-org-wrap-plan id)
    (should (string-match-p "already has a :PLAN: drawer"
                            (claude-code-ide-org-wrap-plan id)))))

(ert-deftest claude-code-ide-org-test-plan-seam-refuses-empty-unless-allowed ()
  "`--plan-seam' still refuses a first-line seam by default.

The relaxation is opt-in, so a caller that cannot represent \"there was
nothing to wrap\" keeps refusing rather than silently producing an empty
drawer.  Uniqueness is enforced in *both* modes: EMPTY-OK answers
\"nothing is prospective\", never \"I could not tell which line you
meant\"."
  (with-temp-buffer
    (org-mode)
    (insert "* H\n")
    (let* ((beg (point))
           (_ (insert "First line.\nSecond line.\nDuplicated.\nDuplicated.\n"))
           (end (point)))
      ;; Default: the old error stands.
      (should-error (claude-code-ide-org--plan-seam beg end "First line.")
                    :type 'error)
      ;; EMPTY-OK: the same call answers BEG instead.
      (should (= beg (claude-code-ide-org--plan-seam beg end "First line." t)))
      ;; A genuine seam is unaffected by the flag.
      (should (= (claude-code-ide-org--plan-seam beg end "Second line.")
                 (claude-code-ide-org--plan-seam beg end "Second line." t)))
      ;; Ambiguity still errors *with* the flag -- this is the assertion
      ;; that keeps EMPTY-OK from becoming "never refuse anything".
      (should-error (claude-code-ide-org--plan-seam beg end "Duplicated." t)
                    :type 'error)
      (should-error (claude-code-ide-org--plan-seam beg end "Absent." t)
                    :type 'error))))

(ert-deftest claude-code-ide-org-test-wrap-plan-records-no-prospective-half ()
  "A debrief-only body gets an EMPTY :PLAN: drawer, not a refusal.

TODO.org :ID: f421c5c3.  The `:PLAN:' lint asks one question -- is there
a drawer? -- and a heading written outcome-first had no way to answer
\"yes, and it is empty on purpose\".  Six existing headings are in that
position, and the only way to satisfy the warning was to wrap a debrief
into a drawer readers are told to skip, which is the exact inversion the
lifecycle exists to prevent.

Whether a body has a prospective half is a judgement, not something
derivable from its prose -- so it is *declared*, by running the wrap and
letting it record the answer."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "\n*Shipped 2026-08-25.* It works, and here is how it was checked.\nA second debrief line.\n")
    (save-buffer)
    (let ((result (claude-code-ide-org-wrap-plan
                   id "*Shipped 2026-08-25.* It works, and here is how it was checked.")))
      (should (string-match-p "no prospective half" result))
      (should (string-match-p "Text preserved: yes" result)))
    (let ((body (claude-code-ide-org-test--body-of id)))
      ;; The drawer exists, so the lint's question now has an answer...
      (should (string-match-p ":PLAN:" body))
      ;; ...and it is empty: nothing between the markers but whitespace.
      (should (string-match-p ":PLAN:[ \t\n]*:END:" body))
      ;; The debrief stayed in the body, where a reader will see it.
      (should (string-match-p "It works, and here is how it was checked" body))
      (should-not (string-match-p ":PLAN:[ \t\n]*\\*Shipped" body)))
    ;; Idempotent for the same reason a real wrap is: the drawer exists.
    (should (string-match-p "already has a :PLAN: drawer"
                            (claude-code-ide-org-wrap-plan id)))))

;;; CLOSED: backfill (TODO.org :ID: f4b07fc0)

(defmacro claude-code-ide-org-test--with-backfill-file (&rest body)
  "Run BODY with `file' bound to an org file holding four finished
headings: one evidenced, one reopened-then-closed, one with no State
line at all, and one that already carries CLOSED:."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "ccio-backfill" t)))
          (file (expand-file-name "DONE.org" dir)))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "#+TODO: TODO(t!) DOING(d!) | DONE(D!) CANCELLED(c@)\n"
                     "#+STARTUP: logdrawer logdone content\n\n"
                     "* DONE Evidenced\n:LOGBOOK:\n"
                     "- State \"DONE\"       from \"DOING\"      [2026-08-12 Wed 17:01]\n"
                     ":END:\n"
                     "* DONE Reopened then closed again\n:LOGBOOK:\n"
                     "- State \"DONE\"       from \"DOING\"      [2026-08-14 Fri 09:00]\n"
                     "- State \"DOING\"      from \"DONE\"       [2026-08-13 Thu 12:00]\n"
                     "- State \"DONE\"       from \"DOING\"      [2026-08-13 Thu 09:00]\n"
                     ":END:\n"
                     "* DONE No evidence\n:PROPERTIES:\n:ARCHIVE_TIME: 2026-08-17 Sun 10:00\n:END:\n"
                     "* DONE Already closed\nCLOSED: [2026-08-01 Sat 08:00]\n"
                     ":LOGBOOK:\n"
                     "- State \"DONE\"       from \"DOING\"      [2026-08-02 Sun 09:00]\n"
                     ":END:\n"))
           ,@body)
       (delete-directory dir t))))

(defmacro claude-code-ide-org-test--with-drifted-drawers (&rest body)
  "Run BODY with `file' bound to a tracked org file whose drawers drift.

Three headings: one newest-first (org's own insert order, which is
exactly what a hand `C-c C-x C-i' leaves behind), one already ascending,
and one carrying a still-open CLOCK line above older closed ones.
`claude-code-ide-org-query-files' is bound to it, so
`claude-code-ide-org--tracked-files' returns this and nothing else --
the real agenda is never touched."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "ccio-consol" t)))
          (file (expand-file-name "TODO.org" dir))
          (claude-code-ide-org-query-files (list file)))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "#+TODO: TODO(t!) DOING(d!) | DONE(D!) CANCELLED(c@)\n\n"
                     "* DONE Newest first\n:LOGBOOK:\n"
                     "CLOCK: [2026-08-20 Thu 11:00]--[2026-08-20 Thu 11:30] =>  0:30\n"
                     "CLOCK: [2026-08-20 Thu 09:00]--[2026-08-20 Thu 09:15] =>  0:15\n"
                     ":END:\n"
                     "* DONE Already ascending\n:LOGBOOK:\n"
                     "CLOCK: [2026-08-21 Fri 09:00]--[2026-08-21 Fri 09:20] =>  0:20\n"
                     "CLOCK: [2026-08-21 Fri 10:00]--[2026-08-21 Fri 10:10] =>  0:10\n"
                     ":END:\n"
                     "* DOING Open clock on top\n:LOGBOOK:\n"
                     "CLOCK: [2026-08-22 Sat 14:00]\n"
                     "CLOCK: [2026-08-22 Sat 10:00]--[2026-08-22 Sat 10:30] =>  0:30\n"
                     "CLOCK: [2026-08-22 Sat 08:00]--[2026-08-22 Sat 08:45] =>  0:45\n"
                     ":END:\n"))
           ,@body)
       (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-consolidate-all-drawers-reaches-untouched-headings ()
  "The point of the command: it repairs drawers no apply pass will revisit.

TODO.org :ID: 7ae6562d.  `consolidate-on-apply' only fires on a heading
an apply actually writes to, so a drawer disturbed by a hand `C-c C-x
C-i' stays disordered forever -- and archiving is the last moment a
heading is ever touched, which is how 43 of 60 multi-entry drawers in
DONE.org came to be out of order."
  (claude-code-ide-org-test--with-drifted-drawers
    ;; Explicit t: from Lisp the default is to WRITE, matching its
    ;; sibling `recompute-accumulated-clock-lines'.  Only a bare `M-x'
    ;; defaults to a dry run.  Asserted here so the asymmetry has a test
    ;; holding it in place rather than only a docstring.
    (let ((report (claude-code-ide-org-consolidate-all-drawers t)))
      (should (string-match-p "Dry run:" report))
      (should (string-match-p "3 drawer(s) scanned" report))
      (should (string-match-p "2 would be reordered" report)))
    ;; Dry run wrote NOTHING: the first drawer is still newest-first.
    ;; Asserted on ORDER, not on the presence of a timestamp -- both
    ;; orderings contain both lines, so a presence check passes whether
    ;; the dry run wrote or not.  It did exactly that until a
    ;; stash-and-break pass caught it.
    (should (string-match-p
             "11:00\\]--\\[2026-08-20 Thu 11:30\\][^\0]*09:00\\]--\\[2026-08-20 Thu 09:15\\]"
             (with-temp-buffer (insert-file-contents file)
                               (buffer-substring-no-properties (point-min) (point-max)))))
    (let ((report (claude-code-ide-org-consolidate-all-drawers nil)))
      (should (string-match-p "Consolidated:" report))
      (should (string-match-p "2 reordered" report))
      (should (string-match-p "1 file(s) saved" report)))
    (let ((text (with-temp-buffer (insert-file-contents file)
                                  (buffer-substring-no-properties (point-min) (point-max)))))
      ;; Newest-first drawer is now ascending.
      (should (string-match-p
               "09:00\\]--\\[2026-08-20 Thu 09:15\\][^\0]*11:00\\]--\\[2026-08-20 Thu 11:30\\]"
               text))
      ;; The still-open CLOCK stays FIRST -- it is live state, not history.
      (should (string-match-p
               ":LOGBOOK:\nCLOCK: \\[2026-08-22 Sat 14:00\\]\n" text))
      ;; Nothing was invented or dropped: still seven CLOCK lines
      ;; (2 + 2 + 3 across the three fixture headings).
      (should (= 7 (cl-count-if (lambda (l) (string-prefix-p "CLOCK:" l))
                                (split-string text "\n")))))))

(ert-deftest claude-code-ide-org-test-ceremony-stamp-silences-until-tomorrow ()
  "The stamp is what stops the prompt being a nag.

TODO.org :ID: aa1ba915.  Before it is written the ceremony has a status;
after, it has none until the date rolls over.  The mtime carries the
date, so a stamp backdated to yesterday must not silence today."
  (claude-code-ide-org-test--with-queue
    (should-not (claude-code-ide-org--ceremony-done-today-p))
    (claude-code-ide-org-mark-ceremony-done)
    (should (claude-code-ide-org--ceremony-done-today-p))
    (should-not (claude-code-ide-org--ceremony-status))
    ;; Backdate it: yesterday's ceremony does not count as today's.
    (let ((f (claude-code-ide-org--ceremony-stamp-file)))
      (set-file-times f (time-subtract (current-time) (days-to-time 1)))
      (should-not (claude-code-ide-org--ceremony-done-today-p)))))

(ert-deftest claude-code-ide-org-test-ceremony-a-pass-alone-no-longer-quiets ()
  "A pass having run must not silence the prompt; only the stamp does.

*This reverses `...-quiets-on-a-real-pass\', deliberately* (TODO.org
:ID: 29734f79).  That test was right for its world: the steps after
apply needed a human, so asking twice in a day would have been asking
for work only they could do, and :ID: 806ff394\'s point was that the
clock derives \"a pass ran\" from the act rather than from anyone
remembering.  Both still hold.  What changed is that the steps now run
on leaving the review buffer and stamp the ceremony only if all of them
succeed -- so a missing stamp means unfinished, and the case the old
disjunct hid is the worst one: a pass that ran, failed a step, held the
repeater, and was then silenced by its own apply clock.

The clock is still read.  It now decides what the report *says* rather
than whether it speaks, which is why `:reviewed-today\' is asserted here
and not merely the absence of silence."
  (claude-code-ide-org-test--with-attention-target
    (let ((claude-code-ide-org-queue-directory
           (file-name-directory (claude-code-ide-org--capture-target-file))))
      (should-not (claude-code-ide-org--ceremony-reviewed-today-p))
      ;; Running a pass is what creates the evidence.
      (claude-code-ide-org-review-attention-start)
      (claude-code-ide-org-review-attention-stop)
      (should (claude-code-ide-org--ceremony-reviewed-today-p))
      ;; Still speaking -- and now able to say which case this is.
      (let ((status (claude-code-ide-org--ceremony-status)))
        (should status)
        (should (plist-get status :reviewed-today))
        (let ((text (claude-code-ide-org--format-ceremony-report
                     (list :pending 1 :drifted 0 :archivable 0
                           :reviewed-today t :last-done "never"))))
          (should (string-match-p "did not complete" text))))
      ;; The stamp, and only the stamp, quiets it.
      (claude-code-ide-org-mark-ceremony-done)
      (should-not (claude-code-ide-org--ceremony-status)))))

(ert-deftest claude-code-ide-org-test-ceremony-quiet-does-not-mean-complete ()
  "Silence after a pass must not read as the ceremony being finished.

The two signals answer different questions and the report has to keep
them apart: a pass being *run* is derived and cannot be forgotten; the
ceremony being *complete* spans steps nothing observes and only a human
can assert.  So the report states when it was last actually marked
complete, rather than letting quiet imply it."
  (let ((text (claude-code-ide-org--format-ceremony-report
               '(:pending 3 :drifted 1 :archivable 9 :last-done "2026-08-20 Thu"))))
    (should (string-match-p "last marked complete 2026-08-20 Thu" text)))
  ;; Never marked complete says so outright rather than omitting it.
  (let ((text (claude-code-ide-org--format-ceremony-report
               '(:pending 3 :drifted 1 :archivable 9))))
    (should (string-match-p "last marked complete never" text))))

(ert-deftest claude-code-ide-org-test-ceremony-report-asks-and-never-proposes ()
  "It states counts and asks; it must not announce an intention to act.

The first step of the ceremony cannot be performed by an agent at all --
apply only completes inside a genuinely interactive command -- so a
report that said \"I will run it\" would be wrong before it was
unwelcome.  Same manners :ID: 7771fc63 established for the stale-clock
report, which asks the stop time and forbids guessing one."
  (let ((text (claude-code-ide-org--format-ceremony-report
               '(:pending 4 :drifted 12 :archivable 7))))
    (should text)
    (should (string-match-p "4 queued item" text))
    (should (string-match-p "12 :LOGBOOK: drawer" text))
    (should (string-match-p "7 finished heading" text))
    (should (string-match-p "Ask the user whether" text))
    (should (string-match-p "do not announce that you will" text))
    ;; It no longer asks anyone to stamp the ceremony, because the pass
    ;; stamps itself once its steps have all succeeded (:ID: 29734f79).
    ;; Asserted as an absence *and* a presence: dropping the instruction
    ;; without putting the new contract in its place would leave a report
    ;; that says what not to do and never what happens instead.
    (should-not (string-match-p "mark-ceremony-done" text))
    (should (string-match-p "burying the review buffer" text))
    ;; Nothing waiting: no line at all, rather than a cheerful "0 items".
    (should-not (claude-code-ide-org--format-ceremony-report
                 '(:pending 0 :drifted 0 :archivable 0)))
    ;; And no status at all (already run today) is also silence.
    (should-not (claude-code-ide-org--format-ceremony-report nil))))

(ert-deftest claude-code-ide-org-test-session-start-payload-carries-both-reports ()
  "One hook, one payload, either half optional.

A stale clock and the ceremony are independent questions wanting the
same moment; `additionalContext' is a single string, so they concatenate
rather than needing a second SessionStart hook and a second Emacs
round-trip.  The payload is `{}' only when both are silent."
  (claude-code-ide-org-test--with-queue
    (cl-letf (((symbol-function 'claude-code-ide-org-find-stale-open-intervals)
               (lambda () nil))
              ((symbol-function 'claude-code-ide-org--ceremony-status)
               (lambda () '(:pending 2 :drifted 0 :archivable 0))))
      (let ((json (claude-code-ide-org--session-start-hook-json)))
        (should (string-match-p "SessionStart" json))
        (should (string-match-p "2 queued item" json))))
    ;; Ceremony silent AND no stale interval -> empty object, so the
    ;; hook script's `[[ -s ]]' guard suppresses it entirely.
    (cl-letf (((symbol-function 'claude-code-ide-org-find-stale-open-intervals)
               (lambda () nil))
              ((symbol-function 'claude-code-ide-org--ceremony-status)
               (lambda () nil)))
      (should (equal "{}" (claude-code-ide-org--session-start-hook-json))))
    ;; A stale interval alone still reports, ceremony or not -- the
    ;; pre-existing behaviour must survive the addition.
    (cl-letf (((symbol-function 'claude-code-ide-org-find-stale-open-intervals)
               (lambda () (list (list :id "deadbeef" :heading "H"
                                      :file "/tmp/TODO.org"
                                      :logbook-open (current-time)))))
              ((symbol-function 'claude-code-ide-org--ceremony-status)
               (lambda () nil)))
      (let ((json (claude-code-ide-org--session-start-hook-json)))
        (should (string-match-p "unclosed CLOCK entry" json))
        (should-not (string-match-p "review-and-planning pass" json))))))

(ert-deftest claude-code-ide-org-test-consolidate-all-drawers-dry-run-spares-open-buffers ()
  "A dry run must not leave an already-open buffer modified.

*This is the only assertion that actually reaches the dry-run guard on
the write*, and it took a break-it-on-a-copy pass to find that out.  The
save gate blocks the write to disk whether or not the region was edited,
and a buffer this command opened is killed with `set-buffer-modified-p'
nil -- so checking the FILE passes even with the guard removed.  The one
case it protects is the human's own open buffer, which would otherwise
be left silently dirty and written out by their next `C-x C-s'."
  (claude-code-ide-org-test--with-drifted-drawers
    (let ((pre (find-file-noselect file)))
      (unwind-protect
          (progn
            (claude-code-ide-org-consolidate-all-drawers t)
            (should-not (buffer-modified-p pre))
            ;; ...and the real run does modify it, so the assertion above
            ;; is about the dry run rather than about nothing happening.
            (claude-code-ide-org-consolidate-all-drawers nil)
            (should-not (buffer-modified-p pre))   ; saved, hence clean
            (should (string-match-p
                     "09:00\\]--\\[2026-08-20 Thu 09:15\\][^\0]*11:00\\]--\\[2026-08-20 Thu 11:30\\]"
                     (with-current-buffer pre
                       (buffer-substring-no-properties (point-min) (point-max))))))
        (with-current-buffer pre (set-buffer-modified-p nil))
        (kill-buffer pre)))))

(ert-deftest claude-code-ide-org-test-consolidate-all-drawers-is-idempotent ()
  "Running it twice changes nothing the second time, and a healthy file
is left byte-identical.

That is what makes it safe to put in a daily ceremony: a maintenance
command whose second run is not a no-op cannot be run on a schedule."
  (claude-code-ide-org-test--with-drifted-drawers
    (claude-code-ide-org-consolidate-all-drawers nil)
    (let ((after-first (with-temp-buffer (insert-file-contents file)
                                         (buffer-string))))
      (let ((report (claude-code-ide-org-consolidate-all-drawers nil)))
        (should (string-match-p "0 reordered" report))
        (should (string-match-p "0 file(s) saved" report)))
      (should (equal after-first
                     (with-temp-buffer (insert-file-contents file)
                                       (buffer-string)))))))

(ert-deftest claude-code-ide-org-test-consolidate-all-drawers-leaves-open-buffers-open ()
  "A file the user already had open is left open; one this command opened
is closed again.

Killing a buffer the human was working in would be a surprising side
effect of a maintenance command, and leaking a buffer per file would
accumulate across a daily run."
  (claude-code-ide-org-test--with-drifted-drawers
    (let ((pre (find-file-noselect file)))
      (claude-code-ide-org-consolidate-all-drawers nil)
      (should (buffer-live-p pre))
      (kill-buffer pre))
    ;; Now with no buffer open beforehand: none is left behind.
    (claude-code-ide-org-consolidate-all-drawers nil)
    (should-not (find-buffer-visiting file))))

(ert-deftest claude-code-ide-org-test-backfill-closed-uses-only-recorded-times ()
  "Fills from the :LOGBOOK:, takes the latest close, and invents nothing.

The no-evidence heading deliberately carries an :ARCHIVE_TIME:, which is
the obvious substitute and the wrong one -- when the subtree moved, not
when the work stopped.  If it were ever used, this heading would gain a
CLOSED: of 2026-08-17 that reads as authoritative.  The assertion is
that it gains nothing at all."
  (claude-code-ide-org-test--with-backfill-file
    (let ((report (claude-code-ide-org-backfill-closed file)))
      (should (string-match-p "2 filled" report))
      (should (string-match-p "1 skipped" report))
      (should (string-match-p "1 already" report)))
    (with-current-buffer (find-file-noselect file)
      (revert-buffer t t t)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "\\* DONE Evidenced\nCLOSED: \\[2026-08-12 Wed 17:01\\]" text))
        ;; The LATEST close, not the first one in the drawer.
        (should (string-match-p
                 "\\* DONE Reopened then closed again\nCLOSED: \\[2026-08-14 Fri 09:00\\]" text))
        ;; Nothing invented from :ARCHIVE_TIME:.
        (should-not (string-match-p "CLOSED: \\[2026-08-17" text))
        (should (string-match-p "\\* DONE No evidence\n:PROPERTIES:" text))
        ;; The pre-existing marker is left exactly as it was.
        (should (string-match-p "CLOSED: \\[2026-08-01 Sat 08:00\\]" text))
        (should-not (string-match-p "CLOSED: \\[2026-08-02" text))))))

(ert-deftest claude-code-ide-org-test-backfill-closed-dry-run-writes-nothing ()
  "A dry run reports exactly what a real run would do, and changes no byte.

The report has to be identical, because a dry run whose output differs
from the real one is not a preview of anything."
  (claude-code-ide-org-test--with-backfill-file
    (let ((before (with-temp-buffer (insert-file-contents file) (buffer-string)))
          (dry (claude-code-ide-org-backfill-closed file t)))
      (should (string-match-p "dry run" dry))
      (should (equal before
                     (with-temp-buffer (insert-file-contents file) (buffer-string))))
      ;; Same counts as the real run that follows it.
      (let ((real (claude-code-ide-org-backfill-closed file)))
        (should (equal (replace-regexp-in-string "  \\[dry run.*" "" dry) real))))))

(ert-deftest claude-code-ide-org-test-backfill-closed-is-idempotent ()
  "A second pass fills nothing, because the first pass's markers are seen.

Without this a repeated run would stack CLOSED: lines, and the command
is one somebody will reasonably run twice while wondering whether it
worked."
  (claude-code-ide-org-test--with-backfill-file
    (claude-code-ide-org-backfill-closed file)
    (let ((second (claude-code-ide-org-backfill-closed file)))
      (should (string-match-p "0 filled" second))
      (should (string-match-p "3 already had" second)))))

;;; :PLAN: drawer lint rule (TODO.org :ID: 8bcd56f4)

(defun claude-code-ide-org-test--plan-fixture (closed body &optional plan)
  "A finished heading CLOSED at that date, with BODY prose lines.
With PLAN non-nil the prose is wrapped in a :PLAN: drawer."
  (concat "* Category\n"
          "** DONE A finished task                                             :code:\n"
          (if closed (format "CLOSED: %s\n" closed) "")
          ":PROPERTIES:\n"
          ":ID:       11111111-1111-1111-1111-111111111111\n"
          ":CREATED:  [2026-08-14 Fri 10:00]\n"
          ":END:\n"
          (if plan ":PLAN:\n" "")
          (mapconcat (lambda (n) (format "Prose line %d." n))
                     (number-sequence 1 body) "\n")
          "\n"
          (if plan ":END:\n" "")))

(ert-deftest claude-code-ide-org-test-lint-wants-a-plan-drawer-on-recent-finished-headings ()
  "The rule fires, which is the assertion the real files cannot make.

On the tracked files this check reports nothing at all -- by design, since
it is scoped to headings closed on or after the convention landed and none
are yet. A rule that has never been seen to fail proves nothing, so the
positive case has to come from a fixture."
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint
            (claude-code-ide-org-test--plan-fixture "[2026-08-25 Tue 09:00]" 12))
           'warn "no :PLAN: drawer")))

(ert-deftest claude-code-ide-org-test-lint-plan-drawer-rule-is-narrow ()
  "Every exemption, because each one silently swallowing a real finding is
how a lint rule becomes decorative.

Four ways not to fire, and they are different in kind: the drawer is
already there; the heading closed before the convention existed; it has no
CLOSED: at all, so its date is unknowable and 39 headings in DONE.org are
permanently in that position; and the body is too short to be worth
wrapping."
  (dolist (case (list
                 ;; Already wrapped.
                 (claude-code-ide-org-test--plan-fixture "[2026-08-25 Tue 09:00]" 12 t)
                 ;; Closed before the convention landed.
                 (claude-code-ide-org-test--plan-fixture "[2026-08-01 Sat 09:00]" 12)
                 ;; No CLOSED: at all -- date unknowable, so exempt.
                 (claude-code-ide-org-test--plan-fixture nil 12)
                 ;; Body too short to be worth a drawer.
                 (claude-code-ide-org-test--plan-fixture "[2026-08-25 Tue 09:00]" 3)))
    (should-not (claude-code-ide-org-test--lint-matches
                 (claude-code-ide-org-test--lint case)
                 'warn "no :PLAN: drawer"))))

(ert-deftest claude-code-ide-org-test-lint-plan-drawer-body-length-excludes-drawers ()
  "Drawer contents are not body prose, so a :LOGBOOK: cannot make a short
heading look substantial. Without this a heading whose only bulk is thirty
CLOCK lines would be told to wrap a body it does not have."
  (should-not
   (claude-code-ide-org-test--lint-matches
    (claude-code-ide-org-test--lint
     (concat "* Category\n"
             "** DONE Short body, long logbook                                    :code:\n"
             "CLOSED: [2026-08-25 Tue 09:00]\n"
             ":PROPERTIES:\n"
             ":ID:       11111111-1111-1111-1111-111111111111\n"
             ":CREATED:  [2026-08-14 Fri 10:00]\n"
             ":END:\n"
             ":LOGBOOK:\n"
             (mapconcat (lambda (n)
                          (format "CLOCK: [2026-08-2%d Tue 09:00]--[2026-08-2%d Tue 09:30] =>  0:30" (mod n 9) (mod n 9)))
                        (number-sequence 1 30) "\n")
             "\n:END:\n"
             "One line of prose.\n"))
    'warn "no :PLAN: drawer")))

;;; The meta-work day node (TODO.org :ID: 9575e65b)

(defmacro claude-code-ide-org-test--with-datetree (&rest body)
  "Run BODY with `file' bound to an org file holding a :DATE_TREE: category."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "ccio-datetree" t)))
          (file (expand-file-name "TODO.org" dir))
          (org-id-locations-file (expand-file-name ".org-id-locations" dir))
          (org-id-locations (make-hash-table :test 'equal))
          (org-id-files nil)
          (claude-code-ide-org-capture-file file)
          (claude-code-ide-org-query-files (list file)))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "#+TODO: TODO(t!) DOING(d!) | DONE(D!)\n\n"
                     "* Review and planning\n:PROPERTIES:\n:DATE_TREE: t\n:END:\n\n"
                     "Meta-work.\n"))
           ,@body)
       (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-day-node-dates-from-the-event-not-today ()
  "The node is dated from the event's timestamp, which is the whole decision.

Option (b) -- apply time, dated \"today\" -- was rejected precisely
because an event queued Monday 23:00 and applied Tuesday files Monday's
work under Tuesday. So this asks for a node for a date that is
emphatically not today and asserts the title org wrote."
  (claude-code-ide-org-test--with-datetree
    (let* ((when- (date-to-time "2026-08-17T23:00:00-0500"))
           (id (claude-code-ide-org-resolve-day-node when- 'create)))
      (should id)
      (with-temp-buffer
        (insert-file-contents file)
        (should (string-match-p "^\\*\\*\\*\\* 2026-08-17 Monday$" (buffer-string)))
        ;; And nothing dated today crept in.
        (should-not (string-match-p (format-time-string "^\\*\\*\\*\\* %Y-%m-%d %A$")
                                    (buffer-string)))
        ;; :CREATED: is stamped from the event too -- a node minted later
        ;; for Monday's work was created, as a record, on Monday.
        (should (string-match-p ":CREATED:  \\[2026-08-17 Mon 23:00\\]" (buffer-string)))))))

(ert-deftest claude-code-ide-org-test-day-node-is-idempotent-and-nests ()
  "Resolving twice returns the same id and writes one node, and the tree
nests inside the category rather than beside it.

The nesting is what `:DATE_TREE:' buys: without the narrowing,
`org-datetree-find-date-create' writes a second `* 2026' at level 1,
which `bin/lint-org' would then see as an uncategorised level-1
heading."
  (claude-code-ide-org-test--with-datetree
    (let* ((when- (date-to-time "2026-08-17T09:00:00-0500"))
           (a (claude-code-ide-org-resolve-day-node when- 'create))
           (b (claude-code-ide-org-resolve-day-node when- 'create)))
      (should (equal a b))
      (with-temp-buffer
        (insert-file-contents file)
        (let ((text (buffer-string)))
          (should (= 1 (cl-count "2026-08-17 Monday" (split-string text "\n")
                                 :test (lambda (n l) (string-match-p (regexp-quote n) l)))))
          ;; year node under the category, not at level 1
          (should (string-match-p "^\\*\\* 2026$" text))
          (should-not (string-match-p "^\\* 2026$" text)))))))

(ert-deftest claude-code-ide-org-test-day-node-never-created-without-create ()
  "Read-only resolution creates nothing and answers nil.

This is the `SessionStart' side: a session starting is not evidence that
any meta-work happened, so refreshing `org-clock-default-task' must
never mint a node. Without this the on-demand design would manufacture
one node per calendar day after all, just from a different trigger."
  (claude-code-ide-org-test--with-datetree
    (let ((before (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (should-not (claude-code-ide-org-resolve-day-node
                   (date-to-time "2026-08-17T09:00:00-0500")))
      (should (equal before (with-temp-buffer (insert-file-contents file)
                                              (buffer-string)))))))

(ert-deftest claude-code-ide-org-test-day-node-target-recognises-only-the-category ()
  "The category title is a target; anything else is not.

If this were loose, an ordinary heading whose title happened to match
would be silently redirected into the datetree."
  (claude-code-ide-org-test--with-datetree
    (should (claude-code-ide-org--day-node-target-p "Review and planning"))
    (should (claude-code-ide-org--day-node-target-p "  Review and planning  "))
    (should-not (claude-code-ide-org--day-node-target-p "Review and planning!"))
    (should-not (claude-code-ide-org--day-node-target-p "Tooling"))
    (should-not (claude-code-ide-org--day-node-target-p
                 "11111111-1111-1111-1111-111111111111"))
    (should-not (claude-code-ide-org--day-node-target-p nil))))

(ert-deftest claude-code-ide-org-test-apply-resolves-a-category-target ()
  "An item naming the category applies against that day's node.

The end-to-end shape of the decision: the queue carries the category,
apply turns it into a real heading, and the date comes from the item."
  (claude-code-ide-org-test--with-datetree
    (let* ((start (date-to-time "2026-08-17T09:00:00-0500"))
           (item (list :type 'clock :id "Review and planning"
                       :start start :end (time-add start 600)))
           (resolved (claude-code-ide-org--resolve-item-target item)))
      (should resolved)
      (should-not (equal resolved "Review and planning"))
      (with-temp-buffer
        (insert-file-contents file)
        (should (string-match-p "2026-08-17 Monday" (buffer-string))))
      ;; An ordinary :ID: target passes straight through, untouched.
      (should (equal "some-id"
                     (claude-code-ide-org--resolve-item-target
                      (list :type 'clock :id "some-id" :start start)))))))

(ert-deftest claude-code-ide-org-test-assign-offers-the-meta-work-category ()
  "The category is offered first, by title, and resolves through apply.

It is the one destination `org-id' cannot supply -- a category carries no
:ID: by convention and bin/lint-org enforces that -- so without this the
review buffer's `a' can never reach it however candidates are ranked.
That gap is not theoretical: the resolver shipped, and assigning a span
to the day node was still impossible from the only command meant to do
it (TODO.org :ID: 9575e65b)."
  (claude-code-ide-org-test--with-datetree
    (let* ((start (date-to-time "2026-08-17T09:00:00-0500"))
           (cands (claude-code-ide-org--assign-candidates start (time-add start 600))))
      ;; Present, first, and carrying the title rather than a UUID.
      (should (equal "Review and planning" (cdr (car cands))))
      (should (string-match-p "meta-work" (car (car cands))))
      ;; And what `a' would store resolves to a real day node dated from
      ;; the span, not from today.
      (let ((resolved (claude-code-ide-org--resolve-item-target
                       (list :type 'clock :id (cdr (car cands)) :start start))))
        (should resolved)
        (should-not (equal resolved "Review and planning"))
        (with-temp-buffer
          (insert-file-contents file)
          (should (string-match-p "2026-08-17 Monday" (buffer-string))))))))

(ert-deftest claude-code-ide-org-test-assign-omits-the-category-when-there-is-none ()
  "A file with no :DATE_TREE: offers no category row.

Without this the candidate list would grow a permanent entry naming a
destination that does not exist, and `completing-read' runs with
REQUIRE-MATCH -- so choosing it would fail at apply rather than at the
prompt."
  (let* ((dir (file-name-as-directory (make-temp-file "ccio-nodt" t)))
         (file (expand-file-name "TODO.org" dir))
         (claude-code-ide-org-capture-file file)
         (claude-code-ide-org-query-files (list file)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "* Tooling\n** DONE A task\n"))
          (should-not (claude-code-ide-org--datetree-category-title))
          (let ((cands (claude-code-ide-org--assign-candidates
                        (current-time) (current-time))))
            (should-not (seq-find (lambda (c) (string-match-p "meta-work" (car c)))
                                  cands))))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-review-buffer-wraps-rather-than-truncates ()
  "The review buffer wraps, at word boundaries, whatever the global default.

Every line in it is prose the human reads to decide something -- an
annotation label, a heading title, the reason an item writes nothing --
so truncation hides the part that carries the decision. Asserted against
a global default of t, because that is the case that matters: this user's
Doom config sets truncate-lines globally, and the buffer had been
toggled by hand on every visit.

word-wrap is asserted too: with truncation off but word-wrap nil the
break lands mid-word, which reads worse than either extreme."
  (let ((truncate-lines t) (word-wrap nil))
    (with-temp-buffer
      (claude-code-ide-org-review-mode)
      (should-not truncate-lines)
      (should word-wrap)
      ;; Buffer-local, so a global preference for truncation survives.
      (should (local-variable-p 'truncate-lines))
      (should (local-variable-p 'word-wrap)))))

(ert-deftest claude-code-ide-org-test-wrap-plan-refuses-a-body-holding-END ()
  "A bare `:END:' in the body is refused, because org's grammar cannot
contain it.

`:END:' IS the drawer terminator: `org-element's drawer parser stops at
the first line matching it and nothing escapes that -- not a comma, not
a #+BEGIN_ block. Measured on org 9.8.7 with :ID: cd1e974e, whose body
demonstrates a datetree subtree inside #+BEGIN_EXAMPLE. Wrapping closed
the drawer at the example's own `:END:', leaving the rest of the body --
a literal `SCHEDULED: <... +1d>' among it -- outside the drawer, where
`org-get-repeat' found it. One lint error and five spurious warnings out
of two inserted lines, with the heading still looking fine on screen.

The fixture is that heading in miniature. Note it deliberately puts the
`:END:' inside a block, since a reasonable reading is that a block
protects its contents -- the whole finding is that it does not."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "\nProspective prose.\n\n"
            "#+BEGIN_EXAMPLE\n"
            ",* Demo heading\n"
            ":PROPERTIES:\n:ID:  demo\n:END:\n"
            "SCHEDULED: <2026-08-22 Sat +1d>\n"
            "#+END_EXAMPLE\n\n"
            "*Shipped.* The debrief.\n")
    (save-buffer)
    (let ((result (claude-code-ide-org-wrap-plan id "*Shipped.*")))
      (should (string-match-p "bare :END: line" result)))
    ;; Refused means untouched: no drawer, and the heading still reads
    ;; as having no repeater.
    (claude-code-ide-org--at-id
     id (lambda ()
          (should-not (claude-code-ide-org--find-drawer "PLAN"))
          (should-not (org-get-repeat))))))

(ert-deftest claude-code-ide-org-test-interior-gap-keeps-its-timestamps ()
  "An interior gap still prints its times, because there they are the
information.

The discriminator for :ID: a279216c's fix: it drops the timestamps only
when the gap spans the whole window, where they merely repeat the line
above. A gap between two pieces of evidence says WHICH stretch was
empty, and that cannot be recovered from the span's own endpoints."
  (let* ((start (date-to-time "2026-08-13T17:00:00-0500"))
         (end (time-add start (* 30 60)))
         (claude-code-ide-org-span-evidence-gap 300))
    (claude-code-ide-org-test--with-stub-evidence
        (list (cons start "commit  aaa at the start")
              (cons (time-add start (* 20 60)) "commit  bbb twenty minutes in"))
      (let ((lines (claude-code-ide-org--span-evidence start end)))
        (should (seq-find (lambda (l) (string-match-p "nothing for" l)) lines))
        (should (seq-find (lambda (l) (string-match-p "17:00-17:20" l)) lines))
        (should-not (seq-find (lambda (l)
                                (string-match-p "no evidence found in this window" l))
                              lines))))))

(ert-deftest claude-code-ide-org-test-group-heading-names-all-four-kinds-of-id ()
  "The group heading distinguishes four kinds of :id, not two.

TODO.org :ID: 2b050e7a. This `cond' has been wrong three times, and each
fix added a case rather than questioning the shape: :ID: 98700ea3 fixed an
error string appearing where a title belonged, then a :DATE_TREE:
category target rendered as the first eight characters of its own title
\(\"Review a  (unresolved)\"), then a pending capture rendered as
\"(unresolvable :ID:)\" -- of an id whose heading is *supposed* not to
exist yet, since apply is what creates it.

Asserted together because the failure each time was a case falling into
a branch that describes a different thing, and only comparing all four
shows that."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org-test--with-datetree
      ;; 1. A real heading resolves to its title.
      (should (equal "Review and planning -- that day's meta-work node, created at apply"
                     (claude-code-ide-org--review-heading-title "Review and planning")))
      ;; 2. A category target is not unresolvable: it names a real
      ;;    destination that is not a heading.
      (should-not (string-match-p
                   "unresolv"
                   (claude-code-ide-org--review-heading-title "Review and planning")))
      ;; 3. A genuinely unknown id still answers nil, so the last branch
      ;;    keeps its meaning rather than being emptied by the others.
      (should-not (claude-code-ide-org--review-heading-title
                   "deadbeef-0000-0000-0000-000000000000")))))

(ert-deftest claude-code-ide-org-test-pending-capture-is-not-unresolvable ()
  "A capture's :ID: names a heading that does not exist YET, and the
render must say so rather than calling it broken.

The distinction is not cosmetic: the human is being asked to approve
that item, and `(unresolvable :ID:)' reads as a fault in the thing they
are approving -- exactly the wrong prompt for an item whose entire
purpose is to create the heading it names."
  (claude-code-ide-org-test--with-queue
    (apply #'claude-code-ide-org-test--queue-write "sess-a"
           (list (json-encode
                  `((ts . "2026-08-24T09:00:00-0500") (kind . "capture")
                    (id . "cap-0001") (title . "A heading not yet written")
                    (target . "Tooling") (session_id . "sess-a")))))
    (should (claude-code-ide-org--pending-capture "cap-0001"))
    (should-not (claude-code-ide-org--pending-capture "cap-9999"))))

(ert-deftest claude-code-ide-org-test-lint-caps-a-repeater-body ()
  "A repeater with an oversized body warns; a short one does not.

TODO.org :ID: ff92700e. Every pruning event in the :PLAN: lifecycle is
tied to reaching DONE, and a repeater never does -- its keyword resets
and its SCHEDULED stamp advances -- so nothing in the convention will
ever collect its body. The lint is the only thing that can notice.

It fires on nothing in the real files, so the positive case has to be a
fixture. Drawer contents are excluded from the count, which is asserted
here because the first measurement of this defect counted them and was
off by an order of magnitude."
  (let ((claude-code-ide-org-repeater-body-max 5))
    (let ((long (concat "* Category\n"
                        "** TODO A ritual                                                    :code:\n"
                        "SCHEDULED: <2026-08-24 Mon 07:00 ++1d>\n"
                        ":PROPERTIES:\n"
                        ":ID:       11111111-1111-1111-1111-111111111111\n"
                        ":CREATED:  [2026-08-14 Fri 10:00]\n"
                        ":END:\n"
                        (mapconcat (lambda (n) (format "Prose line %d." n))
                                   (number-sequence 1 8) "\n")
                        "\n")))
      (should (claude-code-ide-org-test--lint-matches
               (claude-code-ide-org-test--lint long) 'warn "repeater with a")))
    ;; A short body does not warn ...
    (let ((short (concat "* Category\n"
                         "** TODO A ritual                                                    :code:\n"
                         "SCHEDULED: <2026-08-24 Mon 07:00 ++1d>\n"
                         ":PROPERTIES:\n"
                         ":ID:       11111111-1111-1111-1111-111111111111\n"
                         ":CREATED:  [2026-08-14 Fri 10:00]\n"
                         ":END:\n"
                         "One line.\n")))
      (should-not (claude-code-ide-org-test--lint-matches
                   (claude-code-ide-org-test--lint short) 'warn "repeater with a")))
    ;; ... and neither does a short body inside a long drawer, which is
    ;; the miscount that made the first measurement of this defect wrong.
    (let ((drawered (concat "* Category\n"
                            "** TODO A ritual                                                :code:\n"
                            "SCHEDULED: <2026-08-24 Mon 07:00 ++1d>\n"
                            ":PROPERTIES:\n"
                            ":ID:       11111111-1111-1111-1111-111111111111\n"
                            ":CREATED:  [2026-08-14 Fri 10:00]\n"
                            ":END:\n"
                            ":LOGBOOK:\n"
                            (mapconcat (lambda (n)
                                         (format "- note line %d" n))
                                       (number-sequence 1 20) "\n")
                            "\n:END:\n"
                            "One line.\n")))
      (should-not (claude-code-ide-org-test--lint-matches
                   (claude-code-ide-org-test--lint drawered) 'warn "repeater with a")))))



(ert-deftest claude-code-ide-org-test-apply-failure-names-the-item ()
  "A failed item's report says WHICH item failed.

Measured 2026-08-24: an apply reported \"Applied 0 item(s); 5 failed:
Error: Before first headline at position 1 in buffer TODO.org\" five
times over. Every word true, and between them they identified nothing --
not the heading, not the kind, not the time. Three wrong hypotheses were
tried before anyone could act on it.

The bare error string is what `claude-code-ide-org--at-id' produces by
design: it converts every error so a batch is not unwound. This asserts
the identity is added back at the point of reporting."
  (let ((item (list :type 'state :id "11111111-1111-1111-1111-111111111111"
                    :ts (date-to-time "2026-08-24T15:02:00-0500")
                    :from "TODO" :to "DONE"))
        (claude-code-ide-org--last-error-backtrace nil))
    (let ((s (claude-code-ide-org--review-describe-failure
              item "Error: Before first headline at position 1")))
      (should (string-match-p "Before first headline" s))
      (should (string-match-p "state" s))
      (should (string-match-p "11111111" s))
      (should (string-match-p "15:02" s)))))

(ert-deftest claude-code-ide-org-test-apply-failure-handles-an-unassigned-item ()
  "An item with no :ID: still identifies itself.

The five failures that prompted this could each have been an unassigned
span, and a describer that assumed an :ID: would have errored while
reporting an error -- replacing a bad diagnosis with no diagnosis."
  (let ((item (list :type 'clock :id nil
                    :start (date-to-time "2026-08-24T16:00:00-0500")
                    :end (date-to-time "2026-08-24T16:31:00-0500")))
        (claude-code-ide-org--last-error-backtrace nil))
    (let ((s (claude-code-ide-org--review-describe-failure item "Error: boom")))
      (should (string-match-p "unassigned" s))
      (should (string-match-p "clock" s))
      (should (string-match-p "16:00" s)))))

(ert-deftest claude-code-ide-org-test-at-id-records-a-backtrace ()
  "`--at-id' keeps the stack it swallows.

It converts every error to a string so callers can report a failure
without unwinding a batch. That is deliberate and stays -- but it also
discarded the only evidence of WHERE the failure was, which is what made
five identical messages unactionable."
  (let ((claude-code-ide-org--last-error-backtrace nil))
    (claude-code-ide-org-test--with-heading
      (let ((result (claude-code-ide-org--at-id
                     id (lambda () (error "deliberate test failure")))))
        (should (string-match-p "deliberate test failure" result)))
      (let ((bt claude-code-ide-org--last-error-backtrace))
        (should bt)
        (should (equal id (plist-get bt :id)))
        (should (string-match-p "deliberate test failure" (plist-get bt :message)))
        (should (stringp (plist-get bt :backtrace)))))))

(ert-deftest claude-code-ide-org-test-mark-all-distinguishes-its-two-refusals ()
  "`M' says which items it skipped and why, because the answers differ.

`--review-markable-p' refuses two unrelated things: a STALE item, whose
heading has moved past what the event assumed, and an UNASSIGNED span
with no suggestion, which simply needs `a'. Reporting both as \"stale\"
told the user on 2026-08-24 that 13 items were stale when 7 were --
and sent them to dismiss six spans that merely wanted a heading, three
of which carried real recorded time. A dismissal has no undo.

Asserted on the message text, since the message is the defect."
  (let ((claude-code-ide-org--review-items
         (list
          ;; unassigned, no suggestion -> wants `a'
          (list :type 'clock :id nil :unassigned t :suggested t
                :start (date-to-time "2026-08-24T16:00:00-0500")
                :end (date-to-time "2026-08-24T16:31:00-0500"))
          ;; stale state item -> wants individual confirmation
          (list :type 'state :id "test-0001" :from "TODO" :to "DONE"
                :ts (date-to-time "2026-08-24T15:00:00-0500")
                :stale t)))
        captured)
    (cl-letf (((symbol-function 'claude-code-ide-org--review-render) #'ignore)
              ((symbol-function 'claude-code-ide-org--review-goto-line) #'ignore)
              ((symbol-function 'claude-code-ide-org--review-state-stale-p)
               (lambda (item) (plist-get item :stale)))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq captured (apply #'format fmt args)))))
      (claude-code-ide-org--review-set-all (lambda (_) t)))
    (should captured)
    (should (string-match-p "1 stale" captured))
    (should (string-match-p "1 unassigned" captured))
    ;; And it names the remedy for each, since they are different.
    (should (string-match-p "individually" captured))
    (should (string-match-p "assign a heading" captured))))

(ert-deftest claude-code-ide-org-test-annotation-honours-an-asserted-active-interval ()
  "An interval the human typed with <...> renders active; [...] does not.

Reported 2026-08-24: the user edited [16:00]--[16:00] to
<16:00>--<16:31> via `e', to say \"I thought about the design for those
31 minutes\". The times were kept and the bracket style -- the only
signal available about what KIND of time it was -- was discarded at
parse, because `--parse-org-timestamp' reads both forms identically.

Active matters: it is what reaches org-agenda, and
`--review-format-annotation' reserves it for intervals a human logs
themselves. :ID: b8e6007a established that rule while noting there was
no case that could reach it. `e' is that case.

Inactive stays the default and is asserted too, since an accidental
active timestamp publishes agent activity to the agenda -- the defect
b8e6007a was filed for."
  (let* ((start (date-to-time "2026-08-24T16:00:00-0500"))
         (end (date-to-time "2026-08-24T16:31:00-0500"))
         (base (list :type 'clock :id "id-a" :start start :end end :note "thinking")))
    ;; Default: inactive.
    (should (string-match-p "\\`- \\[2026-08-24"
                            (claude-code-ide-org--review-format-annotation base)))
    (should-not (string-match-p "<"
                                (claude-code-ide-org--review-format-annotation base)))
    ;; Asserted by the human: active, both endpoints.
    (let ((asserted (append base (list :active t))))
      (should (string-match-p "\\`- <2026-08-24[^>]*>--<2026-08-24[^>]*>"
                              (claude-code-ide-org--review-format-annotation asserted)))
      (should-not (string-match-p "\\["
                                  (claude-code-ide-org--review-format-annotation asserted))))))

;;; :ID: prefix expansion at the write boundary

(defmacro claude-code-ide-org-test--with-known-ids (&rest body)
  "Run BODY against a scratch file holding two known :ID:s."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "ccio-ids" t)))
          (file (expand-file-name "TODO.org" dir))
          (claude-code-ide-org-query-files (list file))
          (claude-code-ide-org-capture-file file))
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "* Category\n"
                     "** TODO First\n:PROPERTIES:\n"
                     ":ID:       8ca6541d-0fc7-45a2-a4d3-76e1608f658d\n:END:\n"
                     "** TODO Second\n:PROPERTIES:\n"
                     ":ID:       29439196-bbb8-4b64-b8d5-3bf9d457bf6c\n:END:\n"))
           ;; Ids written as raw text are unknown to org until something
           ;; scans for them -- which is the honest shape of a hand edit
           ;; or a `git pull', and exactly what the rescan-on-miss in
           ;; `claude-code-ide-org-resolve-id-links' exists to survive.
           ;; A fresh table per test, so one never leaks into the next.
           (let ((org-id-locations (make-hash-table :test 'equal))
                 (org-id-track-globally t))
             ,@body))
       (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-id-prefix-is-expanded ()
  "An 8-character prefix becomes the full :ID:.

This is the whole fix, and it is not policing -- it removes the need to
produce a tail at all. Nine UUIDs were fabricated across two sessions,
every one with a correct prefix and a wrong tail, with a memory
forbidding exactly that in force throughout. The prefix is reliably
known because it is cited in prose constantly; the 28 characters after
it feel like part of the same recollection and are not."
  (claude-code-ide-org-test--with-known-ids
    (let ((r (claude-code-ide-org-resolve-id-links
              "See [[id:8ca6541d][8ca6541d]] and [[id:29439196][29439196]].")))
      (should (car r))
      (should (string-match-p "8ca6541d-0fc7-45a2-a4d3-76e1608f658d" (cdr r)))
      (should (string-match-p "29439196-bbb8-4b64-b8d5-3bf9d457bf6c" (cdr r)))
      ;; The display half is untouched -- prose still cites the prefix.
      (should (string-match-p "\\]\\[8ca6541d\\]\\]" (cdr r))))))

(ert-deftest claude-code-ide-org-test-fabricated-id-is-refused ()
  "A full UUID that resolves to nothing is refused, not written.

The literal case from 2026-08-25: `8ca6541d-0fc7-41a3-9a3f-4dc9d8a97c9c'
was written for `...-0fc7-45a2-a4d3-76e1608f658d'. Correct for eleven
characters, wrong after, and it reached the file -- caught by
bin/lint-org on the next run, which meant a second commit and a
conversation that had already moved on."
  (claude-code-ide-org-test--with-known-ids
    (let ((r (claude-code-ide-org-resolve-id-links
              "See [[id:8ca6541d-0fc7-41a3-9a3f-4dc9d8a97c9c][8ca6541d]].")))
      (should-not (car r))
      (should (string-match-p "resolves to no heading" (cdr r)))
      ;; The message names the offender and the remedy.
      (should (string-match-p "8ca6541d-0fc7-41a3" (cdr r)))
      (should (string-match-p "8-character prefix" (cdr r))))))

(ert-deftest claude-code-ide-org-test-id-prefix-accepts-four-characters ()
  "A prefix shorter than eight expands, provided it is unique.

TODO.org :ID: 478d6ec9. The eight-character floor was the citation
convention's width, never a correctness requirement -- uniqueness is
what makes a prefix safe, and `--expand-id-prefix' already refuses an
ambiguous one rather than guessing.

Measured over the real corpus 2026-08-27, 282 ids: two characters
collide in 73 groups, three in four, and four in none -- identical to
eight. The user reports using short prefixes constantly, and until this
change every one of them fell through to `org-id-find' with a string
that could not possibly match."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-query-files (list file))
          (full "9f3c21ae-6b40-4d18-9a77-0c5e2b81d4f6"))
      (claude-code-ide-org-test--add-child
       file (concat "* TODO Short-prefix target\n:PROPERTIES:\n:ID:       "
                    full "\n:END:\n"))
      (org-id-update-id-locations (list file))
      (dolist (prefix '("9f3c" "9f3c21" "9f3c21ae"))
        (let ((loc (claude-code-ide-org--id-find prefix)))
          (should loc)
          (should (equal (file-truename file) (file-truename (car loc))))))
      ;; Below the floor, no expansion is attempted at all.
      (should-not (claude-code-ide-org--id-find "9f")))))

(ert-deftest claude-code-ide-org-test-ambiguous-prefix-does-not-rescan ()
  "An ambiguous prefix must not trigger a full re-index.

Rescanning reads every tracked file and its archives. For a *missing*
id that is worth it -- the id may have arrived out of band. For an
ambiguous one it is worthless by construction: more data can only add
matches, never resolve them.

Missing that distinction is what pinned Emacs at 99% CPU on 2026-08-27,
when a four-character prefix fell past the eight-character gate and
every lookup rescanned the corpus. Asserted by counting calls rather
than by timing, which would be flaky."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-query-files (list file))
          (calls 0))
      (claude-code-ide-org-test--add-child
       file (concat "* TODO One\n:PROPERTIES:\n"
                    ":ID:       abcd1234-1111-4111-8111-111111111111\n:END:\n"
                    "* TODO Two\n:PROPERTIES:\n"
                    ":ID:       abcd1234-2222-4222-8222-222222222222\n:END:\n"))
      (org-id-update-id-locations (list file))
      (cl-letf* ((orig (symbol-function 'org-id-update-id-locations))
                 ((symbol-function 'org-id-update-id-locations)
                  (lambda (&rest args) (setq calls (1+ calls)) (apply orig args))))
        (claude-code-ide-org--id-find "abcd1234")
        (should (= 0 calls))
        ;; A genuinely absent prefix still earns exactly one rescan.
        (claude-code-ide-org--id-find "beef")
        (should (= 1 calls))))))

(ert-deftest claude-code-ide-org-test-id-prefix-refuses-rather-than-guesses ()
  "An unmatched or ambiguous prefix is an error, never a choice.

Picking one of two candidates would produce a link that resolves, points
somewhere plausible, and is wrong -- the confidently-wrong record this
whole project exists to avoid."
  (claude-code-ide-org-test--with-known-ids
    (let ((r (claude-code-ide-org-resolve-id-links "See [[id:deadbeef][deadbeef]].")))
      (should-not (car r))
      (should (string-match-p "matches no heading" (cdr r))))
    ;; Both known ids share no prefix, so build ambiguity explicitly.
    (let* ((table (make-hash-table :test 'equal)))
      (puthash "abcd1234-1111-1111-1111-111111111111" t table)
      (puthash "abcd1234-2222-2222-2222-222222222222" t table)
      (let ((verdict (claude-code-ide-org--expand-id-prefix "abcd1234" table)))
      (should (eq 'ambiguous (car-safe verdict)))
      ;; The candidates travel with the verdict, so a caller can say
      ;; WHICH headings collided instead of "try again" -- the answer
      ;; that matters most for a short prefix.
      (should (equal '("abcd1234-1111-1111-1111-111111111111"
                       "abcd1234-2222-2222-2222-222222222222")
                     (cdr verdict)))))))

(ert-deftest claude-code-ide-org-test-text-without-id-links-is-untouched ()
  "Prose with no id links passes through byte-identical.

Every amendment goes through this, so a transform that altered ordinary
text would corrupt bodies wholesale rather than fail visibly."
  (claude-code-ide-org-test--with-known-ids
    (let* ((text "*Shipped 2026-08-25.* No links here -- just = markup = and [brackets].")
           (r (claude-code-ide-org-resolve-id-links text)))
      (should (car r))
      (should (equal text (cdr r))))))

(ert-deftest claude-code-ide-org-test-id-find-rescans-for-an-unindexed-prefix ()
  "A prefix whose full id org has never indexed still expands.

TODO.org :ID: 020d3688. Since 2026-08-27 expansion consults
`org-id-locations' rather than a table rebuilt from disk each call. That
is faster and strictly more complete, but it inherits org's one
assumption: an id enters the index when `org-id-get-create' runs *here*.
An id that arrived by hand edit, by `git pull', or from another Emacs is
unknown until something rescans.

`org-id-find's own fallback cannot cover this. It rescans and retries
the id it was given -- and what we hold is an eight-character prefix,
which will never match a full uuid however many times org looks. So the
rescan has to happen during expansion, before `org-id-find' is called at
all.

The fixture builds exactly that shape: a file written without org ever
visiting it, and an index that has never seen it."
  (let* ((dir (file-name-as-directory (make-temp-file "ccio-unindexed" t)))
         (file (expand-file-name "TODO.org" dir))
         (claude-code-ide-org-query-files (list file))
         (org-id-locations (make-hash-table :test 'equal))
         (org-id-track-globally t))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Category\n"
                    "** TODO Arrived out of band\n:PROPERTIES:\n"
                    ":ID:       7e1d40cb-2222-4222-8222-222222222222\n:END:\n"))
          (should-not (gethash "7e1d40cb-2222-4222-8222-222222222222"
                               org-id-locations))
          (let ((loc (claude-code-ide-org--id-find "7e1d40cb")))
            (should loc)
            (should (equal (file-truename file) (file-truename (car loc))))))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-at-id-accepts-an-8-char-prefix ()
  "Every tool taking an :ID: argument accepts the prefix instead.

The second fabrication surface. Expanding links protects what gets
WRITTEN; the `id\' argument is the other place a tail has to be produced
from nothing, and was on 2026-08-25 -- an `org_amend\' call carrying a
uuid whose first eight characters were right and whose remaining
twenty-eight were invented.  It errored, which is the good case.

Asserted through `--at-id\' rather than through a tool, because that is
where the expansion lives and every entry point inherits it, including
ones written later.

Note the heading here carries a *hexadecimal* id rather than the
fixture\'s `test-0001\': the expansion is gated on eight hex characters,
so the fixture id is correctly left alone and would make this test pass
for the wrong reason."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-query-files (list file))
          (full "9f3c21ae-6b40-4d18-9a77-0c5e2b81d4f6"))
      ;; Append through the visiting buffer rather than `write-region\',
      ;; because the fixture has already opened FILE and org-id would
      ;; otherwise search the stale buffer and not find the heading.
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-max))
        (insert "\n* TODO Prefixed heading\n:PROPERTIES:\n:ID:       " full
                "\n:END:\n\nBody.\n")
        (save-buffer))
      (org-id-add-location full file)
      (should (equal (claude-code-ide-org--at-id
                      (substring full 0 8) (lambda () (org-get-heading t t t t)))
                     "Prefixed heading")))))

(ert-deftest claude-code-ide-org-test-at-id-still-refuses-an-unknown-prefix ()
  "An 8-character string that matches nothing is still an error.

The expansion must not turn `no such heading' into a silent
no-op: it leaves the id untouched when nothing matches, so the normal
lookup failure is reported exactly as before."
  (claude-code-ide-org-test--with-heading
    (should (string-match-p "no org heading found"
                            (claude-code-ide-org--at-id
                             "deadbeef" (lambda () "unreachable"))))))

(ert-deftest claude-code-ide-org-test-amend-accepts-an-8-char-prefix ()
  "`org_amend\' takes a prefix, like every other id-taking tool.

The regression this exists for is specific and was found by using the
feature rather than by testing it.  `claude-code-ide-org-amend\' does its
own `org-id-find\' *before* delegating to `--at-id\', so the first
version of the prefix fix -- which expanded inside `--at-id\' only --
left amend failing on a prefix while `org_set_todo\' accepted one, and
the commit message claimed it covered every tool.  Fourteen call sites
had the same shape.

Asserting through the tool rather than through the wrapper is the point:
a wrapper test would have passed against the broken version."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-query-files (list file))
          (full "3ad9c47e-51b2-4f0c-8e63-7d2a90b615cc"))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-max))
        (insert "\n* TODO Amend target\n:PROPERTIES:\n:ID:       " full
                "\n:END:\n\nOriginal body.\n")
        (save-buffer))
      (org-id-add-location full file)
      (let ((reply (claude-code-ide-org-amend (substring full 0 8) "Appended by prefix.")))
        (should (string-match-p "Amend target" reply))
        (should-not (string-match-p "no org heading found" reply)))
      (with-temp-buffer
        (insert-file-contents file)
        (should (string-match-p "Appended by prefix\\." (buffer-string)))))))

;;; Slices: the :BLOCKER: half and its lint assertion --------------------

(defconst claude-code-ide-org-test--slice-fixture
  (concat "* Slices\n:PROPERTIES:\n:ARCHIVE:  DONE.org::* Slices\n:END:\n"
          "** DOING [1/3] A slice\n:PROPERTIES:\n"
          ":KIND:     slice\n"
          ":ID:       aaaaaaaa-0000-0000-0000-000000000000\n"
          ":COOKIE_DATA: checkbox recursive\n:END:\n\n"
          "- [X] [[id:11111111-0000-0000-0000-000000000000][11111111]] DONE done one\n"
          "  - [ ] [[id:22222222-0000-0000-0000-000000000000][22222222]] TODO nested, unstarted\n"
          "- [-] [[id:33333333-0000-0000-0000-000000000000][33333333]] DOING partial\n"
          "- [[id:44444444-0000-0000-0000-000000000000][44444444]] CANCELLED cookie deleted\n"
          "- [[orgit-rev:claude-code-ide-org::abc1234][abc1234]] a plan revision, not a member\n")
  "One slice covering every member shape at once.

Each line is here to defeat a different plausible-but-wrong parser: a
ticked member, an *unstarted* one (`[ ]' is a cookie, and an early
version of `--slice-members' wrongly treated it as an absent one), a
nested one, a cancelled one whose cookie was deleted, and an
`orgit-rev:' revision link that is a cookie-less list item but not a
member at all.")

(ert-deftest claude-code-ide-org-test-slice-members-parse ()
  "Every member shape is read, and the revision link is not one.

The nested member counts: a slice may mirror the tree, and a member
indented under another is still a member of the slice."
  (claude-code-ide-org-test--with-heading
    (with-temp-buffer
      (insert claude-code-ide-org-test--slice-fixture)
      (org-mode)
      (goto-char (point-min))
      (search-forward "** DOING")
      (let ((members (claude-code-ide-org--slice-members)))
        (should (= 4 (length members)))
        (should (equal '("11111111" "22222222" "33333333" "44444444")
                       (mapcar (lambda (m) (substring (car m) 0 8)) members)))
        ;; the cancelled member is the only one with no cookie
        (should (equal '("X" " " "-" nil) (mapcar #'cdr members)))))))

(ert-deftest claude-code-ide-org-test-slice-blocker-ids-exclude-deleted-cookies ()
  "A member that cannot block must not be in the blocker.

This is the whole reason the two sets are defined as \"members that
still carry a cookie\" rather than \"all members\". A deferred member is
*unfinished*, so blocking on it would hold the slice open forever for
work it explicitly decided not to do -- and unlike a cancelled one,
org-depend would never see it finish."
  (claude-code-ide-org-test--with-heading
    (with-temp-buffer
      (insert claude-code-ide-org-test--slice-fixture)
      (org-mode)
      (goto-char (point-min))
      (search-forward "** DOING")
      (let ((ids (claude-code-ide-org--slice-blocker-ids)))
        (should (= 2 (length ids)))
        (should (equal '("22222222" "33333333")
                       (mapcar (lambda (i) (substring i 0 8)) ids)))
        ;; Two exclusions with different reasons, asserted separately so a
        ;; regression says which rule broke: 44444444 has no cookie
        ;; (cancelled or deferred), 11111111 has an `X' one (done).
        (should-not (seq-find (lambda (i) (string-prefix-p "44444444" i)) ids))
        (should-not (seq-find (lambda (i) (string-prefix-p "11111111" i)) ids))))))

(ert-deftest claude-code-ide-org-test-slice-declaration-is-not-inherited ()
  "A subheading of a slice is not itself a slice.

`org-entry-get' without the inherit flag, so a child cannot pick the
declaration up from its parent. Slices have no subheadings by design,
which is exactly why an inheriting test would go unnoticed until one
did.

This replaced a tag-based detector that lasted an hour: the tags on the
first real slice were deleted as inadvertent and the lint assertion built
on them went silently inert, reporting zero errors because nothing was a
slice any more."
  (claude-code-ide-org-test--with-heading
    (with-temp-buffer
      (insert "* Top\n:PROPERTIES:\n:KIND:     slice\n:END:\n** Child\n")
      (org-mode)
      (goto-char (point-min))
      (search-forward "** Child")
      (should-not (claude-code-ide-org--slice-p))
      (goto-char (point-min))
      (search-forward "* Top")
      (should (claude-code-ide-org--slice-p)))))

(ert-deftest claude-code-ide-org-test-settle-refreshes-slices-after-apply ()
  "Apply's settle phase regenerates slices; an empty batch does not.

TODO.org :ID: a0abf97d.  A slice's member lines are copies of its
referents' keywords, and apply is the only thing that changes those in
bulk -- so without this a slice is stale by default between passes, and
silently, since `bin/lint-org' compares the `:BLOCKER:' against the
checkbox list and `refresh-slice' regenerates both together.

Asserted by counting calls rather than by inspecting a file, because
what was missing was the *invocation*: `refresh-slice' itself is already
covered by :ID: 0acc1df2's tests, and re-testing it here would pass
whether or not anything called it."
  (let ((calls 0))
    (cl-letf (((symbol-function 'claude-code-ide-org-refresh-slice)
               (lambda (&optional _id) (setq calls (1+ calls)))))
      ;; Nothing applied -> nothing to restate.
      (claude-code-ide-org--review-settle-slices nil)
      (should (= 0 calls))
      ;; Anything applied -> exactly one regeneration for the batch,
      ;; not one per item.
      (claude-code-ide-org--review-settle-slices '((:id "a") (:id "b") (:id "c")))
      (should (= 1 calls)))))

(ert-deftest claude-code-ide-org-test-settle-normalises-separation-after-apply ()
  "Apply repairs the separation drift it causes, rather than reporting it.

TODO.org :ID: 601c885c asked for a lint rule and got this instead.  The
drift is *structural* -- apply appends without the trailing lines, so it
arrives on every pass -- and a defect produced by apply can be repaired
by apply.  Eighteen warnings telling a human to run one idempotent
command is eighteen lines standing in for one call.

Ordered after the slice refresh, which rewrites member lines and can
itself disturb separation."
  (let (calls)
    (cl-letf (((symbol-function 'claude-code-ide-org-normalize-heading-separation)
               (lambda (&optional _f _dry) (push 'separation calls))))
      (claude-code-ide-org--review-settle-separation nil)
      (should (null calls))
      (claude-code-ide-org--review-settle-separation '((:id "a")))
      (should (equal '(separation) calls))))
  ;; Ordering is asserted against the CALL SITE, not by calling the two
  ;; in sequence here -- that only proves this test's own order and
  ;; passes with the call site reversed, which a break-it pass showed.
  (let ((src (prin1-to-string
              (symbol-function 'claude-code-ide-org--review-apply))))
    (should (string-match-p "settle-slices" src))
    (should (string-match-p "settle-separation" src))
    (should (< (string-match "settle-slices" src)
               (string-match "settle-separation" src)))))

(ert-deftest claude-code-ide-org-test-settle-separation-failure-does-not-fail-the-apply ()
  "Same contract as the slice refresh: bookkeeping must not sink the pass."
  (cl-letf (((symbol-function 'claude-code-ide-org-normalize-heading-separation)
             (lambda (&optional _f _dry) (error "normaliser is on fire"))))
    (should (eq 'survived
                (condition-case nil
                    (progn (claude-code-ide-org--review-settle-separation '((:id "a")))
                           'survived)
                  (error 'escaped))))))

(ert-deftest claude-code-ide-org-test-settle-separation-writes-rather-than-reports ()
  "It must run for real, not as a dry run.

The whole decision was to repair instead of report; passing DRY-RUN
non-nil would silently turn it back into a report nobody reads."
  (let (args)
    (cl-letf (((symbol-function 'claude-code-ide-org-normalize-heading-separation)
               (lambda (&optional f dry) (setq args (list f dry)))))
      (claude-code-ide-org--review-settle-separation '((:id "a")))
      (should (equal '(nil nil) args)))))

(ert-deftest claude-code-ide-org-test-settle-slice-failure-does-not-fail-the-apply ()
  "A slice that cannot be regenerated must not sink a successful apply.

This is bookkeeping *after* the work.  The staleness left behind is the
status quo ante rather than new damage, whereas an error escaping here
would report a pass that genuinely landed as a failed one."
  (cl-letf (((symbol-function 'claude-code-ide-org-refresh-slice)
             (lambda (&optional _id) (error "slice is on fire"))))
    ;; Asserted on whether an error ESCAPES, not on the return value --
    ;; the function returns whatever `message' hands back, so
    ;; `should-not' on its result tests the wrong thing and fails
    ;; against correct code.
    (should (eq 'survived
                (condition-case nil
                    (progn (claude-code-ide-org--review-settle-slices '((:id "a")))
                           'survived)
                  (error 'escaped))))))

(ert-deftest claude-code-ide-org-test-refresh-slice-blocker-writes-the-property ()
  "The blocker is derived from the checklist, not authored.

Asserts idempotence too: a second run reports no change, which is what
lets this sit in the ceremony beside the other normalisers without
producing a diff every time it is run."
  (claude-code-ide-org-test--with-heading
    (with-temp-buffer
      (insert claude-code-ide-org-test--slice-fixture)
      (org-mode)
      (goto-char (point-min))
      (search-forward "** DOING")
      (should (claude-code-ide-org--refresh-slice-blocker-at-point))
      (let ((blocker (org-entry-get nil "BLOCKER")))
        (should (string-prefix-p "ids(" blocker))
        (should (= 2 (length (claude-code-ide-org--lint-blocker-ids blocker))))
        (should-not (string-match-p "44444444" blocker))
        (should-not (string-match-p "11111111" blocker)))
      ;; idempotent
      (should-not (claude-code-ide-org--refresh-slice-blocker-at-point)))))

(ert-deftest claude-code-ide-org-test-refresh-slice-blocker-removes-an-empty-one ()
  "A slice with no cookie-carrying members loses its :BLOCKER: entirely.

`ids()' is not written, because it would read as a declaration that
nothing blocks and the lint would then have to tell that apart from a
slice whose blocker was never built."
  (claude-code-ide-org-test--with-heading
    (with-temp-buffer
      (insert "* Slices\n** DOING A slice\n:PROPERTIES:\n:KIND:     slice\n"
              ":BLOCKER:  ids(11111111-0000-0000-0000-000000000000)\n:END:\n\n"
              "- [[id:11111111-0000-0000-0000-000000000000][11111111]] CANCELLED dropped\n")
      (org-mode)
      (goto-char (point-min))
      (search-forward "** DOING")
      (should (claude-code-ide-org--refresh-slice-blocker-at-point))
      (should-not (org-entry-get nil "BLOCKER")))))

(ert-deftest claude-code-ide-org-test-lint-catches-slice-with-keyworded-children ()
  "A declared slice with a keyworded child is a hybrid and errors.

The negative cases carry the rule's two deliberate edges: a keyword-less
child under a slice is a note and legal, and an ordinary container with
keyworded children is a story and none of this rule's business."
  (let ((cat "* Slices\n:PROPERTIES:\n:ARCHIVE:  DONE.org::* Slices\n:END:\n")
        (child-props ":PROPERTIES:\n:ID:       22222222-0000-0000-0000-000000000000\n:CREATED:  [2026-09-03 Thu 12:00]\n:END:\n"))
    ;; hybrid: slice with a keyworded child
    (should (claude-code-ide-org-test--lint-matches
             (claude-code-ide-org-test--lint
              (concat cat "** DOING [0/0] A slice\n:PROPERTIES:\n:KIND:     slice\n:END:\n\n"
                      "*** TODO a keyworded child\n" child-props))
             'error "slice has keyworded children"))
    ;; a keyword-less child is a note, not a hybrid
    (should-not (claude-code-ide-org-test--lint-matches
                 (claude-code-ide-org-test--lint
                  (concat cat "** DOING [0/0] A slice\n:PROPERTIES:\n:KIND:     slice\n:END:\n\n"
                          "*** a note child\n" child-props))
                 'error "slice has keyworded children"))
    ;; an ordinary container is a story, not this rule's business
    (should-not (claude-code-ide-org-test--lint-matches
                 (claude-code-ide-org-test--lint
                  (concat cat "** DOING [0/1] A story\n:PROPERTIES:\n:ID:       33333333-0000-0000-0000-000000000000\n:CREATED:  [2026-09-03 Thu 12:00]\n:END:\n\n"
                          "*** TODO a keyworded child\n" child-props))
                 'error "slice has keyworded children"))))

(ert-deftest claude-code-ide-org-test-lint-catches-slice-blocker-drift ()
  "The lint reports a slice whose blocker and checklist disagree.

Both directions, because an implementation that only compared one way
would pass the other. And the negative case matters most: an untagged
heading carrying an identical checkbox list must NOT be linted as a
slice, since an ordinary body may hold a list of id links for reference
-- which is precisely why a slice has to be declared rather than
derived."
  (let* ((cat "* Slices\n:PROPERTIES:\n:ARCHIVE:  DONE.org::* Slices\n:END:\n")
         ;; Unfinished deliberately: since 2026-08-28 a done member is not
         ;; in the blocker, so an `[X]' member here would make every case
         ;; below vacuous rather than failing loudly.
         (member "- [ ] [[id:11111111-0000-0000-0000-000000000000][11111111]] TODO one\n")
         (done "- [X] [[id:88888888-0000-0000-0000-000000000000][88888888]] DONE two\n"))
    ;; blocker missing entirely
    (should (claude-code-ide-org-test--lint-matches
             (claude-code-ide-org-test--lint
              (concat cat "** DOING A slice\n:PROPERTIES:\n:KIND:     slice\n:END:\n" "\n" member))
             'error "omits 1 unfinished member"))
    ;; blocker names something that is not a checked member
    (should (claude-code-ide-org-test--lint-matches
             (claude-code-ide-org-test--lint
              (concat cat "** DOING A slice\n:PROPERTIES:\n:KIND:     slice\n"
                      ":BLOCKER:  ids(11111111-0000-0000-0000-000000000000 "
                      "99999999-0000-0000-0000-000000000000)\n:END:\n\n" member))
             'error "not an unfinished member"))
    ;; a *done* member is not in the blocker, and its absence is not drift
    (should-not (claude-code-ide-org-test--lint-matches
                 (claude-code-ide-org-test--lint
                  (concat cat "** DOING A slice\n:PROPERTIES:\n:KIND:     slice\n"
                          ":BLOCKER:  ids(11111111-0000-0000-0000-000000000000)\n:END:\n\n"
                          member done))
                 'error "omits"))
    ;; and naming it *is* drift, in the other direction
    (should (claude-code-ide-org-test--lint-matches
             (claude-code-ide-org-test--lint
              (concat cat "** DOING A slice\n:PROPERTIES:\n:KIND:     slice\n"
                      ":BLOCKER:  ids(11111111-0000-0000-0000-000000000000 "
                      "88888888-0000-0000-0000-000000000000)\n:END:\n\n" member done))
             'error "not an unfinished member"))
    ;; matching: silent
    (should-not (claude-code-ide-org-test--lint-matches
                 (claude-code-ide-org-test--lint
                  (concat cat "** DOING A slice\n:PROPERTIES:\n:KIND:     slice\n"
                          ":BLOCKER:  ids(11111111-0000-0000-0000-000000000000)\n:END:\n\n"
                          member))
                 'error "slice :BLOCKER:"))
    ;; same list, no tag: not a slice, not linted
    (should-not (claude-code-ide-org-test--lint-matches
                 (claude-code-ide-org-test--lint
                  (concat cat "** DOING Not a slice\n" "\n" member))
                 'error "slice :BLOCKER:"))))

(ert-deftest claude-code-ide-org-test-refresh-slice-regenerates-member-lines ()
  "A stale member line is rewritten from its referent.

Covers the three fields that are copies -- checkbox, keyword, title --
and the one that is not: the link is left alone, because it is the only
part that cannot go stale.

The referent's own statistics cookie is *stripped*, and that is not
cosmetic. Copying `[0/1]' into a checkbox list does not carry the
referent's progress across: org reads it as a cookie belonging to that
list item and recomputes it against the slice's structure, so a leaf
member renders `[0/0]' -- a number that reports the slice while reading
as the referent."
  (claude-code-ide-org-test--with-heading
    (let ((slice (expand-file-name "slice.org" dir)))
      (with-temp-file slice
        (insert "#+TODO: TODO NEXT DOING REVIEW | DONE CANCELLED\n"
                "* Slices\n:PROPERTIES:\n:ARCHIVE:  DONE.org::* Slices\n:END:\n"
                "** DOING [0/0] S\n:PROPERTIES:\n:KIND:     slice\n"
                ":COOKIE_DATA: checkbox recursive\n:END:\n\n"
                ;; every field stale: box, keyword and title
                "- [ ] [[id:11111111-0000-0000-0000-000000000000][11111111]] TODO an old title\n"
                "- [X] [[id:22222222-0000-0000-0000-000000000000][22222222]] DONE also stale\n\n"
                "* Work\n"
                "** DONE [1/2] Finished, and carrying a cookie\n:PROPERTIES:\n"
                ":ID:       11111111-0000-0000-0000-000000000000\n:END:\n"
                "** REVIEW Handed back\n:PROPERTIES:\n"
                ":ID:       22222222-0000-0000-0000-000000000000\n:END:\n"))
      (let ((claude-code-ide-org-query-files (list slice)))
        (claude-code-ide-org-refresh-slice)
        (with-temp-buffer
          (insert-file-contents slice)
          (let ((text (buffer-string)))
            ;; DONE -> [X], keyword and title refreshed, cookie stripped
            (should (string-match-p
                     "- \\[X\\] \\[\\[id:11111111[^]]*\\]\\[11111111\\]\\] DONE Finished, and carrying a cookie$"
                     text))
            (should-not (string-match-p "11111111\\]\\] DONE \\[1/2\\]" text))
            ;; REVIEW -> [-], and the wrongly-ticked box is corrected downward
            (should (string-match-p
                     "- \\[-\\] \\[\\[id:22222222[^]]*\\]\\[22222222\\]\\] REVIEW Handed back$"
                     text))
            ;; the slice's own cookie follows
            (should (string-match-p "^\\*\\* DOING \\[1/2\\] S" text))))))))

(ert-deftest claude-code-ide-org-test-refresh-slice-skips-what-it-cannot-resolve ()
  "An unresolvable or keywordless member is left exactly as written.

Both are already errors in `bin/lint-org'. A regenerator that invented a
state for them would paper over precisely what those errors exist to
surface, and it would do so by *editing the file*, which is the harder
kind of wrong to notice."
  (claude-code-ide-org-test--with-heading
    (let ((slice (expand-file-name "slice2.org" dir)))
      (with-temp-file slice
        (insert "#+TODO: TODO | DONE\n"
                "* Slices\n** DOING S\n:PROPERTIES:\n:KIND:     slice\n:END:\n\n"
                "- [ ] [[id:99999999-0000-0000-0000-000000000000][99999999]] TODO resolves to nothing\n"
                "- [ ] [[id:33333333-0000-0000-0000-000000000000][33333333]] TODO keywordless target\n\n"
                "* Work\n** A heading with no keyword\n:PROPERTIES:\n"
                ":ID:       33333333-0000-0000-0000-000000000000\n:END:\n"))
      (let ((claude-code-ide-org-query-files (list slice))
            (before (with-temp-buffer (insert-file-contents slice) (buffer-string))))
        (claude-code-ide-org-refresh-slice)
        (with-temp-buffer
          (insert-file-contents slice)
          (should (string-match-p "99999999\\]\\] TODO resolves to nothing" (buffer-string)))
          (should (string-match-p "33333333\\]\\] TODO keywordless target" (buffer-string))))))))

(ert-deftest claude-code-ide-org-test-apply-writes-through-a-read-only-buffer ()
  "Apply succeeds when the user has set `buffer-read-only', and restores it.

The user sets that flag to guard against their own stray keystrokes
while reading a file. Pressing `x' in the review buffer is the opposite
of a stray keystroke, so the guard must not stand between them and a
command they just invoked.

Hit for real 2026-08-25: a pass reported \"Applied 0 item(s); 1 failed\"
and the failure was `Buffer is read-only', caused by an assistant
*correctly* restoring the flag after borrowing it for an `org_amend'.

The second assertion is the one that keeps this honest. `inhibit-read-only'
is *bound*, not set, so the buffer must still be read-only afterwards --
an implementation that cleared `buffer-read-only' instead would pass the
first assertion and silently disarm the user's guard, which is the very
defect c8a97d9d is named for."
  (claude-code-ide-org-test--with-heading
    (let ((item (list :type 'clock :id id
                      :start (date-to-time "2026-08-06T09:00:00-0500")
                      :end (date-to-time "2026-08-06T09:15:00-0500")
                      :agent nil :suggested nil :events nil)))
      (with-current-buffer (find-file-noselect file)
        (setq buffer-read-only t))
      (should-not (claude-code-ide-org--review-apply-item item))
      (should (string-match-p "=>  0:15" (claude-code-ide-org-test--logbook file)))
      (should (with-current-buffer (find-file-noselect file) buffer-read-only)))))

(ert-deftest claude-code-ide-org-test-at-id-writable-binds-and-at-id-does-not ()
  "The write dispatcher binds `inhibit-read-only'; the plain one must not.

`claude-code-ide-org--at-id' serves the read-only tools too, so binding
there would grant write permission to code that should never write --
turning a bug in a query tool into a silent edit of a buffer the user
deliberately guarded. The second assertion is the one that would catch
someone \"simplifying\" the two into one."
  (claude-code-ide-org-test--with-heading
    (should (claude-code-ide-org--at-id-writable
             id (lambda () inhibit-read-only)))
    (should-not (claude-code-ide-org--at-id
                 id (lambda () inhibit-read-only)))))

(defmacro claude-code-ide-org-test--with-read-only-heading (&rest body)
  "Fixture with a second sibling, the buffer read-only, and BODY run there.
Asserts afterwards that the guard survived: `inhibit-read-only' is
*bound*, never set, so an implementation that cleared
`buffer-read-only' instead would satisfy every write assertion and
silently disarm the user\'s guard -- which is the defect TODO.org
:ID: c8a97d9d is named for, reintroduced by its own fix."
  (declare (indent 0))
  `(claude-code-ide-org-test--with-heading
     (goto-char (point-max))
     (insert "* TODO Second heading\n:PROPERTIES:\n:ID:       test-0002\n:END:\n")
     (save-buffer)
     (org-id-update-id-locations (list file))
     (with-current-buffer (find-file-noselect file) (setq buffer-read-only t))
     ,@body
     (should (with-current-buffer (find-file-noselect file) buffer-read-only))))

;; Each write tool gets its own case rather than a shared table, so a
;; failure names the tool. Between them they cover both code paths: amend,
;; move-sibling and refile route through `--at-id-writable', while
;; set-property and divide reach their buffer directly and bind in their
;; own `let'. A fix applied to only one path passes a single-tool test,
;; which is why both are represented (TODO.org :ID: c8a97d9d).
;;
;; Measured 2026-08-31, before the fix: amend, divide and move-sibling all
;; returned "Error: Buffer is read-only" and wrote nothing. set-property
;; did *not* -- `org-entry-put' binds `inhibit-read-only' itself, so that
;; one passed before the change and passes after it. Its binding is
;; therefore defence in depth rather than load-bearing, and mutating it
;; away will not fail anything here. That is recorded rather than tidied
;; away, because a reader who greps for the binding is owed the
;; difference.

(ert-deftest claude-code-ide-org-test-amend-survives-a-read-only-buffer ()
  (claude-code-ide-org-test--with-read-only-heading
    (should (equal "Amended: \"Test heading\""
                   (claude-code-ide-org-amend id "read-only probe")))
    (should (string-match-p "read-only probe"
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-set-property-survives-a-read-only-buffer ()
  (claude-code-ide-org-test--with-read-only-heading
    (should-not (string-match-p
                 "read-only" (claude-code-ide-org-set-property id "PROBE" "yes")))
    (should (string-match-p ":PROBE:\\s-+yes"
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-divide-survives-a-read-only-buffer ()
  (claude-code-ide-org-test--with-read-only-heading
    (should-not (string-match-p
                 "read-only" (claude-code-ide-org-divide id "Probe parent")))
    (should (string-match-p "^\\* TODO Probe parent"
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-move-sibling-survives-a-read-only-buffer ()
  "Asserts the resulting *order*, not that the heading is present.
Presence is true before the move as well, so it would pass against a
tool that failed outright -- which is exactly what an earlier draft of
this test did on 2026-08-31, caught by the reply assertion alone."
  (claude-code-ide-org-test--with-read-only-heading
    (should-not (string-match-p
                 "read-only" (claude-code-ide-org-move-sibling "test-0002" "up")))
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (< (string-match-p "Second heading" disk)
                 (string-match-p "Test heading" disk))))))

(ert-deftest claude-code-ide-org-test-refile-survives-a-read-only-buffer ()
  (claude-code-ide-org-test--with-read-only-heading
    (should-not (string-match-p
                 "read-only" (claude-code-ide-org-refile id "test-0002")))
    (should (string-match-p "^\\*\\* TODO Test heading"
                            (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-archive-finished-survives-a-read-only-buffer ()
  "The ceremony's archive step must not die on the user's own guard.

Hit for real 2026-09-01, on the first ceremony to fire unattended: it
reported `archive: FAILED (Buffer is read-only ...)\' against a read-only
TODO.org, correctly withheld the stamp, and left 20 finished headings in
place (TODO.org :ID: 13ea6770). This runs at the tail of an apply the
human already authorised by pressing `x\' and then `q\', so there is no
keystroke left to prompt on.

As everywhere else, the flag is *bound*, so the buffer is still
read-only afterwards -- an implementation that cleared it would pass the
archive assertion and disarm the guard."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--set-todo-for-real id "DONE")
    (let ((claude-code-ide-org-query-files (list file)))
      (with-current-buffer (find-file-noselect file)
        (setq buffer-read-only t))
      (should (= 1 (claude-code-ide-org-archive-finished file)))
      ;; It left the source, and it reached the archive target.
      (should-not (string-match-p
                   "Test heading" (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p
               "Test heading"
               (claude-code-ide-org-test--disk-contents archive-file)))
      (should (with-current-buffer (find-file-noselect file) buffer-read-only)))))

(ert-deftest claude-code-ide-org-test-refresh-slice-survives-a-read-only-buffer ()
  "The ceremony step after apply must not fail where apply now succeeds.

`claude-code-ide-org-refresh-slice' runs immediately after a review
pass, on the human's own `M-x'. Leaving it subject to `buffer-read-only'
would reproduce the 2026-08-25 incident one command later: apply
succeeds, the normaliser that keeps the slice honest does not, and the
slice silently stays stale -- which nothing detects, since the lint
compares :BLOCKER: against the checkbox list and both go stale together.

As in the apply path the flag is *bound*, so the buffer is still
read-only afterwards."
  (claude-code-ide-org-test--with-heading
    (let ((slice (expand-file-name "ro-slice.org" dir)))
      (with-temp-file slice
        (insert "#+TODO: TODO | DONE\n"
                "* Slices\n** DOING [0/0] S\n:PROPERTIES:\n:KIND:     slice\n:END:\n\n"
                "- [ ] [[id:11111111-0000-0000-0000-000000000000][11111111]] TODO stale\n\n"
                "* Work\n** DONE Finished\n:PROPERTIES:\n"
                ":ID:       11111111-0000-0000-0000-000000000000\n:END:\n"))
      (with-current-buffer (find-file-noselect slice) (setq buffer-read-only t))
      (let ((claude-code-ide-org-query-files (list slice)))
        (claude-code-ide-org-refresh-slice)
        (with-temp-buffer
          (insert-file-contents slice)
          (should (string-match-p "- \\[X\\] .*11111111\\]\\] DONE Finished" (buffer-string))))
        (should (with-current-buffer (find-file-noselect slice) buffer-read-only))))))

(provide 'claude-code-ide-org-config-test)

;;; config-test.el ends here

(ert-deftest claude-code-ide-org-test-divide-carries-everything-to-the-child ()
  "Mitosis: a new parent appears above the leaf and the leaf moves under
it, keeping its :ID:, its clock and its history (TODO.org :ID: a0813ae3).

Asserts what *stayed* as well as what moved, because the id question was
the one thing the heading had to settle and it settled on the leaf: a
queued clock event names a heading by id, so an id that migrated to the
new parent would make a pending clock_in open a clock on a container --
the exact outcome mitosis exists to prevent.

The parent is asserted to be born *empty* -- no CLOCK, no :LOGBOOK: --
rather than merely to exist, since a story that inherited a clock is the
defect 3964c575 could not enforce its way out of."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker)
      (org-entry-put nil "CATEGORY" "Skill")
      (org-end-of-meta-data t)
      (insert ":LOGBOOK:\nCLOCK: [2026-08-01 Sat 09:00]--[2026-08-01 Sat 10:00] =>  1:00\n:END:\n")
      (save-buffer))
    (let ((reply (claude-code-ide-org-divide id "A story now")))
      (should (string-prefix-p "Divided:" reply)))
    (with-current-buffer (find-file-noselect file)
      (revert-buffer t t)
      (goto-char (point-min))
      ;; The parent sits where the child used to, at level 1.
      (should (re-search-forward "^\\* TODO A story now \\[0/1\\]$" nil t))
      (let ((parent-end (save-excursion (org-end-of-subtree t t))))
        (org-back-to-heading t)
        (should (org-entry-get nil "ID"))
        (should (org-entry-get nil "CREATED"))
        (should (equal "Skill" (org-entry-get nil "CATEGORY")))
        ;; Born empty: the parent's own body holds no clock or logbook.
        (let ((own (buffer-substring-no-properties
                    (point) (save-excursion (org-goto-first-child) (point)))))
          (should-not (string-match-p "CLOCK:" own))
          (should-not (string-match-p ":LOGBOOK:" own)))
        ;; The child is now one level deeper, and kept everything.
        (org-goto-first-child)
        (should (= 2 (org-current-level)))
        (should (equal id (org-entry-get nil "ID")))
        (should (equal "TODO" (org-get-todo-state)))
        (let ((child (buffer-substring-no-properties (point) parent-end)))
          (should (string-match-p "CLOCK: \\[2026-08-01 Sat 09:00\\]" child)))))))

(ert-deftest claude-code-ide-org-test-set-property-writes-and-refuses ()
  "`org_set_property' fills the gap that made the discouraged form cheaper.

TODO.org :ID: 36b811d9: no tool set a property, so every :BLOCKER: was an
`emacsclient' call while a prose \"depends on ...\" sentence cost nothing
-- and CLAUDE.md asks for the property precisely because it is
machine-checkable and the sentence is not.

:ID: and :CREATED: are refused rather than merely discouraged.  They are
identity, written once at capture; rewriting an :ID: orphans every
inbound link and every queued event naming it, silently."
  (claude-code-ide-org-test--with-heading
    (should (string-prefix-p "Set CATEGORY"
                             (claude-code-ide-org-set-property id "CATEGORY" "Skill")))
    (should (equal "Skill" (org-with-point-at (org-id-find id 'marker)
                             (org-entry-get nil "CATEGORY"))))
    ;; lower case is accepted; the property name is normalised
    (should (string-prefix-p "Set ARCHIVE"
                             (claude-code-ide-org-set-property id "archive" "X.org::* Done")))
    (should (string-prefix-p "Error:" (claude-code-ide-org-set-property id "ID" "nope")))
    (should (string-prefix-p "Error:" (claude-code-ide-org-set-property id "CREATED" "nope")))
    (should (equal id (org-with-point-at (org-id-find id 'marker)
                        (org-entry-get nil "ID"))))
    (should (string-prefix-p "Error:" (claude-code-ide-org-set-property "no-such" "CATEGORY" "x")))))

(ert-deftest claude-code-ide-org-test-set-property-validates-blocker-ids ()
  "A :BLOCKER: naming an id that does not exist never blocks and never
errors -- it does nothing, forever.  So the ids are resolved at the call
site, 8-character prefixes expanded, and anything unresolvable refused.

TODO.org :ID: 36b811d9 records three fabricated ids in one session, each
caught only by a later link-resolution sweep.  Nothing downstream would
have caught them, which is why validation belongs here rather than in a
convention.

APPEND unions rather than overwrites, because :BLOCKER: holds a *set* --
the one thing a general property writer would get silently wrong."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file "** TODO Blocking one\n:PROPERTIES:\n:ID:       aaaaaaaa-1111-2222-3333-444444444444\n:END:\n")
    (claude-code-ide-org-test--add-child
     file "** TODO Blocking two\n:PROPERTIES:\n:ID:       bbbbbbbb-1111-2222-3333-444444444444\n:END:\n")
    (org-id-update-id-locations (list file))
    ;; an unresolvable id is refused, and nothing is written
    (should (string-match-p "cannot resolve"
                            (claude-code-ide-org-set-property id "BLOCKER" "deadbeef")))
    (should-not (org-with-point-at (org-id-find id 'marker) (org-entry-get nil "BLOCKER")))
    ;; an 8-character prefix is expanded to the full id
    (should (string-prefix-p "Set BLOCKER"
                             (claude-code-ide-org-set-property id "BLOCKER" "aaaaaaaa")))
    (let ((v (org-with-point-at (org-id-find id 'marker) (org-entry-get nil "BLOCKER"))))
      (should (equal "ids(aaaaaaaa-1111-2222-3333-444444444444)" v)))
    ;; append unions rather than replacing
    (claude-code-ide-org-set-property id "BLOCKER" "bbbbbbbb" t)
    (let ((v (org-with-point-at (org-id-find id 'marker) (org-entry-get nil "BLOCKER"))))
      (should (string-match-p "aaaaaaaa" v))
      (should (string-match-p "bbbbbbbb" v)))
    ;; without append it replaces
    (claude-code-ide-org-set-property id "BLOCKER" "bbbbbbbb")
    (let ((v (org-with-point-at (org-id-find id 'marker) (org-entry-get nil "BLOCKER"))))
      (should-not (string-match-p "aaaaaaaa" v)))))

(ert-deftest claude-code-ide-org-test-set-property-warns-on-keywordless-blocker ()
  "Warns, rather than refusing, when a :BLOCKER: names a keyword-less
heading.  `org-depend' blocks only on unfinished work, so such a blocker
is inert -- but a heading captured this session is keyword-less until a
human applies the queue, so refusing would break the case the tool is
most wanted for.  Same check `bin/lint-org' runs, moved to the call site."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file "** Keywordless\n:PROPERTIES:\n:ID:       cccccccc-1111-2222-3333-444444444444\n:END:\n")
    (org-id-update-id-locations (list file))
    (let ((reply (claude-code-ide-org-set-property id "BLOCKER" "cccccccc")))
      (should (string-prefix-p "Set BLOCKER" reply))
      (should (string-match-p "WARNING" reply))
      (should (string-match-p "cccccccc" reply)))))

(ert-deftest claude-code-ide-org-test-outline-keeps-the-path-to-a-live-child ()
  "`active_only' must not orphan a live child of a finished parent.

Indentation is the *only* thing the outline says about parentage, so a
filtered-out ancestor does not leave a gap -- it leaves the child at its
unchanged absolute indent, and the reader silently re-parents it onto
whatever line above happens to have a smaller indent.  Wrong structure,
not a visible hole (TODO.org :ID: 98908aff).

Asserts the *parent* is present and the sibling's indent is smaller,
which is the property that makes the output readable as a tree.  Merely
asserting the child appears would pass against the broken code, since it
appeared there too -- just misparented."
  (claude-code-ide-org-test--with-heading
    ;; A fresh path, not `file\': the fixture already has a buffer visiting
    ;; that one, and writing behind a visiting buffer leaves org mapping
    ;; over the stale text -- which is how the first run of this test
    ;; failed, reporting the parent absent when it was simply not read.
    (let ((tree (expand-file-name "tree.org" dir)))
      (with-temp-file tree
        (insert "#+TODO: TODO NEXT DOING REVIEW WAITING MAYBE | DONE CANCELLED\n\n"
                "* DONE Finished parent\n:PROPERTIES:\n:ID:       p-0001\n:END:\n"
                "** TODO Active child\n:PROPERTIES:\n:ID:       c-0001\n:END:\n"
                "* TODO Live sibling\n:PROPERTIES:\n:ID:       s-0001\n:END:\n"))
    (let* ((claude-code-ide-org-query-files (list tree))
           (out (claude-code-ide-org-outline nil nil "true"))
           (lines (split-string out "\n" t)))
      (cl-flet ((indent-of (needle)
                  (let ((l (seq-find (lambda (s) (string-match-p (regexp-quote needle) s)) lines)))
                    (and l (- (length l) (length (string-trim-left l)))))))
        ;; the finished ancestor is emitted, so the path is intact
        (should (indent-of "Finished parent"))
        ;; and the child sits deeper than it, not level with a real sibling
        (should (> (indent-of "Active child") (indent-of "Finished parent")))
        (should (= (indent-of "Finished parent") (indent-of "Live sibling"))))))))

(ert-deftest claude-code-ide-org-test-outline-scope-root-carries-front-matter ()
  "A scoped outline leads with the root's front matter (TODO.org :ID:
2d9eeebd).  The request that opened that heading -- show me the front
matter of a heading, sans body, and the tree below it -- had no answer:
the tree line carries keyword, title, id and tags, and a bare `[blocked]'
marker that says a blocker exists without saying which ids.

Asserts the blocker is rendered with its ids AND their keywords, since
`[blocked]' alone was already available and is what this replaces.

Asserts root-only explicitly.  Per-heading front matter would multiply by
heading count and destroy the property the tool sells -- being far
smaller than reading the file -- so `only at the root' is the design, not
an implementation detail."
  (claude-code-ide-org-test--with-heading
    (let ((tree (expand-file-name "fm.org" dir)))
      (with-temp-file tree
        (insert "#+TODO: TODO NEXT DOING REVIEW WAITING MAYBE | DONE CANCELLED\n\n"
                "* TODO Root\n:PROPERTIES:\n:ID:       aaaaaaaa-0000-0000-0000-000000000001\n"
                ":CREATED:  [2026-08-01 Sat 09:00]\n:CATEGORY: Queue\n"
                ":BLOCKER:  ids(bbbbbbbb-0000-0000-0000-000000000002)\n:END:\n"
                "Body prose with a [[file:~/.claude/plans/x.md][Plan]] link.\n"
                "** TODO Child\n:PROPERTIES:\n:ID:       cccccccc-0000-0000-0000-000000000003\n"
                ":CREATED:  [2026-08-02 Sun 09:00]\n:END:\n"
                "* TODO Blocking\n:PROPERTIES:\n:ID:       bbbbbbbb-0000-0000-0000-000000000002\n:END:\n"))
      (let ((claude-code-ide-org-query-files (list tree)))
        (org-id-update-id-locations (list tree))
        (let* ((out (claude-code-ide-org-outline "aaaaaaaa-0000-0000-0000-000000000001" nil nil))
               (lines (split-string out "\n" t)))
          (should (string-match-p ":CREATED: \\[2026-08-01" out))
          (should (string-match-p ":CATEGORY: Queue" out))
          (should (string-match-p ":PLAN-FILE: ~/.claude/plans/x.md" out))
          ;; the blocker's ids and their states, not a bare marker
          (should (string-match-p ":BLOCKER: bbbbbbbb TODO" out))
          ;; root only: exactly one :CREATED: line, though the child has one
          (should (= 1 (seq-count (lambda (l) (string-match-p ":CREATED:" l)) lines)))
          ;; and the tree still follows
          (should (string-match-p "TODO Child" out)))))))

(ert-deftest claude-code-ide-org-test-outline-unresolved-id-is-not-a-missing-file ()
  "An id-shaped scope that resolves to nothing must say so.

It used to fall through to the file interpretation and answer `no
readable file at .../f4e628ce', which reports the wrong failure: a
missing file rather than an unresolvable heading.  TODO.org :ID: 2d9eeebd
found this while asking for a heading by its 8-character prefix -- the
form this project uses everywhere in prose, commits and conversation."
  (claude-code-ide-org-test--with-heading
    (let* ((claude-code-ide-org-query-files (list file))
           (out (claude-code-ide-org-outline "zzzzzzzz" nil nil)))
      (should (string-match-p "resolves to no heading" out))
      (should-not (string-match-p "no readable file" out)))
    ;; a real file name still reads as a file
    (should-not (string-match-p "resolves to no heading"
                                (claude-code-ide-org-outline file nil nil)))))

(ert-deftest claude-code-ide-org-test-goto-candidates-lead-with-the-prefix ()
  "Candidates carry the 8-character prefix IN THE STRING, at the front.

Two separate claims, and the test asserts both because only one of them
is obvious.  The prefix must be *present* -- an annotation supplied
through `completion-extra-properties' is displayed but not matched by
several completion styles, so typing 720b2dcf would narrow nothing, and
making this project's abbreviations typeable is most of the point
(TODO.org :ID: 915378ac).  And it must be *first*, which is the same
argument :ID: 46e4ce2b makes for the review buffer: the prefix is what a
reader arrives with.

Also asserts a keywordless heading still appears.  Excluding one would
lose exactly the headings captured this session, which are the ones most
likely to be jumped to."
  (claude-code-ide-org-test--with-heading
    (let ((tree (expand-file-name "goto.org" dir)))
      (with-temp-file tree
        (insert "#+TODO: TODO NEXT DOING REVIEW WAITING MAYBE | DONE CANCELLED\n\n"
                "* TODO First heading\n:PROPERTIES:\n"
                ":ID:       12345678-0000-0000-0000-000000000001\n:END:\n"
                "* Keywordless one\n:PROPERTIES:\n"
                ":ID:       abcdef01-0000-0000-0000-000000000002\n:END:\n"
                "* A heading with no id at all\n"))
      (let* ((claude-code-ide-org-query-files (list tree))
             (cands (claude-code-ide-org--goto-candidates)))
        (should (= 2 (length cands)))
        ;; present, and leading
        (should (string-prefix-p "12345678" (car (nth 0 cands))))
        (should (string-match-p "First heading" (car (nth 0 cands))))
        (should (equal "12345678-0000-0000-0000-000000000001" (cdr (nth 0 cands))))
        ;; a keywordless heading is a candidate, marked as such
        (should (string-prefix-p "abcdef01" (car (nth 1 cands))))
        (should (string-match-p "-" (car (nth 1 cands))))
        ;; document order is preserved
        (should (string-match-p "First heading" (car (nth 0 cands))))))))

(ert-deftest claude-code-ide-org-test-refresh-leaves-a-closed-slice-alone ()
  "A closed slice is a record, not a projection, and the refresh skips it.

Member lines are derived from referents' keywords, and referents keep
changing after a slice is done -- so refreshing a closed one lets
unrelated later work rewrite finished history.  Observed on :ID:
c44c2119: a member cancelled when the slice closed was reopened two days
later, its checkbox came back, and a DONE slice silently became [27/28]
\(TODO.org :ID: 30a340fd\).

Asserts a LIVE slice in the same file is still refreshed, because a
guard that skipped everything would pass an assertion about the closed
one and break the feature."
  (claude-code-ide-org-test--with-heading
    (let ((f (expand-file-name "slices.org" dir)))
      (with-temp-file f
        (insert "#+TODO: TODO NEXT DOING REVIEW WAITING MAYBE | DONE CANCELLED\n\n"
                "* DONE A closed slice\n:PROPERTIES:\n:KIND:     slice\n"
                ":ID:       cccccccc-0000-0000-0000-000000000001\n"
                ":COOKIE_DATA: checkbox recursive\n:END:\n\n"
                ;; stale on purpose: the referent below is TODO, not DONE
                "- [X] [[id:11111111-0000-0000-0000-000000000009][11111111]] DONE stale copy\n\n"
                "* DOING A live slice\n:PROPERTIES:\n:KIND:     slice\n"
                ":ID:       dddddddd-0000-0000-0000-000000000002\n"
                ":COOKIE_DATA: checkbox recursive\n:END:\n\n"
                "- [X] [[id:11111111-0000-0000-0000-000000000009][11111111]] DONE stale copy\n\n"
                "* TODO The referent\n:PROPERTIES:\n"
                ":ID:       11111111-0000-0000-0000-000000000009\n:END:\n"))
      (let ((claude-code-ide-org-query-files (list f)))
        (org-id-update-id-locations (list f))
        (claude-code-ide-org-refresh-slice)
        (with-current-buffer (find-file-noselect f)
          (revert-buffer t t)
          (let ((text (buffer-string)))
            ;; the live slice was corrected to the referent's real keyword
            (should (string-match-p "- \\[ \\] \\[\\[id:11111111[^\n]*TODO The referent" text))
            ;; and the closed one still carries its stale copy, untouched
            (should (string-match-p "- \\[X\\] \\[\\[id:11111111[^\n]*DONE stale copy" text))))))))

(ert-deftest claude-code-ide-org-test-plan-lint-exempts-a-slice ()
  "A finished slice is not asked for a :PLAN: drawer.

The :PLAN: lifecycle was argued for *tasks* (:ID: 8bcd56f4), on the
hazard that a closed task's design claims outlive their truth and a
later reader repeats one as current.  A slice designs nothing: its body
is an argument for a grouping, a sequence, a derived member list and
revision links, nearly all of it retrospective once it closes.  TODO.org
:ID: f89c912a.

Asserts a finished *task* with the same shape is still reported, because
an exemption that silenced everything would satisfy the slice assertion
while removing the rule."
  (let* ((cat "")
         (body (concat "\n" (mapconcat (lambda (n) (format "Line %d of a substantial body." n))
                                       (number-sequence 1 40) "\n") "\n"))
         (closed "CLOSED: [2026-08-30 Sun 10:00]\n")
         (slice (concat cat "* DONE A finished slice\n" closed
                        ":PROPERTIES:\n:KIND:     slice\n"
                        ":ID:       aaaaaaaa-0000-0000-0000-00000000000a\n:END:\n" body))
         (task (concat cat "* DONE A finished task\n" closed
                       ":PROPERTIES:\n"
                       ":ID:       bbbbbbbb-0000-0000-0000-00000000000b\n:END:\n" body)))
    ;; the slice is exempt
    (should-not (claude-code-ide-org-test--lint-matches
                 (claude-code-ide-org-test--lint slice)
                 'warn "no :PLAN: drawer"))
    ;; the task, identical but for :KIND:, is still reported
    (should (claude-code-ide-org-test--lint-matches
             (claude-code-ide-org-test--lint task)
             'warn "no :PLAN: drawer"))))


;;; claude-code-ide-org-archive-finished ---------------------------------------

(ert-deftest claude-code-ide-org-test-archive-finished-leaves-a-finished-child-of-a-live-parent ()
  "The sweep must not archive a finished heading nested under a live one.

*This is the whole safety rule, so it is the first test written.*
`org-archive-subtree' lands a directly-archived child one level up in the
target file -- a sibling of its former parent -- with only
`:ARCHIVE_OLPATH:' recording where it came from.  A sweep that took every
finished heading would therefore silently restructure live work.
Measured on 2026-08-31: of 106 finished headings in TODO.org, 21 were
children of a live parent, seven of them under one heading.

Asserts the archive file was never *created*, not merely that it lacks
the child: a check for absent text passes against a sweep that archived
the wrong thing and then failed to write it."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file (concat "** DONE Finished child\n"
                  ":PROPERTIES:\n"
                  ":ID:       test-0002\n"
                  ":END:\n"
                  "Child body prose.\n"))
    ;; The fixture heading keeps its TODO keyword -- it is the live parent.
    (should (= 0 (claude-code-ide-org-archive-finished file)))
    (let ((src (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "^\\*\\* DONE Finished child" src))
      (should (string-match-p "Child body prose" src)))
    (should-not (file-exists-p archive-file))))

(ert-deftest claude-code-ide-org-test-archive-finished-takes-children-with-the-parent ()
  "A finished top-level heading is archived with its finished descendants.

The counterpart to the test above: those 20 children travel rather than
being swept in their own right, so the sweep's count is a count of
*subtrees* and not of headings."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file (concat "** DONE Finished child\n"
                  ":PROPERTIES:\n"
                  ":ID:       test-0002\n"
                  ":END:\n"
                  "Child body prose.\n"))
    (claude-code-ide-org-test--set-todo-for-real id "DONE")
    (should (= 1 (claude-code-ide-org-archive-finished file)))
    (let ((src (claude-code-ide-org-test--disk-contents file))
          (arch (claude-code-ide-org-test--disk-contents archive-file)))
      (should-not (string-match-p "Test heading" src))
      (should-not (string-match-p "Finished child" src))
      (should-not (string-match-p "Child body prose" src))
      (should (string-match-p "Test heading" arch))
      (should (string-match-p "Finished child" arch))
      (should (string-match-p "Child body prose" arch)))))

(ert-deftest claude-code-ide-org-test-archive-finished-refuses-a-parent-with-a-live-descendant ()
  "A finished heading with a live descendant is skipped, not archived.

Today\\'s corpus has none -- zero of 65, measured 2026-08-31 -- which is
precisely why this is a test rather than a comment: the guard has no
natural exercise, so nothing else would notice it being removed.  A
finished parent over unfinished work is itself a defect, but archiving it
would bury the live child where no `org_outline' or `org_query' run
looks."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file (concat "** TODO Unfinished child\n"
                  ":PROPERTIES:\n"
                  ":ID:       test-0002\n"
                  ":END:\n"))
    (claude-code-ide-org-test--set-todo-for-real id "DONE")
    (should (= 0 (claude-code-ide-org-archive-finished file)))
    (let ((src (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "Test heading" src))
      (should (string-match-p "Unfinished child" src)))
    (should-not (file-exists-p archive-file))))

(ert-deftest claude-code-ide-org-test-archive-finished-sweeps-every-top-level-heading ()
  "Several finished top-level headings are all archived, and counted.

*What this pins is that the sweep reaches every heading, not the order it
reaches them in.*  Reversing the marker list was measured on 2026-08-31 to
change nothing -- markers track deletions, so the order genuinely does not
matter, and an earlier docstring here claimed otherwise.  What can still
break is the walk stopping early or losing its place, so three headings is
the smallest number that distinguishes \"processed one and stopped\" from
\"processed all\", and the interleaved live heading checks the sweep skips
rather than halts."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file (concat "* DONE Second finished\n"
                  ":PROPERTIES:\n:ID:       test-0002\n:END:\n"
                  "* TODO Still live\n"
                  ":PROPERTIES:\n:ID:       test-0003\n:END:\n"
                  "* CANCELLED Third finished\n"
                  ":PROPERTIES:\n:ID:       test-0004\n:END:\n"))
    (claude-code-ide-org-test--set-todo-for-real id "DONE")
    (should (= 3 (claude-code-ide-org-archive-finished file)))
    (let ((src (claude-code-ide-org-test--disk-contents file))
          (arch (claude-code-ide-org-test--disk-contents archive-file)))
      (should-not (string-match-p "Test heading" src))
      (should-not (string-match-p "Second finished" src))
      (should-not (string-match-p "Third finished" src))
      (should (string-match-p "Still live" src))
      (dolist (title '("Test heading" "Second finished" "Third finished"))
        (should (string-match-p title arch)))
      (should-not (string-match-p "Still live" arch))
      ;; No id may appear twice across source and target.  This is the
      ;; assertion that would have caught the 2026-08-31 live pass, which
      ;; reported 65 and wrote 66 -- one story and its six children
      ;; duplicated, ids and all, into DONE.org.  Every other check there
      ;; passed: the count was right, the levels were right, and nothing
      ;; had gone missing.  Only counting the ids found it.
      (let ((ids nil) (dupes nil))
        (dolist (text (list src arch))
          (let ((start 0))
            (while (string-match ":ID: +\\([^\n]+\\)" text start)
              (let ((id (string-trim (match-string 1 text))))
                (if (member id ids) (push id dupes) (push id ids)))
              (setq start (match-end 0)))))
        ;; Positive evidence first: an id scan that matched nothing would
        ;; satisfy the duplicate check vacuously, which is the shape of
        ;; passing test this project keeps catching itself writing.
        (should (= 4 (length ids)))
        (should-not dupes)))))

(ert-deftest claude-code-ide-org-test-archive-finished-honours-a-changed-archive-directive ()
  "The sweep must read the archive target the file *currently* declares.

*The regression this exists for.*  `#+ARCHIVE:' is parsed into a
buffer-local the first time a buffer enters `org-mode', and nothing
re-parses it after that -- `auto-revert-mode' replaces the text and
leaves the variable behind.  So a long-open buffer archives to the target
the file declared when it was opened, while the directive on screen says
something else.  On 2026-08-31 that sent 65 subtrees under a retired
`* Done' heading, and the pre-flight check had confirmed the *text* of
the directive in that very buffer.

The fixture opens FILE with one target and this test rewrites the
directive in the live buffer without restarting the mode, which is the
stale state exactly.  A sweep that trusts the cached parse puts the entry
under `* Wrong' instead."
  (claude-code-ide-org-test--with-heading
    (with-current-buffer (get-file-buffer file)
      (goto-char (point-min))
      (should (re-search-forward "^#\\+ARCHIVE:.*$" nil t))
      (replace-match "#+ARCHIVE: DONE.org::* Right")
      (save-buffer))
    ;; Poison the cached value the way a pre-change buffer would hold it.
    (with-current-buffer (get-file-buffer file)
      (setq-local org-archive-location "DONE.org::* Wrong"))
    (claude-code-ide-org-test--set-todo-for-real id "DONE")
    (should (= 1 (claude-code-ide-org-archive-finished file)))
    (let ((arch (claude-code-ide-org-test--disk-contents archive-file)))
      (should (string-match-p "^\\* Right" arch))
      (should-not (string-match-p "Wrong" arch)))))

(ert-deftest claude-code-ide-org-test-duplicate-ids-in-file-detects-a-repeat ()
  "The archive post-condition's detector must actually find a repeated id.

*Tested directly, because the failure it guards cannot be provoked.* On
2026-08-31 a sweep reported 65 while writing 66, duplicating one story
and its six children into the archive; the second copy landed inside a
single `org-archive-subtree' call and the mechanism was never
identified, so there is no input that reproduces it on demand. What can
be pinned is that the check would have seen it -- and that it stays
quiet on a clean file, which is the half that would otherwise rot into a
detector matching nothing at all."
  (claude-code-ide-org-test--with-heading
    (should-not (claude-code-ide-org--duplicate-ids-in-file file))
    (claude-code-ide-org-test--add-child
     file (concat "** DONE Impostor\n"
                  ":PROPERTIES:\n"
                  ":ID:       " id "\n"
                  ":END:\n"))
    (let ((dupes (claude-code-ide-org--duplicate-ids-in-file file)))
      (should (equal (list id) dupes)))))

(ert-deftest claude-code-ide-org-test-no-tool-declares-an-optional-argument-required ()
  "An argument the elisp function takes as `&optional' must carry
`:optional t' in the tool's `:args' declaration.

*This is TODO.org :ID: 72463b68, and its failure mode is a hang rather
than an error, which is why nothing caught it for two days.*
`claude-code-ide-mcp-http-server--validate-args' signals
`json-rpc-error' when a required argument is absent -- a symbol the
package signals in three places and never passes to `define-error', so
it carries no `error-conditions' and no `(error ...)' handler matches
it.  It escapes `--handle-post' entirely, so `--send-json-response' is
never reached, the HTTP connection is neither answered nor closed, and
the caller waits until it times out.  Emacs stays responsive throughout
and nothing is persisted, which is exactly what the heading recorded
and could not explain.

Three tools shipped with a semantically optional argument marked
required -- `org_capture's target, `org_set_property's append and
`org_divide's parent_state -- and each one's own description told the
caller to omit it.  So every call that followed the description hung.

The registry is asserted non-empty first, deliberately.  `config.el'
registers its tools inside `with-eval-after-load', and in batch
`claude-code-ide' is not otherwise loaded, so without that guard this
test would iterate an empty list and pass while checking nothing."
  (require 'claude-code-ide)
  (let ((specs claude-code-ide-mcp-server-tools)
        (violations '()))
    (should (> (length specs) 10))
    (dolist (spec specs)
      (let* ((norm (claude-code-ide--normalize-tool-spec spec))
             (fn (plist-get norm :function))
             (name (plist-get norm :name))
             (mandatory (car (func-arity fn)))
             (index 0))
        (dolist (arg (plist-get norm :args))
          (unless (plist-get arg :optional)
            (when (>= index mandatory)
              (push (format "%s/%s" name (plist-get arg :name)) violations)))
          (setq index (1+ index)))))
    (should (equal nil (nreverse violations)))))

(ert-deftest claude-code-ide-org-test-lint-accepts-an-unanchored-archive-datetree ()
  "The datetree `org-archive-subtree' builds in DONE.org carries no
:DATE_TREE: property and lints clean anyway (TODO.org :ID: 33864a0f).

*It cannot be anchored, which is why the predicate had to widen.*
`org-archive-subtree' calls `org-datetree-find-date-create' on the
widened buffer with no restriction (org-archive.el:343), and that
function never consults the property -- so the tree is built at file top
level, outside this project entirely.  Recognising it by org's own title
shapes is the published-contract case CLAUDE.md settles.

Against the pre-2026-09-02 rule this fixture produced the four errors
:ID: e30d52d7 predicted hours after that rule landed: no :ID: on the
year, the month or the day, plus a level-4 heading that is not a day
node.  Measured on a real archive rather than imagined -- the fixture is
the exact shape `org-archive-subtree' wrote into a scratch file with
`#+ARCHIVE: A.org::datetree/'.

Note the year, month and day nodes sit at levels 1-3 here against 2-4 in
the anchored tree, because there is no category heading above them.  That
is precisely what the depth arithmetic had to stop assuming."
  (should (null (claude-code-ide-org-test--lint
                 (concat "* 2026\n"
                         "** 2026-08 August\n"
                         "*** 2026-08-21 Friday\n"
                         ;; The cookie is not decoration: this story has a
                         ;; keyworded child, and the container rule wants
                         ;; one wherever it sits. It fires identically on
                         ;; the same content flat, so it is not a datetree
                         ;; consequence -- checked both ways rather than
                         ;; assumed, after a first pass compared against a
                         ;; file the archive had already emptied.
                         "**** DONE [1/1] An archived task\n"
                         "CLOSED: [2026-08-21 Fri 13:20]\n"
                         ":PROPERTIES:\n"
                         ":ID:       aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n"
                         ":CREATED:  [2026-08-20 Thu 09:00]\n:END:\n"
                         "***** DONE A child that travelled with it\n"
                         ":PROPERTIES:\n"
                         ":ID:       bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\n"
                         ":CREATED:  [2026-08-20 Thu 09:01]\n:END:\n")))))

(ert-deftest claude-code-ide-org-test-lint-exempts-the-day-node-only-when-unanchored ()
  "The day node's :ID: requirement turns on which tree it is in, and the
two trees want opposite things.

In the *anchored* meta-work tree the day node is the heading time is
assigned to, so it must carry :ID: -- asserted by
`claude-code-ide-org-test-lint-still-requires-an-id-on-the-day-node'.  In
the *unanchored* archive tree nothing is ever clocked against it and
`org-archive-subtree' writes it bare, so requiring one would be demanding
a property org will never write.

This test is the second half of that pair and exists so the exemption
cannot quietly widen into the anchored tree, which would silently drop
the one datetree heading the project most needs addressable."
  (should (null (claude-code-ide-org-test--lint
                 (concat "* 2026\n"
                         "** 2026-08 August\n"
                         "*** 2026-08-21 Friday\n"))))
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint
            (concat "* Review and planning\n"
                    ":PROPERTIES:\n"
                    ":DATE_TREE: t\n"
                    ":ARCHIVE:  DONE.org::* Review and planning\n"
                    ":END:\n"
                    "** 2026\n"
                    "*** 2026-08 August\n"
                    "**** 2026-08-21 Friday\n"))
           'error "heading has no :ID:")))

(ert-deftest claude-code-ide-org-test-lint-does-not-exempt-a-task-beside-the-archive-tree ()
  "Widening the predicate to an unanchored tree must not exempt ordinary
level-1 work that merely shares the file with one.  A heading whose title
is not org's own year shape is a task and is linted as one, which is the
same over-application guard the anchored tree already carries -- the
difference is only that there is no anchor to measure depth from."
  (let ((findings (claude-code-ide-org-test--lint
                   (concat "* 2026\n"
                           "** 2026-08 August\n"
                           "*** 2026-08-21 Friday\n"
                           "* DONE A task filed beside the tree\n"))))
    (should (claude-code-ide-org-test--lint-matches
             findings 'error "level-1 task has no :ID:"))))

(defun claude-code-ide-org-test--datetree-fixture (path body)
  "Write BODY to PATH under a minimal org header and return PATH.
The header is not decoration: `org-sort-entries' signals \"Nothing to
sort\" unless point can sit before the first heading, so a fixture
without one cannot be sorted at all."
  (with-temp-file path
    (insert "#+TITLE: Archive\n\n" body))
  path)

(ert-deftest claude-code-ide-org-test-datetree-file-files-tasks-by-their-close-date ()
  "A flat archive becomes a year/month/day tree, newest first
(TODO.org :ID: 33864a0f).

Asserts both halves at once, because they fail differently: the tasks
must land under the day node their own CLOSED: names, and the tiers must
read descending.  Org builds a datetree *ascending*, so a conversion that
only filed would produce a correct tree in exactly the wrong order."
  (claude-code-ide-org-test--with-heading
    (let ((f (claude-code-ide-org-test--datetree-fixture
              archive-file
              (concat "* DONE Older task\n"
                      "CLOSED: [2026-07-15 Wed 10:00]\n"
                      ":PROPERTIES:\n:ID:       aaaaaaaa-0001\n"
                      ":CREATED:  [2026-07-14 Tue 09:00]\n:END:\n"
                      "* DONE Earlier that Friday\n"
                      "CLOSED: [2026-08-21 Fri 09:00]\n"
                      ":PROPERTIES:\n:ID:       aaaaaaaa-0002\n"
                      ":CREATED:  [2026-08-20 Thu 09:00]\n:END:\n"
                      "* DONE Later that Friday\n"
                      "CLOSED: [2026-08-21 Fri 13:20]\n"
                      ":PROPERTIES:\n:ID:       aaaaaaaa-0003\n"
                      ":CREATED:  [2026-08-20 Thu 09:00]\n:END:\n"))))
      (claude-code-ide-org-datetree-file f)
      (let* ((text (claude-code-ide-org-test--disk-contents f))
             (lines (seq-filter (lambda (l) (string-prefix-p "*" l))
                                (split-string text "\n"))))
        (should (equal lines
                       '("* 2026"
                         "** 2026-08 August"
                         "*** 2026-08-21 Friday"
                         "**** DONE Later that Friday"
                         "**** DONE Earlier that Friday"
                         "** 2026-07 July"
                         "*** 2026-07-15 Wednesday"
                         "**** DONE Older task")))))))

(ert-deftest claude-code-ide-org-test-datetree-file-refuses-a-heading-with-no-closed ()
  "The conversion refuses rather than filing an undated heading under today.

This is the guard that made TODO.org :ID: 33864a0f block on :ID: b7b46a26
instead of merely following it.  `org-archive-subtree' dates a datetree
entry from `(or (org-entry-get nil \"CLOSED\" t) time)', so a heading with
no CLOSED: files under *today* and nothing warns -- 39 headings would
have collapsed into one wrong day node when this was measured.

Asserts the file is untouched as well as the error, because a refusal
raised halfway through a conversion would be worse than none."
  (claude-code-ide-org-test--with-heading
    (let* ((body (concat "* DONE Dated\n"
                         "CLOSED: [2026-07-15 Wed 10:00]\n"
                         ":PROPERTIES:\n:ID:       aaaaaaaa-0001\n"
                         ":CREATED:  [2026-07-14 Tue 09:00]\n:END:\n"
                         "* DONE Undated\n"
                         ":PROPERTIES:\n:ID:       aaaaaaaa-0002\n"
                         ":CREATED:  [2026-07-14 Tue 09:00]\n:END:\n"))
           (f (claude-code-ide-org-test--datetree-fixture archive-file body))
           (before (claude-code-ide-org-test--disk-contents f)))
      ;; The *message* is asserted, not merely that something signalled.
      ;; Without the pre-flight guard this still raises -- CLOSED: is nil,
      ;; `org-date-to-gregorian' returns (nil nil nil) and `encode-time'
      ;; throws `wrong-type-argument' from three frames down. A bare
      ;; `should-error' therefore passes with the guard deleted, which is
      ;; what a mutation run showed on 2026-09-02: the test was
      ;; structurally incapable of failing for its own reason.
      (should (string-match-p
               "Refusing to convert"
               (cadr (should-error (claude-code-ide-org-datetree-file f)))))
      ;; And nothing moved -- checked in the buffer as well as on disk,
      ;; since the write happens only at the end and an aborted half
      ;; conversion would leave disk innocent and the buffer wrecked.
      (should (equal before (claude-code-ide-org-test--disk-contents f)))
      (should-not (buffer-modified-p (find-file-noselect f))))))

(ert-deftest claude-code-ide-org-test-datetree-file-dates-a-story-from-its-own-closed ()
  "A story files under *its own* close date, never a child's.

`org-entry-get' is called without the inherit flag for exactly this
reason.  Scoping a date scan to the subtree is what dated `b5f7c5c7' two
days early during :ID: 38b92521's manifest work; here the same mistake
would file a parent under a child's date and mis-order the largest
entries, with nothing downstream to notice.

The child is deliberately closed in a *different month*, so an inherited
or subtree-scoped read lands in a visibly wrong place rather than one
day off."
  (claude-code-ide-org-test--with-heading
    (let ((f (claude-code-ide-org-test--datetree-fixture
              archive-file
              (concat "* DONE [1/1] A story\n"
                      "CLOSED: [2026-07-15 Wed 10:00]\n"
                      ":PROPERTIES:\n:ID:       aaaaaaaa-0001\n"
                      ":CREATED:  [2026-07-01 Wed 09:00]\n:END:\n"
                      "** DONE A child closed much later\n"
                      "CLOSED: [2026-08-21 Fri 13:20]\n"
                      ":PROPERTIES:\n:ID:       aaaaaaaa-0002\n"
                      ":CREATED:  [2026-07-02 Thu 09:00]\n:END:\n"))))
      (claude-code-ide-org-datetree-file f)
      (let ((lines (seq-filter (lambda (l) (string-prefix-p "*" l))
                               (split-string
                                (claude-code-ide-org-test--disk-contents f) "\n"))))
        ;; July, from the parent's own CLOSED: -- and the child travelled
        ;; with it rather than being filed separately under August.
        (should (equal lines
                       '("* 2026"
                         "** 2026-07 July"
                         "*** 2026-07-15 Wednesday"
                         "**** DONE [1/1] A story"
                         "***** DONE A child closed much later")))))))

(ert-deftest claude-code-ide-org-test-sort-datetree-descending-is-idempotent ()
  "Sorting an already-sorted tree changes nothing.

It runs after every archive pass, so a sort that perturbed a settled file
would produce a diff per ceremony and make the real reorderings
unreadable."
  (claude-code-ide-org-test--with-heading
    (let ((f (claude-code-ide-org-test--datetree-fixture
              archive-file
              (concat "* DONE Older\n"
                      "CLOSED: [2026-07-15 Wed 10:00]\n"
                      ":PROPERTIES:\n:ID:       aaaaaaaa-0001\n"
                      ":CREATED:  [2026-07-14 Tue 09:00]\n:END:\n"
                      "* DONE Newer\n"
                      "CLOSED: [2026-08-21 Fri 13:20]\n"
                      ":PROPERTIES:\n:ID:       aaaaaaaa-0002\n"
                      ":CREATED:  [2026-08-20 Thu 09:00]\n:END:\n"))))
      (claude-code-ide-org-datetree-file f)
      (let ((once (claude-code-ide-org-test--disk-contents f)))
        (claude-code-ide-org-sort-datetree-descending f)
        (should (equal once (claude-code-ide-org-test--disk-contents f)))))))

(ert-deftest claude-code-ide-org-test-archiving-lands-in-the-existing-datetree ()
  "An archive pass files into the datetree and the ceremony re-sorts it
newest-first (TODO.org :ID: 33864a0f).

This covers the *steady state* rather than the one-time conversion, and
it is the half that rots silently: `org-datetree-find-date-create'
inserts each node in ascending date order, so an archive left to itself
drifts back to oldest-first one pass at a time, with every individual
pass looking correct.

Both halves are asserted together because each is useless alone -- an
entry filed under the right day in the wrong order, or the right order
over the wrong day, would each pass a narrower test."
  (claude-code-ide-org-test--with-heading
    ;; A pre-existing tree, exactly the shape DONE.org now carries.
    (claude-code-ide-org-test--datetree-fixture
     archive-file
     (concat "* 2026\n"
             "** 2026-08 August\n"
             "*** 2026-08-21 Friday\n"
             "**** DONE Already archived :code:\n"
             "CLOSED: [2026-08-21 Fri 13:20]\n"
             ":PROPERTIES:\n:ID:       aaaaaaaa-0001\n"
             ":CREATED:  [2026-08-20 Thu 09:00]\n:END:\n"))
    (with-temp-file file
      (insert "#+TODO: TODO NEXT DOING REVIEW WAITING | DONE CANCELLED MAYBE\n"
              "#+ARCHIVE: DONE.org::datetree/\n\n"
              "* DONE A newer finished task :code:\n"
              "CLOSED: [2026-09-01 Tue 10:00]\n"
              ":PROPERTIES:\n:ID:       aaaaaaaa-0002\n"
              ":CREATED:  [2026-08-30 Sun 09:00]\n:END:\n"))
    ;; Both fixtures were written to disk under buffers the enclosing
    ;; macro had already opened, so the next `find-file-noselect' would
    ;; stop and ask whether to reread -- which in batch is a hang, not an
    ;; error. Drop the stale buffers rather than answering the question.
    (dolist (f (list file archive-file))
      (let ((b (get-file-buffer f))) (when b (kill-buffer b))))
    (claude-code-ide-org-archive-finished file)
    (claude-code-ide-org-sort-datetree-descending archive-file)
    (let ((lines (mapcar
                  ;; Org right-aligns tags to a column, so the heading
                  ;; line carries a run of spaces whose width depends on
                  ;; the title. Collapse it -- this test is about where
                  ;; the heading sits, not how org pads it.
                  (lambda (l) (replace-regexp-in-string "[ \t]+" " " l))
                  (seq-filter (lambda (l) (string-prefix-p "*" l))
                              (split-string
                               (claude-code-ide-org-test--disk-contents archive-file)
                               "\n")))))
      ;; September ahead of August: org appended the new month *after* the
      ;; existing one, and the sort is what puts it first.
      (should (equal (seq-take lines 4)
                     '("* 2026"
                       "** 2026-09 September"
                       "*** 2026-09-01 Tuesday"
                       "**** DONE A newer finished task :code:")))
      (should (member "** 2026-08 August" lines)))))

(ert-deftest claude-code-ide-org-test-archive-datetree-target-p-reads-the-location ()
  "The predicate is the shared spelling of the rule, so it is asserted directly.
Both archive call sites read it, and the whole defect was that only one
of them read anything at all."
  (should (claude-code-ide-org--archive-datetree-target-p "DONE.org::datetree/"))
  (should-not (claude-code-ide-org--archive-datetree-target-p "DONE.org::"))
  (should-not (claude-code-ide-org--archive-datetree-target-p "DONE.org::* Done"))
  ;; Unset is not a datetree, and must not error.
  (should-not (claude-code-ide-org--archive-datetree-target-p nil)))

(ert-deftest claude-code-ide-org-test-org-archive-nests-under-the-day-node ()
  "The `org_archive' tool must force reversed order off for a datetree.

The guard shipped on `claude-code-ide-org-archive-finished' alone, while
`claude-code-ide-org-archive' is this file's other `org-archive-subtree'
call site and archived under whatever the global held.  Latent only
because the global is unset, so this test sets it -- otherwise it would
pass against the unguarded code and prove nothing (TODO.org
:ID: eb3b8e84).

With reversed order on and a day node already present, org inserts
*before* that node: the entry lands at level 4 parented to the month,
with an empty day node after it."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--datetree-fixture
     archive-file
     (concat "* 2026\n"
             "** 2026-09 September\n"
             "*** 2026-09-01 Tuesday\n"
             "**** DONE Already archived :code:\n"
             "CLOSED: [2026-09-01 Tue 13:20]\n"
             ":PROPERTIES:\n:ID:       aaaaaaaa-0001\n"
             ":CREATED:  [2026-08-30 Sun 09:00]\n:END:\n"))
    (with-temp-file file
      (insert "#+TODO: TODO NEXT DOING REVIEW WAITING | DONE CANCELLED MAYBE\n"
              "#+ARCHIVE: DONE.org::datetree/\n\n"
              "* DONE A finished task :code:\n"
              "CLOSED: [2026-09-01 Tue 10:00]\n"
              ":PROPERTIES:\n:ID:       " id "\n"
              ":CREATED:  [2026-08-30 Sun 09:00]\n:END:\n"))
    ;; Both fixtures were written under buffers already open, so the next
    ;; `find-file-noselect' would stop and ask whether to reread -- a hang
    ;; in batch, not an error.
    (dolist (f (list file archive-file))
      (let ((b (get-file-buffer f))) (when b (kill-buffer b))))
    (org-id-update-id-locations (list file))
    (let ((org-archive-reversed-order t))
      (claude-code-ide-org-archive id))
    (let ((lines (mapcar
                  (lambda (l) (replace-regexp-in-string "[ \t]+" " " l))
                  (seq-filter (lambda (l) (string-prefix-p "*" l))
                              (split-string
                               (claude-code-ide-org-test--disk-contents archive-file)
                               "\n")))))
      ;; The three scaffolding tiers come first, in order. Under the bug
      ;; the entry is inserted BEFORE the day node, so a `****' line
      ;; appears at index 2 and the day node is pushed down.
      (should (equal (seq-take lines 3)
                     '("* 2026"
                       "** 2026-09 September"
                       "*** 2026-09-01 Tuesday")))
      ;; Everything after them is a task under that day node -- nothing
      ;; is parented to the month, and the day node is not duplicated.
      (should (seq-every-p (lambda (l) (string-prefix-p "**** " l))
                           (seq-drop lines 3)))
      (should (member "**** DONE A finished task :code:" lines))
      (should (= 1 (seq-count (lambda (l) (equal l "*** 2026-09-01 Tuesday"))
                              lines))))))

(ert-deftest claude-code-ide-org-test-org-archive-leaves-a-flat-target-reversed ()
  "The guard is scoped to a datetree and must not disarm reversed order generally.
A flat archive reads newest-first *because* of that setting, so turning
it off everywhere would trade one malformation for a buried entry."
  (claude-code-ide-org-test--with-heading
    (with-temp-file archive-file
      (insert "* DONE An older entry :code:\n"
              ":PROPERTIES:\n:ID:       aaaaaaaa-0001\n:END:\n"))
    (claude-code-ide-org-test--set-todo-for-real id "DONE")
    (dolist (f (list file archive-file))
      (let ((b (get-file-buffer f))) (when b (kill-buffer b))))
    (org-id-update-id-locations (list file))
    (let ((org-archive-reversed-order t))
      (claude-code-ide-org-archive id))
    (let ((lines (seq-filter (lambda (l) (string-prefix-p "* " l))
                             (split-string
                              (claude-code-ide-org-test--disk-contents archive-file)
                              "\n"))))
      (should (string-match-p "Test heading" (car lines))))))

(ert-deftest claude-code-ide-org-test-datetree-target-follows-the-archive-directive ()
  "The datetree sort and the archive step must agree on which file they
are working on (TODO.org :ID: 33864a0f).

*This is a regression test for a defect the whole suite missed*, because
every other test passes the path explicitly and only the ceremony calls
with no argument.  The old implementation computed \"DONE.org beside the
capture target\", and the capture target is a directory holding nothing
but a *symlink* to the real TODO.org -- so it named a file that does not
exist, `find-file-noselect' made an empty buffer for it, and
`org-sort-entries' failed with \"Nothing to sort\" on every ceremony while
every hand call succeeded.  Found by a human noticing 2026-09-02 filed
below 2026-09-01.

The fixture reproduces the real layout rather than a simplified one: the
capture target is reached *through a symlink* and the archive lives
beside the link's target, not beside the link."
  (let* ((dir (file-name-as-directory (make-temp-file "cciorg-symlink" t)))
         (real (file-name-as-directory (expand-file-name "real" dir)))
         (link (file-name-as-directory (expand-file-name "link" dir))))
    (unwind-protect
        (progn
          (make-directory real) (make-directory link)
          (with-temp-file (expand-file-name "TODO.org" real)
            (insert "#+ARCHIVE: DONE.org::datetree/\n\n* TODO Live\n"))
          (with-temp-file (expand-file-name "DONE.org" real)
            (insert "#+TITLE: Archive\n\n* 2026\n"))
          (make-symbolic-link (expand-file-name "TODO.org" real)
                              (expand-file-name "TODO.org" link))
          (let ((claude-code-ide-org-capture-file
                 (expand-file-name "TODO.org" link)))
            ;; Resolves through the link, to the archive the directive
            ;; names -- not to a sibling of the link that does not exist.
            (should (file-equal-p (claude-code-ide-org--datetree-target-file)
                                  (expand-file-name "DONE.org" real)))
            ;; And agrees with the step that actually writes there.
            (should (file-equal-p
                     (claude-code-ide-org--datetree-target-file)
                     (claude-code-ide-org--archive-target-file
                      (claude-code-ide-org--capture-target-file))))))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-advance-repeater-survives-a-read-only-buffer ()
  "Advancing the ceremony repeater works against a read-only TODO.org.

TODO.org is normally read-only -- the user's guard against their own
stray keystrokes -- and this step runs with no keystroke left to prompt
on.  :ID: 13ea6770 bound `inhibit-read-only' for the ceremony *steps*
and did not reach the repeater advance, which sits outside the step
list; the omission surfaced 2026-09-02 as
`repeater: FAILED (Buffer is read-only)' after every other step had run
clean.

Asserts the guard is still armed afterwards, which is the half that
matters: an implementation clearing `buffer-read-only' instead of
binding `inhibit-read-only' would satisfy the write assertion and
silently disarm the user (TODO.org :ID: c8a97d9d)."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file (concat "* TODO Archive closed tasks daily\n"
                  "SCHEDULED: <2026-09-03 Thu 07:00 ++1d>\n"
                  ":PROPERTIES:\n"
                  ":ID:       cbe282ec-10c3-4aa0-8d3a-f30e17a12fa8\n"
                  ":CREATED:  [2026-08-01 Sat 09:00]\n:END:\n"))
    (with-current-buffer (find-file-noselect file) (setq buffer-read-only t))
    (should (claude-code-ide-org--ceremony-advance-repeater))
    ;; Org advanced the date rather than leaving the heading DONE.
    (let ((text (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "2026-09-04" text))
      (should (string-match-p "^\\* TODO Archive closed tasks daily" text)))
    (should (with-current-buffer (find-file-noselect file) buffer-read-only))))

(defun claude-code-ide-org-test--prose-lines (id)
  "Prose-line count the lint would see for heading ID."
  (let ((m (claude-code-ide-org--id-find id 'marker)))
    (org-with-point-at m (claude-code-ide-org--lint-body-prose-lines))))

(defun claude-code-ide-org-test--give-body (file lines)
  "Append LINES prose lines to the fixture heading's body in FILE and save."
  (with-current-buffer (get-file-buffer file)
    (goto-char (point-max))
    (dotimes (i lines) (insert (format "Prospective design line %d.\n" i)))
    (save-buffer)))

(ert-deftest claude-code-ide-org-test-set-todo-nudges-the-plan-wrap-at-close ()
  "Queueing a finished keyword on a heading with an unwrapped body says so.

The reminder fires at the one moment it is actionable.  `bin/lint-org'
reports the same condition, but only over headings *already* closed --
by which time the next ceremony has archived them and the missing drawer
is history rather than a prompt.  Measured 2026-09-02: 93 of DONE.org's
98 post-convention headings carry no drawer while 88 of those carry a
debrief, so the debrief happens at close and the wrap does not
(TODO.org :ID: 79a3d89e)."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--give-body file 12)
    (let ((reply (claude-code-ide-org-set-todo id "DONE" "finishing up")))
      (should (string-match-p "no :PLAN: drawer" reply))
      (should (string-match-p "org_wrap_plan" reply)))))

(ert-deftest claude-code-ide-org-test-set-todo-nudge-preserves-the-queue-append-contract ()
  "The reminder must not add a second `(was ...)' to the reply.

`bin/hooks/queue-append' recovers the prior keyword with a *greedy* sed,
`s/.*(was \\([^)]*\\)).*/\\1/p', so a second parenthetical anywhere in the
reply would win and the queued event would record the wrong `from'.
That field is what lets review notice reality has moved past a queued
transition, so getting it wrong is silent and consequential.

Asserts the recovery itself rather than the absence of a substring: this
runs the exact expression the hook runs."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--give-body file 12)
    (let ((reply (claude-code-ide-org-set-todo id "DONE" "finishing up")))
      ;; The nudge is present, so this is not a vacuous assertion.
      (should (string-match-p "org_wrap_plan" reply))
      (should (string-match ".*(was \\([^)]*\\)).*" reply))
      (should (equal "TODO" (match-string 1 reply)))
      ;; And the reply still does not begin with `Error:', which the hook
      ;; treats as "drop this event".
      (should-not (string-prefix-p "Error:" reply)))))

(ert-deftest claude-code-ide-org-test-set-todo-nudge-stays-quiet-when-it-should ()
  "Three cases where the reminder must not fire, each for its own reason.

A short body needs no drawer -- wrapping a one-liner is ceremony rather
than structure.  A heading that already has one is done.  And a
transition that is not to a finished keyword is not the moment: the body
is still live and still prospective."
  ;; Short body: nothing worth wrapping.
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--give-body file 3)
    (should-not (string-match-p
                 "org_wrap_plan"
                 (claude-code-ide-org-set-todo id "DONE" "finishing up"))))
  ;; A drawer already exists AND a substantial debrief sits below it --
  ;; which is the realistic post-wrap state, and the only one that tests
  ;; the drawer guard at all. Wrapping alone drops the prose count to
  ;; zero, so the substantial-body guard suppresses the nudge and the
  ;; drawer guard is never reached: a mutation run on 2026-09-02 removed
  ;; that guard and this case still passed.
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--give-body file 12)
    (claude-code-ide-org-wrap-plan id)
    (claude-code-ide-org-test--give-body file 12)
    (should (>= (claude-code-ide-org-test--prose-lines id) 10))
    (should-not (string-match-p
                 "org_wrap_plan"
                 (claude-code-ide-org-set-todo id "DONE" "finishing up"))))
  ;; Substantial body, no drawer, but not a finished keyword.
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--give-body file 12)
    (should-not (string-match-p
                 "org_wrap_plan"
                 (claude-code-ide-org-set-todo id "DOING" "starting")))))

(ert-deftest claude-code-ide-org-test-lint-refuses-a-line-anchor-in-a-live-body ()
  "A live heading may not cite `file.el:NNN' (TODO.org :ID: 5fc7b934).

The form rots *upward*, which is what makes it worse than a broken link:
the file grows, the cited line still exists, and it now holds something
else plausible. Measured when the rule shipped -- all eight live anchors
already named their symbol in the same sentence, so deleting the line
number lost nothing in every case."
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint
            (concat "* TODO A live heading\n"
                    ":PROPERTIES:\n"
                    ":ID:       aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n"
                    ":CREATED:  [2026-09-02 Wed 09:00]\n:END:\n"
                    "The helper =claude-code-ide-org--merge-time-intervals=\n"
                    "(config.el:973) sorts conses and merges them.\n"))
           'error "live body cites a line number")))

(ert-deftest claude-code-ide-org-test-lint-leaves-a-closed-heading-s-line-anchor ()
  "A finished heading's anchor is history and is deliberately left alone.

\"This was true at config.el:2792 on 2026-08-21\" is a statement about
the past; rewriting it would falsify the record rather than repair it.
38 such anchors stand in the corpus, and the rule must not touch them --
which is the half that keeps this from being a corpus-wide rewrite.

Also asserts the `:PLAN:' case, because that is how a heading carrying an
anchor legitimately closes: the citation travels into the drawer with the
rest of the prospective half and stops being a live pointer."
  (should-not
   (claude-code-ide-org-test--lint-matches
    (claude-code-ide-org-test--lint
     (concat "* DONE A closed heading\n"
             "CLOSED: [2026-08-21 Fri 13:20]\n"
             ":PROPERTIES:\n"
             ":ID:       bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\n"
             ":CREATED:  [2026-08-20 Thu 09:00]\n:END:\n"
             "It was true at =config.el:2792= when this was written.\n"))
    'error "live body cites a line number"))
  (should-not
   (claude-code-ide-org-test--lint-matches
    (claude-code-ide-org-test--lint
     (concat "* TODO A live heading whose anchor sits in :PLAN:\n"
             ":PROPERTIES:\n"
             ":ID:       cccccccc-cccc-cccc-cccc-cccccccccccc\n"
             ":CREATED:  [2026-09-02 Wed 09:00]\n:END:\n"
             ":PLAN:\n"
             "The old note cited =config.el:973= here.\n"
             ":END:\n"
             "Body prose with no anchor.\n"))
    'error "live body cites a line number")))

(ert-deftest claude-code-ide-org-test-slice-window-ignores-work-predating-it ()
  "A member's clock from before the slice existed does not open its window.

TODO.org :ID: 42ba0a80 bounded the window to first work rather than
`:CREATED:'.  That fix is defeated by a member with earlier history: the
scan returns the earliest clock anywhere in the slice, and a heading
refiled into a new slice routinely carries clocks from weeks before it
was composed.  Measured 2026-09-02 -- `8a2eb687' was TODO, unstarted,
and listed four incidentals because its member `8ddd7fa8' carried a
CLOCK from 2026-08-19 against a slice created 2026-09-01.

The floor is applied *inside* the scan rather than to its result, and
that distinction is the test's real subject: rejecting the earliest
clock afterwards zeroes every slice, because almost every slice has some
member with older history.  Ignoring pre-creation clocks while scanning
keeps the first one that happened after the slice existed."
  (claude-code-ide-org-test--with-slice-window
    (with-current-buffer (find-file-noselect file)
      ;; Strip the slice's own clock; its members now carry all the time.
      (goto-char (point-min))
      (re-search-forward "^\\* TODO \\[1/1\\] A slice")
      (org-back-to-heading t)
      (let ((lim (save-excursion (org-end-of-subtree t t))))
        (save-excursion
          (when (re-search-forward "^[ \t]*CLOCK:.*\n" lim t) (replace-match ""))))
      ;; Give the planned member a clock from BEFORE the slice was created.
      (goto-char (point-min))
      (re-search-forward "^:ID:       member-01$")
      (re-search-forward "^:END:$")
      (insert "\n:LOGBOOK:\nCLOCK: [2026-08-18 Mon 09:00]--"
              "[2026-08-18 Mon 09:30] =>  0:30\n:END:")
      ;; Point must be ON the slice for `--slice-incidental-ids'. Asserting
      ;; from wherever the last edit left it returns nil for the wrong
      ;; reason, which is a check with no way to fail -- caught here by the
      ;; positive half failing while the negative half "passed".
      (cl-flet ((incidentals ()
                  (goto-char (point-min))
                  (re-search-forward "^\\* TODO \\[1/1\\] A slice")
                  (org-back-to-heading t)
                  (claude-code-ide-org--slice-incidental-ids)))
        (should-not (incidentals))
        ;; Move the same clock to after creation and the window returns, so
        ;; the guard is the date rather than the mere presence of a clock.
        (goto-char (point-min))
        (re-search-forward "CLOCK: \\[2026-08-18 Mon 09:00\\]--\\[2026-08-18 Mon 09:30\\]")
        (replace-match "CLOCK: [2026-08-21 Fri 09:00]--[2026-08-21 Fri 09:30]" t t)
        (should (member "incid-002" (incidentals)))))))

(ert-deftest claude-code-ide-org-test-refresh-preserves-a-deleted-cookie ()
  "A member whose cookie was deleted stays cookie-less across a refresh.

Deleting the checkbox is how a slice drops a member -- cancelled,
deferred, or moved to another slice.  `--slice-member-regexp' documents
the absent cookie, `--slice-members' returns nil for its mark, and
`--slice-blocker-ids' excludes it deliberately so a deferred member
cannot hold the slice open forever.

But the rewriter derived the box from the referent's keyword and put it
back, so the documented mechanism was defeated by the very command that
maintains slices.  Measured 2026-09-02: four lines de-cookied by hand
returned checked on the next refresh, and the two conventions had been
contradicting each other in writing -- CLAUDE.md says the checkbox is
derived and regenerated, the code says its absence is a declaration.
Absence wins, because only it can express something the referent's
keyword cannot."
  (claude-code-ide-org-test--with-slice-window
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (re-search-forward "^- \\[X\\] \\(\\[\\[id:member-01\\)")
      (replace-match "- \\1" t)
      (let ((index (claude-code-ide-org--slice-referent-index)))
        (goto-char (point-min))
        (re-search-forward "^\\* TODO \\[1/1\\] A slice")
        (org-back-to-heading t)
        (claude-code-ide-org--refresh-slice-members-at-point index))
      (goto-char (point-min))
      (should (re-search-forward "^- \\[\\[id:member-01" nil t))
      (goto-char (point-min))
      (should-not (re-search-forward "^- \\[[ Xx-]\\] \\[\\[id:member-01" nil t)))))

(ert-deftest claude-code-ide-org-test-advance-repeater-leaves-no-deferred-note ()
  "Advancing the repeater must register nothing on `post-command-hook'.

`org-todo' with a `!' cookie calls `org-add-log-setup', which schedules
`org-add-log-note' to run *after* the command -- by which time the
`inhibit-read-only' binding has unwound.  Against the user's read-only
TODO.org that surfaces as
\"error in post-command-hook (org-add-log-note): (buffer read-only ...)\",
observed live 2026-09-03.  Binding `inhibit-read-only' alone does not fix
it; it moves the failure from `org-todo' into the deferred note.

Asserts the absence of the hook rather than the absence of an error,
because the error happens in a later command loop that a batch test does
not have -- the thing this test can see is the registration."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--add-child
     file (concat "* TODO Archive closed tasks daily\n"
                  "SCHEDULED: <2026-09-03 Thu 07:00 ++1d>\n"
                  ":PROPERTIES:\n"
                  ":ID:       cbe282ec-10c3-4aa0-8d3a-f30e17a12fa8\n"
                  ":CREATED:  [2026-08-01 Sat 09:00]\n:END:\n"))
    (with-current-buffer (find-file-noselect file) (setq buffer-read-only t))
    (let ((post-command-hook nil)
          (org-log-repeat 'time))
      (should (claude-code-ide-org--ceremony-advance-repeater))
      (should-not (memq 'org-add-log-note post-command-hook)))
    ;; The advance still did its job, so the suppression is scoped to the
    ;; note and not to the transition.
    (let ((text (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p "2026-09-04" text))
      (should (string-match-p "^\\* TODO Archive closed tasks daily" text)))
    (should (with-current-buffer (find-file-noselect file) buffer-read-only))))
