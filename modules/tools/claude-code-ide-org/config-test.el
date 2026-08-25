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
             (insert "#+TODO: TODO NEXT(n!) PLANNING(p!) DOING(d!) WAITING(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n"
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

Note the level arithmetic, the part most likely to surprise: org pastes at
`(org-get-valid-level 1 1)', so a level-1 source lands at level 2 under
the target and its level-2 child at level 3.  Relative depth is preserved.
Flattening happens only when a *child* is archived directly, which is why
the sweep archives at level 2 only."
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
      (should (string-match-p "^\\*\\* DONE Test heading" arch))
      (should (string-match-p "^\\*\\*\\* DONE Child heading" arch))
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
        (insert (concat "#+TODO: TODO NEXT(n!) PLANNING(p!) DOING(d!) WAITING(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n"
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

(ert-deftest claude-code-ide-org-test-trigger-hook-auto-clocks-in-on-planning ()
  "org-trigger-hook must also auto-clock-in the moment PLANNING is set
-- TODO.org :ID: b95b9fba-f78e-48fe-8546-988709cce309 -- mirroring the
existing DOING coverage above."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-auto-clock-in-on-doing t))
      (should (not (org-clocking-p)))
      (org-with-point-at (org-id-find id 'marker)
        (org-todo "PLANNING"))
      (should (org-clocking-p))
      (should (equal id (org-with-point-at org-clock-marker
                          (org-entry-get nil "ID")))))))

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

(ert-deftest claude-code-ide-org-test-trigger-hook-skips-container-on-planning ()
  "The exemption must cover PLANNING as well as DOING -- both states
open a clock via the same trigger, so both must skip it for a
container."
  (claude-code-ide-org-test--with-heading
    (let ((claude-code-ide-org-auto-clock-in-on-doing t)
          (org-trigger-hook (list #'claude-code-ide-org--trigger-auto-clock-in)))
      (claude-code-ide-org-test--add-child file "** TODO A real child\n")
      (org-with-point-at (org-id-find id 'marker) (org-todo "PLANNING"))
      (should (not (org-clocking-p))))))

(ert-deftest claude-code-ide-org-test-trigger-hook-skips-clock-in-when-already-clocked-on-planning ()
  "No duplicate CLOCK line when a clock is already running on the
heading being set to PLANNING."
  (claude-code-ide-org-test--with-heading
    (claude-code-ide-org-test--clock-in-for-real id)
    (org-with-point-at (org-id-find id 'marker) (org-todo "PLANNING"))
    (should (org-clocking-p))
    (let ((disk (with-current-buffer (get-file-buffer file) (buffer-string)))
          (count 0) (start 0))
      (while (string-match "CLOCK: \\[" disk start)
        (setq count (1+ count) start (match-end 0)))
      (should (= 1 count)))))

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
    ;; The superseding sibling is named by an [[id:...]] link, not a bare
    ;; title: titles get revised as scope clarifies, and a note explaining
    ;; *why* something was demoted is the last place a stale name should
    ;; appear. Asserting the id specifically, since a title-only match
    ;; would still pass against the old format.
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p
               "Auto-demoted: superseded by sibling \\[\\[id:test-0002\\]\\[Sibling B\\]\\] becoming NEXT"
               disk))
      (should-not (string-match-p "sibling \"Sibling B\"" disk)))))

(ert-deftest claude-code-ide-org-test-single-next-demote-note-falls-back-to-title ()
  "When the superseding sibling has no :ID:, the note names it by quoted
title rather than producing a broken link. A slightly stale name beats a
dangling [[id:nil]], and beats no note at all -- the note exists to
explain a demotion the reader did not ask for.

Note this test passes against the *pre-id-link* implementation too, which
always quoted the title: it pins the fallback rather than demonstrating
the change. The discriminating assertion lives in
`claude-code-ide-org-test-single-next-demotes-old-next-among-top-level-headings\'."
  (claude-code-ide-org-test--with-heading
    (org-with-point-at (org-id-find id 'marker) (org-todo "NEXT"))
    (goto-char (point-max))
    (insert "* TODO Sibling with no id                                           :code:\n")
    (save-buffer)
    (goto-char (point-min))
    (re-search-forward "^\\* TODO Sibling with no id")
    (org-todo "NEXT")
    (save-buffer)
    (let ((disk (claude-code-ide-org-test--disk-contents file)))
      (should (string-match-p
               "Auto-demoted: superseded by sibling \"Sibling with no id\" becoming NEXT"
               disk))
      (should-not (string-match-p "\\[\\[id:" disk)))))

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
    (org-with-point-at (org-id-find id 'marker) (org-todo "WAITING"))
    (org-with-point-at (org-id-find id 'marker) (org-todo "TODO"))
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))
    (org-with-point-at (org-id-find id 'marker) (org-todo "NEXT"))
    (org-with-point-at (org-id-find id 'marker) (org-todo "TODO"))
    (should (equal "TODO" (org-with-point-at (org-id-find id 'marker) (org-get-todo-state))))))


(ert-deftest claude-code-ide-org-test-single-next-does-not-promote-a-container ()
  "A container is a project, not an action, so the sole-TODO promotion
must refuse it however cleanly it survives its sibling group (TODO.org
:ID: 42808717).  Reproduces 2026-08-19's scratch-file case: an epic left
NEXT while its own child action stayed TODO, which inverts the one thing
NEXT means.

The discriminating half -- that a *leaf* sole survivor is still promoted
-- is asserted by
`claude-code-ide-org-test-single-next-promotes-sole-remaining-todo-when-sibling-goes-done\',
which fails the moment this guard is applied to every heading rather than
to containers only.  Both are needed: an assertion that only checks the
refusal would pass against a function that had simply stopped promoting."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "* TODO An epic with children                                       :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0002\n"
                     ":END:\n"
                     "** TODO A real child action                                        :code:\n"
                     ":PROPERTIES:\n"
                     ":ID:       test-0003\n"
                     ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    ;; Group is {id=TODO, epic=TODO}; close `id\' so the epic becomes the
    ;; sole TODO survivor with no NEXT anywhere in the group.
    (org-with-point-at (org-id-find id 'marker) (org-todo "DONE"))
    (should (equal "TODO" (org-with-point-at (org-id-find "test-0002" 'marker)
                            (org-get-todo-state))))
    ;; And nothing descended into the child either -- 42808717 leaves
    ;; descend-vs-nothing open, and this pins the answer shipped.
    (should (equal "TODO" (org-with-point-at (org-id-find "test-0003" 'marker)
                            (org-get-todo-state))))
    (save-buffer)
    (should-not (string-match-p "Auto-promoted"
                                (claude-code-ide-org-test--disk-contents file)))))

(ert-deftest claude-code-ide-org-test-review-batch-does-not-promote-on-apply-order ()
  "Observed live 2026-08-21 on this repo's own file (TODO.org :ID:
c8a6c5d2): children captured in one session are keywordless until their
queued `none -> TODO\' events are applied, and apply lands one event at a
time -- so the first child to land is momentarily the only keyworded
sibling of the group and gets promoted to NEXT.  Nobody chose it; the
NEXT records queue order.

Three children rather than the five that were observed: the mechanism is
the first landing, not the count."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "** Child A\n:PROPERTIES:\n:ID:       test-0002\n:END:\n"
                     "** Child B\n:PROPERTIES:\n:ID:       test-0003\n:END:\n"
                     "** Child C\n:PROPERTIES:\n:ID:       test-0004\n:END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let* ((mk (lambda (child at)
                 (list :type 'state :id child :from "none" :to "TODO"
                       :ts (date-to-time (format "2026-08-21T%s-0500" at))
                       :events nil)))
           (result (claude-code-ide-org--review-apply
                    (list (funcall mk "test-0002" "09:52:00")
                          (funcall mk "test-0003" "09:52:10")
                          (funcall mk "test-0004" "09:52:20")))))
      (should (= 3 (plist-get result :applied)))
      (should-not (plist-get result :errors))
      (dolist (child '("test-0002" "test-0003" "test-0004"))
        (should (equal "TODO" (org-with-point-at (org-id-find child 'marker)
                                (org-get-todo-state)))))
      (should-not (string-match-p "Auto-promoted"
                                  (claude-code-ide-org-test--disk-contents file))))))

(ert-deftest claude-code-ide-org-test-review-batch-still-promotes-a-genuine-sole-survivor ()
  "The other half of c8a6c5d2's fix, and the one that keeps it from
amounting to deleting the trigger.  Suppressing the promotion during a
batch and stopping there would leave it dead in production -- under the
queue architecture nearly every transition arrives through apply -- so
`claude-code-ide-org--review-settle-auto-promote\' runs it once
afterwards, against the batch's finished state.

Here the batch genuinely does reduce the group to one TODO survivor, and
that survivor must come out NEXT.  This test fails against a
suppress-only fix, which is exactly what it is for."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert (concat "** TODO Survivor\n:PROPERTIES:\n:ID:       test-0002\n:END:\n"
                     "** TODO Closes in the batch\n:PROPERTIES:\n:ID:       test-0003\n:END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let ((result (claude-code-ide-org--review-apply
                   (list (list :type 'state :id "test-0003" :from "TODO" :to "DONE"
                               :ts (date-to-time "2026-08-21T10:27:00-0500")
                               :events nil)))))
      (should (= 1 (plist-get result :applied)))
      (should-not (plist-get result :errors))
      (should (equal "NEXT" (org-with-point-at (org-id-find "test-0002" 'marker)
                              (org-get-todo-state))))
      (should (string-match-p "Auto-promoted: sole remaining TODO in its sibling group"
                              (claude-code-ide-org-test--disk-contents file))))))


;;; Session context ("what was I last doing") -----------------------------

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

(ert-deftest claude-code-ide-org-test-session-context-omits-doing-containers ()
  "A container in DOING is a true and unremarkable statement about the
project. Reporting it would add one permanent, never-changing line --
the failure mode this filter exists to prevent -- so it must be
excluded while an otherwise identical leaf is not."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* DOING Epic heading                                                :code:\n"
            ":PROPERTIES:\n:ID:       test-0002\n:END:\n"
            "** TODO A real child                                                :code:\n"
            ":PROPERTIES:\n:ID:       test-0003\n:END:\n")
    (save-buffer)
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
    ;; `--trigger-auto-clock-in' firing on the DOING transition, which is
    ;; off by default since 2026-08-18 -- and relying on it was wrong even
    ;; before that, since what is under test is how session-context
    ;; reports a clocked heading, not what opened the clock.
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
               "#+TODO: TODO NEXT(n!) PLANNING(p!) DOING(d!) WAITING(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n#+TAGS:"
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
            (insert "#+TODO: TODO NEXT PLANNING DOING WAITING MAYBE | DONE CANCELLED\n")
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
Without this the other tests could pass by the lint flagging everything."
  (should (null (claude-code-ide-org-test--lint
                 (concat "* Category\n"
                         "** TODO A task                                     :code:\n"
                         ":PROPERTIES:\n"
                         ":ID:       11111111-1111-1111-1111-111111111111\n"
                         ":CREATED:  [2026-08-14 Fri 10:00]\n"
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

(ert-deftest claude-code-ide-org-test-lint-catches-stray-level-1-heading ()
  "A level-1 heading that neither routes nor mirrors one that does.

The stronger half of :ID: 95087d8f: it catches the incident even had the
phantom been named something word-like. A category is a level-1 heading
with an =:ARCHIVE:= target, which is what makes it routable rather than
merely top-level.

Three cases in one fixture, because an implementation that collapsed any
two would still satisfy the others."
  ;; Routing category present, so the convention is in evidence: a
  ;; second level-1 without :ARCHIVE: is a stray.
  (should (claude-code-ide-org-test--lint-matches
           (claude-code-ide-org-test--lint
            (concat "* Real category\n:PROPERTIES:\n"
                    ":ARCHIVE:  DONE.org::* Real category\n:END:\n"
                    "* Phantom\n"))
           'error "neither a category"))
  ;; No routing level-1 anywhere: nothing to infer the convention from,
  ;; so the check stays silent rather than flagging every fixture in
  ;; this file.
  (should-not (claude-code-ide-org-test--lint-matches
               (claude-code-ide-org-test--lint "* Category\n")
               'error "neither a category")))

(ert-deftest claude-code-ide-org-test-lint-allows-an-archive-mirror ()
  "A level-1 heading mirroring a category, in the file it archives to.

Measured on the real files 2026-08-19: all seven of TODO.org's level-1
headings carry =:ARCHIVE:= and none of DONE.org's seven do, because the
latter are archive *targets*. So the routing set is collected across
every linted file and matched by title, and a target is recognised by
the source it mirrors.

Two files, not one, because that is the only shape in which this case
exists -- an earlier single-file version of this assertion passed with
the mirror allowance mutated away, since its only level-1 carried
=:ARCHIVE:= and the allowance was never reached."
  (let* ((dir (file-name-as-directory (make-temp-file "lint-mirror" t)))
         (src (expand-file-name "TODO.org" dir))
         (dst (expand-file-name "DONE.org" dir)))
    (unwind-protect
        (progn
          (with-temp-file src
            (insert "* Real category\n:PROPERTIES:\n"
                    ":ARCHIVE:  DONE.org::* Real category\n:END:\n"))
          (with-temp-file dst
            (insert "* Real category\n"      ; the mirror: no :ARCHIVE:
                    "* Phantom\n"))          ; and a stray beside it
          (let ((findings (claude-code-ide-org-lint (list src dst))))
            (should-not (claude-code-ide-org-test--lint-matches
                         findings 'error "mirror of one: Real category"))
            (should (claude-code-ide-org-test--lint-matches
                     findings 'error "mirror of one: Phantom"))))
      (delete-directory dir t))))

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
                 "* Category\nWrite links as [[id:...]] in prose.\n"))))

(ert-deftest claude-code-ide-org-test-lint-resolves-across-reference-files ()
  "A link out of the linted set resolves when the target file is given
as a reference — otherwise every cross-file link reads as dangling."
  (let ((text (concat "* Category\nSee [[id:22222222-2222-2222-2222-222222222222][elsewhere]].\n"))
        (ref (concat "* Notes\n** TODO Over here\n:PROPERTIES:\n"
                     ":ID:       22222222-2222-2222-2222-222222222222\n"
                     ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n")))
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

(ert-deftest claude-code-ide-org-test-lint-catches-category-conventions ()
  "Level-1 headings are structure: no keyword, no :ID:, no tags."
  (let ((findings (claude-code-ide-org-test--lint
                   (concat "* TODO Category                                  :code:\n"
                           ":PROPERTIES:\n"
                           ":ID:       55555555-5555-5555-5555-555555555555\n"
                           ":CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"))))
    (should (claude-code-ide-org-test--lint-matches findings 'error "carries TODO keyword"))
    (should (claude-code-ide-org-test--lint-matches findings 'error "carries :ID:"))
    (should (claude-code-ide-org-test--lint-matches findings 'error "carries tags"))
    (should (claude-code-ide-org-test--lint-matches findings 'error "carries :CREATED:"))))

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
             (insert "#+TODO: TODO NEXT(n!) PLANNING(p!) DOING(d!) WAITING(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)\n"
                     "#+TAGS: code comms research review\n"
                     "#+ARCHIVE: DONE.org::* Done\n"
                     "\n"
                     ;; A category to file into. `target' is required
                     ;; since 2026-08-20 (:ID: 97696fc2), so a fixture
                     ;; with nowhere to put a heading cannot exercise
                     ;; capture at all.
                     "* Scratch\n"))
           ,@body)
       (when (org-clocking-p) (org-clock-out))
       (let ((buf (get-file-buffer capture-file)))
         (when buf
           (with-current-buffer buf (set-buffer-modified-p nil))
           (kill-buffer buf)))
       (delete-directory dir t))))

(ert-deftest claude-code-ide-org-test-capture-creates-heading-with-id ()
  (claude-code-ide-org-test--with-capture-file
    (let ((result (claude-code-ide-org-capture "Buy stamps" "Scratch")))
      (should (string-match-p "\\`Captured: \"Buy stamps\" (ID: [^)]+)" result))
      (string-match "(ID: \\([^)]+\\))" result)
      (let ((returned-id (match-string 1 result))
            (disk (claude-code-ide-org-test--disk-contents capture-file)))
        ;; A real, non-empty ID landed both in the return string and on disk.
        (should (> (length returned-id) 0))
        (should (string-match-p "^\\*\\* Buy stamps[ \t]*$" disk))
        (should (string-match-p (concat "^:ID: +" (regexp-quote returned-id) "[ \t]*$") disk))
        (should (not (buffer-modified-p (get-file-buffer capture-file))))))))

(ert-deftest claude-code-ide-org-test-capture-writes-no-todo-keyword ()
  "The heading is deliberately keyword-less: state is supplied at
ingestion so org logs the transition natively, rather than asserted live
by a tool whose every other state write is queued."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-capture "Keywordless task" "Scratch")
    (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
      (should (string-match-p "^\\*\\* Keywordless task[ \t]*$" disk))
      (should-not (string-match-p "^\\* \\(TODO\\|NEXT\\|DOING\\) " disk)))))

(ert-deftest claude-code-ide-org-test-capture-writes-created-property ()
  "Formatted in elisp, not via the template's %U escape: an escape that
fails to expand leaves a literal \"%U\" and still passes a naive
is-the-property-there check."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-capture "Stamped task" "Scratch")
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
           (result (claude-code-ide-org-capture "Round trip task" "Scratch")))
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
           (result (claude-code-ide-org-capture title "Scratch")))
      (should (string-match-p (regexp-quote (format "Captured: \"%s\"" title)) result))
      (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
        (should (string-match-p (regexp-quote (concat "* " title)) disk))))))

(ert-deftest claude-code-ide-org-test-capture-target-by-category-title ()
  "Top-level categories carry no :ID: by convention, so a title is the
only handle.  Safe for these specifically: few, human-curated, never
refiled."
  (claude-code-ide-org-test--with-capture-file
    (with-current-buffer (find-file-noselect capture-file)
      (goto-char (point-max))
      (insert "* Tooling\n* Skill logic\n")
      (save-buffer))
    (let ((result (claude-code-ide-org-capture "Filed under a category" "Tooling")))
      (should (string-match-p "under \"Tooling\"" result))
      (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
        ;; Landed as a child of Tooling, not of Skill logic, and not at
        ;; the end of the file.
        (should (string-match-p
                 "^\\* Tooling\n\\*\\* Filed under a category" disk))))))

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

(ert-deftest claude-code-ide-org-test-capture-unknown-target-refuses ()
  "Better to error than to file it somewhere the caller did not ask for:
a caller that named a destination and silently got a different one is
worse off than one that got an error."
  (claude-code-ide-org-test--with-capture-file
    (let ((result (claude-code-ide-org-capture "Nowhere task" "No Such Category")))
      (should (string-prefix-p "Error:" result))
      (let ((disk (claude-code-ide-org-test--disk-contents capture-file)))
        (should-not (string-match-p "Nowhere task" disk))))))

(ert-deftest claude-code-ide-org-test-capture-refuses-without-a-target ()
  "Omitting `target\' is refused rather than guessed at.

This test asserted the opposite until 2026-08-20: that capture appended
at end of file. That fallback was reasoned as \"the honest answer for
placement unknown\", which it is in general and is not here -- the capture
file is TODO.org, so appending means a *level-1* heading, and this
project reserves those for categories (TODO.org :ID: 97696fc2).

The `Error:\' prefix is asserted specifically, because
`bin/hooks/queue-append\' drops a reply carrying it -- so the prefix is
what stops a deferred capture being queued as well."
  (claude-code-ide-org-test--with-capture-file
    (dolist (bad (list nil "" "   "))
      (let ((result (claude-code-ide-org-capture "Unplaced task" bad)))
        (should (string-prefix-p "Error:" result))
        (should (string-match-p "target is required" result))))
    ;; Nothing was written under any of them.
    (should-not (string-match-p "Unplaced task"
                                (claude-code-ide-org-test--disk-contents capture-file)))))

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
          ;; `target\' is required since :ID: 97696fc2, so the fallback file
          ;; needs a category to name. What is under test is still which
          ;; *file* capture resolves to, not where in it the heading lands.
          (with-temp-file notes-file (insert "* Inbox\n"))
          (claude-code-ide-org-capture "Fallback target task" "Inbox")
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
      (should (string-match-p "^TODO Test heading" result))
      (should (string-match-p "^  TODO Child heading" result)))))

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
      (should (string-match-p "Blocked heading.*\\[blocked\\]" result))
      (should-not (string-match-p "Test heading.*\\[blocked\\]" result)))))

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
      (should (string-match-p "Dangling blocker.*\\[blocked\\?\\]" result))
      (should (string-match-p "Sibling-form blocker.*\\[blocked\\?\\]" result)))))

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
      (should (string-match-p "Bare-form dependent.*\\[blocked\\]" result)))))

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
  "An empty set is written as `[]'/`{}', never `null'.

Asserted on the bytes, because the round-trip cannot catch this: Elisp
spells the empty list, the empty object and JSON null all as nil, so
this reader accepts `null' happily and every in-process test still
passes.  No other JSON stack is that forgiving -- `d.get(\"applied\",
[])' does not fall back when the key is present holding null, which
crashed a real inspection script on a real watermark file.  Dismissing
before anything is applied is the case that produces it."
  (claude-code-ide-org-test--with-queue
    (claude-code-ide-org--queue-mark-dismissed
     "sess-a" '("2026-08-07T09:00:00-0500") "never applying this")
    (let ((text (claude-code-ide-org-test--disk-contents
                 (claude-code-ide-org--queue-watermark-file "sess-a"))))
      (should (string-match-p "\"applied\":\\[\\]" text))
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

(ert-deftest claude-code-ide-org-test-review-line-shows-what-will-be-written ()
  "The review line names the total apply will really write.

The median span writes about 46% of what it displays, so confirming the
displayed figure means confirming a number that is recorded nowhere.
An item with no backing kinds says nothing extra -- there is no
divergence to report."
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
      (should (string-match-p "writes 0:21 in 2"
                              (claude-code-ide-org--review-describe split)))
      (should-not (string-match-p "writes" (claude-code-ide-org--review-describe bare)))
      ;; The confirmed case writes what it displays, and says nothing.
      (should-not (string-match-p
                   "writes"
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
    ;; one-minute floor (:ID: 31c6ac39) it writes 0:01. This used to
    ;; assert "writes nothing (11s of turns, none crossing a minute)",
    ;; and that reason is now unreachable by construction -- the branch
    ;; survives only as a guard that says so.
    (let* ((events (list (claude-code-ide-org-test--guidepost "09:00:14" "resume")
                         (claude-code-ide-org-test--guidepost "09:00:25" "pause")))
           (item (list :type 'clock :id "id-a" :suggested t :events events
                       :start (plist-get (car events) :ts)
                       :end (plist-get (cadr events) :ts))))
      (should-not (string-match-p "writes nothing"
                                  (claude-code-ide-org--review-written-summary item))))
    ;; The trailing in-flight span: one guidepost, start = end.
    (let* ((events (list (claude-code-ide-org-test--guidepost "09:00:14" "resume")))
           (item (list :type 'clock :id "id-a" :suggested t :events events
                       :start (plist-get (car events) :ts)
                       :end (plist-get (car events) :ts))))
      (should (equal "writes nothing (a single point, not an interval)"
                     (claude-code-ide-org--review-written-summary item))))
    ;; Guideposts spanning real time, but never a resume then a pause.
    (let* ((events (list (claude-code-ide-org-test--guidepost "09:00:00" "resume")
                         (claude-code-ide-org-test--guidepost "09:08:00" "resume")))
           (item (list :type 'clock :id "id-a" :suggested t :events events
                       :start (plist-get (car events) :ts)
                       :end (plist-get (cadr events) :ts))))
      (should (equal "writes nothing (no completed turn in it)"
                     (claude-code-ide-org--review-written-summary item))))
    ;; And a span that DOES write keeps saying so -- the reason must not
    ;; leak onto items that are not no-ops.
    (let ((item (list :type 'clock :id "id-a" :suggested t
                      :events (claude-code-ide-org-test--two-run-events)
                      :start (date-to-time "2026-08-06T09:00:00-0500")
                      :end (date-to-time "2026-08-06T09:31:00-0500"))))
      (should (equal "writes 0:21 in 2"
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
  "The review buffer's `writes H:MM' must be what apply really writes.

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
         (item (list :suggested t :events events)))
    (should (equal "writes 0:06 in 2"
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
PLANNING transition asserts work is happening there in a way TODO or
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
    (goto-char (point-max))
    (insert (concat "* NEXT Sibling B                                                   :code:\n"
                    ":PROPERTIES:\n"
                    ":ID:       test-0002\n"
                    ":END:\n"))
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let ((item (list :type 'state :id id
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
writing a `State \"PLANNING\" from \"DOING\"' line that looks correct
(TODO.org :ID: f9f61c04-150b-4ee7-96c9-582cf2bda95a)."
  (claude-code-ide-org-test--with-heading
    ;; Reality has moved on to DOING; the queued event still says NEXT.
    (claude-code-ide-org-test--set-todo-for-real id "DOING")
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
  ;; Both halves need the trigger switched ON: since 2026-08-18 it is off
  ;; by default (`claude-code-ide-org-auto-clock-in-on-doing'), and a
  ;; guard against a trigger that never fires would assert nothing. This
  ;; pins that the guard still works for a user who opts back in.
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

(ert-deftest claude-code-ide-org-test-review-assign-advances-to-next-item ()
  "Assigning answers the question a line poses, so point moves on -- the
same reasoning behind the mark commands' ADVANCE.  Re-rendering erases
the buffer and left point at the top, so assigning a run of spans meant
scrolling back to find your place after every one.

Restoring by identity rather than line number is load-bearing here:
assigning removes the evidence lines an unassigned span carries, so the
buffer is shorter afterwards and the old line number points elsewhere."
  (claude-code-ide-org-test--with-heading
    (let ((review (get-buffer-create "*org-review-assign-test*"))
          (first (list :type 'clock :id nil :unassigned t :suggested t
                       :start (claude-code-ide-org-test--t "09:00")
                       :end (claude-code-ide-org-test--t "09:30") :events nil))
          (second (list :type 'clock :id nil :unassigned t :suggested t
                        :start (claude-code-ide-org-test--t "11:00")
                        :end (claude-code-ide-org-test--t "11:30") :events nil)))
      (org-id-update-id-locations (list file))
      (unwind-protect
          (with-current-buffer review
            (claude-code-ide-org-review-mode)
            (setq claude-code-ide-org--review-items (list first second))
            (claude-code-ide-org--review-render)
            (claude-code-ide-org-test--goto-nth-item 0)
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
            ;; Point is on the *second* span, not back at the top.
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
    ;; one: only DOING/PLANNING assert that work is happening.
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
    (let ((result (claude-code-ide-org-capture "Immediate task" "Scratch")))
      (should (string-prefix-p claude-code-ide-org--reply-captured result))
      (should (string-match-p "^\\*\\* Immediate task[ \t]*$"
                              (claude-code-ide-org-test--disk-contents capture-file))))))

(ert-deftest claude-code-ide-org-test-capture-defers-when-busy ()
  "With unsaved human edits in the buffer, capture queues instead of
writing -- and writes *nothing*, which is the half that matters.  A
reply that says queued while the heading also landed is the
double-apply this gate exists to prevent."
  (claude-code-ide-org-test--with-capture-file
    (claude-code-ide-org-test--make-busy capture-file)
    (let ((result (claude-code-ide-org-capture "Deferred task" "Scratch")))
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
        (should (string-match-p "capture \"New thing\" +-> end of file" text))
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
    (should (string-match-p "nothing would be wrapped"
                            (claude-code-ide-org-wrap-plan id "A line.")))
    ;; None of those refusals may have written anything.
    (should-not (string-match-p ":PLAN:" (claude-code-ide-org-test--body-of id)))
    ;; A successful wrap, then a second attempt on the same heading.
    (claude-code-ide-org-wrap-plan id)
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

(ert-deftest claude-code-ide-org-test-auto-promote-does-not-re-enter-itself ()
  "The promotion writes ONCE, counted rather than inferred.

TODO.org: the trigger calls `org-todo', which fires `org-trigger-hook',
which is the trigger -- so without a re-entrancy guard it promotes in
the group it has just changed, and repeats. Measured on one real apply
2026-08-24: 1201 mutations across 114 headings in nine seconds, against
twelve queued state changes.

Counted, not asserted on the end state, and that is the whole point of
this test. The finished keywords can be perfectly correct while
hundreds of writes happened underneath -- which is exactly what the
audit log showed and what no end-state assertion would have caught.

*This test does not discriminate on its own*, and saying so matters. A
single sibling group cannot cascade into itself: after the promotion the
group holds a NEXT, so the re-entered call refuses on its own terms. The
production cascade came from the settle loop firing across many groups,
plus level-1 categories becoming eligible once one acquired a keyword,
and no minimal fixture reproduces that. The guard is pinned by the test
below; this one is a regression guard on the write count.

`--review-applying' does not cover this: it is unbound during
`--review-settle-auto-promote' by design, which is when the cascade
ran."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* Parent\n"
            "** TODO Only child left                                             :code:\n"
            ":PROPERTIES:\n:ID:       test-promo-1\n:CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"
            "** DONE Finished sibling                                            :code:\n"
            ":PROPERTIES:\n:ID:       test-promo-2\n:CREATED:  [2026-08-14 Fri 10:00]\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (let ((calls 0))
      (cl-letf* ((real (symbol-function 'org-todo))
                 ((symbol-function 'org-todo)
                  (lambda (&rest args) (setq calls (1+ calls)) (apply real args))))
        (claude-code-ide-org--at-id
         "test-promo-1"
         (lambda () (claude-code-ide-org--trigger-auto-promote-sole-todo nil))))
      ;; Exactly one write: the promotion itself, and nothing it caused.
      (should (= 1 calls)))
    ;; And it did the right thing while doing it once.
    (should (equal "NEXT"
                   (claude-code-ide-org--at-id
                    "test-promo-1" (lambda () (org-get-todo-state)))))))

(ert-deftest claude-code-ide-org-test-auto-promote-guard-is-not-review-applying ()
  "The two guards are not substitutes, which is why the cascade was possible.

`--review-applying' suppresses the promotion for a whole apply batch so
it can settle once afterwards; it is deliberately unbound during that
settle. `--auto-promote-active' guards a single call against its own
`org-todo'. Binding either alone leaves a hole, so both are asserted to
stop the trigger independently."
  (claude-code-ide-org-test--with-heading
    (goto-char (point-max))
    (insert "* Parent\n"
            "** TODO Only child left                                             :code:\n"
            ":PROPERTIES:\n:ID:       test-promo-1\n:CREATED:  [2026-08-14 Fri 10:00]\n:END:\n"
            "** DONE Finished sibling                                            :code:\n"
            ":PROPERTIES:\n:ID:       test-promo-2\n:CREATED:  [2026-08-14 Fri 10:00]\n:END:\n")
    (save-buffer)
    (org-id-update-id-locations (list file))
    (dolist (guard '(claude-code-ide-org--review-applying
                     claude-code-ide-org--auto-promote-active))
      (claude-code-ide-org--at-id
       "test-promo-1"
       (lambda ()
         (eval `(let ((,guard t))
                  (claude-code-ide-org--trigger-auto-promote-sole-todo nil))
               t)))
      (should (equal "TODO"
                     (claude-code-ide-org--at-id
                      "test-promo-1" (lambda () (org-get-todo-state))))))))

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
           ,@body)
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
      (should (eq 'ambiguous
                  (claude-code-ide-org--expand-id-prefix "abcd1234" table))))))

(ert-deftest claude-code-ide-org-test-text-without-id-links-is-untouched ()
  "Prose with no id links passes through byte-identical.

Every amendment goes through this, so a transform that altered ordinary
text would corrupt bodies wholesale rather than fail visibly."
  (claude-code-ide-org-test--with-known-ids
    (let* ((text "*Shipped 2026-08-25.* No links here -- just = markup = and [brackets].")
           (r (claude-code-ide-org-resolve-id-links text)))
      (should (car r))
      (should (equal text (cdr r))))))

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

(provide 'claude-code-ide-org-config-test)

;;; config-test.el ends here
