;;; tools/claude-code-ide-org/config.el -*- lexical-binding: t; -*-
;;
;; MCP tool wrappers exposing org-mode clock, state, and archive
;; operations to Claude Code via claude-code-ide.
;;
;; All tools locate headings by their :ID: property, which means every
;; heading Claude is expected to act on must have one.  Add IDs with
;; M-x org-id-get-create, or configure org-id-link-to-org-use-id so
;; they are created automatically on link creation.

(require 'cl-lib)
(require 'seq)
(require 'org-element)
(require 'org-clock)
(require 'org-id)
(require 'org-capture)
(require 'json)

;;; Configuration -----------------------------------------------------------

(defgroup claude-code-ide-org nil
  "MCP tool wrappers exposing org-mode operations to Claude Code."
  :group 'org)

(defcustom claude-code-ide-org-session-recovery-enabled t
  "When non-nil, check for open CLOCK intervals left
over from a previous day (e.g. after a crash or system shutdown
prevented the Stop hook from pausing them) and report them via the
SessionStart hook so Claude can ask you for the actual stop time."
  :type 'boolean
  :group 'claude-code-ide-org)

;; `claude-code-ide-org-working-hours' and
;; `claude-code-ide-org--guess-stop-time' stood here until 2026-08-14
;; (TODO.org :ID: 7771fc63).  They offered an educated guess for when a
;; stale interval actually ended: the end of working hours on the day it
;; opened.  Retired because the premise was measured and did not hold --
;; of 19 human gaps over 2000s in 422 queue events, 11 begin *inside*
;; working hours, including the two longest (TODO.org :ID: 96a51c2f).
;; Daytime absence is indistinguishable from nighttime absence, so the
;; guess would have been wrong for most long gaps actually observed.
;;
;; Deliberately not replaced with a weaker fallback.  A plausible
;; suggestion is harder to reject than no suggestion (TODO.org :ID:
;; 5ff5a4b8, measured on this project's own review buffer), so a wrong
;; guess is worse than an honest question.

(defcustom claude-code-ide-org-query-files nil
  "Files to scan for cross-file operations (session recovery now;
org_query once built).  Defaults to `org-agenda-files' when nil."
  :type '(repeat file)
  :group 'claude-code-ide-org)

(defcustom claude-code-ide-org-capture-file nil
  "File that `org_capture' quick-adds new TODO headings to.  Defaults
to `org-default-notes-file' when nil, same convention as
`claude-code-ide-org-query-files' falling back to `org-agenda-files'."
  :type '(choice (const :tag "org-default-notes-file" nil) file)
  :group 'claude-code-ide-org)

;;; Helper ----------------------------------------------------------------

(defun claude-code-ide-org--at-id (id fn)
  "Find the org heading whose :ID: property equals ID.
Switch to its buffer, move point to the heading, and call FN with
no arguments.  Return FN's value, or an error string if the ID
cannot be resolved or FN signals an error."
  (require 'org-id)
  (let ((marker (org-id-find id 'marker)))
    (if (not marker)
        (format "Error: no org heading found with :ID: \"%s\"" id)
      (condition-case err
          (org-with-point-at marker
            (funcall fn))
        (error (format "Error: %s" (error-message-string err)))))))

;;; Tool-call audit log ------------------------------------------------------
;;
;; Every org_* wrapper below has, until now, been trust-the-return-string:
;; two bugs (org_archive, org_clock_out) reported success while quietly
;; failing to save the source buffer to disk, caught only by ad-hoc manual
;; disk inspection, more than once. This section hooks the org-native
;; layer itself — org-clock-in-hook, org-clock-out-hook,
;; org-after-todo-state-change-hook, and advice on org-archive-subtree —
;; rather than only the wrappers further down, so hand-edits made
;; directly in Emacs (never routed through any wrapper) AND
;; `claude-code-ide-org-clock-out' (which, per its own docstring, doesn't
;; route through `claude-code-ide-org--at-id') are both covered.
;;
;; Source attribution (which MCP tool, or "hand-edit") comes from
;; `claude-code-ide-org--log-source', a dynamic variable each wrapper
;; below let-binds around its body — see the convention noted on that
;; variable for how nested calls compose without one clobbering the
;; other's attribution. Since the 2026-08-11 cutover the only source
;; that actually appears here is "org_review_apply" or "hand-edit" --
;; the clock/state wrappers no longer mutate anything to attribute.
;;
;; Hashing is always done straight off disk (see
;; `claude-code-ide-org--sha256-file'), never off any Emacs buffer —
;; the whole point is catching exactly the buffer/disk divergence that
;; bit this project twice already. Because each hook/advice fires
;; *during* the org-native mutation, before the calling wrapper (or
;; interactive command) has had a chance to call `save-buffer'
;; afterward, the "after" hash cannot be taken synchronously in the same
;; hook invocation. Instead, `claude-code-ide-org--audit-queue' snapshots
;; the "before" hash immediately (correct, since nothing has been saved
;; yet at that point) and schedules `claude-code-ide-org--audit-flush'
;; via a zero-delay timer, which only runs once Emacs returns to its
;; command loop and goes idle — i.e. strictly after whatever
;; `save-buffer' call the wrapper/command was going to make, since that
;; call happens synchronously and immediately after the hook/advice
;; returns. `claude-code-ide-org--audit-flush' is also plain, directly
;; callable, so tests can finish pending records deterministically
;; without depending on Emacs's timer queue actually turning over.

(defvar claude-code-ide-org--log-source nil
  "Dynamically let-bound around each MCP wrapper's body to a string
such as \"org_clock_in\" identifying which tool is making an
org-native mutation, for audit-log attribution. Left nil for
mutations the audit hooks observe with no such binding in effect —
logged as \"hand-edit\" — which covers both a literal hand-edit made
directly in Emacs and anything else that calls org's clock/todo/
archive functions without going through this module's wrappers.

Each wrapper below binds this with `(or claude-code-ide-org--log-source
\"its-own-name\")' rather than unconditionally, so that a wrapper called
from another keeps the outer, more specific attribution instead of the
inner call clobbering it.  The nesting this was written for
(session-pause calling the clock-out wrapper) is gone as of the
2026-08-11 cutover, but `claude-code-ide-org-review' still binds it
around apply, which does nest.")

(defcustom claude-code-ide-org-audit-log-file nil
  "Path to the JSONL tool-call audit log. When nil (the default), the
log for a given mutated file lives at
\".claude-code-ide-org-audit.jsonl\" in that file's git project root
(found via `locate-dominating-file' for a .git directory), or
alongside the file itself when it isn't inside a git repository at
all (e.g. under a test's scratch temp directory)."
  :type '(choice (const nil) file)
  :group 'claude-code-ide-org)

(defvar claude-code-ide-org--audit-pending nil
  "Alist of pending audit records queued by
`claude-code-ide-org--audit-queue', awaiting the post-mutation disk
hash that `claude-code-ide-org--audit-flush' fills in. Each entry is
a plist (:source SOURCE :id ID-OR-NIL :file FILE :before HASH-OR-NIL).")

(defun claude-code-ide-org--sha256-file (file)
  "Return the sha256 hex digest of FILE's current on-disk contents, or
nil if FILE does not exist. Always reads straight from disk via
`insert-file-contents-literally' into a temp buffer — never hashes an
Emacs buffer's in-memory text — since the entire point of this audit
log is to catch buffer/disk divergence, not merely confirm the buffer
looks right."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents-literally file)
      (secure-hash 'sha256 (current-buffer)))))

(defun claude-code-ide-org--audit-log-path (file)
  "Return the path to the JSONL audit log covering FILE."
  (or claude-code-ide-org-audit-log-file
      (expand-file-name ".claude-code-ide-org-audit.jsonl"
                         (or (locate-dominating-file file ".git")
                             (file-name-directory file)))))

(defun claude-code-ide-org--log-event (source id file before-hash after-hash)
  "Append one JSONL audit record to the audit log covering FILE.
SOURCE attributes the mutation (an MCP tool name such as
\"org_clock_in\", or \"hand-edit\"). ID is the affected heading's
:ID:, or nil if it has none. BEFORE-HASH/AFTER-HASH are sha256
digests of FILE's on-disk contents immediately before and shortly
after the mutation (see `claude-code-ide-org--sha256-file'). The
result field is computed here, not passed in: \"saved\" when the
hashes differ (the mutation reached disk), or \"UNSAVED-MISMATCH\"
when they're equal despite a mutation having definitely occurred —
every call site below only queues a record on an actual clock
event, state change, or archive, never a no-op — which is exactly
the failure mode that motivated this feature. Writes via
`write-region' straight to the log file, appending, bypassing any
Emacs buffer for the log file itself, so the audit log can never
itself suffer the very buffer/disk divergence bug it exists to
catch."
  (let* ((result (if (equal before-hash after-hash) "UNSAVED-MISMATCH" "saved"))
         (line (concat (json-encode
                        `((timestamp . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
                          (tool . ,source)
                          (id . ,id)
                          (file . ,file)
                          (before_sha256 . ,before-hash)
                          (after_sha256 . ,after-hash)
                          (result . ,result)))
                       "\n")))
    (write-region line nil (claude-code-ide-org--audit-log-path file) t 'silent)))

(defun claude-code-ide-org--audit-queue (id file)
  "Snapshot FILE's current on-disk sha256 as the \"before\" hash and
queue a pending audit record attributed to ID and the dynamically-
bound `claude-code-ide-org--log-source' (or \"hand-edit\"), to be
finished by `claude-code-ide-org--audit-flush'. A no-op when FILE is
nil (e.g. a non-file-backed buffer)."
  (when file
    (push (list :source (or claude-code-ide-org--log-source "hand-edit")
                :id id :file file
                :before (claude-code-ide-org--sha256-file file))
          claude-code-ide-org--audit-pending)
    (run-at-time 0 nil #'claude-code-ide-org--audit-flush)))

(defun claude-code-ide-org--audit-flush ()
  "Finish every pending audit record queued by
`claude-code-ide-org--audit-queue': hash each record's file again and
log the before/after comparison, then clear the queue. See the
commentary at the top of this section for why this runs on a
zero-delay timer in normal use, and why it is also safe and useful to
call directly (e.g. from tests)."
  (let ((pending (nreverse claude-code-ide-org--audit-pending)))
    (setq claude-code-ide-org--audit-pending nil)
    (dolist (rec pending)
      (claude-code-ide-org--log-event
       (plist-get rec :source) (plist-get rec :id) (plist-get rec :file)
       (plist-get rec :before)
       (claude-code-ide-org--sha256-file (plist-get rec :file))))))

(defun claude-code-ide-org--audit-clock-hook ()
  "Queue an audit record for the heading org's clock machinery just
clocked in or out of. Shared by `org-clock-in-hook' and
`org-clock-out-hook': both fire with point still located at/within
the affected entry in the clocking buffer (confirmed against
org-clock.el — `org-clock-out' clears `org-clock-marker' to nil
*before* running its hook, so that marker cannot be relied on here;
`org-entry-get' at point works for both hooks regardless)."
  (claude-code-ide-org--audit-queue
   (org-entry-get nil "ID") (buffer-file-name (buffer-base-buffer))))

(defun claude-code-ide-org--audit-todo-hook ()
  "Queue an audit record for the heading whose TODO state just
changed. Added to `org-after-todo-state-change-hook', which runs
with point still at the affected heading."
  (claude-code-ide-org--audit-queue
   (org-entry-get nil "ID") (buffer-file-name (buffer-base-buffer))))

(defun claude-code-ide-org--audit-around-archive (orig-fn &rest args)
  "Advice around `org-archive-subtree' queuing an audit record for the
SOURCE file the heading is cut from — not the archive target — since
that's the file the original org_archive bug failed to save. Captures
the heading's :ID: and file *before* calling ORIG-FN: archiving
removes the heading from the source buffer entirely (via
`org-cut-subtree'), making both unrecoverable at point afterward."
  (let ((id (org-entry-get nil "ID"))
        (file (buffer-file-name (buffer-base-buffer))))
    (prog1 (apply orig-fn args)
      (claude-code-ide-org--audit-queue id file))))

(add-hook 'org-clock-in-hook #'claude-code-ide-org--audit-clock-hook)
(add-hook 'org-clock-out-hook #'claude-code-ide-org--audit-clock-hook)
(add-hook 'org-after-todo-state-change-hook #'claude-code-ide-org--audit-todo-hook)
(advice-add 'org-archive-subtree :around #'claude-code-ide-org--audit-around-archive)

;;; Session tracking --------------------------------------------------------
;;
;; Two separate timekeeping mechanisms, deliberately kept apart:
;;
;; - The :LOGBOOK: CLOCK entries (org's own, native mechanism) track
;;   active work time only.  A running clock is paused (org_clock_out)
;;   whenever Claude Code stops and is waiting on the user, and resumed
;;   (org-clock-in-last) the moment the user sends the next prompt — see
;;   the Stop/UserPromptSubmit hooks this drives.  A DOING task may
;;   therefore accumulate many short CLOCK intervals instead of one long
;;   one spanning idle waiting time.
;;
;; - The :SESSIONS: drawer was RETIRED 2026-08-11 (TODO.org :ID:
;;   9d2fcdad).  It held the bracketing history: a timestamped log of
;;   every pause and resume, so the full wall-clock arc — including the
;;   gaps the CLOCK entries do not cover — stayed visible.  Every drawer
;;   was deleted and nothing writes one.  The per-session event queue
;;   holds the same stream undecimated, survives without a running Emacs,
;;   and carries session/agent attribution the drawer never had.

(defun claude-code-ide-org--find-drawer (drawer-name)
  "Return the `org-element' for the DRAWER-NAME drawer belonging to the
heading at point, or nil when it has none.  Never moves point.

Searches only within the heading's own body, and *keeps searching* past
any line shaped like a drawer marker that is not really one -- inside
`#+begin_example', say -- because `org-element-at-point' is what decides,
not the regexp.  Stopping at the first marker-shaped line was a real bug
\(TODO.org :ID: f42641ab): the reader gave up and reported \"no drawer
here\" for a heading that had one, while the two writers looped past the
decoy correctly.  Three copies of this search existed, two of them
right; this is the one copy they now share.

Returns the element rather than positions because its three callers want
different things from it -- an insertion point, a content region, and a
line scan -- and only the caller knows which.  Note an *empty* drawer has
nil `org-element-contents-begin'/`-end', so callers deriving a region
must supply their own fallback; see
`claude-code-ide-org--drawer-content-bounds'."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point)))
          (marker-re (concat "^[ \t]*:" (regexp-quote drawer-name) ":[ \t]*$"))
          found)
      (while (and (not found) (re-search-forward marker-re end t))
        (let ((element (org-element-at-point)))
          (when (org-element-type-p element 'drawer)
            (setq found element))))
      found)))

(defun claude-code-ide-org--drawer-body-start (element)
  "Return the position of the first line inside drawer ELEMENT --
the line after its marker.  For an empty drawer this is the `:END:'
line itself, which is also where a first entry would be inserted."
  (save-excursion
    (goto-char (org-element-begin element))
    (forward-line 1)
    (point)))

(defun claude-code-ide-org--drawer-contains-line-p (drawer-name line)
  "Non-nil when LINE already appears in the heading's DRAWER-NAME drawer.

Compared on trimmed text, so indentation differences do not produce a
false negative and a duplicate.  Half of the content-based idempotency
`claude-code-ide-org--queue-file-drained-p' and reprocessing rely on
(TODO.org :ID: 78f485a8): an annotation line is a pure function of its
span and label, so an identical one is a replay rather than a second
thing that happened."
  (let ((element (claude-code-ide-org--find-drawer drawer-name))
        (target (string-trim line))
        found)
    (when element
      (let ((cend (or (org-element-contents-end element)
                      (claude-code-ide-org--drawer-body-start element))))
        (save-excursion
          (goto-char (claude-code-ide-org--drawer-body-start element))
          (while (and (not found) (< (point) cend))
            (when (equal target (string-trim
                                 (buffer-substring-no-properties
                                  (line-beginning-position)
                                  (line-end-position))))
              (setq found t))
            (forward-line 1)))))
    found))

(defun claude-code-ide-org--append-to-drawer (drawer-name line)
  "Append LINE to the :DRAWER-NAME: drawer of the heading at point.
Creates the drawer immediately after the heading's planning line
and property drawer if it does not already exist.  Adapted from
org-clock.el's own `org-clock-find-position', which solves the same
find-or-create-drawer problem for :LOGBOOK:.

Does nothing when LINE is already present, which is what makes replaying
an archived queue file safe.  Checking the destination beats tracking
applied identities in a sidecar precisely because it survives losing the
sidecar -- which is the situation reprocessing puts you in."
  (if (claude-code-ide-org--drawer-contains-line-p drawer-name line)
      nil
    (claude-code-ide-org--append-to-drawer-1 drawer-name line)))

(defun claude-code-ide-org--append-to-drawer-1 (drawer-name line)
  "Unconditionally append LINE to DRAWER-NAME at point."
  (org-back-to-heading t)
  (let ((element (claude-code-ide-org--find-drawer drawer-name)))
    (if element
        (progn
          ;; For a populated drawer this is the start of the `:END:'
          ;; line; for an empty one `contents-end' is nil and the body
          ;; start is that same line.  Both mean "just before :END:".
          (goto-char (or (org-element-contents-end element)
                         (claude-code-ide-org--drawer-body-start element)))
          (unless (bolp) (insert "\n"))
          (insert line "\n"))
      (org-end-of-meta-data)
      (unless (bolp) (insert "\n"))
      (insert ":" drawer-name ":\n" line "\n:END:\n"))))

;; Three session-identity variables stood here until the 2026-08-11
;; cutover (TODO.org :ID: feba67eb-35b3-48bd-a892-8ecd47ca52e0):
;; `--log-session-id', `--clock-owner-session-id' and
;; `--planning-owner-session-id'.
;;
;; All three existed to answer "which concurrent session does this live
;; state belong to?" -- who may pause the one global clock
;; (:ID: 337f7fb2-b9e9-4c02-82dd-d88e60df364b), whose PLANNING heading
;; an ExitPlanMode may promote (:ID: b95b9fba-f78e-48fe-8546-988709cce309).
;; Sessions no longer touch live state, so the question has no referent:
;; there is one writer now, apply, and it runs when a human says so.
;;
;; Their replacement is not another variable but the queue's own shape.
;; Each session appends to its own file, keyed by the session_id that
;; arrives on hook stdin -- so "which session did this" is recorded on
;; every event rather than inferred from a single global value that only
;; ever held the most recent answer, and it survives an Emacs restart,
;; which none of these did.

;; The :SESSIONS: drawer was retired 2026-08-11 (TODO.org :ID:
;; 9d2fcdad-9bf7-47b6-8018-223b13ec4577). It held a Paused/Resumed line
;; per turn boundary, collapsed to one min-to-max span per day, as "the
;; bracketing history" beside :LOGBOOK:'s CLOCK entries. Every existing
;; drawer was deleted and nothing writes one now.
;;
;; What replaced it is the per-session event queue: the same pause/resume
;; timestamps, undecimated, durable without Emacs, and carrying
;; session_id/agent_id/agent_type/source, none of which the drawer ever
;; recorded. Reviewed spans reach :LOGBOOK: as annotation lines; the raw
;; stream stays in the queue file, archived rather than deleted.

;;; Wrappers --------------------------------------------------------------

(defun claude-code-ide-org-clock-in (id &optional note)
  "Validate ID and report the clock_in as queued.  Opens no clock.

Cut over to append-only 2026-08-11 (TODO.org :ID:
feba67eb-35b3-48bd-a892-8ecd47ca52e0).  This used to call `org-clock-in'
and save the buffer.  It now touches nothing: `bin/hooks/queue-append'
records the event from the `PostToolUse' payload, and
`claude-code-ide-org-review' is the only thing that ever writes a CLOCK
line, inside a genuinely interactive command with a human confirming the
interval.  A session's own view of the clock is therefore *intent*, not
state -- see the queue commentary further down this file.

Still resolves ID, and still reports an unresolvable one as an
\"Error: ...\" string.  That is the whole remaining job, and it is not a
formality: `bin/hooks/queue-append' drops any event whose tool reply
starts with `Error:', so this validation is the only thing standing
between a typo'd :ID: and a queue entry that cannot be applied and
cannot be explained at review time.

NOTE rides the tool call into the queue, where the hook reads it off
`tool_input'; it was already unused here before the cutover, for
exactly the reason the cutover generalises (TODO.org :ID:
32272061-1d78-4726-b13b-90338edb2ba5).  See clock-template.org for the
conventions it feeds."
  (claude-code-ide-org--tolerating-pending-capture id
    (lambda (title)
      (format "Queued clock_in on \"%s\"; pending review." title))
    (lambda ()
      (claude-code-ide-org--at-id
       id
       (lambda ()
         (format "Queued clock_in on \"%s\"; pending review."
                 (org-get-heading t t t t)))))))

(defun claude-code-ide-org-clock-out (&optional note)
  "Report the clock_out as queued.  Closes no clock.

Cut over to append-only 2026-08-11 alongside
`claude-code-ide-org-clock-in' (TODO.org :ID:
feba67eb-35b3-48bd-a892-8ecd47ca52e0).

Takes no id and reports none, which is a deliberate simplification of
what it did before.  It used to recover the running clock's heading and
report it as \"(id: ID)\" for `bin/hooks/queue-append' to parse, because
the running clock was the only thing that knew which heading was being
closed.  There is no running clock now, and the ingestion layer already
answers the question better:
`claude-code-ide-org--queue-events-by-id' walks each session's own
stream in order and attributes a null-id `clock_out' to whichever
heading that session's last `clock_in' named.  Reading a live clock here
would be actively worse -- the only clock that can be running now
belongs to a *human's* own `org-clock-in', so it would attribute this
session's interval to whatever the user happens to be clocking.

Consequently this cannot fail and does not validate: there is no :ID: to
resolve.  NOTE rides into the queue off `tool_input' as before.

The one-minute floor (`--minimum-clock-seconds'/`--clock-out-floor-time')
went with this function's body.  It was a write-path policy protecting
sub-minute intervals from reading as `=>  0:00', and apply is the write
path now -- it writes the exact confirmed endpoints, and handles a
zero-width span by annotating it without a CLOCK line rather than by
inventing seconds that did not elapse."
  "Queued clock_out; pending review.")

;; `claude-code-ide-org-session-pause'/`-resume' and their helper
;; `--clock-history-head-done-p' were retired at the 2026-08-11 cutover
;; (TODO.org :ID: feba67eb-35b3-48bd-a892-8ecd47ca52e0). The Stop and
;; UserPromptSubmit hooks that called them through `emacsclient -e' now
;; append a bare `pause'/`resume' guidepost to the queue and never reach
;; Emacs at all -- which is the point: a turn boundary is recorded even
;; when no Emacs is running, and review decides what the guideposts
;; bracket.
;;
;; They were the last readers of `--clock-owner-session-id', so the
;; ownership variables go with them; see the commentary where those
;; used to be defined.

;;; Stale interval recovery --------------------------------------------------
;;
;; org-clock-persist is set to `history' (not `t'/`clock') in this
;; project's Doom config, so a crash or restart does NOT auto-resume
;; the in-memory clock state — meaning an open interval left by a
;; crash can only be found by scanning the actual TEXT of tracked org
;; files for an unclosed CLOCK line, never by checking org-clocking-p.
;; (It also used to look for an unclosed "Resumed" :SESSIONS: entry;
;; that drawer was retired 2026-08-11, TODO.org :ID: 9d2fcdad.)
;; Checked at the start of
;; every session; naturally self-limiting to "first thing each day"
;; since it only reports intervals whose open timestamp predates today.

(defun claude-code-ide-org--tracked-files ()
  "Files to scan for stale open intervals, org_query, and
org_clock_report.  Calls the `org-agenda-files' function, not the
variable of the same name, so directory entries (e.g. a bare
\"~/org\") are actually expanded to their contained files rather than
passed through as an unusable directory string."
  (or claude-code-ide-org-query-files (org-agenda-files)))

(defun claude-code-ide-org--parse-org-timestamp (ts-string)
  "Parse an org timestamp string like \"[2026-07-27 Mon 17:45]\"
into an Emacs time value."
  (org-time-string-to-time ts-string))

(defun claude-code-ide-org--today-p (time)
  "Non-nil if TIME falls on today's calendar date."
  (let ((now (decode-time)) (then (decode-time time)))
    (and (= (nth 3 now) (nth 3 then))
         (= (nth 4 now) (nth 4 then))
         (= (nth 5 now) (nth 5 then)))))

(defun claude-code-ide-org--entry-open-interval ()
  "If the entry at point has an open CLOCK line, return a plist
\(:logbook-open TIME).  Nil means nothing is open here.  Does not rely
on org-clocking-p — see commentary above.

Used to also report an unclosed :SESSIONS: \"Resumed\" entry as
`:sessions-open\'; that drawer was retired 2026-08-11 (TODO.org :ID:
9d2fcdad) and every one deleted, so the scan can never match again.  The
plist shape is kept rather than flattened to a bare time: callers destructure
it, and a second kind of open interval is plausible enough — a queued
`clock_in\' with no `clock_out\' — that the shape is likely to earn its
keep again."
  (let ((end (save-excursion (outline-next-heading) (point)))
        logbook-open)
    (save-excursion
      (when (re-search-forward "^[ \t]*CLOCK: \\(\\[[^]]+\\]\\)[ \t]*$" end t)
        (setq logbook-open (claude-code-ide-org--parse-org-timestamp (match-string 1)))))
    (when logbook-open
      (list :logbook-open logbook-open))))

(defun claude-code-ide-org-find-stale-open-intervals ()
  "Scan `claude-code-ide-org--tracked-files' for open CLOCK intervals
whose open timestamp predates today.  Returns nil if
`claude-code-ide-org-session-recovery-enabled' is nil.  Otherwise a
list of plists: (:id ID :heading HEADING :file FILE :logbook-open TIME).

Carried a :guess until 2026-08-14; see the commentary where
`claude-code-ide-org--guess-stop-time' used to live for why guessing
was retired rather than weakened."
  (when claude-code-ide-org-session-recovery-enabled
    (let (results)
      (dolist (file (claude-code-ide-org--tracked-files))
        (when (file-exists-p file)
          (with-current-buffer (find-file-noselect file)
            (org-map-entries
             (lambda ()
               (let ((interval (claude-code-ide-org--entry-open-interval))
                     (id (org-entry-get nil "ID")))
                 (when (and interval id)
                   (let ((lb (plist-get interval :logbook-open)))
                     (unless (claude-code-ide-org--today-p lb)
                       (push (list :id id
                                   :heading (org-get-heading t t t t)
                                   :file file
                                   :logbook-open lb)
                             results))))))
             "ID={.}" 'file))))
      (nreverse results))))

(defun claude-code-ide-org--format-stale-interval-report (findings)
  "Format FINDINGS (as returned by
`claude-code-ide-org-find-stale-open-intervals') into a plain-text
report for Claude to relay to the user as a question.

Asks without proposing an answer.  It used to offer a working-hours
guess; that was retired 2026-08-14 (TODO.org :ID: 7771fc63) because the
guess was measurably wrong for most long gaps observed, and because a
plausible suggestion is harder to reject than none.  The open timestamp
is stated because it is a fact; the stop time is asked for because it is
not."
  (mapconcat
   (lambda (f)
     (format (concat "\"%s\" (:ID: %s, in %s) has an unclosed CLOCK entry "
                      "open since %s that was never closed — most likely a "
                      "crash or system shutdown before the clock could be "
                      "stopped. Ask the user what time they actually stopped "
                      "work; do not propose a time, and do not infer one from "
                      "the timestamps below. Once they give you one, call "
                      "claude-code-ide-org-close-open-interval via emacsclient "
                      "with that timestamp.")
             (plist-get f :heading) (plist-get f :id)
             (file-name-nondirectory (plist-get f :file))
             (format-time-string "[%Y-%m-%d %a %H:%M]"
                                 (plist-get f :logbook-open))))
   findings "\n\n"))

(defun claude-code-ide-org--session-start-hook-json ()
  "Return the SessionStart hook JSON payload: an empty object if
there is nothing to report, otherwise one with additionalContext
describing every stale open interval and its educated guess."
  (let ((findings (claude-code-ide-org-find-stale-open-intervals)))
    (if (not findings)
        "{}"
      (json-encode
       `((hookSpecificOutput
          . ((hookEventName . "SessionStart")
             (additionalContext
              . ,(claude-code-ide-org--format-stale-interval-report findings)))))))))

(defun claude-code-ide-org-write-session-start-report (output-path)
  "Write the SessionStart hook JSON payload to OUTPUT-PATH.
Called directly via `emacsclient -e' by the SessionStart hook
script, which then just cats the file — avoids any need to
unescape emacsclient's printed-representation output in shell."
  (with-temp-file output-path
    (insert (claude-code-ide-org--session-start-hook-json))))

;;; Session context (SessionStart "what was I last doing") -------------------
;;
;; Surfaces "what was I last doing" automatically at session start: the
;; currently clocked-in heading (if any) plus every WAIT-state heading
;; across `claude-code-ide-org--tracked-files' (the same file list
;; stale-interval-recovery and org_query already use), collapsed into a
;; single plain-text string. Turns "what was I working on" from a
;; question into something Claude already knows walking in — a standing,
;; automatic instance of what `claude-code-ide-org-query' answers on
;; demand via "todo:WAIT".

(defun claude-code-ide-org--clocked-heading-context ()
  "Return a one-line description of the currently clocked-in org
heading, or nil if no clock is running."
  (when (org-clocking-p)
    (org-with-point-at org-clock-marker
      (let ((heading (org-get-heading t t t t))
            (id (org-entry-get nil "ID"))
            (file (buffer-file-name (buffer-base-buffer))))
        (format "Currently clocked in: \"%s\"%s%s"
                heading
                (if id (format " (:ID: %s)" id) "")
                (if file (format " in %s" (file-name-nondirectory file)) ""))))))

(defun claude-code-ide-org--attention-headings-context ()
  "Return a list of one-line descriptions, one per heading across
`claude-code-ide-org--tracked-files' that a *starting* session should be
told about, or nil if none. Two kinds, which are the same keyword's
opposite news (TODO.org :ID: ab75d6d2, :ID: 9d7531f5):

- WAIT -- blocked, or waiting on someone.
- DOING on a leaf that is not the currently clocked heading -- an
  increment somebody walked away from.

A DOING *container* (`claude-code-ide-org--container-heading-p') is
deliberately excluded. A container in DOING is a true and unremarkable
statement about the project, so reporting it would add one permanent,
never-changing line -- and a report that always says the same thing
stops being read, which defeats the only purpose this one has. The
currently clocked heading is excluded for a duller reason:
`claude-code-ide-org--clocked-heading-context' already reports it on its
own line, ahead of these.

Scans each tracked file via `find-file-noselect'; any buffer
that was not already open before the scan is killed again afterward,
so this never leaves stray buffers in the user's real buffer list —
only buffers the user already had open (e.g. one they're editing)
are left alone. The modified flag on a freshly-opened buffer is
cleared before killing it: this scan never edits the buffer, but
`kill-buffer' on a buffer Emacs still considers modified — e.g. one
some other hook touched, or a decoding/`find-file-hook' side effect
in the user's real config — would otherwise prompt with
`yes-or-no-p', which blocks indefinitely under `emacsclient -e' and
would silently eat this hook's whole timeout."
  (let ((clocked-id (and (org-clocking-p)
                         (org-with-point-at org-clock-marker
                           (org-entry-get nil "ID"))))
        results)
    (dolist (file (claude-code-ide-org--tracked-files))
      (when (file-exists-p file)
        (let* ((already-open (find-buffer-visiting file))
               (buffer (or already-open (find-file-noselect file))))
          (with-current-buffer buffer
            (org-map-entries
             (lambda ()
               (let* ((state (org-get-todo-state))
                      (heading-id (org-entry-get nil "ID"))
                      (label
                       (cond
                        ((equal state "WAIT") "WAIT")
                        ((and (equal state "DOING")
                              (not (and clocked-id heading-id
                                        (equal clocked-id heading-id)))
                              (not (claude-code-ide-org--container-heading-p)))
                         "DOING, not clocked"))))
                 (when label
                   (push (format "%s: \"%s\" (:ID: %s, in %s)"
                                 label
                                 (org-get-heading t t t t)
                                 (or heading-id "none")
                                 (file-name-nondirectory file))
                         results))))
             nil 'file))
          (unless already-open
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))
    (nreverse results)))

(defun claude-code-ide-org-session-context ()
  "Return a plain-text summary of \"what was I last doing\": the
currently clocked-in heading, if any, followed by one line per heading
worth flagging at session start across
`claude-code-ide-org--tracked-files' -- WAIT headings and abandoned
DOING leaves, per `claude-code-ide-org--attention-headings-context'.
Returns the empty string when there is nothing to report, so callers
can treat an empty result as \"nothing worth injecting\"."
  (let* ((clocked (claude-code-ide-org--clocked-heading-context))
         (waits (claude-code-ide-org--attention-headings-context))
         (lines (append (when clocked (list clocked)) waits)))
    (mapconcat #'identity lines "\n")))

(defun claude-code-ide-org--session-context-hook-json ()
  "Return the SessionStart hook JSON payload for
`claude-code-ide-org-session-context': an empty object if there is
nothing to report, otherwise one with additionalContext set to the
session-context summary."
  (let ((context (claude-code-ide-org-session-context)))
    (if (equal context "")
        "{}"
      (json-encode
       `((hookSpecificOutput
          . ((hookEventName . "SessionStart")
             (additionalContext . ,context))))))))

(defun claude-code-ide-org-write-session-context-report (output-path)
  "Write the SessionStart hook JSON payload for \"what was I last
doing\" context to OUTPUT-PATH. Called directly via `emacsclient -e'
by the session-context.sh hook script, which then just cats the
file — avoids any need to unescape emacsclient's printed-
representation output in shell. Deliberately not wrapped in its own
condition-case: if scanning ever throws, OUTPUT-PATH is left empty
(the temp file is created but never written to, or is never created
at all), and the shell script's `[[ -s ... ]]' check treats that
identically to \"Emacs unreachable\" — fail soft either way, same
convention as `claude-code-ide-org-write-session-start-report'."
  (with-temp-file output-path
    (insert (claude-code-ide-org--session-context-hook-json))))

;;; Statusline (bin/statusline) ------------------------------------------
;;
;; Shows the "current default org task" alongside the model name in
;; Claude Code's statusLine: the currently-running clock if one is
;; active, else the most recently clocked task from `org-clock-history'
;; (survives both a clock-out and an Emacs restart, since this user's
;; Doom config sets `org-clock-persist' to 'history — see CLAUDE.md's
;; design notes). All formatting logic lives here, not in
;; bin/statusline, for the same reason every other piece of this
;; project's Elisp does: it's the only place `bin/test' can exercise
;; it.

(defun claude-code-ide-org--queue-latest-session-id ()
  "Session id whose queue file was modified most recently, or nil.

The statusline asks \"what is Claude doing *now*\", and with concurrent
sessions that is the most recently written queue -- so this reads one
file rather than every session's.  mtime is the available signal, the
same one `claude-code-ide-org--queue-file-idle-p' uses to decide a queue
has gone quiet."
  (when (file-directory-p claude-code-ide-org-queue-directory)
    (car (mapcar #'car
                 (sort (mapcar (lambda (f)
                                 (cons (file-name-base f)
                                       (file-attribute-modification-time
                                        (file-attributes f))))
                               (directory-files
                                claude-code-ide-org-queue-directory
                                t "\\.jsonl\\'" t))
                       (lambda (a b) (time-less-p (cdr b) (cdr a))))))))

(defun claude-code-ide-org--statusline-queue-state ()
  "Return (ID . RUNNING-P) from the most recently written queue, or nil.

ID is the heading named by the newest event that names one -- a `todo'
or `clock_in' -- which is the queue's answer to \"what is being worked
on\".  RUNNING-P is non-nil when the newest guidepost is a `resume',
meaning the agent is mid-turn rather than waiting on a human.

Reads with INCLUDE-CONSUMED, deliberately: this is a question about
history, not about what is pending, and an *applied* event is the
strongest evidence of what was being worked on.  Filtering to pending
would make the statusline go blank right after a review pass.

Nil when the queue has nothing to say, which lets the caller fall back
rather than render an empty line."
  (let* ((sid (claude-code-ide-org--queue-latest-session-id))
         (events (and sid (claude-code-ide-org--queue-events sid t)))
         id running)
    (dolist (e events)
      (when (plist-get e :id) (setq id (plist-get e :id)))
      (cond ((equal (plist-get e :kind) "resume") (setq running t))
            ((equal (plist-get e :kind) "pause") (setq running nil))))
    (and id (cons id running))))

(defun claude-code-ide-org--statusline-task-string ()
  "Return a short, pre-formatted description of the task Claude is
attending to, for the statusLine, or the empty string if nothing is
known.  The :ID: is truncated to 8 characters and the heading name to
30 (with an ellipsis), matching a git-commit-style short hash.  Total
clocked time is summed over the heading's whole subtree via
`org-clock-sum', matching `org_clock_report''s own :ID:-scoped
behavior.

Reads the *queue* rather than `org-clocking-p'/`org-clock-marker'
\(TODO.org :ID: 290b6fc5).  Post-cutover the only thing that ever
opened a live clock was `claude-code-ide-org--trigger-auto-clock-in',
and silencing that -- :ID: 226ed53b -- would leave a marker-based
statusline reporting the last *applied* heading, lagging by however
long since the last review pass.  The queue is also the more honest
source: it says what Claude is doing rather than what has been
recorded, and it cannot desync the way a marker can, being an
append-only file read fresh each time.

Falls back to the clock when the queue has nothing to say, so a
session with no queue -- and every existing test -- keeps working."
  (let* ((qs (ignore-errors (claude-code-ide-org--statusline-queue-state)))
         ;; Resolve once. A queue id that does not resolve -- an archived
         ;; heading, a stale entry -- must fall through to the clock rather
         ;; than blank the line: the queue having an opinion is not the same
         ;; as that opinion being usable.
         (qmarker (and qs (ignore-errors (org-id-find (car qs) 'marker))))
         (marker (or qmarker
                     (if (org-clocking-p) org-clock-marker
                       (car org-clock-history))))
         (running (if qmarker (cdr qs) (org-clocking-p))))
    (if (not (and marker (markerp marker) (marker-buffer marker)))
        ""
      (org-with-point-at marker
        (let* ((id (or (org-entry-get nil "ID") ""))
               (short-id (if (> (length id) 8) (substring id 0 8) id))
               (name (org-get-heading t t t t))
               (short-name (if (> (length name) 30)
                               (concat (substring name 0 29) "…")
                             name))
               (status-label (if running "clocked in" "clocked out"))
               (total-minutes (progn
                                (save-restriction
                                  (org-narrow-to-subtree)
                                  (org-clock-sum))
                                (or org-clock-file-total-minutes 0)))
               (total (org-duration-from-minutes total-minutes)))
          (format " | %s [%s] (%s, %s total)"
                  short-name short-id status-label total))))))

(defun claude-code-ide-org--statusline-model-name (input-path)
  "Read the Claude Code statusLine hook JSON payload from INPUT-PATH
and return its model.display_name field, or the empty string if the
field is absent or INPUT-PATH is missing/unparseable. Case study for
\"maximum Emacs, minimal shell\" (TODO.org's shell-standardization
item): this used to be a `jq -r' call in bin/statusline itself; moving
it here means the shell wrapper no longer needs jq, or any JSON
handling, at all. Fails soft (empty string, not an error) on any
problem reading or parsing INPUT-PATH — a status line must never error
or hang the prompt, same reasoning as every other function in this
section."
  (condition-case nil
      (let* ((json-object-type 'alist)
             (payload (json-read-file input-path))
             (model (alist-get 'model payload)))
        (or (alist-get 'display_name model) ""))
    (error "")))

(defun claude-code-ide-org-write-statusline-report (input-path output-path)
  "Read the statusLine hook JSON payload from INPUT-PATH and write the
model display name (`claude-code-ide-org--statusline-model-name')
followed by the current default org task
(`claude-code-ide-org--statusline-task-string') to OUTPUT-PATH. Called
directly via `emacsclient -e' by bin/statusline.sh, which then just
cats the file — same double-escaping-avoidance convention as
`claude-code-ide-org-write-session-start-report'/
`-write-session-context-report'. bin/statusline.sh itself never
touches INPUT-PATH's contents; all parsing happens here."
  (with-temp-file output-path
    (insert (claude-code-ide-org--statusline-model-name input-path))
    (insert (claude-code-ide-org--statusline-task-string))))

(defun claude-code-ide-org-close-open-interval (id timestamp-string)
  "Close the open CLOCK interval, if any, on the heading whose :ID:
equals ID, using TIMESTAMP-STRING (an org timestamp string, e.g.
\"[2026-07-27 Mon 17:45]\") as the recovered stop time.  Computes the
duration and saves the buffer.  Does not touch the live clock — this is
purely a text-level fix for a stale interval, unrelated to whatever (if
anything) is currently clocking.

Two things it used to do and no longer does: append a
\"Paused ... (recovered)\" entry to the :SESSIONS: drawer, retired
2026-08-11 (TODO.org :ID: 9d2fcdad); and call
`claude-code-ide-org-consolidate-history' afterwards, dropped because
rewriting a whole drawer as a side effect of repairing one line is the
shape behind :ID: ba8249c1 and :ID: b74e0f19, and consolidation has
nothing left to contribute here anyway."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (let ((end (save-excursion (outline-next-heading) (point)))
           (stop-time (claude-code-ide-org--parse-org-timestamp timestamp-string))
           closed-logbook)
       (save-excursion
         (when (re-search-forward "^\\([ \t]*CLOCK: \\)\\(\\[[^]]+\\]\\)[ \t]*$" end t)
           ;; Capture match boundaries and strings immediately, then use
           ;; delete-region/insert rather than replace-match — computing
           ;; start-time below calls org-time-string-to-time, which does
           ;; its own regexp matching internally and would otherwise
           ;; silently clobber the match data replace-match relies on.
           (let* ((match-beg (match-beginning 0))
                  (match-end (match-end 0))
                  (prefix (match-string 1))
                  (start-str (match-string 2))
                  (start-time (claude-code-ide-org--parse-org-timestamp start-str))
                  (minutes (round (/ (float-time (time-subtract stop-time start-time)) 60))))
             (goto-char match-beg)
             (delete-region match-beg match-end)
             (insert (format "%s%s--%s =>  %d:%02d"
                              prefix start-str timestamp-string (/ minutes 60) (% minutes 60)))
             (setq closed-logbook t))))
       (save-buffer)
       ;; No consolidate-history call: it has nothing left to do that is
       ;; worth doing as a side effect of a repair, and running a
       ;; whole-drawer rewrite after touching one line is the shape that
       ;; caused :ID: ba8249c1 and :ID: b74e0f19.
       (if closed-logbook
           (format "Closed open CLOCK on \"%s\" at %s"
                   (org-get-heading t t t t) timestamp-string)
         "Nothing open to close.")))))

;;; Historical consolidation --------------------------------------------------
;;
;; What is left of a retrospective cleanup that once collapsed the
;; per-turn write churn: each pause/resume used to write a matching
;; :SESSIONS: pair and :LOGBOOK: CLOCK line, so a work session
;; accumulated dozens of few-minute entries, and this section rounded and
;; merged them.
;;
;; Both halves are gone.  The rounding was retired after it destroyed a
;; reviewed interval (:ID: b74e0f19) and :SESSIONS: was retired outright
;; (:ID: 9d2fcdad), leaving only the ordering of :LOGBOOK: entries and the
;; invariant that an open interval is never touched, since that reflects
;; live clock state rather than history.  The two rounding helpers below
;; have no callers; they are kept, and say so, against the possibility of
;; a deliberate human-invoked compaction pass.

(defun claude-code-ide-org--round-time-to-5-minutes (time)
  "Round TIME to the nearest 5-minute mark, ties rounding up.
Seconds are discarded — org timestamps are minute-resolution, so any
TIME reached via `claude-code-ide-org--parse-org-timestamp' already
has none.

UNWIRED as of 2026-08-10, and deliberately kept rather than deleted.
Nothing calls this: `claude-code-ide-org--consolidate-logbook-text' used
to, and no longer alters intervals at all after rounding destroyed a
reviewed one (TODO.org :ID: b74e0f19-5a26-4c83-9d70-8e1c5a2f6b04).
Retained because per-turn clocking churn is now expected to reappear in
:LOGBOOK: until the queue refactor lands, and the open question is
whether that is actually painful in practice.  If it is, this and
`claude-code-ide-org--merge-time-intervals' are the raw material for a
compaction pass a human invokes *deliberately* on history they have
already reviewed.  What must not come back is a rewrite that fires
automatically on every clock-out."
  (let* ((decoded (decode-time time))
         (minute (nth 1 decoded))
         (remainder (mod minute 5))
         (rounded-minute (if (>= remainder 3)
                              (+ minute (- 5 remainder))
                            (- minute remainder))))
    (encode-time (append (list 0 rounded-minute) (nthcdr 2 decoded)))))

(defun claude-code-ide-org--merge-time-intervals (intervals)
  "Sort INTERVALS — a list of (START . END) time-value conses — by
START, then merge any that are adjacent or overlapping (END of one
>= START of the next) into a single min-to-max span. Return the
merged list, ascending by START.

UNWIRED as of 2026-08-10, for the same reason and on the same terms as
`claude-code-ide-org--round-time-to-5-minutes' — see its docstring."
  (let ((sorted (sort (copy-sequence intervals)
                       (lambda (a b) (time-less-p (car a) (car b)))))
        result)
    (dolist (interval sorted)
      (if (and result (not (time-less-p (cdr (car result)) (car interval))))
          (when (time-less-p (cdr (car result)) (cdr interval))
            (setcdr (car result) (cdr interval)))
        (push (cons (car interval) (cdr interval)) result)))
    (nreverse result)))

(defun claude-code-ide-org--drawer-content-bounds (drawer-name)
  "Return (CONTENT-BEG CONTENT-END) delimiting the body of the
:DRAWER-NAME: drawer belonging to the heading at point — the text
between the marker line and the :END: line, CONTENT-END being the
start of the :END: line itself (so the region includes the last
content line's trailing newline). Return nil if the heading has no
such drawer. Only recognizes a marker line containing nothing but
the drawer name, via `claude-code-ide-org--find-drawer', so prose that
merely mentions \":DRAWER-NAME:\" is never mistaken for an actual
drawer — and, since 2026-08-14, a decoy no longer makes this report
\"no drawer\" for a heading that has one (TODO.org :ID: f42641ab).

An empty drawer yields an empty-but-valid region (BEG equal to END)
rather than (nil nil).  That is deliberate and is why this does not
simply return `org-element-contents-begin'/`-end': those are nil for an
empty drawer, and every caller here does arithmetic on the result.
Measured against org 9.8.7 on 2026-08-14, the two agree exactly on every
non-empty shape and differ only in that one case."
  (let ((element (claude-code-ide-org--find-drawer drawer-name)))
    (when element
      (let ((content-beg (claude-code-ide-org--drawer-body-start element)))
        (list content-beg
              (or (org-element-contents-end element) content-beg))))))

(defun claude-code-ide-org--logbook-entry-time (line)
  "Return the time LINE sorts on, or nil when it carries none.

One rule covers every shape the drawer holds, because in all of them the
*first* timestamp is the one to sort by: a `CLOCK:' interval sorts on its
start, a `State \"X\" from \"Y\" [ts]' note on its stamp, and a range
annotation on the start of its range — active `<...>' and inactive
`[...]' alike.  Anything unrecognised returns nil and is left in place
rather than guessed at."
  (when (string-match "\\(\\[[^]]+\\]\\|<[^>]+>\\)" line)
    (ignore-errors
      (claude-code-ide-org--parse-org-timestamp (match-string 1 line)))))

(defun claude-code-ide-org--parse-clock-lines (text)
  "Parse TEXT (a :LOGBOOK: drawer's body) into a plist.

:open is the raw text of a still-open CLOCK line if TEXT has one, else
nil.  :entries is a list of (:time TIME :text TEXT), one per *logical*
entry, in original order — native state-change notes with their
continuations, timestamp-range annotations, and closed CLOCK intervals
alike.

Entries rather than lines is the whole point.  A
`State \"X\" from \"Y\" [ts] \\\\' note owns the indented continuation
beneath it, and any reordering that separates the two corrupts the note
— exactly the loss `ba8249c1' already had to fix once, when
consolidation silently dropped non-CLOCK drawer lines.  A line starts a
new entry when it begins `CLOCK:' or `- '; every other non-blank line
continues the entry above it.

A closed CLOCK line's :text is *normalised* through
`claude-code-ide-org--format-clock-line', which recomputes the
`=> H:MM' total from the endpoints.  Everything else is kept verbatim,
original indentation included."
  (let (open entries current)
    (dolist (raw (split-string text "\n"))
      (let ((line (string-trim raw)))
        (cond
         ((string-empty-p line))
         ;; A still-open CLOCK reflects live state, not history, and is
         ;; never sorted or rewritten -- checked before the general
         ;; CLOCK: case, which would otherwise swallow it.
         ((string-match "\\`CLOCK: \\[[^]]+\\]\\'" line)
          (setq open line))
         ((string-match "\\`CLOCK: \\(\\[[^]]+\\]\\)--\\(\\[[^]]+\\]\\)" line)
          ;; Capture both groups before parsing either --
          ;; `claude-code-ide-org--parse-org-timestamp' calls
          ;; `org-time-string-to-time', which does its own internal
          ;; regexp matching and would otherwise clobber the match data
          ;; the second `match-string' relies on (the same footgun
          ;; `claude-code-ide-org-close-open-interval' works around).
          (let* ((start-str (match-string 1 line))
                 (end-str (match-string 2 line))
                 ;; Keep the line's own indentation. It used to be
                 ;; dropped harmlessly, because CLOCK lines were emitted
                 ;; as one block; now that they interleave with notes
                 ;; that *do* keep theirs, losing it would visibly
                 ;; misalign an indented drawer.
                 (indent (if (string-match "\\`\\([ \t]*\\)" raw)
                             (match-string 1 raw)
                           ""))
                 (start (claude-code-ide-org--parse-org-timestamp start-str))
                 (end (claude-code-ide-org--parse-org-timestamp end-str)))
            (when current (push current entries))
            (setq current
                  (list :time start
                        :text (concat indent
                                      (claude-code-ide-org--format-clock-line
                                       start end))))))
         ((string-prefix-p "- " line)
          (when current (push current entries))
          (setq current (list :time (claude-code-ide-org--logbook-entry-time line)
                              :text raw)))
         (current
          (plist-put current :text (concat (plist-get current :text) "\n" raw)))
         (t (push (list :time nil :text raw) entries)))))
    (when current (push current entries))
    (list :open open :entries (nreverse entries))))

(defun claude-code-ide-org--format-clock-line (start end)
  "Format START and END (time values) as a closed CLOCK line,
matching org's own \"CLOCK: [start]--[end] =>  H:MM\" convention."
  (let ((minutes (round (/ (float-time (time-subtract end start)) 60))))
    (format "CLOCK: %s--%s =>  %d:%02d"
            (format-time-string "[%Y-%m-%d %a %H:%M]" start)
            (format-time-string "[%Y-%m-%d %a %H:%M]" end)
            (/ minutes 60) (% minutes 60))))

(defun claude-code-ide-org--consolidate-logbook-text (text)
  "Given the raw body TEXT of a :LOGBOOK: drawer, return it normalised:
every entry on *one ascending timeline*, oldest first, keyed on the
first timestamp each carries. Closed CLOCK intervals keep their
endpoints exactly as recorded, with only the `=> H:MM' total recomputed.
A still-open CLOCK line, if present, is left completely untouched and
kept first, since it reflects live clock state, not history. Entries
carrying no parseable timestamp keep their original relative order at
the end — unplaceable, so not placed.

*One timeline across every entry style*, not per-style groups that
happen to be sorted within themselves: a state transition at 14:10
belongs between the interval that ended at 14:00 and the one starting at
14:20, which is what makes the drawer legible as a narrative rather than
three interleaved logs. `clock-template.org' is the shape being matched.

This deliberately abandons the newest-first order org itself uses when
*inserting* CLOCK lines, so the two disagree and the drawer drifts back
out of order between consolidations. That is the accepted cost of the
request (TODO.org :ID: af7d3687), not an oversight.

Reordering is only safe because the parser groups a note with its
indented continuation and moves them together; splitting those is the
corruption `ba8249c1' already fixed once (TODO.org :ID: ba8249c1).

*This function no longer alters any interval.* It used to round each one
to the nearest 5-minute mark, merge those that became adjacent or
overlapping, and drop whatever rounded to zero. That was built to clean
up per-turn clocking churn, under a risk assessment — recorded in
DONE.org — that it \"only ever touches already-closed history, so it can
never corrupt a running clock.\" True when written, and later false in a
way it could not have anticipated: closed history came to include
*reviewed, human-confirmed* intervals written by the apply command, and
rounding erased one within minutes (TODO.org :ID: b74e0f19). A one-minute
interval rounds to zero and is deleted; alone in a drawer, it
consolidates to the empty string.

Rounding is not reinstatable behind a flag here. An interval this
project has confirmed is the most authoritative record it holds, and
nothing downstream of the confirmation may quietly rewrite it. Shortness
is not a problem this has to solve any more: intervals are written by
apply, from endpoints a human confirmed, and a zero-width span is
annotated without a CLOCK line rather than rounded into one.  (The
one-minute floor that used to guard this on the write path went with
the clock-out wrapper's body at the 2026-08-11 cutover.)"
  (let* ((parsed (claude-code-ide-org--parse-clock-lines text))
         (open (plist-get parsed :open))
         (entries (plist-get parsed :entries))
         (dated (seq-filter (lambda (e) (plist-get e :time)) entries))
         (undated (seq-remove (lambda (e) (plist-get e :time)) entries))
         ;; `sort' on lists is a stable merge sort, which is what keeps
         ;; entries sharing a timestamp in the order they already had --
         ;; a CLOCK line and the annotation describing the same span stay
         ;; adjacent, and clock-template.org's own tie order (which is not
         ;; internally consistent) is preserved rather than second-guessed.
         (sorted (sort (copy-sequence dated)
                       (lambda (a b)
                         (time-less-p (plist-get a :time) (plist-get b :time)))))
         (lines (mapcar (lambda (e) (plist-get e :text))
                        (append sorted undated))))
    (concat (if open (concat open "\n") "")
            (mapconcat #'identity lines "\n")
            (if lines "\n" ""))))

(defun claude-code-ide-org--consolidate-drawer-at-point ()
  "Normalise the :LOGBOOK: drawer of the heading at point, in place.
Returns non-nil when the text changed.  Does not save; the caller owns
that, which is what lets apply fold this into the write it was already
making rather than issuing a second one."
  (let ((bounds (claude-code-ide-org--drawer-content-bounds "LOGBOOK"))
        changed)
    (when bounds
      (let* ((old (buffer-substring (nth 0 bounds) (nth 1 bounds)))
             (new (claude-code-ide-org--consolidate-logbook-text old)))
        (unless (equal old new)
          (delete-region (nth 0 bounds) (nth 1 bounds))
          (goto-char (nth 0 bounds))
          (insert new)
          (setq changed t))))
    changed))

(defun claude-code-ide-org-consolidate-history (id)
  "Normalise the :LOGBOOK: drawer of the heading with :ID: equal to ID:
re-emit every entry on one *ascending* timeline with endpoints exactly as
recorded, keeping a still-open CLOCK line first. Saves the buffer.

(This docstring said \"newest-first ... every non-CLOCK line after it\"
until 2026-08-13. That described the behaviour :ID: af7d3687 replaced,
in the very function it replaced it in.)

*Close to a no-op today, and deliberately kept anyway.* It used to round
intervals to 5-minute marks and merge the results, and to collapse a
:SESSIONS: drawer to one span per calendar day. The rounding was retired
after it destroyed a reviewed interval (TODO.org :ID: b74e0f19) and
:SESSIONS: was retired outright (:ID: 9d2fcdad), so ordering is all that
is left. Kept because :ID: af7d3687 — sort :LOGBOOK: chronologically,
keeping notes with their continuations — is precisely a change to this
function; deleting it now would mean recreating it.

It has no automatic caller. Nothing runs it after a clock-out any more,
and `claude-code-ide-org-close-open-interval' stopped calling it too:
rewriting a whole drawer as a side effect of repairing one line is the
shape behind both :ID: ba8249c1 and :ID: b74e0f19. Not registered as an
MCP tool — a deliberate maintenance operation via `emacsclient'."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (let ((heading (org-get-heading t t t t))
           logbook-changed)
       (setq logbook-changed
             (claude-code-ide-org--consolidate-drawer-at-point))
       (save-buffer)
       (if logbook-changed
           (format "Consolidated :LOGBOOK: on \"%s\"" heading)
         (format "Nothing to consolidate on \"%s\"" heading))))))

(defun claude-code-ide-org-set-todo (id state &optional note)
  "Validate ID and STATE and report the transition as queued.
Changes no TODO keyword.

Cut over to append-only 2026-08-11 (TODO.org :ID:
feba67eb-35b3-48bd-a892-8ecd47ca52e0).  This used to call `org-todo'
with `org-inhibit-logging' bound to t, precisely because org's native
state-change logging hangs when driven non-interactively through
`emacsclient -e' (TODO.org :ID: 04d0e7d5-ab6b-4972-925d-d517484c7595).
Suppressing that logging to keep the tool from hanging, and then
reconstructing the log line by hand, is the compromise this whole
refactor exists to undo: apply runs `org-todo' inside a genuinely
interactive command, where org's own logging works and nothing needs
suppressing.

Two things are still validated, and both matter because
`bin/hooks/queue-append' drops any event whose reply starts with
`Error:' -- making this the only gate between a bad tool call and a
queue entry that cannot be applied and cannot be explained at review
time:
- ID resolves to a real heading (via `claude-code-ide-org--at-id');
- STATE is a keyword this file's own `#+TODO:' line declares.

Deliberately *not* checked: whether the transition is legal. :BLOCKER:
and `org-blocker-hook' are consulted by `org-todo' itself, which now
runs at apply time in front of a human who can respond to a refusal.
Answering \"is this allowed?\" here would mean answering it against a
file that has not moved yet -- the same disk-goes-stale problem that
retires `bin/hooks/pretooluse-transition-guard' in this commit.

NOTE is a short (3-10 word) reason for the transition, carried for the
event queue and unused here.  At apply time it becomes the `\\\\'
continuation on org's native `- State \"X\" from \"Y\" [ts]' line.

The reply names the state the heading holds, as `(was NEXT)'.  That
clause is not cosmetic: `bin/hooks/queue-append' parses it back out to
record a `from' field on the queued `todo' event, which is what lets
review notice that reality has moved past a queued transition (TODO.org
:ID: f9f61c04-150b-4ee7-96c9-582cf2bda95a).  The hook is bash with no
Emacs access by design -- writing the queue without a running Emacs is
the premise the whole refactor rests on -- so the prior state has to
travel back in the reply.  A heading with no keyword reports
`(was none)' rather than an empty string, so the parse stays
unambiguous.

What `from' *means* changed with this commit, and not merely in wording:
it was \"the state held before this tool changed it\", and since nothing
here changes anything it is now \"the state on disk when the event was
queued\".  That is what makes the staleness check informative instead of
always-true -- and it is also why every transition in a queued *chain*
on one heading carries the same `from'.  See TODO.org :ID:
6b1e73c4-25da-4f0e-8a51-9c0d3f7ab214, which is that consequence, still
unresolved."
  (claude-code-ide-org--tolerating-pending-capture id
    ;; A capture that deferred has not written its heading yet, so this
    ;; would otherwise return `Error: unknown id' -- and `queue-append'
    ;; drops any event whose reply starts with `Error:', silently losing
    ;; the state. Reported as queued instead, `was none' because a
    ;; captured heading is keyword-less by design.
    (lambda (title)
      (let ((keywords (claude-code-ide-org--pending-capture-keywords id)))
        (if (and keywords (not (member state keywords)))
            (format "Error: %s is not a TODO keyword in this file (have: %s)"
                    state (string-join keywords " "))
          (format "Queued todo -> %s (was none): \"%s\"; pending review."
                  state title))))
    (lambda ()
      (claude-code-ide-org--at-id
       id
       (lambda ()
     ;; org-todo-keywords-1 is buffer-local and derived from the file's
     ;; own `#+TODO:' line, so this validates against the keywords that
     ;; file actually defines rather than against a list hard-coded here
     ;; -- which would drift the first time a file declares a different
     ;; sequence. Checked before anything is reported as queued: a
     ;; misspelled keyword that reaches the queue is a refusal at apply
     ;; time, in front of a human who has no way to tell whether the
     ;; typo was theirs or the model's.
     (if (not (member state org-todo-keywords-1))
         (format "Error: %s is not a TODO keyword in this file (have: %s)"
                 state (string-join org-todo-keywords-1 " "))
       (format "Queued todo -> %s (was %s): \"%s\"; pending review."
               state
               (or (org-get-todo-state) "none")
               (org-get-heading t t t t))))))))

(defun claude-code-ide-org-archive (id)
  "Archive the org heading whose :ID: property equals ID.
Uses the #+ARCHIVE: directive in effect at the heading (file-level
or per-heading :ARCHIVE: property).  For :code: tasks this should
resolve to DONE.org::* Done per your project file headers."
  (let ((claude-code-ide-org--log-source (or claude-code-ide-org--log-source "org_archive")))
    (claude-code-ide-org--at-id
     id
     (lambda ()
       (let ((heading (org-get-heading t t t t)))
         (org-archive-subtree)
         (save-buffer)
         (format "Archived: \"%s\"" heading))))))

;;; Refile ------------------------------------------------------------------
;;
;; Moves a heading to become the last child of a different heading,
;; identified by :ID: rather than by org-refile's usual interactive
;; completion prompt (which walks `org-refile-targets' and asks the
;; user to pick).  Both endpoints are resolved directly via
;; `org-id-find' and used to build org-refile's `rfloc' argument by
;; hand, so the prompt is never entered.
;;
;; Target resolution is deliberately :ID:-only, matching every other
;; tool in this file — there is no v1 way to refile to the top level
;; of a file with no parent heading, since there is no heading to
;; hang an :ID: on to resolve TARGET-ID against.  A file+path
;; alternative codepath was considered (per the open question in
;; TODO.org) and rejected for v1: every other tool in this module
;; resolves its target purely by :ID:, and every real usage seen so
;; far has an existing parent heading to refile under.  Out-of-scope
;; case returns a clear error string instead; revisit if that
;; assumption breaks in practice.

(defun claude-code-ide-org-refile (id target-id)
  "Refile (move) the org heading whose :ID: equals ID so it becomes
the last child of the org heading whose :ID: equals TARGET-ID.
Builds org-refile's `rfloc' argument directly from both headings'
markers rather than going through the interactive completion prompt.
Works across files: the source and target heading may live in
different org files.  Saves every buffer touched — source and
target, which may differ — afterward: the same bug shape that
previously bit `claude-code-ide-org-archive' and
`claude-code-ide-org-clock-out' (reporting success while a buffer
went unsaved).  Passes the target's marker itself (not a plain
integer position) as `rfloc's position element: when source and
target are in the same file, org-refile deletes the source subtree
before visiting the target position, and only a marker
auto-relocates through that deletion the way `goto-char' needs.
Never signals an error to the MCP layer; returns \"Error: ...\" for
an unresolvable ID (either heading) or any failure `org-refile'
itself signals (e.g. refiling a heading into its own subtree).
Binds `org-log-refile' to nil for the duration of the call: it
defaults to nil anyway, but if the user's config sets it to a
note-prompting value, `org-refile' would otherwise try to read a
note interactively, which would hang or error under the MCP layer's
non-interactive call — the same never-block guarantee every other
tool here gives."
  (require 'org-id)
  (let ((marker (org-id-find id 'marker))
        (target-marker (org-id-find target-id 'marker)))
    (cond
     ((not marker)
      (format "Error: no org heading found with :ID: \"%s\"" id))
     ((not target-marker)
      (format "Error: no org heading found with target :ID: \"%s\"" target-id))
     (t
      (condition-case err
          (let* ((source-buffer (marker-buffer marker))
                 (target-buffer (marker-buffer target-marker))
                 (target-file (buffer-file-name
                               (or (buffer-base-buffer target-buffer) target-buffer)))
                 (heading (org-with-point-at marker (org-get-heading t t t t)))
                 (target-heading (org-with-point-at target-marker (org-get-heading t t t t)))
                 (rfloc (list target-heading target-file nil target-marker))
                 (org-log-refile nil))
            (org-with-point-at marker
              (org-refile nil nil rfloc))
            (dolist (buf (delete-dups (list source-buffer target-buffer)))
              (when (buffer-live-p buf)
                (with-current-buffer buf (save-buffer))))
            (format "Refiled: \"%s\" under \"%s\"" heading target-heading))
        (error (format "Error: %s" (error-message-string err))))))))

;;; Capture -----------------------------------------------------------------
;;
;; Quick-add a new TODO heading from a natural-language ask in one call,
;; instead of hand-writing a heading via the org skill and then calling
;; org-id-get-create separately.  Uses a dedicated capture template (key
;; "z", distinct from any personal templates the user may configure
;; themselves) built fresh on every call rather than registered once at
;; load time: the template's :ID: value has to be generated up front in
;; Elisp — via `let'-bound NEW-ID below, not the usual `%(org-id-new)'
;; sexp escape — so the exact same value can be reused verbatim in both
;; the inserted heading and the returned confirmation string, rather than
;; re-parsing the freshly-captured heading off disk to recover it
;; afterward.
;;
;; The template body uses `%i', not `%?' — confirmed by direct test under
;; `emacs --batch -Q': `%?' is purely a cursor-placement marker for
;; interactive capture and expands to nothing under `:immediate-finish'
;; (which this template always sets, since it never displays a buffer to
;; a human), producing a heading with no text at all.  `%i' is the escape
;; that actually substitutes the string passed to `org-capture-string'.
;;
;; Unlike `org-id-get-create' (the manual workflow this tool replaces),
;; plain `org-capture' writes the :ID: property as literal template text
;; and never itself calls `org-id-add-location' — so without an explicit
;; registration step here, the freshly-captured ID would not be in
;; `org-id-locations' yet, and every other tool in this file (org_clock_in,
;; org_set_todo, ...) locates headings via `org-id-find', which only
;; recovers from a cold cache by rescanning `org-agenda-files'/
;; `org-id-extra-files' — files the capture target need not be a member
;; of.  Registering the location directly below makes the returned :ID:
;; immediately usable, as the tool's contract promises, regardless of
;; agenda-file configuration.

(defun claude-code-ide-org--capture-target-file ()
  "File `org_capture' targets: `claude-code-ide-org-capture-file' if
set, else `org-default-notes-file'.  Used as the (file ...) target
spec's function in the dynamically-built capture template — resolved
fresh on every capture, so changing the defcustom at runtime takes
effect immediately."
  (or claude-code-ide-org-capture-file org-default-notes-file))

(defun claude-code-ide-org--capture-level-1-headings (file)
  "Titles of FILE's level-1 headings — this project's categories.
They carry no :ID: by convention, so a title is the only handle there
is; see `claude-code-ide-org--capture-target-spec' for why that is
acceptable here and nowhere else."
  (with-current-buffer (find-file-noselect file)
    (org-map-entries (lambda () (substring-no-properties
                                 (org-get-heading t t t t)))
                     "LEVEL=1" 'file)))

(defun claude-code-ide-org--capture-target-spec (target)
  "Resolve TARGET to a plist (:spec SPEC :file FILE :where DESC).

TARGET is an :ID: to capture under that heading, the title of a
top-level category to capture under that, or nil to append at the end of
the capture file.

*Why a title is allowed at all,* against this project's standing rule
that headings are addressed by :ID: and never by title: top-level
headings here are categories and carry no property drawer by
convention, so no other handle exists.  The properties that make titles
unsafe elsewhere — non-unique, mutable, moved by refiling — do not hold
for these: there are seven, they are human-curated, and they never move.
That is a different risk profile, not an exception grudgingly made.

Signals when TARGET matches neither, rather than silently falling back
to the end of the file.  A caller that named a destination and got a
different one is worse off than a caller that got an error."
  (let ((default (claude-code-ide-org--capture-target-file))
        (target (and (stringp target)
                     (not (string-empty-p (string-trim target)))
                     (string-trim target))))
    (cond
     ((null target)
      (list :spec (list 'file default) :file default :where "end of file"))
     ((org-id-find target)
      (list :spec (list 'id target)
            :file (car (org-id-find target))
            :where (format "under :ID: %s" target)))
     ((member target (claude-code-ide-org--capture-level-1-headings default))
      (list :spec (list 'file+olp default target)
            :file default
            :where (format "under \"%s\"" target)))
     (t (error "target %S is neither a known :ID: nor a top-level heading in %s"
               target (file-name-nondirectory default))))))

;;; Write-through gate for capture and amend ---------------------------------
;;
;; Capture and amend write the file immediately when it is free and queue
;; the proposal when it is not (TODO.org :ID: b5f94b88).  The reply says
;; which happened, and `bin/hooks/queue-append' appends an event only for
;; the deferred one -- so these four prefixes are a contract between two
;; files that change independently.
;;
;; Named constants rather than literals on both sides because this project
;; has already been bitten by a reply parse going stale when a message was
;; reworded, and the failure mode here is silent in both directions:
;; getting it wrong either double-applies the write or drops it.
;; `bin/queue-append-test' asserts the hook's own cases still match these.

(defconst claude-code-ide-org--reply-captured "Captured: "
  "Reply prefix meaning a capture wrote through; queue nothing.")

(defconst claude-code-ide-org--reply-queued-capture "Queued capture: "
  "Reply prefix meaning a capture deferred; queue the event.")

(defconst claude-code-ide-org--reply-amended "Amended: "
  "Reply prefix meaning an amendment wrote through; queue nothing.")

(defconst claude-code-ide-org--reply-queued-amend "Queued amend: "
  "Reply prefix meaning an amendment deferred; queue the event.")

(defun claude-code-ide-org--file-busy-p (file)
  "Non-nil when FILE has unsaved changes in a live Emacs buffer.

*Advisory, and the docstring has to say so.*  Nothing is held between
this check and the write that follows it, so a keystroke or an `Edit'
call landing in that window still collides.  This reduces the collision
window; it does not close it.  Do not add a lock to close the gap --
b5f94b88 rejects that design, because waiting reintroduces the hang class
the queue exists to avoid and a lock cannot bind the `Edit' tool anyway.

Why modification and not, say, a lock file: every MCP write runs inside
one single-threaded Emacs, so two sessions calling `org_capture' are
already serialised and MCP-vs-MCP corruption is not reachable.  The real
collision is the `Edit' tool writing the file on disk while Emacs holds
the buffer, plus `:immediate-finish' committing a human's half-finished
edits along with the new heading.  `buffer-modified-p' is what sees both.

`buffer-read-only' is deliberately *not* busy: the user sets it to guard
against their own keystrokes, and clearing it is established practice
here (TODO.org :ID: c8a97d9d)."
  (let ((buffer (and file (find-buffer-visiting file))))
    (and buffer (buffer-modified-p buffer))))

(defun claude-code-ide-org--format-tags (tags)
  "Render TAGS as an org tag suffix, or \"\" when there are none.
TAGS is a comma- or space-separated string, which is how an MCP argument
can carry a list at all."
  (let ((names (and (stringp tags)
                    (seq-remove #'string-empty-p
                                (split-string tags "[ ,:]+" t)))))
    (if names (format " :%s:" (string-join names ":")) "")))

(defun claude-code-ide-org--capture-write (title new-id created spec tags)
  "Insert TITLE as a heading at SPEC, carrying NEW-ID, CREATED and TAGS.
Factored out of `claude-code-ide-org-capture' so the immediate path and
the apply path insert headings through exactly one code path -- a
deferred capture must produce the same heading it would have produced
had it written through, and two similar templates would drift."
  (let ((org-capture-templates
         (list (list "z" "Claude quick-capture (org_capture MCP tool)"
                     'entry
                     spec
                     (format "* %%i%s\n:PROPERTIES:\n:ID:       %s\n:CREATED:  %s\n:END:\n"
                             (claude-code-ide-org--format-tags tags)
                             new-id created)
                     :immediate-finish t))))
    (org-capture-string title "z")))

(defun claude-code-ide-org-capture (title &optional target tags note)
  "Quick-add TITLE as a new heading via `org-capture'.

Writes a *keyword-less* heading carrying a freshly-generated :ID: and a
:CREATED: stamp.  No TODO keyword: the state is supplied later, at
ingestion, through `org-todo' inside the interactive apply — which makes
it a genuine transition and lets org write the creation entry itself.
Capturing with a keyword would assert a state live while every other
state assertion in this module is queued.  See TODO.org
:ID: 47c027d2-7b5a-4de0-baf4-f992f3b814bd.

:CREATED: is formatted here rather than via the template's `%U' escape.
A template escape that silently fails to expand leaves a literal \"%U\"
behind and still satisfies a naive \"is the property present\" check;
formatting it in elisp cannot fail that way.

TARGET places the heading — an :ID:, a top-level category title, or
omitted for the end of the capture file.  See
`claude-code-ide-org--capture-target-spec'.  TAGS is a comma-separated
tag string.  NOTE is a short reason, carried for the queue and unused on
the immediate path.

*Writes through when the target file is free, and queues when it is
not* (TODO.org :ID: b5f94b88).  In the common case the heading appears at
once, exactly as before; when the human has unsaved edits in that buffer
the proposal becomes a queue event instead, applied later by the same
human review pass that already owns state changes.  So an interjection
never collides and is never lost.

Either way the :ID: is minted *here* and reported, so `org_capture'
followed by `org_set_todo' keeps working with no new ceremony.  On the
deferred path `org-id-add-location' is deliberately not called — the
heading does not exist yet, and poisoning the id cache would make every
later lookup lie.

Returns \"Captured: \\=\"TITLE\\=\" (ID: ...) <where>\" when it wrote,
\"Queued capture: ...\" when it deferred, or an \"Error: ...\" string.
Those prefixes are a contract with `bin/hooks/queue-append' — see
`claude-code-ide-org--reply-captured'.  Never signals to the MCP layer."
  (condition-case err
      (let* ((resolved (claude-code-ide-org--capture-target-spec target))
             (file (plist-get resolved :file))
             (new-id (org-id-new))
             (created (format-time-string "[%Y-%m-%d %a %H:%M]")))
        (if (claude-code-ide-org--file-busy-p file)
            (format "%s\"%s\" (ID: %s) %s; pending review."
                    claude-code-ide-org--reply-queued-capture
                    title new-id (plist-get resolved :where))
          (claude-code-ide-org--capture-write
           title new-id created (plist-get resolved :spec) tags)
          ;; Registered against the file the target actually resolved to,
          ;; which is not necessarily the capture file: an :ID: target can
          ;; live anywhere org-id knows about.
          (org-id-add-location new-id (expand-file-name file))
          (format "%s\"%s\" (ID: %s) %s"
                  claude-code-ide-org--reply-captured
                  title new-id (plist-get resolved :where))))
    (error (format "Error: %s" (error-message-string err)))))

(defun claude-code-ide-org--end-of-body ()
  "Move point to the end of the current heading's own body.

Point lands just after the body's last non-whitespace character — past
any property drawer, :LOGBOOK: or planning line, and *before* the first
child heading, so an amendment lands in the heading it names rather than
inside a drawer or in a subheading's text.

Trailing blank lines are skipped back over rather than appended to, so
repeated amendments do not accumulate a growing gap.  A heading with no
body at all leaves point at the end of its drawer, which is the right
answer for the same reason: the amendment becomes the body.

The subtree end bounds the child search, so the *next* heading at this
level or above — which is not a child — can never be mistaken for one."
  (org-back-to-heading t)
  (let* ((end (save-excursion (org-end-of-subtree t t) (point)))
         (child (save-excursion
                  (forward-line 1)
                  (and (re-search-forward org-heading-regexp end t)
                       (line-beginning-position)))))
    (goto-char (or child end))
    (skip-chars-backward " \t\n")))

(defun claude-code-ide-org-amend (id text &optional note)
  "Append TEXT to the body of the heading with :ID: ID.

The queue-aware counterpart to editing a heading's prose with the `Edit'
tool.  Writes through when the file is free and queues the proposal when
the human has unsaved changes in that buffer — the same gate
`claude-code-ide-org-capture' uses, and for the same reason.

NOTE is a short reason, carried for the queue.

*Positional, not contextual, and v1 accepts that.*  The text lands at the
end of the heading's own body regardless of whether that body changed
since the amendment was written — which may be exactly wrong for an
amendment written in response to what the body said.  There is no
conflict detection; a diff-style guard is a much larger design.  The
review line names the target heading's title so a human can spot a body
that has moved on.

*Honest limit:* this helps only when Claude calls `org_amend' instead of
the `Edit' tool.  `Edit' consults neither Emacs nor any lock and cannot
be intercepted, so the mechanism is a practice plus a safety net, not
enforcement.

Returns \"Amended: ...\", \"Queued amend: ...\", or \"Error: ...\"."
  (require 'org-id)
  (let ((marker (ignore-errors (org-id-find id 'marker))))
    (if (not marker)
        (format "Error: no org heading found with :ID: \"%s\"" id)
      (let* ((file (buffer-file-name (marker-buffer marker)))
             (title (org-with-point-at marker
                      (org-no-properties (org-get-heading t t t t)))))
        (set-marker marker nil)
        (if (claude-code-ide-org--file-busy-p file)
            (format "%s\"%s\" (%d line%s); pending review."
                    claude-code-ide-org--reply-queued-amend
                    title
                    (length (split-string (or text "") "\n"))
                    (if (= 1 (length (split-string (or text "") "\n"))) "" "s"))
          (let ((result
                 (claude-code-ide-org--at-id
                  id
                  (lambda ()
                    (claude-code-ide-org--end-of-body)
                    ;; Blank line before, so the amendment reads as its own
                    ;; paragraph rather than running into whatever the body
                    ;; already ended with.
                    (insert "\n\n" (string-trim (or text "")) "\n")
                    (save-buffer)
                    nil))))
            (or (and (stringp result) result)
                (format "%s\"%s\"" claude-code-ide-org--reply-amended title))))))))

;;; Query -------------------------------------------------------------------
;;
;; Structured search over `claude-code-ide-org--tracked-files' (the same
;; file list stale-interval-recovery already uses), via org-ql's
;; plain-string mini-language.  Deliberately restricted to that
;; mini-language: `org-ql--query-string-to-sexp' only ever recognizes
;; todo:/tags:/priority:/heading:/... predicates plus `!' negation and
;; `,' OR — org-ql's separate full sexp predicate language (arbitrary
;; Elisp evaluated against the user's files) is never reachable from a
;; model-supplied string here.

(defun claude-code-ide-org--parse-query-string (query)
  "Parse QUERY, in org-ql's plain-string mini-language, into an
org-ql sexp query, or nil if QUERY fails to parse.  Never evaluates
QUERY as Elisp — see the commentary above this section."
  (require 'org-ql)
  (org-ql--query-string-to-sexp query 'and))

(defun claude-code-ide-org--format-query-match ()
  "Format the org-ql match at point as one line: TODO state,
heading, tags, :ID:, and file.  Used as `org-ql-select's :action,
called with point already at the heading."
  (let ((state (or (org-get-todo-state) "-"))
        (heading (org-get-heading t t t t))
        (id (or (org-entry-get nil "ID") "none"))
        (tags (org-get-tags nil t))
        (file (buffer-file-name (buffer-base-buffer))))
    (format "%-9s %s%s  (ID: %s, file: %s)"
            state heading
            (if tags (concat "  :" (mapconcat #'identity tags ":") ":") "")
            id (file-name-nondirectory (or file "?")))))

(defun claude-code-ide-org-query (query)
  "Search `claude-code-ide-org--tracked-files' with QUERY, an org-ql
plain-string query, e.g. \"todo:WAIT\", \"tags:research,code\"
(comma = OR), \"priority:A\", \"heading:\\\"text\\\"\", or negated
with `!' (e.g. \"!todo:DONE\").  Multiple space-separated terms are
combined with AND.  Returns one line per match — TODO state,
heading, tags, :ID:, file — or a message string when the query is
empty, fails to parse, or matches nothing.  Never signals an error
to the MCP layer."
  (condition-case err
      (if (string-match-p "\\`[ \t\n\r]*\\'" query)
          "Error: empty query."
        (let ((sexp (claude-code-ide-org--parse-query-string query)))
          (if (null sexp)
              (format "Error: could not parse query: %S" query)
            (let ((matches (org-ql-select (claude-code-ide-org--tracked-files) sexp
                             :action #'claude-code-ide-org--format-query-match)))
              (if matches (mapconcat #'identity matches "\n") "No matches.")))))
    (error (format "Error: %s" (error-message-string err)))))

;;; Outline index ------------------------------------------------------------
;;
;; A compact structural view: one line per heading, carrying level, TODO
;; keyword, title, :ID:, tags, and whether a :BLOCKER: is set.  Measured
;; on TODO.org 2026-08-11, this turns 280,079 bytes into 7,384 — enough
;; of a reduction that "check what this project already knows" becomes
;; affordable mid-task, which is the whole point (see TODO.org
;; :ID: 9f3c35c7-0229-4cd6-908b-779267ec9b97 for the three occasions in
;; one session where it was skipped because reading the file was not).
;;
;; Complementary to org_query rather than overlapping: org_query answers
;; "which headings match this predicate" and flattens; this answers "what
;; is in here and how is it arranged" and preserves hierarchy.
;;
;; :ID:s are emitted in full, not truncated.  Every other tool here takes
;; a full :ID: argument, so a shortened index would force a second lookup
;; on every use.

(defconst claude-code-ide-org--outline-finished-keywords
  '("DONE" "CANCELLED")
  "Keywords `claude-code-ide-org-outline' drops for ACTIVE-ONLY.
Spelled out rather than read from `org-done-keywords', which is
buffer-local and therefore nil outside a visited org buffer — the
filter would silently pass everything.")

(defun claude-code-ide-org--outline-blocker-ids (raw)
  "Extract the :ID:s named by RAW, an org-depend `:BLOCKER:' value.
Handles the documented `ids(a b c)' form, and also a bare id written
without the wrapper -- which org-depend itself would *not* honour, but
which exists in this project's own files, so the reader should see it
rather than silently treat the heading as dependency-free.  Returns nil
for forms that name no ids at all (`previous-sibling',
`chain-siblings(...)'), which is a different answer from \"no blockers\"
and is handled by the caller."
  (let (ids (start 0))
    (while (string-match "[0-9a-fA-F]\\{8\\}-[0-9a-fA-F-]\\{27,\\}" raw start)
      (push (match-string 0 raw) ids)
      (setq start (match-end 0)))
    (nreverse ids)))

(defun claude-code-ide-org--outline-id-finished-p (id)
  "Return `done', `open', or nil (unresolvable) for heading ID.
Finishedness is tested against
`claude-code-ide-org--outline-finished-keywords' rather than
`org-done-keywords', for the reason given there: the latter is
buffer-local and would be nil in the wrong buffer, quietly reporting
every blocker as still open.

`org-with-wide-buffer' rather than `save-excursion', and that is
load-bearing: `org_outline' scoped to an :ID: maps with
`org-map-entries' at `tree' scope, which *narrows* the buffer.  A
blocker almost always lives elsewhere in the same file, so
`find-file-noselect' hands back that very buffer, still narrowed,
`goto-char' is clamped to the accessible region, and
`org-get-todo-state' reads whichever heading is there -- the scoped one
itself.  Being unfinished, it answered `open', so every scoped listing
reported satisfied blockers as [blocked] (TODO.org :ID: f765d782).
Note that failure took the *confident* branch: [blocked?] exists for
\"cannot resolve\" and would have been the honest answer."
  (let ((loc (org-id-find id)))
    (when loc
      (with-current-buffer (find-file-noselect (car loc))
        (org-with-wide-buffer
         (goto-char (cdr loc))
         (if (member (org-get-todo-state)
                     claude-code-ide-org--outline-finished-keywords)
             'done
           'open))))))

(defun claude-code-ide-org--outline-blocked-marker ()
  "Return the dependency marker for the heading at point, or nil.

Distinguishes *having* a `:BLOCKER:' from *being blocked by* it.  The
first version of this tool conflated them -- it printed \"[blocked]\"
whenever the property was present -- and since org-depend treats
`:BLOCKER:' as a durable declaration rather than a flag to clear, every
heading that ever had one read as blocked forever.  Measured on
TODO.org the day it shipped: all 10 markers were false, because all four
referenced headings were DONE.

  [blocked]   at least one named blocker is not in a finished state
  [blocked?]  a dependency exists that cannot be resolved -- an id that
              no longer points anywhere, or a form naming no ids at all.
              Deliberately not silent: unresolvable is not the same as
              satisfied, and collapsing them is how the first version
              went wrong in the other direction."
  (let ((raw (org-entry-get nil "BLOCKER")))
    (when raw
      (let* ((ids (claude-code-ide-org--outline-blocker-ids raw))
             (states (mapcar #'claude-code-ide-org--outline-id-finished-p ids)))
        (cond ((memq 'open states) "  [blocked]")
              ((or (null ids) (memq nil states)) "  [blocked?]")
              (t nil))))))

(defun claude-code-ide-org--outline-line (active-only max-depth)
  "Format the heading at point as one index line, or nil to omit it.
Omits finished headings when ACTIVE-ONLY, and anything deeper than
MAX-DEPTH when that is non-nil.  Levels are absolute, so a MAX-DEPTH
of 2 means the same thing whether the scope is a whole file or one
subtree."
  (let ((level (org-current-level))
        (keyword (org-get-todo-state)))
    (unless (or (and max-depth (> level max-depth))
                (and active-only
                     (member keyword
                             claude-code-ide-org--outline-finished-keywords)))
      (let ((id (org-entry-get nil "ID"))
            (tags (org-get-tags nil t)))
        ;; Stripped once, over the assembled line, rather than per
        ;; component.  Every one of these reads from the buffer and so
        ;; carries its text properties -- `org-get-heading' most visibly,
        ;; but `org-get-todo-state', `org-get-tags' and `org-entry-get'
        ;; all do it too, and concat propagates from any of them.
        ;; Stripping only the heading looked correct and left the result
        ;; propertized anyway; the test caught that, but only after being
        ;; rewritten to propertize the fixture by hand, since batch Emacs
        ;; runs no font-lock and a scratch org file is clean either way.
        (substring-no-properties
         (concat (make-string (* 2 (1- level)) ?\s)
                (and keyword (concat keyword " "))
                ;; All four flags on: no TODO keyword (added above, so it
                ;; is not doubled), no priority cookie, no tags, no
                ;; comment marker.  Notably this also leaves the title
                ;; unescaped -- org-refile-get-targets renders "!/@" as
                ;; "!\\/@" in its paths, which is fine for a completion
                ;; table and wrong for something meant to be read.
                ;;
                ;; Stripped of text properties: `org-get-heading' returns
                ;; propertized text (fontification, org-category and
                ;; friends), and concat propagates that to the whole
                ;; result.  Caught by eyeballing a live call, whose output
                ;; came back as a `#("..." 0 11 (...))' literal rather
                ;; than a plain string -- nothing an MCP client should be
                ;; handed, and invisible to a `string-match-p' test.
                (org-get-heading t t t t)
                (and id (format "  {%s}" id))
                (and tags (format "  :%s:" (string-join tags ":")))
                (claude-code-ide-org--outline-blocked-marker)))))))

(defun claude-code-ide-org--outline-map (active-only max-depth scope)
  "Collect index lines over SCOPE, an `org-map-entries' scope value."
  (let (lines)
    (org-map-entries
     (lambda ()
       (let ((line (claude-code-ide-org--outline-line active-only max-depth)))
         (when line (push line lines))))
     nil scope)
    (nreverse lines)))

(defun claude-code-ide-org-outline (&optional scope max-depth active-only)
  "Return a compact one-line-per-heading index.

SCOPE is an :ID: to index just that subtree, a file name to index one
file, or empty for every file in `claude-code-ide-org--tracked-files'.
MAX-DEPTH caps the outline level reported.  ACTIVE-ONLY drops DONE and
CANCELLED headings.  All three arrive as strings from the MCP layer and
are parsed leniently; anything unusable falls back to the permissive
default rather than erroring, since a too-large index is recoverable and
a failed call is not.

Read-only: verified that `org-map-entries' over an explicit file list
neither moves point nor marks the buffer modified, so this is safe to
run against files the user has open.  Never signals an error to the MCP
layer."
  (condition-case err
      (let* ((scope (and (stringp scope)
                         (not (string-empty-p (string-trim scope)))
                         (string-trim scope)))
             (depth (let ((n (and (stringp max-depth)
                                  (string-to-number max-depth))))
                      ;; string-to-number yields 0 for junk, which reads
                      ;; the same as "no limit" -- correct either way.
                      (and n (> n 0) n)))
             (active (and active-only
                          (member (downcase (format "%s" active-only))
                                  '("t" "true" "yes" "1"))
                          t)))
        (cond
         ;; An :ID: that resolves wins over a file interpretation --
         ;; an :ID: can never also be a readable file name.
         ((and scope (org-id-find scope))
          (let ((lines (claude-code-ide-org--at-id
                        scope
                        (lambda ()
                          (claude-code-ide-org--outline-map
                           active depth 'tree)))))
            (if (stringp lines) lines      ; --at-id's "Error: ..." string
              (if lines (mapconcat #'identity lines "\n")
                "No headings in scope."))))
         (t
          (let* ((files (if scope
                            (list (expand-file-name scope))
                          (claude-code-ide-org--tracked-files)))
                 (multiple (cdr files))
                 chunks)
            (dolist (file files)
              (unless (file-readable-p file)
                (error "no readable file at %s" file))
              (let ((lines (claude-code-ide-org--outline-map
                            active depth (list file))))
                (when lines
                  (push (if multiple
                            ;; Only label files when there is more than
                            ;; one, so the common single-file call stays
                            ;; free of a header that says nothing.
                            (concat (file-name-nondirectory file) "\n"
                                    (mapconcat #'identity lines "\n"))
                          (mapconcat #'identity lines "\n"))
                        chunks))))
            (if chunks
                (mapconcat #'identity (nreverse chunks) "\n")
              "No headings found.")))))
    (error (format "Error: %s" (error-message-string err)))))

;;; Structural manipulation -------------------------------------------------

(defconst claude-code-ide-org--sort-type-codes
  '(("alpha" . ?a)
    ("todo-order" . ?o)
    ("priority" . ?p)
    ("scheduled" . ?s)
    ("deadline" . ?d)
    ("clock-time" . ?k))
  "Map from a friendly `sort-type' string to `org-sort-entries's
character sorting-type codes.  Deliberately a small, named subset of
what `org-sort-entries' itself accepts (e.g. it also supports
numeric, by-creation-time, by-property, and custom-function sorts,
plus capitalized variants for a reversed order) — these six cover
the sorts a model is actually likely to ask for by name.")

(defun claude-code-ide-org-sort-children (id sort-type)
  "Sort the children of the org heading whose :ID: property equals ID.
SORT-TYPE is a friendly string, one of: alpha, todo-order, priority,
scheduled, deadline, clock-time — see
`claude-code-ide-org--sort-type-codes' for the mapping onto
`org-sort-entries's character codes.  Calls `org-sort-entries'
non-interactively with point at ID's heading, so it is the heading's
children (not the heading itself or its siblings) that get sorted.
Saves the buffer afterwards."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (let ((code (cdr (assoc sort-type claude-code-ide-org--sort-type-codes)))
           (heading (org-get-heading t t t t)))
       (if (not code)
           (format "Error: unknown sort-type \"%s\"; expected one of %s"
                   sort-type
                   (mapconcat #'car claude-code-ide-org--sort-type-codes ", "))
         (org-sort-entries nil code)
         (save-buffer)
         (format "Sorted children of \"%s\" by %s" heading sort-type))))))

(defun claude-code-ide-org-move-sibling (id direction)
  "Move the org heading whose :ID: property equals ID up or down
among its siblings (i.e. reorder it relative to other headings at
the same level under the same parent).  DIRECTION must be \"up\" or
\"down\", calling `org-move-subtree-up' / `org-move-subtree-down'
respectively.  Saves the buffer afterwards.  Moving the first
sibling up, or the last sibling down, signals a `user-error' from
org itself (\"Cannot move past superior level or buffer limit\");
this relies on the shared `claude-code-ide-org--at-id' dispatcher's
`condition-case' to turn that into a clean \"Error: ...\" string
rather than adding separate boundary handling here."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (let ((heading (org-get-heading t t t t)))
       (cond
        ((equal direction "up") (org-move-subtree-up))
        ((equal direction "down") (org-move-subtree-down))
        (t (error "Unknown direction \"%s\"; expected \"up\" or \"down\"" direction)))
       (save-buffer)
       (format "Moved \"%s\" %s" heading direction)))))

;;; Clock report --------------------------------------------------------------
;;
;; Wraps org-clock-report/column view's own machinery
;; (`org-dblock-write:clocktable') so "what did I work on this week" is
;; one tool call instead of Claude eyeballing LOGBOOK entries across
;; files by hand. Always computed in a throwaway temp buffer, never a
;; real file's buffer:
;;
;; - :id case — an in-memory copy of just that heading's subtree text
;;   is inserted into the temp buffer, and `org-dblock-write:clocktable'
;;   is left at its own default :scope (`file', i.e. "the whole current
;;   buffer" — which, here, is exactly that copied subtree). The real
;;   file's buffer is never narrowed, visited-and-modified, or saved.
;; - whole-files case — :scope is set to a plain list of
;;   `claude-code-ide-org--tracked-files' file paths, which
;;   `org-dblock-write:clocktable' itself resolves to buffers (opening
;;   any not already visited, exactly as org_query's org-ql-select
;;   already does) without ever touching the throwaway buffer's own
;;   (irrelevant, empty) content.
;;
;; Spot-checked in a scratch `emacs --batch -Q' buffer before committing
;; to this as the mechanism (per this feature's noted risk in TODO.org):
;; confirmed both scoping strategies produce the expected headline/time
;; breakdown and leave the source file buffer's modified-p nil throughout.

(defun claude-code-ide-org--subtree-text-at-point ()
  "Return the subtree at point (its heading through its last child,
if any) as plain text.  Does not modify the buffer."
  (org-back-to-heading t)
  (buffer-substring-no-properties
   (point) (save-excursion (org-end-of-subtree t t) (point))))

(defun claude-code-ide-org--clocktable-string (params &optional subtree-text)
  "Return the clocktable report text for PARAMS, computed in a
throwaway temp buffer that is discarded immediately afterward —
never touches any real file or buffer.  If SUBTREE-TEXT is given, it
is inserted into the temp buffer first, and PARAMS is expected to
leave :scope at its default (`file', meaning \"the current buffer,
unrestricted\") so the report covers exactly that text; otherwise
PARAMS is expected to set :scope itself (e.g. to a list of files).
Either way, `org-dblock-write:clocktable' inserts its output at
point — which, right after SUBTREE-TEXT was inserted, is just past
it — so only the text from that point onward (the actual generated
report) is returned, not the copied source text it was computed
from."
  (with-temp-buffer
    (org-mode)
    (when subtree-text (insert subtree-text))
    (let ((origin (point)))
      (org-dblock-write:clocktable params)
      (buffer-substring-no-properties origin (point-max)))))

(defun claude-code-ide-org-clock-report (&optional id block tstart tend)
  "Summarize clocked time as an org clocktable report — the same
machinery behind `org-clock-report'/column view — returned as a
plain string.  Never creates or modifies any file.

If ID is given, scope to that heading's subtree only.  Otherwise
scope to every file in `claude-code-ide-org--tracked-files' (the
same file list `claude-code-ide-org-query' searches).

BLOCK, if given, selects a named range recognized by
`org-clock-special-range': \"today\", \"yesterday\", \"thisweek\",
\"lastweek\", \"thismonth\", \"lastmonth\", \"thisyear\", \"lastyear\",
or \"untilnow\".  TSTART/TEND, given instead of BLOCK, are explicit
org timestamp strings bounding the range, e.g. \"[2026-07-21 Tue]\".
If neither BLOCK nor a TSTART/TEND pair is given, the report is
unrestricted — all clocked time found in scope.  BLOCK takes
precedence if both it and a TSTART/TEND pair are given.

Returns the clocktable's text (a headline/time breakdown and total),
or an error string (e.g. for an unknown :ID: or an unrecognized
BLOCK).  Never signals an error to the MCP layer."
  (condition-case err
      (let ((params (list :maxlevel 10)))
        (cond
         (block (setq params (plist-put params :block (intern block))))
         ((and tstart tend)
          (setq params (plist-put params :tstart tstart))
          (setq params (plist-put params :tend tend))))
        (if id
            (claude-code-ide-org--at-id
             id
             (lambda ()
               (claude-code-ide-org--clocktable-string
                params (claude-code-ide-org--subtree-text-at-point))))
          (claude-code-ide-org--clocktable-string
           (plist-put params :scope (claude-code-ide-org--tracked-files)))))
    (error (format "Error: %s" (error-message-string err)))))

;;; Native transition enforcement --------------------------------------------
;;
;; CLAUDE.md's transition table (TODO->DOING opens a clock, DOING->DONE
;; closes it, etc.) is otherwise pure prose: nothing stops a hand-edit
;; made directly in Emacs, or some future tool call, from violating it.
;; These two hooks enforce it structurally, inside org itself, so they
;; catch violations regardless of how the state change happened -- not
;; just through `claude-code-ide-org-set-todo'.
;;
;; Both org-blocker-hook and org-trigger-hook are plain defvars in
;; org.el itself, present the instant (provide 'org) fires, and
;; add-hook only ever stores a symbol -- it never invokes it. So
;; registering here via `with-eval-after-load' 'org (not Doom's
;; `after!', which never fires under the plain `emacs --batch -Q' load
;; path config-test.el deliberately uses) is safe, and every actual
;; org-clock.el call stays lazily inside the hook lambdas themselves,
;; never at registration or load time.
;;
;; Always `add-hook', never `setq', on these two hook variables --
;; other work may add its own functions to the same hooks, and
;; `add-hook' composes regardless of load/merge order while `setq'
;; would clobber whatever is already there.

(defvar claude-code-ide-org--auto-clock-in-active nil
  "Re-entrancy guard for `claude-code-ide-org--trigger-auto-clock-in'.
Bound to t for the duration of that function's own `org-clock-in'
call, so if `org-clock-in' itself somehow triggers another DOING
state change on the same heading (e.g. a future
`org-clock-in-switch-to-state' configuration), the nested invocation
is a no-op instead of recursing.")

(defun claude-code-ide-org--blocker-clock-running-p (change-plist)
  "For `org-blocker-hook': deny a transition to DONE on the heading at
point when that heading's :ID: matches whichever heading
`org-clock-marker' currently points at -- i.e. its own clock is still
running. Identity-based, not source-state-based, so this already
covers a clocked PLANNING heading exactly as it does a clocked DOING
one, with no separate PLANNING-specific logic needed. Return non-nil
(permit the change) for every requested state
other than DONE, whenever nothing is currently clocking, or whenever
either heading lacks an :ID:. CHANGE-PLIST is the plist `org-todo'
passes to every `org-blocker-hook' function; see `org-trigger-hook's
docstring for its shape. Never reads `org-clock-marker' or calls any
other org-clock.el function except from inside this hook -- i.e.
never at load or registration time."
  (or (not (equal (plist-get change-plist :to) "DONE"))
      (not (org-clocking-p))
      (let ((target-id (org-entry-get nil "ID"))
            (clocked-id (org-with-point-at org-clock-marker
                          (org-entry-get nil "ID"))))
        (if (and target-id clocked-id (equal target-id clocked-id))
            (progn
              (setq org-block-entry-blocking (org-get-heading t t t t))
              nil)
          t))))

(defun claude-code-ide-org--container-heading-p ()
  "Non-nil when the heading at point has at least one descendant
carrying a TODO keyword -- norang's lazy definition of a project
\(https://doc.norang.ca/org-mode.html), adopted here so that being a
container is derived from structure rather than declared in a property
someone has to remember to maintain.

Used to exempt such headings from
`claude-code-ide-org--trigger-auto-clock-in'. The argument is that org
already rolls a subtree's time up to its parent natively -- a
clocktable's `:maxlevel' does it -- so clocking a container does not
*produce* a roll-up, it adds a second, differently-meaning quantity
*inside* the one that already existed, where it can no longer be told
apart from the children's sum. Measured on TODO.org :ID: b5f7c5c7 on
2026-08-12: parent row 14:52, ten children summing to 13:44, the 1:08
difference being exactly the epic's own two CLOCK lines.

Scans descendants rather than only direct children, matching norang's
own implementation. Note the exemption is deliberately narrow: it
suppresses only the *automatic* clock, never a deliberate
`org-clock-in' on a parent, since a parent's own coordination and
planning time is real and a blanket \"only clock leaves\" rule would
discard it."
  (save-excursion
    (save-restriction
      (widen)
      (org-back-to-heading t)
      (let ((subtree-end (save-excursion (org-end-of-subtree t t)))
            (found nil))
        (forward-line 1)
        (while (and (not found)
                    (< (point) subtree-end)
                    (re-search-forward org-heading-regexp subtree-end t))
          (when (org-get-todo-state) (setq found t)))
        found))))

(defun claude-code-ide-org--trigger-auto-clock-in (change-plist)
  "For `org-trigger-hook': the moment any heading's TODO state becomes
DOING or PLANNING, automatically open a clock on it via `org-clock-in',
unless a clock is already running on that exact heading, or the heading
is a container \(`claude-code-ide-org--container-heading-p'). Guarded
against re-entrancy by `claude-code-ide-org--auto-clock-in-active'.
CHANGE-PLIST is the plist `org-todo' passes to every
`org-trigger-hook' function; see `org-trigger-hook's own docstring for
its shape. Never calls `org-clock-in' or reads `org-clock-marker'
except from inside this hook -- i.e. never at load or registration
time.

*Which paths actually reach it, corrected 2026-08-17.* This said \"via
`claude-code-ide-org-set-todo', a hand-edit made directly in Emacs, or
any other path at all\".  The first has been dead since the 2026-08-11
cutover: `claude-code-ide-org-set-todo' appends a queue event and never
calls `org-todo', so it cannot reach `org-trigger-hook' at all.

What is left is narrower than \"any path at all\" in a second way too.
`claude-code-ide-org--review-apply-item' binds
`claude-code-ide-org--auto-clock-in-active' around the whole apply, and
that test precedes the container test below -- so on the apply path this
hook short-circuits for *every* heading, container or leaf, and the
container exemption is unreachable there.

So the container exemption does its work in exactly one place: a TODO
state changed by hand in Emacs (`C-c C-t', `S-right'), which is the
scenario that raised it (TODO.org :ID: ab75d6d2).  The exemption's
*rationale* is unaffected by any of this and still holds -- see that
heading for the measurement."
  (when (and (member (plist-get change-plist :to) '("DOING" "PLANNING"))
             (not claude-code-ide-org--auto-clock-in-active)
             (not (claude-code-ide-org--container-heading-p)))
    (let* ((target-id (org-entry-get nil "ID"))
           (already-clocked-here
            (and (org-clocking-p)
                 target-id
                 (equal target-id
                        (org-with-point-at org-clock-marker
                          (org-entry-get nil "ID"))))))
      (unless already-clocked-here
        (let ((claude-code-ide-org--auto-clock-in-active t))
          (org-clock-in))))))

;; `--maybe-record-planning-owner' and `--promote-planning-to-doing'
;; stood here until the 2026-08-11 cutover (TODO.org :ID:
;; feba67eb-35b3-48bd-a892-8ecd47ca52e0). Between them they implemented
;; the PLANNING -> DOING auto-promotion on ExitPlanMode: one recorded
;; which session had set PLANNING, the other promoted the heading that
;; owned the running clock if that session matched.
;;
;; Both inputs are gone -- no clock runs, and no MCP tool sets a state --
;; so the promotion moved into bin/hooks/exitplanmode-promote-planning,
;; which reads the session's own queue file for the heading it most
;; recently queued PLANNING on and appends a DOING event beside it. The
;; cross-session guard the owner variable provided comes free there: the
;; file is per-session, so another session's PLANNING is not in it to be
;; found.

;;; Single NEXT action per level ----------------------------------------------
;;
;; GTD's "single next action" idea: at any given level of the task
;; tree -- top-level headings, and independently among each heading's
;; own direct children -- at most one heading should ever be NEXT at a
;; time. Two more org-trigger-hook functions, same mechanism as the
;; pair above, applied to a new invariant.
;;
;; Deliberately no re-entrancy boolean guard (unlike
;; claude-code-ide-org--auto-clock-in-active above): a blanket
;; "skip while re-entrant" guard would disable exactly the nested
;; re-derivation that prevents a double-NEXT race (see the promote
;; function's docstring). Correctness is structural instead:
;; org-trigger-hook runs at the very end of org-todo, so a nested
;; org-todo call cannot corrupt outer work still pending; demote only
;; moves NEXT->TODO and only fires on :to "NEXT" (a heading it just
;; demoted can't re-satisfy that precondition on itself); promote only
;; moves TODO->NEXT (a heading it just promoted no longer counts as a
;; TODO candidate) -- so recursion depth is bounded by sibling count,
;; not unbounded. Refile/capture never triggers either function since
;; neither goes through org-todo; an invariant violation introduced
;; that way is only corrected lazily, on that group's next actual
;; state change.

(defun claude-code-ide-org--map-siblings (function &optional include-self)
  "Call FUNCTION with point at each same-level sibling of the heading
at point -- headings sharing the same parent, or, for top-level
headings, sharing no parent. Self (the heading originally at point) is
included only when INCLUDE-SELF is non-nil. `org-get-next-sibling'/
`org-get-previous-sibling' naturally stop at the enclosing parent's
boundary, or the file's boundary for top-level headings, so top-level
headings need no special-casing. Point is restored afterward."
  (save-excursion
    (org-back-to-heading t)
    (when include-self (funcall function))
    (save-excursion (while (org-get-next-sibling) (funcall function)))
    (save-excursion (while (org-get-previous-sibling) (funcall function)))))

(defun claude-code-ide-org--format-log-state-line (new-state old-state cause)
  "Format a single :LOGBOOK: line matching org's own native
`org-log-note-headings' \"state\" template (\"State %-12s from %-12s
%t\"), but with CAUSE as the note text instead of one typed
interactively. Used by automatic transitions that already know exactly
why they fired, so they can produce output indistinguishable from a
real interactively-logged state change without ever going through
org's own note-prompt machinery."
  (format "- State %-12s from %-12s %s \\\\\n  %s"
          (format "\"%s\"" new-state)
          (format "\"%s\"" old-state)
          (format-time-string "[%Y-%m-%d %a %H:%M]")
          cause))

(defun claude-code-ide-org--trigger-demote-conflicting-next (change-plist)
  "For `org-trigger-hook': GTD's \"single next action\" per level. The
moment any heading's TODO state becomes NEXT, demote every OTHER
heading in the same sibling group that is currently NEXT back to TODO,
with an explanatory :LOGBOOK: note. No-op unless CHANGE-PLIST's :to is
\"NEXT\". Demoting a sibling re-enters `org-todo' (hence this hook)
for that sibling -- safe by construction, see
`claude-code-ide-org--trigger-auto-promote-sole-todo's docstring. The
nested `org-todo' call is wrapped in `org-inhibit-logging' so org's own
native logging (an interactive note-prompt, if TODO or NEXT is ever
marked `@' in the future) never fires for this programmatic
transition; `claude-code-ide-org--format-log-state-line' supplies an
equivalent line by hand instead."
  (when (equal (plist-get change-plist :to) "NEXT")
    ;; Name the superseding sibling by an [[id:...]] link rather than a
    ;; bare title. Titles are not stable here -- headings get retitled as
    ;; their scope becomes clearer, which is exactly why every tool in
    ;; this module addresses by :ID: -- so a quoted title silently becomes
    ;; wrong, and the note is the one place a reader would go to find out
    ;; *why* something was demoted. The link is also navigable, which a
    ;; quoted title is not. Falls back to the quoted title when the
    ;; sibling has no :ID:, since a slightly stale note beats no note.
    (let* ((new-next-heading (org-get-heading t t t t))
           (new-next-id (org-entry-get nil "ID"))
           (reference (if new-next-id
                          (format "[[id:%s][%s]]" new-next-id new-next-heading)
                        (format "\"%s\"" new-next-heading))))
      (claude-code-ide-org--map-siblings
       (lambda ()
         (when (equal (org-get-todo-state) "NEXT")
           (let ((org-inhibit-logging t)) (org-todo "TODO"))
           (claude-code-ide-org--append-to-drawer
            "LOGBOOK"
            (claude-code-ide-org--format-log-state-line
             "TODO" "NEXT"
             (format "Auto-demoted: superseded by sibling %s becoming NEXT."
                     reference)))))))))

(defun claude-code-ide-org--trigger-auto-promote-sole-todo (_change-plist)
  "For `org-trigger-hook': whenever this heading's sibling group (self
included, group size >= 2) has exactly one member in TODO and none in
NEXT, promote that lone TODO to NEXT, with an explanatory :LOGBOOK:
note. Deliberately unconditional on CHANGE-PLIST's :to -- a transition
to DONE/CANCELLED/WAIT/MAYBE/DOING on ANY sibling can be what drops
the group to one TODO survivor, not just a transition into/out of
NEXT. Always re-derives group state fresh from the live buffer, never
from CHANGE-PLIST -- this is what keeps this safe against re-promoting
a heading that `claude-code-ide-org--trigger-demote-conflicting-next'
just demoted: by the time this function evaluates, any sibling still
NEXT already shows as NEXT in the buffer, so the next-p guard below
correctly refuses to create a second simultaneous NEXT. A group of
size 1 (no siblings) is never eligible -- auto-promotion only resolves
conflicts among competing candidates, it is not a rule that a solitary
heading must always be NEXT."
  (let (todo-markers next-p (group-size 0))
    (claude-code-ide-org--map-siblings
     (lambda ()
       (setq group-size (1+ group-size))
       (let ((state (org-get-todo-state)))
         (cond ((equal state "NEXT") (setq next-p t))
               ((equal state "TODO") (push (point-marker) todo-markers)))))
     'include-self)
    (when (and (> group-size 1) (not next-p) (= (length todo-markers) 1))
      (org-with-point-at (car todo-markers)
        (let ((org-inhibit-logging t)) (org-todo "NEXT"))
        (claude-code-ide-org--append-to-drawer
         "LOGBOOK"
         (claude-code-ide-org--format-log-state-line
          "NEXT" "TODO" "Auto-promoted: sole remaining TODO in its sibling group."))))))

(with-eval-after-load 'org
  (add-hook 'org-blocker-hook #'claude-code-ide-org--blocker-clock-running-p)
  (add-hook 'org-trigger-hook #'claude-code-ide-org--trigger-auto-clock-in)
  (add-hook 'org-trigger-hook #'claude-code-ide-org--trigger-demote-conflicting-next)
  (add-hook 'org-trigger-hook #'claude-code-ide-org--trigger-auto-promote-sole-todo))

;;; Clock status file -------------------------------------------------------
;;
;; org-clock-in-hook/org-clock-out-hook write the currently-clocked
;; heading (or idle) to a small JSON file, so something outside Emacs —
;; a Warp status line, a menu bar widget — can answer "what's Claude
;; doing right now" at a glance without opening Emacs.
;;
;; Wired via add-hook at load time below, not inside the
;; claude-code-ide-org-clock-in/-out wrappers above, so a clock-in/out
;; done by hand directly in Emacs (not via the MCP tools) updates the
;; status file too.
;;
;; Two separate named handlers, one per hook, rather than one shared
;; function branching on org-clocking-p: org-clock-out already clears
;; org-clock-marker/org-clock-hd-marker (via move-marker ... nil)
;; *before* it runs org-clock-out-hook, so org-clocking-p is already
;; nil by the time this runs — but that ordering is an internal detail
;; of org-clock.el, not something to depend on. The out-handler always
;; writes the idle object unconditionally; the in-handler always writes
;; the active object unconditionally. Each is add-hook'd with a defun,
;; not a lambda, so re-loading this file (as bin/test does) or another
;; branch's own add-hook onto the same hook variables (e.g. a parallel
;; tool-call audit log) composes cleanly instead of accumulating
;; duplicate anonymous closures.

(defcustom claude-code-ide-org-clock-status-file
  (expand-file-name "clock-status.json"
                     (file-name-directory
                      (or load-file-name buffer-file-name default-directory)))
  "Path to the JSON file that always reflects current clock state:
the active heading/:ID:/start time, or an idle object when nothing
is clocked in. Written by `claude-code-ide-org--clock-status-hook-in'
and `claude-code-ide-org--clock-status-hook-out', hooked onto
`org-clock-in-hook'/`org-clock-out-hook'. Defaults next to this file,
inside the repo; gitignored, since it is pure runtime state, not
something to track."
  :type 'file
  :group 'claude-code-ide-org)

(defun claude-code-ide-org--write-clock-status (data)
  "Atomically write DATA — an alist suitable for `json-encode' — to
`claude-code-ide-org-clock-status-file'. Writes to a sibling temp
file in the same directory first, then `rename-file's it into place,
so a poller reading the status file never observes a half-written
one (a cross-filesystem rename would not be atomic, hence \"sibling\").
Does nothing, rather than signaling, if the target directory does
not exist yet."
  (let* ((target claude-code-ide-org-clock-status-file)
         (dir (file-name-directory target)))
    (when (file-directory-p dir)
      (let ((tmp (make-temp-file (expand-file-name ".clock-status-" dir))))
        (with-temp-file tmp
          (insert (json-encode data)))
        (rename-file tmp target t)))))

(defun claude-code-ide-org--clock-status-active-data ()
  "Return the alist describing the currently-active clock, built
from org's own clock globals (`org-clock-heading',
`org-clock-start-time', `org-clock-hd-marker') rather than point —
`org-clock-in-hook' runs with those already set, but does not
guarantee point is on the clocked-in heading."
  `((active . t)
    (heading . ,org-clock-heading)
    (id . ,(org-with-point-at org-clock-hd-marker (org-id-get)))
    (start . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z" org-clock-start-time))))

(defun claude-code-ide-org--clock-status-hook-in ()
  "`org-clock-in-hook' handler: write the active clock object to
`claude-code-ide-org-clock-status-file'. Wrapped in `condition-case'
— an error here must never propagate back into org's own clock-in
machinery, so any failure here is swallowed silently rather than
risking a corrupted clock-in."
  (condition-case nil
      (claude-code-ide-org--write-clock-status
       (claude-code-ide-org--clock-status-active-data))
    (error nil)))

(defun claude-code-ide-org--clock-status-hook-out ()
  "`org-clock-out-hook' handler: write the idle object to
`claude-code-ide-org-clock-status-file', unconditionally — the
out-hook always means \"nothing is clocked in now\", regardless of
whatever org-clock-marker/org-clock-heading/etc. still happen to
hold at this point in org-clock.el's internal hook ordering. Wrapped
in `condition-case', same reasoning as the in-handler."
  (condition-case nil
      (claude-code-ide-org--write-clock-status '((active . :json-false)))
    (error nil)))

(add-hook 'org-clock-in-hook #'claude-code-ide-org--clock-status-hook-in)
(add-hook 'org-clock-out-hook #'claude-code-ide-org--clock-status-hook-out)

;; Emacs-restart case: org-clock-persist is 'history (not 'clock/t — see
;; the "Why no explicit clock-persistence-restore call" design note in
;; CLAUDE.md), so a restart never auto-resumes an in-memory clock, and
;; every actual resume path (org-clock-in / org-clock-in-last) already
;; fires org-clock-in-hook above. The only gap is a status file left
;; over from a *previous* Emacs session showing "active" when this one
;; starts out idle; correct that once org-clock is actually loaded,
;; without ever calling org-clock-load/org-clock-persist-load ourselves
;; (that footgun is why this is deferred to with-eval-after-load rather
;; than called eagerly at top level here). Skipped under `noninteractive'
;; (i.e. `bin/test's `emacs --batch') — a fresh batch process has no
;; previous session's stale status file to correct, and firing here
;; unconditionally would otherwise write to the *default* (real, in-
;; repo) status path on every test run, since this runs before any
;; test's own let-binding of `claude-code-ide-org-clock-status-file'
;; is in effect.
(unless noninteractive
  (with-eval-after-load 'org-clock
    (unless (org-clocking-p)
      (claude-code-ide-org--clock-status-hook-out))))

;;; Background planning write-back ----------------------------------------

(defun claude-code-ide-org--insert-plan-link (plan-file)
  "Insert a `[[file:PLAN-FILE][Plan]]' link into the body of the
heading at point, unless a Plan link is already present there.
Inserted after the property drawer and any :LOGBOOK:
drawers, per this project's Plan-link convention (see CLAUDE.md).
Idempotent regardless of PLAN-FILE's value -- a heading only ever
carries one Plan link, matching CLAUDE.md's \"the link is written
once and never needs updating\" rule for plan revisions."
  (org-back-to-heading t)
  (let ((end (save-excursion (outline-next-heading) (point))))
    (unless (save-excursion
              (re-search-forward "\\[\\[file:[^]]*\\]\\[Plan\\]\\]" end t))
      (org-end-of-meta-data t)
      (unless (bolp) (insert "\n"))
      (insert (format "[[file:%s][Plan]]\n\n" plan-file)))))

(defun claude-code-ide-org-log-background-plan (id plan-file session-id)
  "Record a completed background-planning pass on the heading whose
:ID: property equals ID by inserting a Plan-file link (idempotent, see
`claude-code-ide-org--insert-plan-link').  Never transitions TODO state
and never touches the clock -- the single shared clock cannot represent
true parallelism honestly, so this tool structurally cannot produce a
CLOCK/:LOGBOOK: entry.

SESSION-ID is accepted and no longer recorded.  It used to tag a
\"Background-planned\" entry in the heading's :SESSIONS: drawer with a
*synthetic* id (e.g. \"<real-session-id>-bg1\"), so unattended research
time was never misattributed as the orchestrating session's own
interactive work.  That drawer was retired 2026-08-11 (TODO.org :ID:
9d2fcdad-9bf7-47b6-8018-223b13ec4577) and its entries deleted, including
these -- a deliberate choice, made knowing this was the only record of
which session background-planned a heading and when.  The argument
against keeping them: a drawer surviving for one rare entry is worse
than either clean outcome, and the queue is where per-session
attribution belongs now.  The parameter stays in the signature so the
MCP tool schema and its callers are unaffected; wire it to a queued
event if that attribution is ever wanted back."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (claude-code-ide-org--insert-plan-link plan-file)
     (save-buffer)
     (format "Logged background plan for \"%s\"." (org-get-heading t t t t)))))

;;; Event queue ------------------------------------------------------------
;;
;; The read side of the append-only event queue (TODO.org :ID:
;; 32272061-1d78-4726-b13b-90338edb2ba5, under the refactor at :ID:
;; b5f7c5c7-7ad6-4c68-9cce-3479db1f1644). Sessions append events via
;; bin/hooks/queue-append; this layer reads them back.
;;
;; Three layers, and only the middle one is lossy -- in presentation only:
;;
;;   queue file (append-only, raw) -> ingestion (aggregated) -> apply (exact)
;;
;; Deliberately pure data: no writing to org buffers, no org state, no
;; point. Everything here is a function from files to lists, which is what
;; makes it cheap to test and safe to call from anywhere. The consumers --
;; the review-and-apply command (720b2dcf), the pending-queue tool
;; (63a642c7) and the statusline (290b6fc5) -- all share it rather than
;; parsing the queue three separate times, per 63a642c7's own instruction.

(defcustom claude-code-ide-org-queue-directory
  (expand-file-name "org-updates" "~/.claude")
  "Directory holding per-session append-only event queue files.
Each Claude Code session writes to \"<session-id>.jsonl\" here -- one
writer per file, so appends never contend -- alongside a sibling
\"<session-id>.applied\" watermark recording how far a review pass has
consumed. Kept outside the repository: these are runtime state, not
tracked content, and they span every project a session touches."
  :type 'directory
  :group 'claude-code-ide-org)

(defcustom claude-code-ide-org-consolidate-on-apply t
  "Whether apply normalises the drawer of each heading it writes to.

Set nil to leave drawers exactly as org built them, newest-CLOCK-first
and interleaved with notes in insertion order.

Decided 2026-08-13 (TODO.org :ID: 12e0adac).  Consolidation was kept off
the apply path because it used to round intervals to 5 minutes and drop
what became zero -- but that was retired in :ID: b74e0f19, and the
justification outlived it in a comment that read as settled.  With
rounding gone, `claude-code-ide-org--consolidate-logbook-text' is
idempotent and provably lossless: :ID: af7d3687 pinned it as a
byte-identical fixed point against `clock-template.org' and asserted a
second pass is a no-op.

Scoped deliberately to the heading apply is *already writing*, not the
file.  Apply's claim is that it writes what the human confirmed and
nothing else; reordering a drawer it is opening anyway stretches that,
reordering drawers it never touched would break it.  A bug here damages
one heading's history, which is also the one place a human is about to
look."
  :type 'boolean
  :group 'claude-code-ide-org)

(defcustom claude-code-ide-org-queue-idle-seconds 3600
  "Seconds a queue file must go untouched before it counts as finished.

Guards the one way archiving can lose data silently.
`bin/hooks/queue-append' appends with `>>', which *recreates* a missing
file -- so moving the queue of a session that is still writing does not
stop it writing.  It splits that session's stream across an archived
file the reader no longer scans and a fresh one it does.  Nothing
errors; the older half simply stops being consulted, mid-session.

Emacs cannot ask which session is live: `session_id' only ever appears
on hook stdin and never reaches an MCP tool (TODO.org :ID: 32272061), so
mtime is the available signal rather than the ideal one.  An hour is
deliberately generous -- archiving late costs nothing, archiving early
costs a split stream."
  :type 'integer
  :group 'claude-code-ide-org)

(defcustom claude-code-ide-org-guidepost-gap-threshold 1200
  "Seconds between consecutive guideposts below which they collapse
into one span for review, in `claude-code-ide-org--aggregate-guideposts'.

Purely a presentation control: the queue files themselves always keep
every raw event, so raising or lowering this never destroys anything and
never needs a migration.

Was 900 until 2026-08-13, when the retune its own docstring called for
finally had data to stand on: 422 queue events over four days (TODO.org
:ID: 96a51c2f).  `pause' -> `resume' latency is sharply bimodal, and the
two modes are separated by a band containing *no observations at all* --
the longest short gap is 1061s and the shortest long gap 2070s.  A
threshold sweep sees the same hole from the other side: span count is
flat at 29 across 1200-1800s, so every value inside the band yields an
identical reconstruction.  900s sat just below it and split five spans
nothing in the data justifies splitting.

1200s is the round number inside the band, at the start of that plateau
with margin on both sides.  Still a default, not a law: n=150 gaps from
one person over four days, so it is *better founded* rather than
settled, and the heading above schedules a re-measure."
  :type 'integer
  :group 'claude-code-ide-org)

(defcustom claude-code-ide-org-span-evidence-slack 300
  "Seconds past an unassigned span's end still counted as its window.

Extends the *end* only, and the asymmetry is the finding rather than an
implementation convenience (TODO.org :ID: 5ff5a4b8).  A `:CREATED:'
stamp lands while the work is happening, so it falls inside the span on
its own; a commit timestamp marks when work was *finished*, so the
commit that concludes a span reliably lands just after it.  Widening the
start instead would only pull in the previous span's commits.

Five minutes because the observed lag was seconds, not minutes -- a
4-minute span preceded its commit by seconds.  The margin is for the
case where the human kept typing a commit message after the last
guidepost, not for a genuinely later commit, which belongs to whatever
came next."
  :type 'integer
  :group 'claude-code-ide-org)

(defcustom claude-code-ide-org-span-evidence-limit 8
  "Most evidence lines rendered under one unassigned span.

A bound on the *display*, not on the query: the point of the evidence is
to make one span assignable at a glance, and a span that swept up thirty
commits has stopped answering that question.  Anything beyond the limit
is reported as a count, so a flooded window reads as flooded rather than
as silently trimmed.

Eight covers the observed worst case with room to spare -- the widest
span measured, 23 minutes, contained three commits."
  :type 'integer
  :group 'claude-code-ide-org)

(defcustom claude-code-ide-org-span-evidence-gap 300
  "Seconds of unattested time inside a span worth reporting as a gap.

Added 2026-08-14 after the first real use of the evidence lines, which
found the opposite defect from the one expected.  The evidence was
*persuasive*: the reviewer read it, found it reasonable, and applied the
batch without evaluating it critically.  That is the anchoring objection
recorded against TODO.org :ID: 0c8644ff arriving by another route --
showing more support for a suggestion makes it easier to accept, not
easier to reject.

Gaps invert that, which is the whole point of reporting them.  A commit
list answers \"here is support for the suggestion\"; the stretches with
nothing in them answer \"here is what you still have to decide\", which
is the posture review is supposed to have.  The evidence-free span is
the case that matters most: it used to render no lines at all, making
\"nothing was found here\" visually identical to \"nobody looked\".

Five minutes because a gap has to be longer than the ordinary pause
between a thought and its commit before it means anything.  Measured
against the span itself, never the slack window -- a commit *after* the
span concluded it rather than filled it."
  :type 'integer
  :group 'claude-code-ide-org)

(defconst claude-code-ide-org--queue-kinds
  '("todo" "clock_in" "clock_out" "pause" "resume" "capture" "amend"
    "block_start" "block_end")
  "Event kinds bin/hooks/queue-append is allowed to emit.
A line carrying anything else is treated as unparseable and skipped, so
a future writer emitting a kind this Emacs does not know about degrades
to \"ignored\" rather than \"crashes the review command\".")

(defun claude-code-ide-org--queue-file (session-id)
  "Return the queue file path for SESSION-ID."
  (expand-file-name (concat session-id ".jsonl")
                    claude-code-ide-org-queue-directory))

(defun claude-code-ide-org--queue-watermark-file (session-id)
  "Return the watermark file path for SESSION-ID."
  (expand-file-name (concat session-id ".applied")
                    claude-code-ide-org-queue-directory))

(defun claude-code-ide-org--queue-session-ids ()
  "Return the session ids that currently have a queue file, sorted."
  (when (file-directory-p claude-code-ide-org-queue-directory)
    (sort (mapcar #'file-name-base
                  (directory-files claude-code-ide-org-queue-directory
                                   nil "\\.jsonl\\'" t))
          #'string<)))

(defun claude-code-ide-org--queue-files ()
  "Return the absolute path of every pending queue file, sorted by
session id."
  (mapcar #'claude-code-ide-org--queue-file
          (claude-code-ide-org--queue-session-ids)))

(defun claude-code-ide-org--parse-iso8601 (string)
  "Parse STRING, an ISO 8601 timestamp with offset, to a time value.
Returns nil rather than signaling if STRING is not parseable -- callers
here treat an unparseable timestamp as an unparseable event.

Shape-checks STRING before parsing rather than relying on
`date-to-time' to reject junk: `date-to-time' is deliberately lenient
and happily returns a time for input with no recognizable date in it at
all, defaulting the fields it could not read. A garbage timestamp would
then parse to some point near the epoch and sort *ahead* of every real
event -- silently corrupting ordering instead of being skipped, which is
far worse than the malformed line it came from."
  (when (and (stringp string)
             (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[T ]"
                             string))
    (ignore-errors (date-to-time string))))

(defun claude-code-ide-org--queue-parse-line (line)
  "Parse one JSONL queue LINE into a plist, or nil if unusable.
Nil covers a torn final line from a hard crash, a line from a writer
emitting an unknown `kind', and anything whose timestamp will not parse
-- all of which must cost exactly one event rather than failing the
whole file. This is the single place that judgement is made."
  (let ((obj (ignore-errors
               (json-parse-string line :object-type 'alist
                                  :null-object nil :false-object nil))))
    (when obj
      (let ((kind (alist-get 'kind obj))
            (ts (claude-code-ide-org--parse-iso8601 (alist-get 'ts obj))))
        (when (and ts (member kind claude-code-ide-org--queue-kinds))
          (list :ts ts
                :ts-string (alist-get 'ts obj)
                :kind kind
                :id (alist-get 'id obj)
                :state (alist-get 'state obj)
                ;; The state the heading held when the event was queued,
                ;; or nil on events written before the field existed.
                ;; "none" is a real value meaning "no keyword", kept
                ;; distinct from nil meaning "unknown" -- see
                ;; `claude-code-ide-org--review-state-stale-p'.
                :from (alist-get 'from obj)
                :note (alist-get 'note obj)
                ;; capture: what heading to write and where. amend: the
                ;; prose to append. Null on every other kind, and on
                ;; events written before these kinds existed.
                :title (alist-get 'title obj)
                :target (alist-get 'target obj)
                :tags (alist-get 'tags obj)
                :text (alist-get 'text obj)
                ;; Which tool call a permission block belongs to, so
                ;; block_start/block_end pair by identity rather than by
                ;; position -- tool calls interleave. Null on every other
                ;; kind (TODO.org :ID: f4e628ce).
                :tool-use-id (alist-get 'tool_use_id obj)
                :session-id (alist-get 'session_id obj)
                :agent-id (alist-get 'agent_id obj)
                :agent-type (alist-get 'agent_type obj)
                :source (alist-get 'source obj)))))))

(defun claude-code-ide-org--queue-applied (session-id)
  "Return the set of SESSION-ID's already-applied event timestamps.
A hash table keyed by `ts' string; empty when nothing has been applied.

A *set* rather than a high-water mark, deliberately. A watermark can
only describe a contiguous prefix, and review is not contiguous: a human
applies the two items they care about and leaves the rest, whose events
sit earlier in the same file. A watermark then cannot advance at all --
observed 2026-08-07, where a real apply wrote no watermark whatsoever and
every applied item would have been re-proposed, and re-applied, on the
next pass. Per-event is the honest model for per-item review."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (ts (alist-get 'applied
                           (claude-code-ide-org--queue-watermark-data session-id)))
      (puthash ts t table))
    table))

(defun claude-code-ide-org--queue-watermark-data (session-id)
  "Return SESSION-ID's parsed watermark file as an alist, or nil.

One reader for the whole file, because it carries two independent facts
-- `applied' and `dismissed' -- and every writer therefore has to
round-trip the one it is not changing. A writer that serialized only its
own key would silently erase the other, and that failure is a nasty one
to diagnose from the symptom: dismissed items quietly reappearing reads
as \"dismissal does not work\" rather than \"apply clobbered it\"."
  (let ((file (claude-code-ide-org--queue-watermark-file session-id)))
    (when (file-readable-p file)
      (ignore-errors
        (json-parse-string
         (with-temp-buffer
           (insert-file-contents file)
           (buffer-string))
         :object-type 'alist :array-type 'list
         :null-object nil :false-object nil)))))

(defun claude-code-ide-org--queue-dismissed (session-id)
  "Return SESSION-ID's dismissed events, a hash of `ts' string -> reason.

Dismissal is for an item that will *never* apply, which the applied set
cannot express: skipping is how a human defers, and the watermark
rightly refuses to consume a merely-deferred item. Without a third
answer an item like the `dead-beef' phantom clock -- whose :ID: cannot
resolve, ever -- reappears at every review for the rest of time, and the
only exits are hand-editing an append-only queue or forging watermark
entries.

Carries a reason rather than being a bare set because \"already applied
live pre-cutover\" and \"this event should never have existed\" want
different treatment at any later audit, and the reason costs one
`read-string'."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (cell (alist-get 'dismissed
                             (claude-code-ide-org--queue-watermark-data session-id)))
      (puthash (format "%s" (car cell)) (cdr cell) table))
    table))

(defun claude-code-ide-org--queue-watermark-write (session-id applied dismissed)
  "Write both APPLIED and DISMISSED for SESSION-ID, atomically.

The single writer for the watermark file. Both callers pass both facts,
which is what makes clobbering one by writing the other impossible by
construction rather than by remembering."
  (claude-code-ide-org--atomic-write
   (claude-code-ide-org--queue-watermark-file session-id)
   (json-encode
    ;; An empty set serializes as `[]'/`{}', never `null'.  Elisp spells
    ;; the empty list, the empty object and JSON null all as nil, so
    ;; `json-encode' would happily emit `null' and this reader would
    ;; happily accept it -- the round-trip works only because both ends
    ;; are lossy in the same direction.  No other JSON stack is: the
    ;; common `d.get("applied", [])' idiom does not fall back when the
    ;; key is present holding null, so the field would be an array
    ;; sometimes and null others, which is not a shape worth handing to
    ;; whatever eventually reports on these files.  A vector and a hash
    ;; table are how you say "empty, and still an array/object" here.
    `((applied . ,(let (all)
                    (maphash (lambda (k _) (push k all)) applied)
                    (if all (sort all #'string<) [])))
      (dismissed . ,(let (all)
                      (maphash (lambda (k v) (push (cons (intern k) v) all)) dismissed)
                      (if all
                          (sort all (lambda (a b)
                                      (string< (symbol-name (car a))
                                               (symbol-name (car b)))))
                        (make-hash-table))))))))

(defun claude-code-ide-org--queue-mark-dismissed (session-id ts-strings reason)
  "Record TS-STRINGS as permanently dismissed for SESSION-ID, with REASON.

Records a fact *beside* the queue and destroys nothing: the queue file
itself is never touched, so undoing a dismissal means deleting one key
from a small JSON file. That is deliberate -- an append-only log stays
append-only, and the decision to retire an event is bookkeeping about
the log, not an edit to it."
  (let ((dismissed (claude-code-ide-org--queue-dismissed session-id)))
    (dolist (ts ts-strings) (puthash ts (or reason "") dismissed))
    (claude-code-ide-org--queue-watermark-write
     session-id
     (claude-code-ide-org--queue-applied session-id)
     dismissed)))

(defun claude-code-ide-org--atomic-write (path string)
  "Write STRING to PATH atomically, via a sibling temp file and rename.
Generalizes the temp-then-`rename-file' pattern
`claude-code-ide-org--write-clock-status' already uses for the status
file, so a concurrent reader never observes a half-written file. The
sibling (rather than a $TMPDIR) temp file is what makes the rename
atomic -- a cross-filesystem rename is not."
  (let ((dir (file-name-directory path)))
    (make-directory dir t)
    (let ((tmp (make-temp-file (expand-file-name ".queue-tmp-" dir))))
      (with-temp-file tmp (insert string))
      (rename-file tmp path t))))

(defun claude-code-ide-org--queue-mark-applied (session-id ts-strings)
  "Add TS-STRINGS to SESSION-ID's set of applied events.
Unions with whatever is already recorded, so a partial apply followed by
another partial apply accumulates rather than replacing.

Never truncates or rewrites the queue file itself: the session that owns
it may still be appending, and racing an appending writer is exactly the
class of bug this refactor exists to remove. Applied state is therefore
recorded beside the log, never in it.

Round-trips the `dismissed' map untouched. It shares this file, and
writing only `applied' would erase every dismissal the moment anything
was applied -- see `claude-code-ide-org--queue-watermark-data'."
  (let ((applied (claude-code-ide-org--queue-applied session-id)))
    (dolist (ts ts-strings) (puthash ts t applied))
    (claude-code-ide-org--queue-watermark-write
     session-id applied
     (claude-code-ide-org--queue-dismissed session-id))))

(defun claude-code-ide-org--queue-events (&optional session-id include-consumed)
  "Return pending queue events, oldest first.
With SESSION-ID, read only that session's queue; otherwise read every
session's, merged and re-sorted by timestamp. Events already applied --
or explicitly dismissed, which is the answer for one that will never
apply -- are omitted. Unparseable lines are skipped silently, see
`claude-code-ide-org--queue-parse-line'.

With INCLUDE-CONSUMED non-nil, applied and dismissed events are returned
too.  Only for questions about *history* rather than about what is
pending -- `claude-code-ide-org--review-suggest-heading' is the caller
that needs it, because an applied `todo' event is the strongest possible
evidence of what was being worked on and the watermark would otherwise
hide exactly the confirmed ones.  Never use this to build review items:
it would re-propose work already applied."
  (let (events)
    (dolist (sid (if session-id (list session-id)
                   (claude-code-ide-org--queue-session-ids)))
      (let ((file (claude-code-ide-org--queue-file sid))
            (applied (if include-consumed (make-hash-table :test 'equal)
                       (claude-code-ide-org--queue-applied sid)))
            (dismissed (if include-consumed (make-hash-table :test 'equal)
                         (claude-code-ide-org--queue-dismissed sid))))
        (when (file-readable-p file)
          (dolist (line (split-string
                         (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))
                         "\n" t))
            (let ((event (claude-code-ide-org--queue-parse-line line)))
              (when (and event
                         (not (gethash (plist-get event :ts-string) applied))
                         (not (gethash (plist-get event :ts-string) dismissed)))
                (push event events)))))))
    (sort (nreverse events)
          (lambda (a b) (time-less-p (plist-get a :ts) (plist-get b :ts))))))

(defun claude-code-ide-org--pending-capture (id)
  "Return the pending queued `capture' event that will create ID, or nil.

The bridge across the sharpest edge in the write-through design
(TODO.org :ID: b5f94b88): a capture that deferred has minted its :ID:
and reported it, but the heading does not exist yet, so every later tool
call naming that id resolves to nothing.  Consulting the queue is what
tells \"not written yet\" apart from \"never existed\".

Reading the queue from a tool has precedent in
`claude-code-ide-org-pending-updates'."
  (seq-find (lambda (event)
              (and (equal (plist-get event :kind) "capture")
                   (equal (plist-get event :id) id)))
            (claude-code-ide-org--queue-events)))

(defun claude-code-ide-org--pending-capture-keywords (id)
  "TODO keywords legal for ID's pending capture, or nil if undeterminable.

Read from the file that capture's own target resolves to, rather than
from a list hard-coded here, for the same reason the resolved path reads
`org-todo-keywords-1' off the buffer: the answer belongs to the file.
Nil when the target cannot be resolved at all, which means \"cannot
check\" and must not be mistaken for \"nothing is legal\"."
  (let* ((event (claude-code-ide-org--pending-capture id))
         (file (and event
                    (or (ignore-errors
                          (plist-get (claude-code-ide-org--capture-target-spec
                                      (plist-get event :target))
                                     :file))
                        (claude-code-ide-org--capture-target-file)))))
    (when (and file (file-readable-p file))
      (with-current-buffer (find-file-noselect file)
        org-todo-keywords-1))))

(defun claude-code-ide-org--tolerating-pending-capture (id pending-fn resolve-fn)
  "Call RESOLVE-FN, falling back to PENDING-FN when ID is only pending.

RESOLVE-FN is the normal path and runs first, so the common case costs no
queue read at all.  When it fails *specifically* because the :ID: names
nothing -- not for any other error -- and a queued `capture' is going to
create exactly that heading, PENDING-FN is called with the pending
heading's title and its answer returned instead.

Narrow on purpose.  A genuinely unknown :ID: must still report an error,
because `bin/hooks/queue-append' drops any reply starting with `Error:'
and that drop is the only thing standing between a typo and an
unexplainable queue entry."
  (let ((result (funcall resolve-fn)))
    (if (and (stringp result)
             (string-prefix-p "Error: no org heading found" result))
        (let ((event (claude-code-ide-org--pending-capture id)))
          (if event
              (funcall pending-fn (or (plist-get event :title) "(untitled)"))
            result))
      result)))

(defun claude-code-ide-org--queue-events-by-id (&optional session-id)
  "Group pending events by the heading :ID: they belong to.
Returns an alist of (ID . EVENTS), plus an entry keyed nil for events
that could not be attributed to any heading.

`pause'/`resume' events are session-global -- nothing in them names a
heading -- so attribution is resolved by walking each session's stream
in order and tracking which heading its `clock_in'/`clock_out' events
last named. That is the entire reason those two kinds are retained: a
`todo' event alone cannot do this job, because returning to a heading
that never left DOING emits no `todo' event, and every subsequent
guidepost would silently attribute to the wrong heading.

That tracking is per *lane*, not per session: `agent_id' if the event
came from a subagent, the main session otherwise. Subagents share their
parent's `session_id', so concurrent ones interleave into a single
stream and a session-wide `current' would let them clobber each other
-- which they did, observably (TODO.org :ID: 0d789b68)."
  (let ((by-session (make-hash-table :test 'equal))
        (groups (make-hash-table :test 'equal))
        order)
    ;; Partition first: attribution is only meaningful within one session's
    ;; own ordered stream, never across the interleaving of several.
    (dolist (event (claude-code-ide-org--queue-events session-id))
      (push event (gethash (plist-get event :session-id) by-session)))
    (maphash
     (lambda (_sid events)
       ;; One `current' per *lane*, not per session. A subagent shares
       ;; its parent's session_id, so two concurrent agents interleave
       ;; into one stream; with a single `current' they clobber each
       ;; other, and since `org_clock_out' names no heading it resolves
       ;; against whichever clock_in happened to run last. Measured
       ;; 2026-08-12 (TODO.org :ID: 0d789b68): one agent's interval
       ;; landed in the nil bucket and produced no review item at all,
       ;; while the other paired correctly purely because the agents
       ;; finished LIFO. Reverse the finish order and the interval
       ;; attributes to the wrong heading with a plausible duration.
       ;;
       ;; Keying by agent_id also stops a subagent's clock_in from
       ;; capturing the human's pause/resume guideposts, which carry no
       ;; agent_id: those belong to the main lane's own current heading,
       ;; not to whatever a background agent happened to start.
       (let ((lanes (make-hash-table :test 'equal)))
         (dolist (event (nreverse events))
           (let* ((kind (plist-get event :kind))
                  (own-id (plist-get event :id))
                  (lane (or (plist-get event :agent-id) :main))
                  (id (cond
                       ((equal kind "clock_in")
                        (puthash lane own-id lanes)
                        own-id)
                       ((equal kind "clock_out")
                        (prog1 (or own-id (gethash lane lanes))
                          (remhash lane lanes)))
                       (own-id own-id)
                       (t (gethash lane lanes)))))
             (unless (member id order) (push id order))
             (push event (gethash id groups))))))
     by-session)
    (mapcar (lambda (id)
              (cons id
                    (sort (nreverse (gethash id groups))
                          (lambda (a b)
                            (time-less-p (plist-get a :ts) (plist-get b :ts))))))
            (nreverse order))))

(defun claude-code-ide-org--block-intervals (events)
  "Return (START . END) pairs for the permission blocks in EVENTS.

A block is the stretch between a `block_start' and the next `block_end'
-- the agent stalled waiting on a human to answer a permission prompt.
`Stop' cannot see this: it fires when a *turn* ends, and a turn blocked
mid-flight has not ended, so the run of guideposts continues straight
across the wait (TODO.org :ID: f4e628ce).

Paired by position rather than by `tool_use_id', and that is the
2026-08-14 correction rather than a simplification for its own sake.
`PermissionRequest' carries no `tool_use_id' -- the field is on
`PostToolUse' and absent from the event that opens the block -- so the
original key did not exist to pair on, and the hook that required it
refused every real payload.  Position is sound because prompts
serialise: measured the same day, two calls dispatched in one parallel
block still produced the second `PermissionRequest' only after the first
was approved, so at most one block is open at a time and interleaving
cannot arise.

Should a second `block_start' arrive while one is open anyway -- that
measurement is one trial, not a guarantee -- the later start wins and
the earlier is dropped, on the same reasoning as an unmatched start
below.

An unmatched `block_start' is *dropped*, not extended to the end of the
events.  It means the session died between the prompt and the tool
finishing, and choosing an end for it would be inventing the one number
nobody knows -- the class of guess :ID: 7771fc63 retired for being wrong
more often than right.  The cost of dropping is that such a block still
reads as work, which is a strictly smaller error than a fabricated one.

The interval covers the human's decision latency *plus* the tool's own
execution, since nothing signals the moment of approval separately.  For
the case this was built for -- 54m11s of waiting and seconds of running
-- that distinction is noise.  It would matter for a long-running
approved tool, and the overstatement is bounded by that tool's runtime."
  (let ((open nil)
        intervals)
    ;; Sorted explicitly rather than trusting the caller: the queue is
    ;; append-only and so arrives in order, but position is now the
    ;; whole pairing rule, and a fixture built out of order would pair
    ;; silently wrong instead of failing loudly.
    (dolist (e (sort (seq-filter
                      (lambda (e)
                        (member (plist-get e :kind)
                                '("block_start" "block_end")))
                      (copy-sequence events))
                     (lambda (a b)
                       (time-less-p (plist-get a :ts) (plist-get b :ts)))))
      (let ((kind (plist-get e :kind))
            (ts (plist-get e :ts)))
        (cond
         ((equal kind "block_start") (setq open ts))
         ((equal kind "block_end")
          (when open
            (push (cons open ts) intervals)
            (setq open nil))))))
    (nreverse intervals)))

(defun claude-code-ide-org--time-within-any-p (time intervals)
  "Non-nil when TIME falls *strictly* inside one of INTERVALS.

Endpoints are excluded on purpose, and the reason is not fussiness: a
`block_start' fires the instant the permission prompt appears, so the
agent worked right up to it, and a `block_end' fires when the tool
finally runs.  Those two timestamps are the last moment of work before
the wait and the first moment after it -- the closing and opening edges
of the spans either side.  Treating them as inside the block deletes both
edges and collapses each neighbouring span to zero width, which is what
the first version of this did."
  (seq-find (lambda (iv)
              (and (time-less-p (car iv) time)
                   (time-less-p time (cdr iv))))
            intervals))

(defun claude-code-ide-org--aggregate-guideposts (events &optional threshold)
  "Collapse EVENTS' timestamps into (START . END) spans for review.
Consecutive timestamps separated by less than THRESHOLD seconds (default
`claude-code-ide-org-guidepost-gap-threshold') join one span; a larger
gap starts a new one. A lone timestamp yields a zero-width span, which
is honest -- one interaction point is not evidence of a duration.

These spans are review scaffolding only. They are rendered as *active*
timestamps so org's own agenda picks them up (confirmed live, TODO.org
:ID: c084553c-0621-4a96-9fa1-f32850aeec6a), and they inform the human's
composition of CLOCK: entries.  Nothing here rounds.

That last sentence used to carry a justification that has since expired,
and it is corrected rather than deleted because the stale version read
as a settled decision and would have survived review indefinitely.  It
said consolidation must be kept away from this path because
`claude-code-ide-org--consolidate-logbook-text' rounds to 5 minutes and
drops anything under ~2.5.  It no longer does: that rounding was retired
outright in the incident where it erased a real two-minute interval
(TODO.org :ID: b74e0f19), and that function's own docstring now opens
\"This function no longer alters any interval\".

Not rounding here still matters, on its own terms rather than by
contrast: a span is the human's evidence for an interval they have not
yet confirmed, and quantising evidence before anyone has looked at it is
how a two-minute span becomes a zero-minute one.  Whether apply should
*consolidate* afterwards is a live question, now that its stated
obstacle is gone -- see TODO.org :ID: 12e0adac.

Not built on `claude-code-ide-org--merge-time-intervals': that merges
only touching or overlapping intervals, with no gap tolerance, which is
a different question from clustering points that are merely near each
other."
  (let* ((gap (or threshold claude-code-ide-org-guidepost-gap-threshold))
         (blocks (claude-code-ide-org--block-intervals events))
         ;; A guidepost inside a permission block is not evidence of
         ;; work: the agent was stalled waiting on a human for the whole
         ;; of it. Dropping those timestamps is what splits the span,
         ;; and it is decided here rather than offered at review because
         ;; a block is not ambiguous the way a commit-less gap is -- it
         ;; is a mechanically certain fact that nothing was running.
         (times (sort (mapcar (lambda (e) (plist-get e :ts))
                              (seq-remove
                               (lambda (e)
                                 (and blocks
                                      (claude-code-ide-org--time-within-any-p
                                       (plist-get e :ts) blocks)))
                               events))
                      #'time-less-p))
         spans start previous)
    (dolist (time times)
      (cond
       ((null start) (setq start time previous time))
       ;; A block between two timestamps breaks the span even when the
       ;; two are closer together than the gap threshold -- otherwise a
       ;; 54-minute wait bracketed by guideposts a minute apart on each
       ;; side would be clustered straight through.
       ((and (<= (float-time (time-subtract time previous)) gap)
             ;; Non-strict on both sides: the two timestamps either side
             ;; of a block are normally the block's own endpoints -- a
             ;; `block_start' is the last event before the wait and a
             ;; `block_end' the first after it, since no guidepost fires
             ;; while a turn is stalled. A strict test therefore never
             ;; fires in the case this exists for.
             (not (seq-find (lambda (iv)
                              (and (not (time-less-p (car iv) previous))
                                   (not (time-less-p time (cdr iv)))))
                            blocks)))
        (setq previous time))
       (t (push (cons start previous) spans)
          (setq start time previous time))))
    (when start (push (cons start previous) spans))
    (nreverse spans)))

;;; Review and apply ---------------------------------------------------------
;;
;; The human-triggered half of the event-queue refactor (TODO.org :ID:
;; 720b2dcf-6af1-45f3-96a7-aa841e5651e1). Everything above only *records*
;; what happened; this is where a human turns those records into real org
;; state, through org's own machinery, inside a genuinely interactive
;; command so native !/@ logging fires with no `org-inhibit-logging'
;; anywhere in the call path.
;;
;; Two modes, deliberately not one (see 720b2dcf's core design principle):
;;
;; - Subagent-derived intervals are mechanically knowable -- an agent was
;;   either running or not -- so a CLOCK: line is proposed directly, and
;;   the :LOGBOOK: annotation uses *inactive* timestamps, staying out of
;;   the agenda.
;; - Human-derived intervals are NOT knowable: the system cannot tell
;;   reading and thinking from lunch. So the pause/resume guideposts are
;;   clustered into a *suggested* span the human edits or rejects, and the
;;   annotation uses *active* timestamps so org-agenda doubles as a
;;   retrospective "what did I actually attend to" view (confirmed live,
;;   TODO.org :ID: c084553c).
;;
;; Nothing here rounds. `claude-code-ide-org--consolidate-logbook-text'
;; rounds to 5 minutes and drops what becomes zero-length, which silently
;; ate a real 2-minute interval; apply writes exactly the endpoints the
;; human confirmed. That is also why apply calls raw `org-clock-out'
;; rather than `claude-code-ide-org-clock-out', which consolidates.

(defvar-local claude-code-ide-org--review-items nil
  "Review items rendered in the current `*org-review*' buffer.
Each is a plist; see `claude-code-ide-org--review-items-from-queue'.")

(defun claude-code-ide-org--review-guidepost-p (event)
  "Non-nil when EVENT is a pause/resume guidepost."
  (member (plist-get event :kind) '("pause" "resume")))

(defun claude-code-ide-org--review-items-from-queue (&optional session-id)
  "Build review items from the pending queue, oldest first.

Returns a list of plists, each one proposed action:

  (:type state :id ID :ts TIME :from STATE :to STATE :note NOTE
         :events EVENTS)
  (:type clock :id ID :start TIME :end TIME :note NOTE :agent AGENT
         :suggested BOOL :events EVENTS)
  (:type capture :id ID :ts TIME :title TITLE :target TARGET :tags TAGS
         :note NOTE :events EVENTS)
  (:type amend :id ID :ts TIME :text TEXT :note NOTE :events EVENTS)

A `capture' item's :ID: names a heading that does *not exist yet* -- it
was minted when the capture deferred, and apply is what writes it.  Every
other item type names a heading that already exists, so anything walking
these items has to keep that distinction (TODO.org :ID: b5f94b88).

`:suggested' distinguishes the two modes above: non-nil means the span
was reconstructed from human guideposts and is a proposal the human must
confirm or edit; nil means it came from a subagent's own paired
clock_in/clock_out, where the interval is authoritative.

Items carry the `:events' they were derived from, which is what lets
`claude-code-ide-org--review-advance-watermarks' tell an applied event
from a skipped one."
  (let (items)
    (dolist (group (claude-code-ide-org--queue-events-by-id session-id))
      (let* ((id (car group))
             (events (cdr group)))
        (when id
          ;; State transitions replay one per todo event, in order --
          ;; never collapsed. A TODO->PLANNING->DOING run is three real
          ;; transitions and org's own log wants a line for each; it is
          ;; the *clock interval* that must not be broken up by them.
          (dolist (event events)
            (pcase (plist-get event :kind)
              ("todo"
               (push (list :type 'state :id id
                           :ts (plist-get event :ts)
                           :from (plist-get event :from)
                           :to (plist-get event :state)
                           :note (plist-get event :note)
                           :events (list event))
                     items))
              ;; One item per event for these two as well, and for the
              ;; same reason: two amendments to one heading are two
              ;; separate proposals a human may accept independently.
              ("capture"
               (push (list :type 'capture :id id
                           :ts (plist-get event :ts)
                           :title (plist-get event :title)
                           :target (plist-get event :target)
                           :tags (plist-get event :tags)
                           :note (plist-get event :note)
                           :events (list event))
                     items))
              ("amend"
               (push (list :type 'amend :id id
                           :ts (plist-get event :ts)
                           :text (plist-get event :text)
                           :note (plist-get event :note)
                           :events (list event))
                     items))))
          ;; Subagent intervals: pair each agent's own clock_in/clock_out.
          (let ((by-agent (make-hash-table :test 'equal)))
            (dolist (event events)
              (when (and (plist-get event :agent-id)
                         (member (plist-get event :kind) '("clock_in" "clock_out")))
                (push event (gethash (plist-get event :agent-id) by-agent))))
            (maphash
             (lambda (agent agent-events)
               (let ((ordered (nreverse agent-events))
                     open)
                 (dolist (event ordered)
                   (if (equal (plist-get event :kind) "clock_in")
                       (setq open event)
                     (when open
                       (push (list :type 'clock :id id
                                   :start (plist-get open :ts)
                                   :end (plist-get event :ts)
                                   :note (or (plist-get open :note)
                                             (plist-get event :note))
                                   :agent agent :suggested nil
                                   :events (list open event))
                             items)
                       (setq open nil))))))
             by-agent))
          ;; Human spans: cluster this heading's guideposts. The label
          ;; inherits the enclosing clock_in's note, which is the only
          ;; source of one -- pause/resume come from hooks Claude never
          ;; invokes, so they can carry no note of their own.
          (let* ((guideposts (seq-filter
                              (lambda (e)
                                (and (claude-code-ide-org--review-guidepost-p e)
                                     (not (plist-get e :agent-id))))
                              events))
                 (label (car (delq nil
                                   (mapcar (lambda (e)
                                             (and (equal (plist-get e :kind) "clock_in")
                                                  (plist-get e :note)))
                                           events)))))
            (dolist (span (claude-code-ide-org--aggregate-guideposts guideposts))
              (push (list :type 'clock :id id
                          :start (car span) :end (cdr span)
                          :note label :agent nil :suggested t
                          :events (seq-filter
                                   (lambda (e)
                                     (let ((ts (plist-get e :ts)))
                                       (and (not (time-less-p ts (car span)))
                                            (not (time-less-p (cdr span) ts)))))
                                   guideposts))
                    items))))))
    ;; Unassigned spans: guideposts that never fell inside a
    ;; clock_in/clock_out bracket, so `--queue-events-by-id' could attach
    ;; no heading to them and filed them under the nil key.  Before
    ;; 2026-08-13 the loop above skipped that group wholesale under its
    ;; `(when id ...)' guard, which meant the timestamps sat on disk
    ;; undroppable and unusable: 316 of them, 14.6 hours, against 3.6
    ;; hours actually recorded (TODO.org :ID: 3d0487f4).
    ;;
    ;; They are clustered exactly like attributed guideposts and carry a
    ;; *suggested* heading, so accepting one is an ordinary mark and
    ;; apply needs no new path -- `:id' is already the heading the
    ;; interval will land on.  `:unassigned' records that the id was
    ;; guessed rather than bracketed, which is what the review line
    ;; shows and what `claude-code-ide-org-review-assign' rewrites.
    (let* ((groups (claude-code-ide-org--queue-events-by-id session-id))
           (orphans (cdr (assoc nil groups)))
           ;; Suggestions read the *full* history, applied events
           ;; included. Measured live 2026-08-13: with only pending
           ;; events visible, 21 of 23 spans got no suggestion at all,
           ;; because 85% of `todo' events had already been applied --
           ;; the watermark had eaten precisely the confirmed signal the
           ;; suggestion wants. Nothing is proposed from these; they are
           ;; read only to answer "what was being worked on then".
           (all (claude-code-ide-org--queue-events session-id t))
           (guideposts (seq-filter
                        (lambda (e)
                          (and (claude-code-ide-org--review-guidepost-p e)
                               (not (plist-get e :agent-id))))
                        orphans)))
      (dolist (span (claude-code-ide-org--aggregate-guideposts guideposts))
        (push (list :type 'clock
                    :id (claude-code-ide-org--review-suggest-heading (car span) all)
                    :start (car span) :end (cdr span)
                    ;; :unassigned is transient -- `a' clears it once a
                    ;; heading is chosen. :origin is permanent, so the
                    ;; annotation can still say the interval was
                    ;; reconstructed rather than clocked live, long after
                    ;; the assignment decision is made.
                    :note nil :agent nil :suggested t
                    :unassigned t :origin 'unbracketed
                    :events (seq-filter
                             (lambda (e)
                               (let ((ts (plist-get e :ts)))
                                 (and (not (time-less-p ts (car span)))
                                      (not (time-less-p (cdr span) ts)))))
                             guideposts))
              items)))
    (sort (nreverse items)
          (lambda (a b)
            (time-less-p (or (plist-get a :ts) (plist-get a :start))
                         (or (plist-get b :ts) (plist-get b :start)))))))

(defconst claude-code-ide-org--work-in-progress-keywords '("DOING" "PLANNING")
  "Keywords asserting that work is happening on a heading right now.

The positive half of the keyword set, and the only half worth naming:
every other keyword -- including any added later -- means work is not
happening, which is what `claude-code-ide-org--review-suggest-heading'
needs to know.  Defining the small, stable side and treating the rest as
its complement is what keeps a new keyword from having to be remembered
in a second place.

Not read from `org-todo-keywords' because that answers a different
question.  Org divides keywords into not-done and done at the `|'; this
divides them into \"being worked\" and everything else, and WAIT, TODO
and NEXT all sit on org's not-done side while meaning nobody is working.")

(defun claude-code-ide-org--review-suggest-heading (time events)
  "Return the :ID: most plausibly being worked on at TIME, from EVENTS.

A heading is the answer only while it is *in* a work-in-progress state
at TIME: something entered it into DOING or PLANNING before TIME and
nothing has taken it out since.  Otherwise nil, and the span is offered
unattributed for a human to assign (TODO.org :ID: 3d0487f4 built that
path precisely so nil is workable).

There used to be a fallback here -- \"the most recent `todo' of any
state\" -- and it silently defeated the clear below.  Closing a heading
emits a `todo' event naming it, so the clear would set `active' to nil
and the fallback would immediately hand the very same id back.  The
guess therefore latched from the moment a heading was closed until the
next one opened, which is exactly the window filled by documentation,
planning and review -- work that often enters no heading at all.

Measured 2026-08-14: a 53-minute span was suggested, and accepted, for
`e51d6ba1', a heading that had gone DONE seven minutes before the span
began.  It swallowed two properly bracketed intervals on other headings
in the process.  Three further spans later that day all named
`4cda6bf7', CANCELLED an hour earlier.  Removing the fallback is the
whole fix; the clear was already correct.

Nil is the honest answer in that window and a better one than a
plausible wrong id, which this project has now measured twice: :ID:
7771fc63 retired a stop-time guess for being wrong more often than not,
and :ID: 5ff5a4b8 found that supporting detail makes a suggestion harder
to reject rather than easier to evaluate.

This is *only* ever a suggestion the human confirms, and that distinction
is the whole justification for deriving it from `todo' events at all.
`claude-code-ide-org--queue-events-by-id' deliberately refuses to do so
for real attribution, because a return to a heading that never left
DOING emits no `todo' event and every later guidepost would then attach
to the wrong heading -- silently.  That objection stands and nothing
here weakens it: attribution is unchanged, and a wrong guess made *here*
is visible on the review line at the moment of decision and one keystroke
from correction.  See TODO.org :ID: 3d0487f4."
  (let (active)
    (dolist (e events)
      (when (and (equal (plist-get e :kind) "todo")
                 (plist-get e :id)
                 (not (time-less-p time (plist-get e :ts))))
        (let ((id (plist-get e :id))
              (state (plist-get e :state)))
          (cond
           ((member state claude-code-ide-org--work-in-progress-keywords)
            (setq active id))
           ;; A heading that has left DOING is no longer what anyone is
           ;; working on, so it must stop being suggested. Without this
           ;; the guess latches: measured live 2026-08-13, three spans
           ;; spanning eight hours all suggested a heading that had gone
           ;; CANCELLED before the first of them even began.
           ;;
           ;; Stated as "anything that is not work in progress" rather
           ;; than by naming the six keywords that are not. The two forms
           ;; were exact complements, so the list was a second copy of the
           ;; keyword set that had to be kept in step with `#+TODO:' by
           ;; hand -- and a keyword forgotten there fails *silently*, by
           ;; latching, which is the failure mode hardest to notice. This
           ;; form brackets correctly for a keyword nobody has invented
           ;; yet (TODO.org :ID: c954f650, where adding REVIEW is under
           ;; discussion).
           ((equal id active) (setq active nil))))))
    active))

(defun claude-code-ide-org--review-current-state (id)
  "Return the TODO keyword heading ID holds right now, or nil.
Resolves by :ID: through `org-id-find', the same property search every
other read here uses.  Returns the symbol `unresolved' -- distinct from
nil, which is a real answer meaning \"no keyword\" -- when the :ID:
names nothing, so a caller can tell \"heading has no keyword\" from
\"heading is gone\"."
  (let ((marker (ignore-errors (org-id-find id 'marker))))
    (if (not marker)
        'unresolved
      (org-with-point-at marker (org-get-todo-state)))))

(defun claude-code-ide-org--review-state-stale-p (item)
  "Non-nil when ITEM's queued transition disagrees with reality.

The hazard this exists for, observed live 2026-08-07: a queued
`todo -> PLANNING' was applied long after the heading had moved on to
DOING, and apply faithfully regressed it, writing a
`State \"PLANNING\" from \"DOING\"' line to prove it.  Nothing errored;
the record simply became wrong in a plausible-looking way.  A queue is
reviewed at a moment of the human's choosing, so *any* out-of-band
change in between -- a hand-edit, another session, an agenda bulk
action -- leaves a queued transition stale, and deferring review is the
entire premise of the design (TODO.org :ID:
f9f61c04-150b-4ee7-96c9-582cf2bda95a).

Answers nil, deliberately, in the two cases where there is nothing to
compare: an event predating the `from' field (nil `:from', meaning
\"unknown\", not \"none\"), and an :ID: that no longer resolves --
apply reports that one on its own terms rather than pre-empting it
here.  Silence on an unknown is the right default; flagging every
legacy event would train the reader to ignore the flag.

Prefers the `:stale' annotation left by
`claude-code-ide-org--review-projected-staleness' when one is present,
which is what makes a chain of transitions within one batch read
correctly.  Falls back to comparing against the file alone when there is
no annotation -- the case for a direct caller or a test, which has no
batch to be a link in."
  (if (plist-member item :stale)
      (plist-get item :stale)
    (let ((from (plist-get item :from)))
      (when from
        (let ((current (claude-code-ide-org--review-current-state (plist-get item :id))))
          (and (not (eq current 'unresolved))
               ;; "none" is how the queue spells "the heading carried no
               ;; keyword", which `org-get-todo-state' spells as nil.
               (not (equal (if (equal from "none") nil from) current))))))))

(defun claude-code-ide-org--review-normalize-from (from)
  "Return FROM as `org-get-todo-state' would spell it.
\"none\" is how the queue spells \"the heading carried no keyword\",
which org spells nil.  Kept as one function so the render path and the
projection path cannot drift apart on it."
  (if (equal from "none") nil from))

(defun claude-code-ide-org--review-projected-staleness (items &optional advances-p)
  "Annotate each of ITEMS with `:stale', judged against the batch.

Exists because post-cutover *nothing* moves an org file until apply
moves it.  A batch holding a chain on one heading (`TODO -> DOING', then
`TODO -> DONE') therefore records the same `from' on every event --
whatever the unmoved file said.  Checking each against the file alone
refuses every link past the first, on the grounds that the file moved,
when the thing that moved it was this very batch.  Verified on the live
queue 2026-08-11: 47c027d2 queued a three-link chain, all three events
carrying `from: TODO'.

So a state item is stale only when its `from' matches neither

  - the *pre-batch* state read from the file, nor
  - the state earlier items in this batch will have left behind.

Both shapes occur for real and both are legitimate: `org_set_todo' reads
`from' off a file that never moves, while the `ExitPlanMode' hook passes
`from' explicitly and so records the chain's own previous `to'.

ADVANCES-P, when given, is called on each item and decides whether that
item contributes to the projection.  The review buffer passes a
marked-item test, since an unmarked item will not move anything; apply
passes nothing, because every item it is handed is about to run.

Reads each heading's state once per batch, through
`claude-code-ide-org--review-current-state', preserving its `unresolved'
answer -- an :ID: that no longer resolves is never reported stale, so
apply can report it on its own terms.

Note what this deliberately does *not* excuse: applying only the first
link of a chain and leaving the rest.  The leftovers then face a moved
file with no batch to account for it, and are correctly stale.  That is
a real divergence at that point, not this bug returning."
  (let ((baseline (make-hash-table :test 'equal))
        (projected (make-hash-table :test 'equal)))
    (dolist (item items)
      (when (eq (plist-get item :type) 'state)
        (let ((id (plist-get item :id)))
          (unless (gethash id baseline)
            (let ((current (claude-code-ide-org--review-current-state id)))
              ;; nil is a real answer ("no keyword"), so box it -- a bare
              ;; nil in the table is indistinguishable from "not seeded".
              (puthash id (list current) baseline)
              (puthash id (list current) projected)))
          (let* ((from (plist-get item :from))
                 (base (car (gethash id baseline)))
                 (proj (car (gethash id projected))))
            (plist-put item :stale
                       (and from
                            (not (eq base 'unresolved))
                            (let ((nf (claude-code-ide-org--review-normalize-from from)))
                              (and (not (equal nf base))
                                   (not (equal nf proj))))))
            ;; Only an item that will actually run moves the projection.
            (when (or (null advances-p) (funcall advances-p item))
              (puthash id (list (plist-get item :to)) projected)))))))
  items)

(defun claude-code-ide-org--review-annotation-label (item)
  "Return ITEM's label, synthesising one for a span that has no note.

A span reconstructed from unbracketed guideposts has no note to inherit:
there is no enclosing `clock_in' to take one from, which is exactly what
made it unattributed.  Left bare it rendered as
`- <12:24>--<13:09>' with nothing after it -- 17 such lines in one apply
pass on 2026-08-13 (TODO.org :ID: c97b3564).

Suppressing the line instead was considered and rejected: the *active*
timestamps are what put a human span into `org-agenda', so dropping the
line would quietly drop the span from the agenda -- a behaviour change
wearing the clothes of a tidy-up.

The synthesised label carries provenance, which is the one thing a
reader cannot recover from the timestamps: this interval was
reconstructed and confirmed, not clocked as it happened.  That
distinction is the whole point of a record whose trustworthiness is a
stated goal."
  (let ((note (plist-get item :note)))
    (cond
     ((and note (not (string-empty-p note))) note)
     ((not (eq (plist-get item :origin) 'unbracketed)) "")
     ((plist-get item :assigned) "assigned at review")
     (t "suggested span, accepted at review"))))

(defun claude-code-ide-org--review-format-annotation (item)
  "Return the :LOGBOOK: annotation line for ITEM.

Always *inactive* timestamps, so nothing written from the queue reaches
`org-agenda'.

This used to branch on ITEM's `:agent', active for anything without one
and inactive for a subagent's -- i.e. it tested \"is this a subagent\"
while its own docstring claimed to test \"is this a human\".  Those come
apart on the outer session, which carries no agent_id and was therefore
rendered active: measured 2026-08-14, all 68 events of one session had
`agent_id' nil, so every span it produced was published to the agenda as
though the user had been at the keyboard for it.

The correction is not a better test but the removal of one.  The queue
records *agent* activity and nothing else -- hooks and MCP tools write
it, and a human clocking in Emacs writes a bare CLOCK: line with no
annotation at all (TODO.org :ID: 4f8500e6).  So there is no case in
which a queue-derived span is the user's own attention, and no branch to
make.

Note this narrows what TODO.org :ID: c084553c established: an active
timestamp inside :LOGBOOK: does reach the agenda, and that remains the
mechanism -- but it is now reserved for intervals a human logs
themselves.  The agenda answers \"where did *my* attention go\"; the
queue answers \"what was the agent doing\", and conflating them makes
the first unreadable.  See :ID: b8e6007a."
  (let* ((fmt "[%Y-%m-%d %a %H:%M]")
         (note (claude-code-ide-org--review-annotation-label item)))
    (format "- %s--%s%s"
            (format-time-string fmt (plist-get item :start))
            (format-time-string fmt (plist-get item :end))
            (if (and note (not (string-empty-p note))) (concat " " note) ""))))

(defun claude-code-ide-org--logbook-has-interval-p (start end)
  "Non-nil when the heading at point already records a CLOCK interval
with exactly START and END.

Compares the *rendered* timestamps rather than parsed times, because
that is what a replay would write: org formats both ends the same way
every time, so string equality on the org form is exact here and avoids
re-parsing every line in the drawer.

The other half of the content idempotency described on
`claude-code-ide-org--append-to-drawer'."
  (let ((needle (format "CLOCK: %s--%s"
                        (format-time-string "[%Y-%m-%d %a %H:%M]" start)
                        (format-time-string "[%Y-%m-%d %a %H:%M]" end))))
    (save-excursion
      (org-back-to-heading t)
      (let ((limit (save-excursion (outline-next-heading) (point))))
        (and (search-forward needle limit t) t)))))

(defun claude-code-ide-org--review-apply-clock (item)
  "Write ITEM's CLOCK: interval and its :LOGBOOK: annotation at point.
Uses raw `org-clock-in'/`org-clock-out' with both endpoints supplied up
front, never the consolidating wrapper, and binds
`org-clock-out-remove-zero-time-clocks' nil so a short confirmed
interval survives. The pair is written back to back so no clock is ever
left open across a state change -- `claude-code-ide-org--blocker-clock-
running-p' would refuse a -> DONE transition if one were."
  (let ((start (plist-get item :start))
        (end (plist-get item :end)))
    ;; Close any running clock FIRST. `org-clock-in' throws `abort' and
    ;; opens nothing when a clock is already running on this same heading
    ;; at this same point (org-clock.el:1440) -- it just messages "Clock
    ;; continues in ...". The subsequent `org-clock-out' then closes the
    ;; *pre-existing* clock at our END, producing a negative-duration
    ;; CLOCK line. Observed live on 2026-08-07: [15:53]--[13:17] => -3:24.
    ;; Pre-cutover this is the common case, not an edge case, since the
    ;; UserPromptSubmit hook keeps a live clock on whatever heading is
    ;; being worked on -- typically the very one under review.
    (when (org-clocking-p)
      (org-clock-out nil t))
    ;; A zero-width span is a single interaction point, not a duration --
    ;; a lone guidepost with nothing to bracket it. Annotate it (it is
    ;; real evidence that something happened at that moment) but write no
    ;; CLOCK: line, since `=>  0:00' would claim an interval that was
    ;; never observed. Note this is NOT the rounding behavior being
    ;; avoided elsewhere: nothing is being discarded, because there was
    ;; no duration to discard.
    (unless (or (time-equal-p start end)
                ;; Content-based idempotency: an interval with identical
                ;; endpoints on this heading is a replay, not two real
                ;; intervals a human happened to confirm twice. Without
                ;; this, reprocessing an archived queue file silently
                ;; doubles recorded time -- and silently is the problem,
                ;; since a duplicated CLOCK line looks exactly like a
                ;; legitimate one (TODO.org :ID: 78f485a8).
                (claude-code-ide-org--logbook-has-interval-p start end))
      (let ((org-clock-out-remove-zero-time-clocks nil)
            (closed nil))
        (org-clock-in nil start)
        ;; Never close a clock we did not open. If `org-clock-in' aborted
        ;; for any reason, calling `org-clock-out' here would close
        ;; whatever else happens to be running, at our end time. Failing
        ;; loudly is the only safe response -- the alternative is a
        ;; plausible-looking interval on the wrong heading.
        (unless (org-clocking-p)
          (error "org-clock-in did not open a clock; refusing to clock out"))
        ;; If `org-clock-out' signals, the clock we just opened stays
        ;; running. `--review-apply' then carries on to the next item,
        ;; whose own defensive close above shuts our clock at *now* --
        ;; writing a duration nobody observed, scaling with the distance
        ;; from the backdated start to wall-clock time. Measured at 9:56
        ;; for an intended 0:30 (TODO.org :ID: 803314aa). Worse, this
        ;; item's `--append-to-drawer' below never runs, so the fabricated
        ;; CLOCK line carries no annotation and reads as legitimate.
        ;;
        ;; Cancelling is the honest cleanup, not retrying the close: the
        ;; item is reported as an error, so its events are never marked
        ;; applied and the interval stays pending for a later pass. No
        ;; record beats a confident wrong one.
        (unwind-protect
            (progn (org-clock-out nil nil end)
                   (setq closed t))
          (unless closed
            ;; `ignore-errors' so a failure here cannot mask the original
            ;; error, which is the one the human needs to see.
            (ignore-errors
              (when (org-clocking-p) (org-clock-cancel))))))))
  (claude-code-ide-org--append-to-drawer
   "LOGBOOK" (claude-code-ide-org--review-format-annotation item)))

(defun claude-code-ide-org--review-apply-state (item)
  "Apply ITEM's TODO transition at point, backdated, with native logging.

Backdates by shadowing `org-current-effective-time' rather than
let-binding `org-log-note-effective-time': `org-add-log-setup' setqs the
latter from the former, so binding the variable is futile (org.el:11031).

Then drives the deferred note directly. `org-add-log-note' normally runs
from `post-command-hook' and pop-to-buffers *Org Note* before it checks
whether a note is even wanted, which is what hangs non-interactively;
calling `org-store-log-note' with the note buffer already current
bypasses that entirely. It takes the note text from that buffer's
contents, so empty yields a bare State line and non-empty yields the
`\\\\' continuation."
  (let ((ts (plist-get item :ts))
        (note (plist-get item :note))
        ;; Land the note inside :LOGBOOK:, matching clock-template.org.
        ;; With `org-log-into-drawer' nil (this user's setting) org writes
        ;; state notes bare, just after the property drawer; they only
        ;; ended up in :LOGBOOK: before because `consolidate-history'
        ;; swept them there via its :other bucket, and apply deliberately
        ;; does not consolidate. Bound locally, so the user's own
        ;; interactive org-todo keeps their configured behavior.
        (org-log-into-drawer t))
    ;; Clear the global note state BEFORE org-todo, so that afterwards
    ;; `org-log-note-marker' answers "did *this* call set up a note?"
    ;; rather than "has anything, ever?". `org-todo' calls
    ;; `org-add-log-setup' only when the state actually changes; applying
    ;; an item whose heading already holds the requested state is a no-op
    ;; that sets up nothing, while the marker and
    ;; `org-log-note-state'/`-previous-state' persist globally from
    ;; whatever last touched them -- possibly a different heading in a
    ;; different file. Driving `org-store-log-note' on that stale state
    ;; writes a correctly-formatted `State "X" from "Y"' line, at the
    ;; stale marker, citing a real timestamp, with no error: exactly the
    ;; confidently-wrong record this whole design exists to prevent.
    ;; Observed live 2026-08-07, marking feba67eb DONE while applying an
    ;; event that named 32272061 (TODO.org :ID: 3d93021d).
    (set-marker org-log-note-marker nil)
    (cl-letf (((symbol-function 'org-current-effective-time) (lambda () ts)))
      (org-todo (plist-get item :to)))
    ;; `org-add-log-setup' registers `org-add-log-note' on
    ;; `post-command-hook' and sets `org-log-setup'. Driving
    ;; `org-store-log-note' directly bypasses `org-add-log-note', so
    ;; nothing ever performs that cleanup -- the hook then fires after
    ;; this command against a marker `org-store-log-note' has already
    ;; cleared, giving "Marker does not point anywhere" (observed live,
    ;; 2026-08-07). Batch never caught it: there is no command loop, so
    ;; `post-command-hook' never runs at all.
    (remove-hook 'post-command-hook 'org-add-log-note)
    (setq org-log-setup nil)
    (when (and (boundp 'org-log-note-marker) (marker-buffer org-log-note-marker))
      (let ((buffer (get-buffer-create "*Org Note*")))
        (with-current-buffer buffer
          (erase-buffer)
          (when (and note (not (string-empty-p note))) (insert note))
          (setq org-log-note-window-configuration (current-window-configuration))
          ;; org-store-log-note ends with set-window-configuration, which
          ;; errors under batch; the note is already written by then.
          (ignore-errors (org-store-log-note)))))))

(defun claude-code-ide-org--review-apply-item (item)
  "Apply one review ITEM. Returns nil on success, an error string on failure.

Refuses outright -- returning an error string, changing nothing -- when
ITEM's queued transition is stale and has not been explicitly confirmed
(see `claude-code-ide-org--review-state-stale-p').  A refusal is not a
failure to be retried: it means the queue and the file disagree, and the
human has not said which one wins.

Binds `claude-code-ide-org--auto-clock-in-active' for the duration.
That is this module's own re-entrancy guard for
`claude-code-ide-org--trigger-auto-clock-in', reused here rather than
inventing a second suppression flag: without it the trigger fires on any
-> DOING/PLANNING transition, opens a clock at *now* rather than the
backdated time, and -- confirmed live during TODO.org :ID: 3d576d29's
verification -- destroys the pending state-change note so it never
lands at all."
  (if (and (claude-code-ide-org--review-state-stale-p item)
           (not (plist-get item :stale-confirmed)))
      ;; Refused, not applied. Checked here as well as at mark time
      ;; because the mark is a UI gesture and this is the gate: an item
      ;; can reach apply through a refreshed buffer, a future bulk
      ;; command, or a caller in a test, and none of those went past the
      ;; `y-or-n-p'. Re-evaluated now rather than trusted from render
      ;; time, so a heading that changed *since* the buffer was drawn is
      ;; caught too.
      (format "Error: refused stale %s -> %s on %s (heading is now %s); mark it again to confirm"
              (plist-get item :from)
              (plist-get item :to)
              (plist-get item :id)
              (or (claude-code-ide-org--review-current-state (plist-get item :id))
                  "unset"))
    (let ((claude-code-ide-org--auto-clock-in-active t)
          (claude-code-ide-org--log-source
           (or claude-code-ide-org--log-source "org_review_apply")))
      ;; A capture is the one item whose :ID: names a heading that does
      ;; not exist yet -- it is what *creates* it -- so it cannot run
      ;; inside `--at-id' the way every other kind does.
      (if (eq (plist-get item :type) 'capture)
          (claude-code-ide-org--review-apply-capture item)
      (let ((result
             (claude-code-ide-org--at-id
              (plist-get item :id)
              (lambda ()
                (pcase (plist-get item :type)
                  ('clock (claude-code-ide-org--review-apply-clock item))
                  ('state (claude-code-ide-org--review-apply-state item))
                  ('amend (claude-code-ide-org--review-apply-amend item)))
                ;; Fold the tidy-up into the write already being made,
                ;; before `save-buffer' rather than after, so one apply
                ;; is one write. org inserts CLOCK lines newest-first
                ;; while notes land in insertion order, so a drawer
                ;; drifts out of order the moment anything is added --
                ;; visible after 2026-08-13's passes, where one drawer
                ;; held four entries at four points on the timeline in
                ;; none of them.
                (when claude-code-ide-org-consolidate-on-apply
                  (claude-code-ide-org--consolidate-drawer-at-point))
                (save-buffer)
                nil))))
        ;; --at-id returns an "Error: ..." string rather than throwing.
        (and (stringp result) result))))))

(defun claude-code-ide-org--review-apply-amend (item)
  "Append ITEM's text to the end of the target heading's own body.
Called with point on the heading, inside
`claude-code-ide-org--review-apply-item's `--at-id' wrapper, which saves.

Positional rather than contextual: the text lands at the body end
regardless of whether the body changed since the amendment was queued.
See `claude-code-ide-org-amend' for why v1 accepts that."
  (claude-code-ide-org--end-of-body)
  (insert "\n\n" (string-trim (or (plist-get item :text) "")) "\n"))

(defun claude-code-ide-org--review-apply-capture (item)
  "Write ITEM's captured heading.  Nil on success, an error string otherwise.

Two things are taken from the *event* rather than from now, and both
matter for the record to be honest: the pre-minted :ID:, so a caller that
was already told the id keeps being right, and the :CREATED: stamp, so
the heading records when it was thought of rather than when a human got
round to reviewing it.

*The target is resolved now, not at queue time,* because a heading can
move between the two.  When it resolves to nothing this returns an error
and applies nothing, leaving the item pending exactly as a stale state
transition does -- the human then retargets or dismisses it.  It never
falls back to the end of the capture file: a heading filed somewhere
nobody chose is precisely the confidently-wrong record this architecture
exists to prevent (TODO.org :ID: b5f94b88)."
  (condition-case err
      (let* ((resolved (claude-code-ide-org--capture-target-spec
                        (plist-get item :target)))
             (file (plist-get resolved :file))
             (id (plist-get item :id)))
        (claude-code-ide-org--capture-write
         (or (plist-get item :title) "(untitled)")
         id
         (format-time-string "[%Y-%m-%d %a %H:%M]" (plist-get item :ts))
         (plist-get resolved :spec)
         (plist-get item :tags))
        (org-id-add-location id (expand-file-name file))
        (with-current-buffer (find-file-noselect file) (save-buffer))
        nil)
    (error (format "Error: %s" (error-message-string err)))))

(defun claude-code-ide-org--review-record-applied (applied-items)
  "Record every event behind APPLIED-ITEMS as applied, per session.

Marks exactly the events that were consumed -- no more. A skipped item's
events stay pending regardless of where they sit relative to applied
ones, which is what makes applying a subset safe and makes re-applying
an already-applied item impossible."
  (let ((by-session (make-hash-table :test 'equal)))
    (dolist (item applied-items)
      (dolist (event (plist-get item :events))
        (push (plist-get event :ts-string)
              (gethash (plist-get event :session-id) by-session))))
    (maphash (lambda (session-id ts-strings)
               (when session-id
                 (claude-code-ide-org--queue-mark-applied session-id ts-strings)))
             by-session)))

(defun claude-code-ide-org--review-apply (items)
  "Apply ITEMS in order. Returns a plist (:applied N :errors ERRORS).

Judges staleness across the whole batch first, via
`claude-code-ide-org--review-projected-staleness', so a chain of
transitions on one heading applies in one pass instead of refusing every
link after the first.

Deliberately computed *here*, immediately before the loop, rather than
inherited from render time.  That is what keeps
`claude-code-ide-org--review-apply-item's guarantee intact: the file is
re-read now, so a heading changed out of band since the buffer was drawn
is still caught, and only this batch's own effects are projected over
it."
  (claude-code-ide-org--review-projected-staleness items)
  (let (applied errors)
    (dolist (item items)
      (let ((error (claude-code-ide-org--review-apply-item item)))
        (if error (push error errors) (push item applied))))
    (claude-code-ide-org--review-record-applied applied)
    ;; :items alongside the count, so the caller can drop exactly what
    ;; applied rather than rebuilding the list from the queue.  The count
    ;; stays for the message, and existing callers are unaffected.
    (list :applied (length applied) :errors (nreverse errors)
          :items (nreverse applied))))

;;; Queue archiving ---------------------------------------------------------
;;
;; "Drained" cannot mean "every event applied": only events that become
;; *items* are ever marked applied, and whole kinds never do.  Measured
;; 2026-08-12 with the review buffer reporting "Nothing pending": todo
;; 31 of 31 consumed, alongside 253 residual clock and guidepost events.
;; A file in that state is finished in every sense that matters and would
;; never move under an all-applied test.  So the predicate is a property
;; of the *reader* -- "would the item builder produce anything from this"
;; -- which is why it lives here rather than in the watermark.
;;
;; The archive is a subdirectory, not a flag.  `--queue-session-ids'
;; calls `directory-files' non-recursively filtered to `\.jsonl\'', so a
;; subdirectory is already invisible to every reader: archiving needs no
;; reader change at all, which a consumed-flag would have.

(defun claude-code-ide-org--queue-archive-directory ()
  "Path of the archive subdirectory, created on demand."
  (let ((dir (expand-file-name "archive" claude-code-ide-org-queue-directory)))
    (unless (file-directory-p dir) (make-directory dir t))
    dir))

(defun claude-code-ide-org--queue-file-idle-p (session-id)
  "Non-nil when SESSION-ID's queue file has gone quiet long enough.
See `claude-code-ide-org-queue-idle-seconds' for why this is mtime and
not the live session's own id."
  (let ((file (claude-code-ide-org--queue-file session-id)))
    (or (not (file-exists-p file))
        (> (float-time (time-subtract (current-time)
                                      (file-attribute-modification-time
                                       (file-attributes file))))
           claude-code-ide-org-queue-idle-seconds))))

(defun claude-code-ide-org--queue-file-drained-p (session-id)
  "Non-nil when SESSION-ID's queue yields no review items and is idle.

Both clauses are load-bearing.  Yielding nothing is what makes a file
finished; being idle is what stops a *live* session's stream being split
in two.  A file can satisfy the first and fail the second all day --
that is a session sitting at a prompt, not a finished one."
  (and (null (claude-code-ide-org--review-items-from-queue session-id))
       (claude-code-ide-org--queue-file-idle-p session-id)))

(defun claude-code-ide-org-archive-drained-queues (&optional dry-run)
  "Move every drained queue file, with its watermark, into the archive.

Interactive, and reports what it moved.  With a prefix argument only
reports, changing nothing -- worth using first, since the whole risk of
this command is archiving something still in use.

The `.applied' sidecar moves alongside its `.jsonl' deliberately: a
restored file that lost its watermark cannot support selective
reprocessing, only all-or-nothing."
  (interactive "P")
  (let ((archive (claude-code-ide-org--queue-archive-directory))
        moved skipped)
    (dolist (sid (claude-code-ide-org--queue-session-ids))
      (if (claude-code-ide-org--queue-file-drained-p sid)
          (let ((jsonl (claude-code-ide-org--queue-file sid))
                (applied (claude-code-ide-org--queue-watermark-file sid)))
            (unless dry-run
              (dolist (f (list jsonl applied))
                (when (file-exists-p f)
                  (rename-file f (expand-file-name (file-name-nondirectory f) archive) t))))
            (push sid moved))
        (push sid skipped)))
    ;; Reverse ONCE, into fresh bindings. `nreverse' is destructive:
    ;; calling it in the `message' and again in the return value left the
    ;; variable pointing at what had become the tail, so the message read
    ;; correctly while the returned :moved list was silently truncated --
    ;; four sessions reported as one. Caught only because the returned
    ;; :moved and :skipped stopped summing to the number of files on
    ;; disk, which is the kind of check worth doing on any function whose
    ;; output nobody eyeballs.
    (setq moved (nreverse moved)
          skipped (nreverse skipped))
    (message "%s%d drained (%s); %d left in place"
             (if dry-run "Dry run: " "Archived ")
             (length moved)
             ;; `substring' to a fixed 8 signals on anything shorter.
             ;; Real session ids are UUIDs so it never bit in use, but a
             ;; command that crashes on an unexpected filename is a poor
             ;; guard for the one operation that moves files around.
             (if moved (mapconcat #'claude-code-ide-org--short-id moved ", ")
               "none")
             (length skipped))
    (list :moved moved :skipped skipped)))

(defun claude-code-ide-org-restore-queue (session-id &optional ignore-watermark)
  "Move SESSION-ID's queue file back out of the archive for reprocessing.

With IGNORE-WATERMARK non-nil (a prefix argument interactively), the
`.applied' sidecar is left behind, so every event is re-examined.

The two modes exist because reprocessing has two motives that want
opposite things.  Repairing a corrupted apply wants the watermark
*honoured*, so only the unapplied remainder is offered.  Re-deriving
under changed reader logic wants it *ignored* -- which is the case that
actually arises: on 2026-08-13 five of seven session files yielded zero
items before `3d0487f4' shipped and would have archived as drained,
then yielded 17 spans and 8.9 hours afterwards.

Safe in either mode because both remaining write paths are
content-idempotent; see `claude-code-ide-org--append-to-drawer'."
  (interactive
   (list (completing-read
          "Restore session: "
          (mapcar #'file-name-base
                  (directory-files (claude-code-ide-org--queue-archive-directory)
                                   nil "\\.jsonl\\'"))
          nil t)
         current-prefix-arg))
  (let* ((archive (claude-code-ide-org--queue-archive-directory))
         (jsonl (expand-file-name (concat session-id ".jsonl") archive))
         (applied (expand-file-name (concat session-id ".applied") archive)))
    (unless (file-exists-p jsonl)
      (user-error "No archived queue for %s" session-id))
    (rename-file jsonl (claude-code-ide-org--queue-file session-id) t)
    (when (and (file-exists-p applied) (not ignore-watermark))
      (rename-file applied (claude-code-ide-org--queue-watermark-file session-id) t))
    (message "Restored %s%s" (claude-code-ide-org--short-id session-id)
             (if ignore-watermark " (watermark left archived; every event re-offered)"
               ""))
    session-id))

;;;###autoload
(defun claude-code-ide-org-pending-updates (&optional session-id)
  "Summarize queued-but-unapplied updates as plain text.

The read-only counterpart to `claude-code-ide-org-review': answers
\"what is waiting?\" without opening Emacs, which stopped being a
curiosity the moment `org_set_todo'/`org_clock_in'/`org_clock_out'
became queue writers rather than buffer writers.  A later read showing
the old state is expected, and this is how you tell that apart from a
tool having failed.

Deliberately reuses `claude-code-ide-org--review-items-from-queue' and
`--review-describe' rather than re-deriving anything, so the summary and
the review buffer can never disagree about what is pending -- the
heading that asked for this (TODO.org :ID:
63a642c7-b04d-42dc-b6ec-3fb13df3ae04) called for exactly that sharing.
Staleness is judged with nothing marked, which is precisely the view the
review buffer opens on.

Reports *proposals*, and says how many raw events carry none.  That
distinction is not pedantry: `clock_in'/`clock_out' and unclustered
`pause'/`resume' guideposts exist to attribute spans and are consumed by
nothing, so the queue files always hold far more lines than there are
items -- a summary that counted lines would report a permanent backlog
that does not exist.

SESSION-ID limits the report to one session's queue.  Never signals to
the MCP layer."
  (condition-case err
      (let* ((session-id (and (stringp session-id)
                              (not (string-empty-p session-id))
                              session-id))
             (items (claude-code-ide-org--review-items-from-queue session-id))
             (events (claude-code-ide-org--queue-events session-id))
             ;; Sessions that contributed an *item*, not every session
             ;; holding a residual event -- the latter is nearly all of
             ;; them, forever, and reporting it as "from N sessions"
             ;; would imply N sessions have something waiting.
             (backing (delete-dups
                       (apply #'append
                              (mapcar (lambda (i) (plist-get i :events)) items))))
             (sessions (delete-dups
                        (delq nil (mapcar (lambda (e) (plist-get e :session-id))
                                          backing))))
             (headings (delete-dups (mapcar (lambda (i) (plist-get i :id)) items)))
             (lines nil)
             (last-id 'none))
        (claude-code-ide-org--review-projected-staleness
         items (lambda (item) (plist-get item :marked)))
        (dolist (item items)
          (unless (equal (plist-get item :id) last-id)
            (setq last-id (plist-get item :id))
            (push (format "\n%s  {%s}"
                          (or (claude-code-ide-org--at-id
                               last-id (lambda () (org-get-heading t t t t)))
                              "(unresolvable :ID:)")
                          last-id)
                  lines))
          (push (claude-code-ide-org--review-describe item) lines))
        (if (null items)
            (format (concat "Nothing pending: no queued update is proposing a "
                            "change.\n%d queue event(s) carry no proposal -- "
                            "clock and guidepost scaffolding, which is "
                            "consumed by nothing and is not a backlog.")
                    (length events))
          ;; Stripped once, over the assembled reply, exactly as
          ;; `claude-code-ide-org--outline-line' does and for the same
          ;; reason: every heading title here is read from a live buffer
          ;; and carries its text properties, which the MCP layer then
          ;; serializes as pages of `(face (org-headline-done ...))'
          ;; noise around the answer.
          ;;
          ;; Seen for the first time 2026-08-13, only once a heading had
          ;; been fontified *and* clock-displayed. The suite cannot catch
          ;; it: batch Emacs runs no font-lock and a scratch org file is
          ;; clean either way -- the same trap already documented on
          ;; `--outline-line', which is why this now matches its idiom
          ;; rather than stripping the title alone.
          (substring-no-properties
           (concat
            (format "%d pending item(s) across %d heading(s), from %d session(s).\n"
                    (length items) (length headings) (length sessions))
            (string-join (nreverse lines) "\n")
            (format (concat "\n\nApply with M-x claude-code-ide-org-review; "
                            "nothing reaches a file until a human does.\n"
                            "%d of %d queue event(s) back these items; the rest "
                            "is attribution scaffolding, not a backlog.")
                    (length backing) (length events))))))
    (error (format "Error: %s" (error-message-string err)))))

;;; Review buffer

(defvar claude-code-ide-org-review-mode-map (make-sparse-keymap)
  "Keymap for `claude-code-ide-org-review-mode'.")

;; Bindings live outside the `defvar' initializer on purpose. `defvar'
;; does not reassign an already-bound variable, so a keymap built inside
;; its initializer is frozen at whatever the first load produced -- a
;; `load-file' reload silently keeps the old bindings while every other
;; change in the file takes effect, which is a genuinely confusing way to
;; lose half an edit. This project live-reloads constantly (see the
;; org-dev skill), so the bindings are applied to the existing map on
;; every load instead.
;; The mark keys follow dired's vocabulary on purpose -- `m'/`u' per
;; line and advancing, `t' to invert every mark, `U' to clear them --
;; because that is the muscle memory a person arrives with. `M' for
;; mark-all is the one addition dired has no single key for.
(dolist (binding '(("m" . claude-code-ide-org-review-mark)
                   ("u" . claude-code-ide-org-review-unmark)
                   ("t" . claude-code-ide-org-review-toggle-all)
                   ("M" . claude-code-ide-org-review-mark-all)
                   ("U" . claude-code-ide-org-review-unmark-all)
                   ("a" . claude-code-ide-org-review-assign)
                   ("e" . claude-code-ide-org-review-edit-interval)
                   ("N" . claude-code-ide-org-review-edit-note)
                   ("d" . claude-code-ide-org-review-dismiss)
                   ("RET" . claude-code-ide-org-review-goto)
                   ("x" . claude-code-ide-org-review-apply)
                   ("g" . claude-code-ide-org-review-refresh)
                   ("?" . claude-code-ide-org-review-help)))
  (define-key claude-code-ide-org-review-mode-map
              (kbd (car binding)) (cdr binding)))

(defun claude-code-ide-org-review-help ()
  "Show this mode's key bindings, preferring `which-key' when available.

Resolved at call time rather than at load: `which-key' is present in
this user's Doom config but not under `emacs --batch -Q', which is what
config-test.el runs, and a hard dependency would break the suite for a
convenience. Falls back to `describe-mode', which shows the same
bindings alongside the mode's own documentation."
  (interactive)
  (if (fboundp 'which-key-show-major-mode)
      (call-interactively 'which-key-show-major-mode)
    (describe-mode)))

(define-derived-mode claude-code-ide-org-review-mode special-mode "Org-Review"
  "Review pending org updates and apply the ones you approve.

Claude Code sessions never write clock or TODO-state changes directly.
They append events to a queue, and nothing reaches an org file until you
apply it here.  Items are grouped under the heading they belong to.

Two kinds of line:

  state   a TODO transition, shown whole (`NEXT -> DOING') so you can see
          what the event assumed.  Applying writes org's native
          `State \"X\" from \"Y\"' log line stamped at the time the event
          actually happened, not now.

  clock   a time interval, shown as the :LOGBOOK: annotation it will
          produce.  The trailing tag is the part to read carefully:

          (suggested)  Reconstructed from your own pause/resume
                       guideposts.  The system cannot tell reading and
                       thinking from lunch, so this is a proposal, not a
                       measurement.  Check it, and press \\[claude-code-ide-org-review-edit-interval] if it is wrong.
          (agent)      A subagent's own paired clock in/out.  The
                       interval is mechanically knowable, so it is
                       authoritative.

A line prefixed `!' is STALE: the heading no longer holds the state the
event was queued from, so something changed out of band -- a hand-edit,
another session, an agenda bulk action -- and applying it would drag the
heading backwards while writing a log line that looks perfectly correct.
That exact thing happened on 2026-08-07, which is why the flag exists.
Stale items are refused by default; marking one asks you to confirm, and
only then will it apply.  Nothing else about them is special -- the queue
is not wrong, it is just older than the file.

Angle brackets <...> mark an active timestamp, which `org-agenda' picks
up -- that is how the agenda doubles as a retrospective \"what did I
attend to\" view.  Agent intervals use [...] and stay out of the agenda,
since unattended machine work is not attention.

A span prefixed `?' is UNASSIGNED: it belongs to no heading yet, and
press \\[claude-code-ide-org-review-assign] to say which.  The indented lines under it are the
*evidence* -- git commits and headings created inside that span's window,
in the order they happened.  They are not a recommendation and nothing
consults them: a `:CREATED:' stamp inside the window names what was being
thought about, a commit just after it marks what was finished, and the
answer is yours to draw.  Absent lines mean an empty window, not an
error.

Three behaviours worth knowing:

  \\[claude-code-ide-org-review-apply] is the only consequential key.  It writes real org state and saves
  the buffers.  Items apply oldest first and independently: if one fails
  it is reported and the rest still go.  If a target buffer is read-only
  it asks first, and answering no applies nothing and keeps your marks.
  When nothing at all applied it does not refresh, so your marks survive
  a failed run.

  \\[claude-code-ide-org-review-refresh] discards your marks.  It rebuilds from the queue, so mark, then
  refresh, loses the marking.

  \\[claude-code-ide-org-review-edit-interval] only works on a clock line, and clears the (suggested) tag --
  an interval you have corrected is one you have confirmed.

Nothing here can lose queue data.  Applying never modifies the queue
files themselves; it only advances a watermark, and only past a
contiguous run of items that actually succeeded.  Apply the third item
but not the first two and nothing is consumed -- press \\[claude-code-ide-org-review-refresh] and it is
all still pending.

\\{claude-code-ide-org-review-mode-map}")

(defun claude-code-ide-org--review-item-at-point ()
  "Return the review item on the current line, or nil."
  (get-text-property (line-beginning-position) 'claude-code-ide-org-item))

(defun claude-code-ide-org--review-describe (item)
  "Return the one-line description of ITEM shown in the review buffer.

A state item renders as the whole transition (`NEXT -> DOING'), not just
its destination, so the reader can see what the event assumed.  When
that assumption no longer holds, the line is prefixed `!' and names the
state the heading actually holds now -- making the stale-replay hazard
visible at the moment of decision rather than discoverable afterwards in
a wrong log line."
  (let ((note (or (plist-get item :note) "")))
    (pcase (plist-get item :type)
      ('state
       (let* ((stale (claude-code-ide-org--review-state-stale-p item))
              (from (plist-get item :from))
              (transition (if from
                              (format "%s -> %s" from (plist-get item :to))
                            (plist-get item :to))))
         (format "%sstate   %-20s %s   %s%s"
                 (if stale "! " "  ")
                 transition
                 (format-time-string "%m-%d %H:%M" (plist-get item :ts))
                 (if stale
                     (format "STALE, heading is now %s -- "
                             (or (claude-code-ide-org--review-current-state
                                  (plist-get item :id))
                                 "unset"))
                   "")
                 note)))
      ;; Two leading spaces so clock lines stay aligned with the `! '
      ;; column state lines reserve.  The note is deliberately *not*
      ;; appended here: `--review-format-annotation' already ends with
      ;; it, because the note is part of the :LOGBOOK: line it produces.
      ;; Adding it again printed every clock note twice (TODO.org :ID:
      ;; e3f70e61-6616-4c57-81e8-e350ffd5824c).
      ('clock
       (if (plist-get item :unassigned)
           ;; An unassigned span leads with `?' in the column state items
           ;; reserve for `!', so it reads as "needs a decision" rather
           ;; than "something is wrong".  The heading it would land on is
           ;; named outright: a suggestion nobody can see is not a
           ;; suggestion, it is a silent guess.
           (format "%sspan    %s  %s"
                   (if (plist-get item :id) "? " "! ")
                   (claude-code-ide-org--review-format-annotation item)
                   (if (plist-get item :id)
                       (format "-> %s  %s"
                               (claude-code-ide-org--short-id (plist-get item :id))
                               (or (claude-code-ide-org--review-heading-title
                                    (plist-get item :id))
                                   "(unknown heading)"))
                     "UNASSIGNED -- press `a' to choose a heading"))
         (format "  clock   %s%s"
                 (claude-code-ide-org--review-format-annotation item)
                 (if (plist-get item :suggested) "  (suggested)" "  (agent)"))))
      ;; The target is resolved here, at render time, purely to say
      ;; whether it still resolves -- a capture can easily outlive the
      ;; heading it was filed under, and finding that out at apply time
      ;; means finding it out one keystroke too late.  `!' is the column's
      ;; established "something is wrong" mark.
      ('capture
       (let ((where (ignore-errors
                      (plist-get (claude-code-ide-org--capture-target-spec
                                  (plist-get item :target))
                                 :where))))
         (format "%scapture %-30s -> %-22s %s   %s"
                 (if where "  " "! ")
                 (format "\"%s\"" (or (plist-get item :title) "(untitled)"))
                 (or where (format "%s (UNRESOLVED)" (plist-get item :target)))
                 (format-time-string "%m-%d %H:%M" (plist-get item :ts))
                 note)))
      ;; The target heading's *title*, not just its id, because an
      ;; amendment is positional -- it lands at the body end whatever the
      ;; body now says -- and the title is the only chance to notice the
      ;; heading has moved on since the text was written.
      ('amend
       (let ((lines (length (split-string (or (plist-get item :text) "") "\n"))))
         (format "  amend   %-30s    (%d line%s)%s %s   %s"
                 (format "\"%s\"" (or (claude-code-ide-org--review-heading-title
                                       (plist-get item :id))
                                      "(unknown heading)"))
                 lines (if (= lines 1) "" "s")
                 (make-string (max 1 (- 8 (length (number-to-string lines)))) ?\s)
                 (format-time-string "%m-%d %H:%M" (plist-get item :ts))
                 note))))))

(defun claude-code-ide-org--assignable-files ()
  "Truenames of the files whose headings may receive an assigned span.

The tracked files plus each one's own archive target, because a span may
legitimately belong to work that has since been archived -- writing an
outcome summary after a heading goes DONE is exactly that case, and
`claude-code-ide-org--tracked-files' does not list DONE.org.

Truenames throughout: `~/org/claude-code-ide-org/TODO.org' is a symlink
to the file in the repo, so a string comparison against the tracked list
would match nothing at all.

The point of the filter is exclusion, not completeness.  `org-id' knows
about every file it has ever scanned, which here includes
`clock-template.org' (a fixture) and scratch files left in /tmp by
debugging sessions -- 110 candidate headings, of which only some are
real work.  Offering a fixture heading as somewhere to file two hours of
time is the kind of plausible-looking wrong answer this project keeps
finding."
  (require 'org-archive)
  (let (files)
    (dolist (f (claude-code-ide-org--tracked-files))
      (when (file-readable-p f)
        (push (file-truename f) files)
        (let ((archive (ignore-errors
                         (with-current-buffer (find-file-noselect f)
                           (car (org-archive--compute-location
                                 org-archive-location))))))
          (when (and archive (file-readable-p archive))
            (push (file-truename archive) files)))))
    (delete-dups files)))

(defun claude-code-ide-org--heading-activity-range ()
  "Return (EARLIEST . LATEST) across CLOCK lines in the subtree at point.

Nil when the heading has never been clocked.  Read from the drawer text
rather than from any index: the whole point is to show what was actually
*recorded*, and a heading's clock history is the only honest answer to
\"was this live then?\".

Shown in the assignment prompt so the human can judge a candidate
against the span in front of them.  A heading whose recorded work ended
three days before the span is a far weaker answer than one clocked on
the same afternoon, and neither its title nor its TODO state says so."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t) (point)))
          earliest latest)
      ;; Two lessons are baked into this regexp, both found by running it.
      ;;
      ;; Emacs regexp syntax: a shy group is `\\(?:...\\)'.  A bare
      ;; `(?:...)' is PCRE and matches those three characters literally,
      ;; so the end timestamp never matched.
      ;;
      ;; And the date shape is required rather than `[^]]+', because
      ;; heading *bodies* in this repo quote CLOCK lines as prose
      ;; examples -- `: input:  CLOCK: [12:46]--[12:47] =>  0:01' among
      ;; them.  A loose pattern captures `12:46', which
      ;; `--parse-org-timestamp' rejects by *signalling*, so a single
      ;; documentation example aborted the scan for the whole heading and
      ;; the failure read as "never clocked".
      (while (re-search-forward
              "^[ \t]*CLOCK: \\[\\([0-9]\\{4\\}-[^]]+\\)\\]\\(?:--\\[\\([0-9]\\{4\\}-[^]]+\\)\\]\\)?"
              end t)
        ;; Read BOTH captures before parsing either.
        ;; `--parse-org-timestamp' runs `string-match' internally, which
        ;; clobbers the match data -- so parsing group 1 first and then
        ;; asking for group 2 returns the parser's match, not this
        ;; search's. The symptom was every interval collapsing to its
        ;; start time, which looks like a plausible zero-length clock
        ;; rather than like a bug.
        (let* ((m1 (match-string 1))
               (m2 (match-string 2))
               (a (ignore-errors
                    (claude-code-ide-org--parse-org-timestamp (concat "[" m1 "]"))))
               (b (and m2
                       (ignore-errors
                         (claude-code-ide-org--parse-org-timestamp
                          (concat "[" m2 "]"))))))
          (when a
            (when (or (null earliest) (time-less-p a earliest)) (setq earliest a))
            (when (or (null latest) (time-less-p latest a)) (setq latest a)))
          (when b
            (when (or (null latest) (time-less-p latest b)) (setq latest b)))))
      (when earliest (cons earliest latest)))))

(defun claude-code-ide-org--heading-bracket (range created)
  "Return (EARLIEST . LATEST) spanning a heading's whole recorded life.

RANGE is `claude-code-ide-org--heading-activity-range''s clock extent;
CREATED is the `:CREATED:' stamp.  The bracket spans both, which is the
correction recorded in TODO.org :ID: 49cbe319: the clock extent alone
misses the heading most likely to be wanted, because a heading created
during a span but not yet clocked has no clock extent at all.  Work
happens, then the heading gets written -- so `:CREATED:' is the left
edge far more often than the first CLOCK line is.

Nil only when the heading has neither, which cannot be ranked and must
not be mistaken for a bracket at the epoch."
  (let ((points (delq nil (list (car-safe range) (cdr-safe range) created))))
    (when points
      (let ((sorted (sort points #'time-less-p)))
        (cons (car sorted) (car (last sorted)))))))

(defun claude-code-ide-org--interval-gap (a-start a-end b-start b-end)
  "Seconds separating intervals A and B; 0 when they touch or overlap.

Overlap is the strongest evidence available that a heading is what a
span was spent on, so it collapses to 0 and nothing outranks it.
Otherwise the distance is to the nearest endpoint, symmetrically -- which
interval is later must not change the answer."
  (cond ((time-less-p a-end b-start) (float-time (time-subtract b-start a-end)))
        ((time-less-p b-end a-start) (float-time (time-subtract a-start b-end)))
        (t 0)))

(defun claude-code-ide-org--format-activity-range (range created &optional reference)
  "Render a heading's bracket as a compact fixed-width field.

REFERENCE, when given, is a time from the span being assigned.  A
bracket falling on the same calendar day renders as *times* rather than
dates, because day resolution carries no information in exactly the case
it is most used: every candidate touched today otherwise reads
`08-15' against a span that is also 08-15.

Shows the merged bracket (`claude-code-ide-org--heading-bracket'), so
the field and the ranking answer the same question.  `made' is kept only
for a heading with no clock history at all, where the distinction
between \"created then\" and \"worked then\" is real."
  (let* ((bracket (claude-code-ide-org--heading-bracket range created))
         (same-day (lambda (a b)
                     (and a b (equal (format-time-string "%Y-%m-%d" a)
                                     (format-time-string "%Y-%m-%d" b)))))
         (fmt (if (and reference bracket
                       (funcall same-day (car bracket) reference)
                       (funcall same-day (cdr bracket) reference))
                  "%H:%M" "%m-%d")))
    (cond
     ((and bracket (or (car-safe range) (cdr-safe range)))
      (let ((a (format-time-string fmt (car bracket)))
            (b (format-time-string fmt (cdr bracket))))
        (format "%-13s" (if (equal a b) a (format "%s..%s" a b)))))
     (bracket (format "%-13s" (format "made %s"
                                      (format-time-string fmt (car bracket)))))
     (t (make-string 13 ?\s)))))

(defun claude-code-ide-org--short-id (id)
  "Return the first 8 characters of ID, or all of it when shorter.

A bare `(substring id 0 8)' signals on anything shorter, which real
UUIDs never are -- so the assumption held until a test used a short id
and crashed the *render*. Display code should degrade, not signal: a
truncated label is a cosmetic problem, an error in the middle of drawing
a review buffer is not."
  (and id (substring id 0 (min 8 (length id)))))

(defun claude-code-ide-org--review-heading-title (id)
  "Return ID's heading title, or nil when ID resolves to nothing."
  (when id
    (let ((marker (ignore-errors (org-id-find id 'marker))))
      (when marker
        (prog1 (org-with-point-at marker
                 (org-no-properties (org-get-heading t t t t)))
          (set-marker marker nil))))))

;;; Span evidence ------------------------------------------------------------
;;
;; What was going on between two timestamps, answered from artefacts the
;; work left behind rather than from a transcript or a model (TODO.org
;; :ID: 5ff5a4b8).  Two sources, and they differ in strength:
;;
;;   - a `:CREATED:' stamp *inside* the window is the best evidence there
;;     is, because a heading written during that time names what was being
;;     thought about;
;;   - a commit is next best, and anchors the window rather than bounding
;;     it, since its timestamp marks when work was finished.
;;
;; Deliberately evidence and not a recommendation.  The suggestion machinery
;; already guesses a heading; this shows the human what the guess is made of,
;; and a mechanical list is easier to reject than a fluent argument would be.

(defun claude-code-ide-org--git-roots ()
  "Distinct git roots containing the tracked org files.

Derived from `claude-code-ide-org--tracked-files' rather than from
`default-directory', which at review time is wherever the human happened
to be when they ran the command -- quite possibly another project, or
$HOME.

Truenames first, then `locate-dominating-file': the tracked path is
normally `~/org/claude-code-ide-org/TODO.org', a symlink into the repo,
and walking up from the symlink's own directory finds no .git at all."
  (let (roots)
    (dolist (file (claude-code-ide-org--tracked-files))
      (let ((true (ignore-errors (file-truename file))))
        (when (and true (file-exists-p true))
          (let ((root (locate-dominating-file true ".git")))
            (when root (push (file-truename root) roots))))))
    (delete-dups roots)))

(defun claude-code-ide-org--commits-in-window (start end)
  "Commits between START and END, as a list of (TIME . DESCRIPTION).

Committer date throughout -- `--since'/`--until' filter on it, so `%ct'
is what makes the timestamp shown agree with the timestamp filtered on.

`--all' rather than the current branch: a concurrent session on its own
branch was still work happening in this window, and which ref it landed
on says nothing about when.  Git dedupes by commit object, so a commit
reachable from both a local branch and its remote appears once.

Never signals.  A missing git, a directory that stopped being a
repository, an unparseable line -- each degrades to \"no commits\", which
is the same thing the human sees today."
  (let (rows)
    (dolist (root (claude-code-ide-org--git-roots))
      (with-temp-buffer
        (let ((status (ignore-errors
                        (call-process
                         "git" nil t nil "-C" root "log" "--all"
                         (concat "--since="
                                 (format-time-string "%Y-%m-%dT%H:%M:%S%z" start))
                         (concat "--until="
                                 (format-time-string "%Y-%m-%dT%H:%M:%S%z" end))
                         "--format=%ct%x09%h%x09%s"))))
          (when (eql status 0)
            (goto-char (point-min))
            (while (re-search-forward "^\\([0-9]+\\)\t\\([^\t]+\\)\t\\(.*\\)$" nil t)
              (push (cons (seconds-to-time (string-to-number (match-string 1)))
                          (format "commit  %s %s"
                                  (match-string 2) (match-string 3)))
                    rows))))))
    rows))

(defun claude-code-ide-org--creations-in-window (start end)
  "Headings created between START and END, as a list of (TIME . DESCRIPTION).

Scoped to `claude-code-ide-org--assignable-files' -- the tracked files
plus their archive targets -- for the same reason assignment is: a
heading created during the span may have been archived since, and it is
still the best answer to what the span was about.

`:CREATED:' is a property, so this is a property read per entry rather
than a text scan.  A malformed stamp is skipped rather than allowed to
signal: this runs inside `claude-code-ide-org--review-render'."
  (let (rows)
    (ignore-errors
      (org-map-entries
       (lambda ()
         (let* ((created (org-entry-get nil "CREATED"))
                (time (and created
                           (ignore-errors
                             (claude-code-ide-org--parse-org-timestamp created)))))
           (when (and time
                      (not (time-less-p time start))
                      (not (time-less-p end time)))
             (push (cons time
                         (format "created %s"
                                 (org-no-properties (org-get-heading t t t t))))
                   rows))))
       t
       (claude-code-ide-org--assignable-files)))
    rows))

(defun claude-code-ide-org--span-evidence (start end)
  "Return display lines naming what happened in the span START--END.

The window runs from START to END plus
`claude-code-ide-org-span-evidence-slack'.  Commits and heading creations
are interleaved in one chronological list, because the order between them
is itself the signal: a heading created at 15:33 followed by a commit at
15:34 tells a story neither line tells alone.

Stretches of the span with no evidence in them are reported too, as
gaps, whenever they exceed `claude-code-ide-org-span-evidence-gap' --
see that variable for why an absence is the more useful half.

Capped at `claude-code-ide-org-span-evidence-limit', with the overflow
reported as a count.  The cap applies to evidence only: gaps are
computed from every row, so truncating the display cannot invent a gap
that is not there."
  (let* ((window-end (time-add end claude-code-ide-org-span-evidence-slack))
         (rows (sort (append (claude-code-ide-org--commits-in-window start window-end)
                             (claude-code-ide-org--creations-in-window start window-end))
                     (lambda (a b) (time-less-p (car a) (car b)))))
         (gaps (claude-code-ide-org--span-gaps start end (mapcar #'car rows)))
         (extra (- (length rows) claude-code-ide-org-span-evidence-limit))
         (shown (if (> extra 0) (butlast rows extra) rows))
         entries)
    ;; Evidence first in the input list, so the stable sort below keeps a
    ;; gap *after* the evidence line it starts from -- an interior gap is
    ;; keyed on the timestamp of the row it follows, and the two would
    ;; otherwise render in an order that reads backwards.
    (dolist (row shown)
      (push (cons (car row)
                  (format "%s  %s"
                          (format-time-string "%H:%M" (car row))
                          (cdr row)))
            entries))
    (dolist (gap gaps)
      (push (cons (car gap)
                  (format "%7s(nothing for %s, %s-%s)" ""
                          (claude-code-ide-org--format-duration (cdr gap))
                          (format-time-string "%H:%M" (car gap))
                          (format-time-string
                           "%H:%M" (time-add (car gap) (cdr gap)))))
            entries))
    (let ((lines (mapcar #'cdr
                         (sort (nreverse entries)
                               (lambda (a b) (time-less-p (car a) (car b)))))))
      (when (> extra 0)
        (setq lines (append lines
                            (list (format "%7s... %d more in this window"
                                          "" extra)))))
      lines)))

(defun claude-code-ide-org--format-duration (seconds)
  "Render SECONDS as a compact duration, e.g. \"6m\" or \"1h04m\"."
  (let ((mins (round (/ seconds 60.0))))
    (if (>= mins 60)
        (format "%dh%02dm" (/ mins 60) (% mins 60))
      (format "%dm" mins))))

(defun claude-code-ide-org--span-gaps (start end times)
  "Return (GAP-START . SECONDS) for stretches of START--END holding no TIMES.

Measured against the span itself, never the slack window: a commit after
the span's end concluded it rather than filled it, so it closes no gap.
An empty span therefore yields one gap covering the whole of it, which is
the case worth surfacing most -- before this, a span with no evidence
rendered nothing at all, and \"nothing was found here\" looked exactly
like \"nobody looked\".

Only stretches of at least `claude-code-ide-org-span-evidence-gap' are
returned; below that a gap is the ordinary pause between a thought and
its commit and reporting it would be noise."
  (let* ((inside (sort (seq-filter (lambda (ts)
                                     (and (not (time-less-p ts start))
                                          (not (time-less-p end ts))))
                                   times)
                       #'time-less-p))
         (points (append (list start) inside (list end)))
         gaps)
    (while (cdr points)
      (let ((seconds (float-time (time-subtract (cadr points) (car points)))))
        (when (>= seconds claude-code-ide-org-span-evidence-gap)
          (push (cons (car points) seconds) gaps)))
      (setq points (cdr points)))
    (nreverse gaps)))

(defvar-local claude-code-ide-org--span-evidence-cache nil
  "Hash table memoizing `claude-code-ide-org--span-evidence' per window.

`claude-code-ide-org--review-render' runs on every keystroke that marks
or unmarks an item, and the evidence costs a `git log' plus a walk of
every tracked heading.  Recomputing that per keystroke is what would make
marking a run of items feel broken.

Keyed on the window rather than on the item, so narrowing a span with `e'
misses the cache and re-reads -- the answer really is different for a
different window.  Cleared by `g', which is the command that exists to go
back to the queue and the files for fresh answers.")

(defun claude-code-ide-org--span-evidence-cached (item)
  "Evidence lines for ITEM's span, computed once per window per buffer."
  (let ((start (plist-get item :start))
        (end (plist-get item :end)))
    (when (and start end)
      (unless claude-code-ide-org--span-evidence-cache
        (setq claude-code-ide-org--span-evidence-cache
              (make-hash-table :test 'equal)))
      (let* ((key (list (float-time start) (float-time end)))
             (hit (gethash key claude-code-ide-org--span-evidence-cache 'miss)))
        (if (eq hit 'miss)
            (puthash key
                     ;; Display code degrades, it does not signal: half a
                     ;; review buffer is worse than no evidence.
                     (ignore-errors
                       (claude-code-ide-org--span-evidence start end))
                     claude-code-ide-org--span-evidence-cache)
          hit)))))

(defvar-local claude-code-ide-org--review-id-health nil
  "Cached `claude-code-ide-org--id-health' result for this review buffer.
Computed when the buffer is built and by `g', never during a redraw:
marking a line re-renders, and a scan on every keystroke would be a
tax paid for a number that cannot have changed.")

(defun claude-code-ide-org--id-health ()
  "Return (:missing N :misfiled M) describing `org-id-locations'.

MISSING counts ids that no known file contains any more -- the heading
was deleted, or a git operation rewrote the file out from under it.
MISFILED counts ids that still exist, but in a different file than the
one recorded.  Keeping them apart is the point: they are different
defects with different fixes, and `org-id-find' cannot distinguish them
because both simply return nil (TODO.org :ID: 8e969114).

Scans each distinct file once rather than resolving each id, which is
what makes this cheap enough to run when the review buffer opens.
Measured 2026-08-17: 0.018 s over 7 files, against 0.218 s for 161
`org-id-find' calls.  The time is the lesser reason -- resolving an id
*visits* its file, so the per-id sweep pulled four buffers into the
user's Emacs as a side effect, where this visits nothing.  It also
scales on file count rather than id count, and this project accumulates
ids far faster than files (161 against 7)."
  (let ((by-file (make-hash-table :test 'equal))
        (missing 0)
        (misfiled 0))
    (when (hash-table-p org-id-locations)
      (maphash
       (lambda (_id file)
         (unless (gethash file by-file)
           (puthash file
                    (let ((ids (make-hash-table :test 'equal))
                          (path (expand-file-name file)))
                      (when (file-readable-p path)
                        (with-temp-buffer
                          (insert-file-contents path)
                          (goto-char (point-min))
                          (while (re-search-forward
                                  "^[ \t]*:ID:[ \t]+\\([^ \t\n]+\\)" nil t)
                            (puthash (match-string 1) t ids))))
                      ids)
                    by-file)))
       org-id-locations)
      (maphash
       (lambda (id file)
         (unless (gethash id (gethash file by-file))
           (if (catch 'found
                 (maphash (lambda (_f ids)
                            (when (gethash id ids) (throw 'found t)))
                          by-file)
                 nil)
               (setq misfiled (1+ misfiled))
             (setq missing (1+ missing)))))
       org-id-locations))
    (list :missing missing :misfiled misfiled)))

(defun claude-code-ide-org--review-id-health-line ()
  "Return a one-line report on stale `org-id-locations' entries, or nil.

Nil when everything resolves, deliberately.  A line reading \"0
unresolvable\" on every pass is noise that trains the eye to skip the
line that matters -- the same self-limiting reasoning as
`claude-code-ide-org-write-session-start-report', which stays silent
unless it has something to say.

The condition it reports is otherwise invisible: stale entries produce
org-element warnings in *Warnings* and silently shrink the assignment
prompt's candidate list, and nothing in this buffer said so.  On
2026-08-17 that hid 22 of 151."
  (let* ((health claude-code-ide-org--review-id-health)
         (missing (or (plist-get health :missing) 0))
         (misfiled (or (plist-get health :misfiled) 0))
         (total (+ missing misfiled)))
    (when (> total 0)
      (format "  %d org-id entr%s stale: %d heading%s gone, %d in another file.  M-x org-id-update-id-locations\n\n"
              total (if (= total 1) "y" "ies")
              missing (if (= missing 1) "" "s")
              misfiled))))

(defun claude-code-ide-org--review-render ()
  "Render `claude-code-ide-org--review-items' into the current buffer.

Re-judges staleness before drawing, projecting over *marked* items only:
an unmarked item will not move any file, so it must not be allowed to
excuse a later one.  With nothing marked the projection collapses to the
file's own state and every line reads exactly as it did before chains
were understood -- marking the first link of a chain is what stops the
rest from lighting up."
  (let ((inhibit-read-only t)
        (items claude-code-ide-org--review-items)
        (last-id nil))
    (claude-code-ide-org--review-projected-staleness
     items (lambda (item) (plist-get item :marked)))
    (erase-buffer)
    (insert "Pending org updates.  m/u mark, M/U all, t invert, "
            "a assign, e interval, N note,\n"
            "d dismiss, RET goto, x apply marked, g refresh, q quit\n\n")
    (let ((health-line (claude-code-ide-org--review-id-health-line)))
      (when health-line (insert health-line)))
    (if (null items)
        (insert "  Nothing pending.\n")
      (dolist (item items)
        (unless (equal (plist-get item :id) last-id)
          (setq last-id (plist-get item :id))
          ;; Resolved through `org-id-find' rather than
          ;; `claude-code-ide-org--at-id', for two reasons. `--at-id'
          ;; *returns* the string "Error: no org heading found with :ID:
          ;; ..." rather than signalling, and a `cond' clause of the form
          ;; `((--at-id ...))' yields its own test -- so an unresolvable
          ;; :ID: used to render that error message as the group heading,
          ;; leaving the `(t last-id)' fallback beneath it unreachable.
          ;; And guarding the marker keeps this call site out of the nil
          ;; trap in :ID: 09230b93.
          (let* ((marker (and last-id (ignore-errors (org-id-find last-id 'marker))))
                 (title (and marker
                             (ignore-errors
                               (org-with-point-at marker
                                 (org-no-properties (org-get-heading t t t t)))))))
            (insert (format "\n%s\n"
                            (cond
                             ;; A span nobody has assigned yet belongs to no
                             ;; heading, so it gets its own group rather than
                             ;; rendering the literal string "nil" as a title.
                             ((null last-id)
                              "(unassigned -- press `a' to choose a heading)")
                             ;; Prefix first, mirroring how a response
                             ;; footnotes a heading (:ID: c2132d3f). Not
                             ;; taste: `--short-id' is exactly 8 characters
                             ;; for any real UUID, so leading with it puts
                             ;; every id in one column and every title in a
                             ;; second. A trailing `{id}' cannot line up,
                             ;; because title lengths vary -- which is what
                             ;; makes it hard to scan in a buffer whose whole
                             ;; job is scanning.
                             (title (format "%s  %s"
                                            (claude-code-ide-org--short-id last-id)
                                            title))
                             (t (format "%s  (unresolved)"
                                        (claude-code-ide-org--short-id last-id))))))))
        (insert (propertize
                 (format "  [%s] %s\n"
                         (if (plist-get item :marked) "x" " ")
                         (claude-code-ide-org--review-describe item))
                 'claude-code-ide-org-item item))
        ;; Evidence goes under the unassigned spans only -- the items that
        ;; pose a question.  An assigned span has already been answered, and
        ;; a state item has no window to look in.
        ;;
        ;; Left unpropertized on purpose: without the item property these
        ;; lines behave exactly as the group headings do, so `m', `n' and
        ;; `--review-forward-item' step over them rather than onto them.
        (when (and (eq (plist-get item :type) 'clock)
                   (plist-get item :unassigned))
          (dolist (line (claude-code-ide-org--span-evidence-cached item))
            (insert (format "          %s\n" line))))))
    (goto-char (point-min))))

(defun claude-code-ide-org--review-set-mark (marked &optional advance)
  "Set the current line's item :marked to MARKED and re-render.

With ADVANCE non-nil, leave point on the next item afterwards.  That is
what makes marking a run of items `m m m' rather than `m n m n m', and
it is what dired, `package-menu' and magit all do; its absence was the
single biggest complaint after the first real by-hand apply.

Marking a stale state item asks for confirmation first, and records the
answer on the item as :stale-confirmed.  This is the deliberate override
`claude-code-ide-org--review-apply-item' requires: the design's premise
is that the human is the validation step, so a stale transition must be
refusable by default and still applicable on purpose -- but never by
default, and never without having been told.  A `y-or-n-p' is safe here
in a way it is not elsewhere in this module: this is a genuinely
interactive command with a human at the keyboard, not an
`emacsclient -e' call with nobody present to answer."
  (let ((item (claude-code-ide-org--review-item-at-point)))
    (unless item (user-error "No review item on this line"))
    (when (and marked (claude-code-ide-org--review-state-stale-p item))
      (if (y-or-n-p
           (format "Stale: queued %s -> %s, but heading is now %s.  Apply anyway? "
                   (plist-get item :from)
                   (plist-get item :to)
                   (or (claude-code-ide-org--review-current-state (plist-get item :id))
                       "unset")))
          (plist-put item :stale-confirmed t)
        (setq marked nil)))
    (plist-put item :marked marked)
    (claude-code-ide-org--review-redraw item advance)))

(defun claude-code-ide-org--review-goto-line (line)
  "Move point to LINE, 1-based, in the current buffer.
Re-rendering erases the buffer, so every command that re-renders has to
put point back by line number; this is that one line of arithmetic,
named once."
  (goto-char (point-min))
  (forward-line (1- line)))

(defun claude-code-ide-org--review-redraw (item &optional advance)
  "Re-render, then put point back on ITEM.  With ADVANCE, on the next item.

The one path every command that *mutates an item* should take, so that
point handling stops being each command's own decision to remember or
forget.  It was forgotten twice: `a' and `e' both dropped point at the
top of the buffer, which meant assigning a run of spans required
scrolling back to find your place after every one.

ADVANCE encodes the rule the mark commands arrived at first: advance
when the command *answers* the question the line posed -- marking,
assigning, dismissing -- and stay when it does not.  `e' narrows an
interval you are still deciding about and `N' annotates one, so both
leave point where it was.

Deliberately not used by `g'.  That command means \"rebuild from the
queue\" and discards session state on purpose; restoring point into a
list that may no longer contain the same items would only look like it
had preserved something."
  (claude-code-ide-org--review-render)
  (when (claude-code-ide-org--review-goto-item item)
    (when advance (claude-code-ide-org--review-forward-item))))

(defun claude-code-ide-org--review-goto-item (item)
  "Move point to the line carrying ITEM.  Return non-nil when found.

By *identity* rather than by line number, unlike
`claude-code-ide-org--review-goto-line'.  The commands that only toggle a
flag leave the buffer the same height, so arithmetic is enough for them.
Assigning does not: an unassigned span carries its evidence lines
underneath and an assigned one does not, so several lines vanish beneath
the item in the same render that moves it into a heading's group.  The
line it occupied before is not the line it occupies after, and restoring
by number lands on whatever slid up into the gap."
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (not (eobp)))
      (if (eq (claude-code-ide-org--review-item-at-point) item)
          (setq found t)
        (forward-line 1)))
    (unless found (goto-char (point-min)))
    found))

(defun claude-code-ide-org--review-forward-item ()
  "Move point to the next line carrying a review item.

Stays put when there is no next item, rather than landing on a blank or
group-heading line.  That matters because the mark commands advance:
running off the end would leave point somewhere that is not an item, and
the next keystroke would then report \"No review item on this line\"
instead of acting on the obvious target."
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (claude-code-ide-org--review-item-at-point)))
      (forward-line 1))
    (unless (claude-code-ide-org--review-item-at-point)
      (goto-char start))))

(defun claude-code-ide-org--review-markable-p (item)
  "Non-nil when ITEM can be marked without asking the human anything.

An unassigned span with no suggestion is refused: it names no heading,
so applying it could only write the interval nowhere.  `a'
\(`claude-code-ide-org-review-assign') is the way forward for those, and
refusing the mark is what makes that visible rather than letting apply
fail later with a confusing error."
  (and (not (and (plist-get item :unassigned)
                 (null (plist-get item :id))))
       (or (not (claude-code-ide-org--review-state-stale-p item))
           (plist-get item :stale-confirmed))))

(defun claude-code-ide-org--review-set-all (fn)
  "Set every item's :marked to (funcall FN ITEM), then re-render.

Refuses to *mark* a stale, unconfirmed item.  Those exist precisely to
be decided one at a time, and a bulk command that popped a `y-or-n-p'
for each would be worse than offering no bulk command at all -- it is
the prompt-fatigue failure `6b1e73c4' already argued against.  Unmarking
is never refused, since it asks nothing of anyone.  Reports the count it
skipped rather than leaving the human to notice."
  (let ((line (line-number-at-pos))
        (skipped 0))
    (dolist (item claude-code-ide-org--review-items)
      (let ((want (funcall fn item)))
        (if (and want (not (claude-code-ide-org--review-markable-p item)))
            (setq skipped (1+ skipped))
          (plist-put item :marked want))))
    (claude-code-ide-org--review-render)
    (claude-code-ide-org--review-goto-line line)
    (when (> skipped 0)
      (message "%d stale item(s) left unmarked -- mark individually to confirm"
               skipped))))

(defun claude-code-ide-org-review-mark ()
  "Mark the item at point and move to the next one."
  (interactive)
  (claude-code-ide-org--review-set-mark t 'advance))

(defun claude-code-ide-org-review-unmark ()
  "Unmark the item at point and move to the next one."
  (interactive)
  (claude-code-ide-org--review-set-mark nil 'advance))

(defun claude-code-ide-org-review-mark-all ()
  "Mark every item, skipping any that needs a stale confirmation."
  (interactive)
  (claude-code-ide-org--review-set-all (lambda (_item) t)))

(defun claude-code-ide-org-review-unmark-all ()
  "Unmark every item."
  (interactive)
  (claude-code-ide-org--review-set-all (lambda (_item) nil)))

(defun claude-code-ide-org-review-toggle-all ()
  "Invert every mark, skipping any item that needs a stale confirmation.

Bound to `t', which previously toggled the single item at point.  That
binding went rather than moving, because dired -- whose vocabulary this
mode borrows for `m'/`u'/`t'/`U' -- has no per-line toggle either, and
does not need one once `m' and `u' advance on their own."
  (interactive)
  (claude-code-ide-org--review-set-all
   (lambda (item) (not (plist-get item :marked)))))

(defun claude-code-ide-org-review-edit-note ()
  "Edit the note on the item at point.

The note is the other half of what reaches the file: it becomes the
`\\\\' continuation on a State line, or the label on a clock interval's
:LOGBOOK: annotation.  It is also the half a human is best placed to
improve -- Claude wrote it *before* doing the work, in three to ten
words, and by review time the human knows what the work actually turned
out to be.  This is the last moment it can be corrected before it
becomes history."
  (interactive)
  (let ((item (claude-code-ide-org--review-item-at-point)))
    (unless item (user-error "No review item on this line"))
    (plist-put item :note
               (read-string "Note: " (or (plist-get item :note) "")))
    ;; No advance: annotating an item does not decide it.
    (claude-code-ide-org--review-redraw item)))

(defun claude-code-ide-org-review-goto ()
  "Show the org heading the item at point belongs to, in another window.

Deliberately *not* `org-id-goto', which is what this used to call.  That
function ends in `pop-to-buffer-same-window', so it displaced the review
buffer with the very file the review buffer exists to talk about --
hiding the list of items at the exact moment you wanted to compare one
against its heading.  The org file is normally already visible in another
window anyway (that is how the review command is usually invoked), so
the same-window jump also produced a second window onto a buffer that was
right there.

`inhibit-same-window' is passed explicitly rather than left to
`display-buffer's defaults.  The defaults would usually do the right
thing, but `display-buffer-alist' is user configuration -- a rule that
routes org buffers somewhere specific would otherwise be free to put this
one back over the review buffer, which is the one placement that must
never happen.

Pushes the org mark ring first, so `\\[org-mark-ring-goto]' returns to
wherever point was in that buffer before the jump.  Reusing the existing
window means that position would otherwise just be lost, and it is
usually the place the human was reading when they ran the review."
  (interactive)
  (let ((item (claude-code-ide-org--review-item-at-point)))
    (unless item (user-error "No review item on this line"))
    (let ((id (plist-get item :id)))
      ;; An unassigned span names no heading at all, and a capture names
      ;; one that apply has not written yet.  Both are ordinary states
      ;; here, not failures, so they get an answer that says what to do
      ;; rather than `org-id-goto's bare "Cannot find entry".
      (unless id
        (user-error "This span is not assigned to a heading yet; press `a' to choose one"))
      (let ((marker (ignore-errors (org-id-find id 'marker))))
        (unless marker
          (if (eq (plist-get item :type) 'capture)
              (user-error "Not written yet -- this heading's capture is still pending; apply it first")
            (user-error "No heading found with :ID: %s" id)))
        (pop-to-buffer (marker-buffer marker) '(nil (inhibit-same-window . t)))
        (org-mark-ring-push)
        (goto-char marker)
        (set-marker marker nil)
        (if (fboundp 'org-fold-show-context)
            (org-fold-show-context 'org-goto)
          (org-show-context 'org-goto))
        (claude-code-ide-org--show-logbook)))))

(defun claude-code-ide-org--show-logbook ()
  "Unfold the :LOGBOOK: drawer of the heading at point, if it has one.

`org-fold-show-context' reveals the entry but leaves drawers closed, so
RET from the review buffer used to land on a folded `:LOGBOOK:...' line
-- and the drawer is the entire reason to jump: the CLOCK lines and
annotations you are comparing the review item against are inside it.

Silent when the heading has no drawer, and bounded to the heading's own
body so a child's drawer is never opened instead of the parent's.  Never
signals: this runs at the end of a navigation command, where an error
would leave point moved and the command reported as failed."
  (ignore-errors
    (save-excursion
      (org-back-to-heading t)
      (let* ((end (save-excursion (org-end-of-subtree t t) (point)))
             ;; Stop at the first child: a heading with no drawer of its
             ;; own would otherwise open its first child's, which looks
             ;; like it worked and shows the wrong intervals.
             (child (save-excursion
                      (forward-line 1)
                      (and (re-search-forward org-heading-regexp end t)
                           (line-beginning-position))))
             (limit (or child end)))
        (when (re-search-forward "^[ \t]*:LOGBOOK:" limit t)
          (beginning-of-line)
          (org-fold-hide-drawer-toggle 'off t))))))

(defun claude-code-ide-org-review-edit-interval ()
  "Edit the endpoints of the clock item at point.
Reads both back as org timestamp strings, so a suggested span can be
corrected to what actually happened before anything is written."
  (interactive)
  (let ((item (claude-code-ide-org--review-item-at-point)))
    (unless item (user-error "No review item on this line"))
    (unless (eq (plist-get item :type) 'clock)
      (user-error "Only clock items have an interval to edit"))
    (let* ((fmt "[%Y-%m-%d %a %H:%M]")
           (start (read-string "Start: " (format-time-string fmt (plist-get item :start))))
           (end (read-string "End: " (format-time-string fmt (plist-get item :end))))
           (start-time (claude-code-ide-org--parse-org-timestamp start))
           (end-time (claude-code-ide-org--parse-org-timestamp end)))
      (unless (and start-time end-time)
        (user-error "Could not parse those timestamps"))
      (when (time-less-p end-time start-time)
        (user-error "End is before start"))
      ;; Re-scope the backing events to the new endpoints, and offer
      ;; whatever falls outside as fresh items *immediately*.
      ;;
      ;; Without this, narrowing was silently destructive: `--review-apply'
      ;; marks every event in `:events' consumed, so an item edited down
      ;; to a fraction of its span still swallowed the whole original.
      ;; Measured 2026-08-13 -- a 54-minute span truncated to 23 minutes
      ;; consumed 32 minutes that never came back (TODO.org :ID:
      ;; ffe65444). Skipping an item was always conservative; narrowing
      ;; one was not, and nothing said so.
      ;;
      ;; Splitting on the spot rather than at the next refresh matters
      ;; because the remainder is the whole reason to narrow: the human
      ;; is mid-thought about which task the tail belongs to, and making
      ;; them re-find it after a refresh is where it gets abandoned.
      (let* ((events (plist-get item :events))
             (inside (seq-filter
                      (lambda (e)
                        (let ((ts (plist-get e :ts)))
                          (and (not (time-less-p ts start-time))
                               (not (time-less-p end-time ts)))))
                      events))
             (outside (seq-remove (lambda (e) (memq e inside)) events)))
        (plist-put item :start start-time)
        (plist-put item :end end-time)
        (plist-put item :events inside)
        ;; An edited interval is a confirmed one, not a suggestion.
        (plist-put item :suggested nil)
        (when outside
          (claude-code-ide-org--review-insert-remainders item outside)))
      ;; No advance: narrowing an interval does not finish it.  `e' is
      ;; the step taken *before* assigning, so point stays on the span
      ;; the human is still working on.
      (claude-code-ide-org--review-redraw item))))

(defun claude-code-ide-org--review-insert-remainders (item events)
  "Add items covering EVENTS, the events ITEM no longer spans.

Clustered with the same gap threshold the original spans used, so a
remainder separated by a long pause becomes two items rather than one
implausible interval.

A remainder inherits ITEM's heading as a *suggestion* but is marked
unassigned again when the original was reconstructed: narrowing usually
means the tail belongs somewhere else, which is the whole reason the
human reached for `e'.  Never inherits `:marked' -- a remainder is a new
decision, not part of the batch already confirmed."
  (let ((threshold claude-code-ide-org-guidepost-gap-threshold))
    (dolist (span (claude-code-ide-org--aggregate-guideposts events threshold))
      ;; Skip a zero-width remainder. On the main path a lone guidepost
      ;; is real evidence that something happened at that moment, so a
      ;; zero-width span is honest and worth offering. As a *remainder*
      ;; it is an artifact of where the human drew the line -- one event
      ;; landing outside the new endpoints -- and offering it produces a
      ;; spurious item whose only possible answer is `d' (reported from
      ;; use, 2026-08-13, after widening a span's start).
      ;;
      ;; Dropping the item does NOT drop the event: an event belonging to
      ;; no item is never marked applied, so it stays pending and
      ;; re-clusters with its neighbours on the next build. That is the
      ;; same conservation property this whole function exists to
      ;; restore, applied to its own output.
      (unless (time-equal-p (car span) (cdr span))
        (let ((new (copy-sequence item)))
          (setq new (plist-put new :start (car span)))
          (setq new (plist-put new :end (cdr span)))
          (setq new (plist-put new :marked nil))
          (setq new (plist-put new :suggested t))
          (setq new (plist-put new :events
                               (seq-filter
                              (lambda (e)
                                (let ((ts (plist-get e :ts)))
                                  (and (not (time-less-p ts (car span)))
                                       (not (time-less-p (cdr span) ts)))))
                              events)))
          (when (eq (plist-get item :origin) 'unbracketed)
            (setq new (plist-put new :unassigned t))
            (setq new (plist-put new :assigned nil)))
          (setq claude-code-ide-org--review-items
                (append claude-code-ide-org--review-items (list new))))))))

(defun claude-code-ide-org--assign-candidates (span-start span-end)
  "Return (DISPLAY . ID) pairs for assigning SPAN-START--SPAN-END, best first.

Ranked by how close each heading's bracket
\(`claude-code-ide-org--heading-bracket') sits to the span, nearest
first, with overlap collapsing to zero.  TODO.org :ID: 49cbe319.

*Nothing is excluded*, and that is the fix for :ID: 0d055205.  This
previously dropped any heading whose `:CREATED:' was later than the
span, calling it \"a hard impossibility\".  It is the normal case: work
happens and the heading is written afterwards, which this project's own
convention requires.  For one span on 2026-08-15 that removed exactly
the five headings created that day -- every candidate the user could
plausibly have wanted -- and `completing-read' runs with REQUIRE-MATCH,
so the heading was simply unreachable with no explanation.

Ranking subsumes the demotion that bug was reaching for: a heading
created five minutes after a span scores five minutes and stays near the
top, one created a week later sorts far down on its own.  No separate
rule is needed, and none is a cliff.

Ties break on open-before-finished, then on creation recency.  A
heading with no bracket at all -- neither `:CREATED:' nor a CLOCK line --
sorts last rather than vanishing: absence of evidence rules nothing out."
  (let ((allowed (claude-code-ide-org--assignable-files))
        rows)
    (maphash
     (lambda (id file)
       (when (member (file-truename file) allowed)
         (let* ((marker (ignore-errors (org-id-find id 'marker)))
                ;; `org-with-point-at' does NOT switch buffers when handed
                ;; nil: its expansion calls `set-buffer' only under
                ;; `(markerp ...)', then falls through to
                ;; `(goto-char (or nil (point)))'. So a nil marker means
                ;; the body runs in whatever buffer happens to be current
                ;; -- during a review pass, `*org-review*' -- where
                ;; `org-get-heading'/`org-entry-get' go through org-element
                ;; and warn "cannot be used in non-Org buffer". Measured
                ;; 2026-08-17: 45 such warnings in one pass, from 22 of 151
                ;; registered IDs that no longer resolved (TODO.org :ID:
                ;; 09230b93). Confirmed by macroexpanding it live, not read
                ;; off the docstring.
                ;;
                ;; Staleness cannot be prevented from inside this module --
                ;; a deleted heading, a git checkout, another session's
                ;; apply -- so tolerating nil here is the fix, not an
                ;; accompaniment to one. `--review-current-state' already
                ;; guards this way; this is the same shape.
                (info (and marker
                           (ignore-errors
                        (org-with-point-at marker
                          (list :title (org-no-properties
                                        (org-get-heading t t t t))
                                :state (org-get-todo-state)
                                ;; Guarded, and the guard is the fix for a
                                ;; defect the old code's own comment denied
                                ;; having: parsing "" signals, and the whole
                                ;; `info' form is wrapped in `ignore-errors',
                                ;; so a heading with no :CREATED: was dropped
                                ;; entirely rather than "kept -- absence of
                                ;; evidence rules nothing out". Invisible in
                                ;; production because every heading here has
                                ;; one; a fixture without one found it.
                                :created (let ((raw (org-entry-get nil "CREATED")))
                                           (and raw (ignore-errors
                                                      (claude-code-ide-org--parse-org-timestamp
                                                       raw))))
                                :range (claude-code-ide-org--heading-activity-range))))))
                (title (plist-get info :title))
                (created (plist-get info :created))
                (range (plist-get info :range))
                (state (plist-get info :state))
                (bracket (claude-code-ide-org--heading-bracket range created)))
           (when title
             (push (list (format "%s %s%s  {%s}"
                                 (claude-code-ide-org--format-activity-range
                                  range created span-start)
                                 (if (member state '("DONE" "CANCELLED"))
                                     (format "[%s] " state) "")
                                 title (claude-code-ide-org--short-id id))
                         id
                         (if bracket
                             (claude-code-ide-org--interval-gap
                              span-start span-end (car bracket) (cdr bracket))
                           most-positive-fixnum)
                         (if (member state '("DONE" "CANCELLED")) 1 0)
                         (if created (float-time created) 0))
                   rows)))))
     (or org-id-locations (make-hash-table :test 'equal)))
    (mapcar (lambda (r) (cons (nth 0 r) (nth 1 r)))
            (sort rows (lambda (a b)
                         (cond ((/= (nth 2 a) (nth 2 b)) (< (nth 2 a) (nth 2 b)))
                               ((/= (nth 3 a) (nth 3 b)) (< (nth 3 a) (nth 3 b)))
                               (t (> (nth 4 a) (nth 4 b)))))))))

(defun claude-code-ide-org--ordered-collection (candidates)
  "Return a `completing-read' collection over CANDIDATES that keeps their order.

CANDIDATES is an alist as `claude-code-ide-org--assign-candidates'
returns it, already sorted best-first.  A bare alist carries no
completion metadata, so the completion UI is free to re-sort it, and
Vertico does: `vertico-sort-history-length-alpha' orders by minibuffer
history, then string *length*, then alphabetically (TODO.org :ID:
85702dba).

Title length has no relationship to relevance, so that ranks an old DONE
heading with a terse title above this morning's work.  The list was never
unranked -- it was ranked on the wrong key, and the proximity ordering,
the `[DONE]' marker and the activity range built into each display string
were all computed and then discarded.  With `vertico-count' at 17 the
order decides what is seen at all.

Declaring `display-sort-function' and `cycle-sort-function' as `identity'
is what makes the computed order authoritative; Vertico honours the
metadata over its own `vertico-sort-function'.

Deliberately *not* a cutoff, though \"too many candidates\" invites one.
Excluding old or DONE headings is what :ID: 0d055205 was filed against,
and ordering achieves the same practical result with no cliff: everything
stays reachable by typing."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string predicate))))

(defun claude-code-ide-org-review-assign ()
  "Assign the span at point to a heading, replacing any suggestion.

Completes over the headings `org-id' knows about, titles shown rather
than raw IDs.  The current suggestion is the default, so accepting it is
`RET' and overriding it costs a few characters -- which is the whole
point of suggesting: 23 confirmations rather than 23 lookups (TODO.org
:ID: 3d0487f4).

Assigning clears `:unassigned', so the line stops reading as a question
and the item becomes markable like any other.  It does *not* clear
`:suggested': the interval endpoints are still reconstructed from
guideposts and still deserve `e' before they are trusted.  Only the
*heading* was decided here, not the times."
  (interactive)
  (let ((item (claude-code-ide-org--review-item-at-point)))
    (unless item (user-error "No review item on this line"))
    (unless (eq (plist-get item :type) 'clock)
      (user-error "Only a span can be assigned to a heading"))
    (let* ((candidates (claude-code-ide-org--assign-candidates
                        (plist-get item :start) (plist-get item :end)))
           (default (and (plist-get item :id)
                         (car (rassoc (plist-get item :id) candidates))))
           (choice (completing-read
                    (if default (format "Assign span to heading (default %s): " default)
                      "Assign span to heading: ")
                    (claude-code-ide-org--ordered-collection candidates)
                    nil t nil nil default)))
      (unless (and choice (not (string-empty-p choice)))
        (user-error "No heading chosen; span left unassigned"))
      (let ((id (cdr (assoc choice candidates))))
        (unless id (user-error "That heading has no :ID:"))
        (plist-put item :id id)
        (plist-put item :unassigned nil)
        (plist-put item :assigned t)
        ;; Advance: assigning *answers* the question this line posed.
        (claude-code-ide-org--review-redraw item t)))))

(defun claude-code-ide-org-review-dismiss ()
  "Retire the item at point permanently, so it stops being proposed.

For the item that will *never* apply, which skipping cannot express:
skipping is how a human defers, and the watermark deliberately keeps a
deferred item pending. Without this, the `dead-beef' phantom clock and
the pre-cutover transitions the tools already performed live come back
at every single review.

Asks for a reason and records it, because \"already applied live
pre-cutover\" and \"this event should never have existed\" read very
differently at a later audit. The `y-or-n-p' is safe here for the reason
given on `claude-code-ide-org--review-set-mark': the review buffer is
only ever reached from a genuinely interactive command, never from an
`emacsclient -e' call with nobody present to answer.

Dismisses the events the item was built from, per owning session, and
touches no org file at all."
  (interactive)
  (let ((item (claude-code-ide-org--review-item-at-point)))
    (unless item (user-error "No review item on this line"))
    (let ((events (plist-get item :events)))
      ;; Nothing to record against means the next refresh would rebuild
      ;; this line unchanged -- better to say so than to appear to work.
      (unless events
        (user-error "Nothing to dismiss: this item carries no queue events"))
      (let ((reason (read-string "Dismiss -- reason: ")))
        (when (y-or-n-p (format "Dismiss permanently: %s? "
                                (string-trim
                                 (claude-code-ide-org--review-describe item))))
          (let ((by-session (make-hash-table :test 'equal)))
            (dolist (event events)
              (push (plist-get event :ts-string)
                    (gethash (plist-get event :session-id) by-session)))
            (maphash (lambda (session-id ts-strings)
                       (when session-id
                         (claude-code-ide-org--queue-mark-dismissed
                          session-id ts-strings reason)))
                     by-session))
          ;; Drop the item in place rather than refreshing.  This used to
          ;; end in `claude-code-ide-org-review-refresh', which rebuilds
          ;; the item list from the queue and so discarded *every
          ;; unapplied decision in the session* -- assignments, edited
          ;; intervals, notes -- while appearing to act on one line.  The
          ;; dismissal is already durable in the queue by this point, so
          ;; there is nothing a rebuild would add beyond that loss.
          (let ((next (cadr (memq item claude-code-ide-org--review-items))))
            (setq claude-code-ide-org--review-items
                  (delq item claude-code-ide-org--review-items))
            ;; Advance, because dismissing answers the line's question as
            ;; surely as assigning does -- but onto the item that took its
            ;; place, since this one is gone.
            (if next
                (claude-code-ide-org--review-redraw next)
              (claude-code-ide-org--review-render))))))))

(defun claude-code-ide-org-review-refresh ()
  "Rebuild the review buffer from the queue, discarding session state.

That means every unapplied decision, not only marks: assigned headings,
edited intervals, notes and stale confirmations all live in
`claude-code-ide-org--review-items' until `x' applies them, and a
rebuild replaces that list wholesale.  The old wording said \"discarding
marks\", which undersold it -- marks are selection and cheap to redo,
whereas an assignment is judgement that has to be made again.  `g' is
typed deliberately, so discarding here is correct; it just has to say so.

Also drops the span-evidence cache.  `g' is the command that means \"go
and look again\", and a commit made since the buffer was drawn is exactly
the kind of thing a human presses it for."
  (interactive)
  (setq claude-code-ide-org--span-evidence-cache nil)
  ;; Recomputed here and only here, so the scan runs when the buffer is
  ;; built and when `g' is typed -- not on the redraw every mark triggers.
  ;; `g' already means "go and look again", which is exactly when a stale
  ;; org-id entry might have been fixed.
  (setq claude-code-ide-org--review-id-health (claude-code-ide-org--id-health))
  (setq claude-code-ide-org--review-items
        (claude-code-ide-org--review-items-from-queue))
  (claude-code-ide-org--review-render))

(defun claude-code-ide-org--review-read-only-buffers (items)
  "Return the distinct read-only buffers ITEMS would have to write to.

Resolves each :ID: the same way apply does, so the answer is about the
buffers apply will actually reach, not about whatever files are open.
An :ID: that does not resolve contributes nothing here -- apply reports
that on its own terms."
  (require 'org-id)
  (let (buffers)
    (dolist (item items)
      (let* ((marker (ignore-errors (org-id-find (plist-get item :id) 'marker)))
             (buffer (and marker (marker-buffer marker))))
        (when (and buffer
                   (buffer-local-value 'buffer-read-only buffer)
                   (not (memq buffer buffers)))
          (push buffer buffers))))
    (nreverse buffers)))

(defun claude-code-ide-org--review-ensure-writable (items)
  "Offer to clear read-only on every buffer ITEMS need to write.

Asked *before* anything is applied, and declining signals a
`user-error' that leaves the review buffer exactly as it was -- marks,
stale confirmations and edited intervals all intact.  Without this
check a read-only target does not merely fail: every item fails
individually with a `buffer-read-only' error, and the human's whole
round of decisions is gone, since they only exist in the review
buffer.  The user sets read-only (\\[read-only-mode]) to guard against
their own stray keystrokes, not to block this command, so being asked
is the whole fix -- but it is still their call, which is why this
prompts rather than binding `inhibit-read-only'.

A `y-or-n-p' is safe here for the same reason it is in
`claude-code-ide-org--review-set-mark': apply is only ever reached from
a genuinely interactive command, never from `emacsclient -e'.

Returns the buffers it actually cleared, so the caller can put the flag
back.  Returning them -- rather than having the caller re-derive the
list afterwards -- is what keeps a buffer the user had already made
writable from being switched to read-only by this command, which would
be a change they never asked for."
  (let ((buffers (claude-code-ide-org--review-read-only-buffers items)))
    (when buffers
      (unless (y-or-n-p (format "%s read-only.  Make %s writable and apply? "
                                (mapconcat #'buffer-name buffers ", ")
                                (if (cdr buffers) "them" "it")))
        (user-error "Left read-only; nothing applied, marks kept"))
      (dolist (buffer buffers)
        (with-current-buffer buffer (read-only-mode -1)))
      buffers)))

(defun claude-code-ide-org--review-restore-read-only (buffers)
  "Put `buffer-read-only' back on BUFFERS.
Skips any that has since been killed.  The flag is the user's guard
against their own stray keystrokes, so leaving it cleared after an apply
silently disables it and they only find out by noticing (TODO.org :ID:
c8a97d9d-8b13-4b6a-a8b9-1a3f24b5e00b)."
  (dolist (buffer buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (read-only-mode 1)))))

(defun claude-code-ide-org-review-apply ()
  "Apply every marked item, then refresh.

Offers to make any read-only target buffer writable first; see
`claude-code-ide-org--review-ensure-writable'.

Refreshes only when something was actually applied.  Refreshing
rebuilds from the queue and so discards marks, which is right after a
successful apply -- the applied items are consumed and the rest are a
fresh reading -- and exactly wrong after a run where nothing landed,
where it would throw away the human's decisions in response to a
failure they had no chance to react to.  A re-render instead, since
that re-evaluates staleness against the file as it now stands."
  (interactive)
  (let ((marked (seq-filter (lambda (i) (plist-get i :marked))
                            claude-code-ide-org--review-items)))
    (unless marked (user-error "Nothing marked"))
    ;; Cleared *outside* the `unwind-protect', because declining signals
    ;; and nothing was cleared to put back.
    (let ((cleared (claude-code-ide-org--review-ensure-writable marked)))
      (unwind-protect
          (let* ((result (claude-code-ide-org--review-apply marked))
                 (line (line-number-at-pos))
                 (done (plist-get result :items))
                 ;; The item to land on: whatever followed the last one
                 ;; applied, since that one is about to disappear.
                 (successor (and done
                                 (cadr (memq (car (last done))
                                             claude-code-ide-org--review-items)))))
            (if done
                (progn
                  ;; Drop exactly what applied and keep the rest *as the
                  ;; same objects*.  This used to call
                  ;; `claude-code-ide-org-review-refresh', which rebuilds
                  ;; from the queue and so discarded every decision on the
                  ;; items it had not applied -- assignments, narrowed
                  ;; intervals, notes, and confirmations of staleness.
                  ;;
                  ;; Note the shape that made it dangerous: the rebuild ran
                  ;; only when apply *succeeded*, so the better things went
                  ;; the more was lost.  Marks on items that failed were
                  ;; cleared too, so retrying a failure meant marking it
                  ;; again.
                  ;;
                  ;; Staleness stays correct without the rebuild:
                  ;; `claude-code-ide-org--review-current-state' resolves
                  ;; through `org-id-find' on every render, so it reads the
                  ;; files this command just wrote.
                  ;;
                  ;; What is given up is freshness -- events queued by
                  ;; another session while you were reviewing no longer
                  ;; appear on their own.  `g' is the command for that, and
                  ;; saying so is better than a list that reorders under
                  ;; you mid-review.
                  (setq claude-code-ide-org--review-items
                        (seq-remove (lambda (i) (memq i done))
                                    claude-code-ide-org--review-items))
                  (if successor
                      (claude-code-ide-org--review-redraw successor)
                    (claude-code-ide-org--review-render)))
              (claude-code-ide-org--review-render)
              (goto-char (point-min))
              (forward-line (1- line)))
            (message "Applied %d item(s)%s"
                     (plist-get result :applied)
                     (if (plist-get result :errors)
                         (format "; %d failed: %s"
                                 (length (plist-get result :errors))
                                 (string-join (plist-get result :errors) "; "))
                       "")))
        ;; An error mid-apply must not leave the user's guard disabled --
        ;; that failure window is the whole objection c8a97d9d raised
        ;; against clear-then-restore, and `unwind-protect' is what closes
        ;; it.
        (claude-code-ide-org--review-restore-read-only cleared)))))

;;;###autoload
(defun claude-code-ide-org-review ()
  "Review pending org updates and apply the approved ones.

The human-triggered entry point for the whole queue design: sessions
append events, and nothing reaches an org file until this command is run
by a person at a moment of their choosing. Deliberately never invoked
programmatically -- org's native state-change logging only completes
correctly inside a real interactive command."
  (interactive)
  (let ((buffer (get-buffer-create "*org-review*")))
    (with-current-buffer buffer
      (claude-code-ide-org-review-mode)
      (claude-code-ide-org-review-refresh))
    (pop-to-buffer buffer)))

;;; Structural lint (TODO.org :ID: 3bd3402b) -------------------------------
;;
;; Assertions about the org files' *own* structural conventions -- the
;; checks that were run by hand roughly twenty times on 2026-08-13, which
;; is the plainest possible signal that they wanted to be a script.
;;
;; The logic lives here rather than in `bin/lint-org' for the reason
;; caf598a1 gives about the statusline: inline shell-embedded elisp is
;; untestable, so it becomes real named functions here and the script
;; becomes a thin wrapper.  That is also what lets the "seed it against a
;; deliberately broken copy first" caution be discharged mechanically --
;; `config-test.el' feeds each check a fixture that violates it, so no
;; check can pass vacuously.
;;
;; Deliberate limit, measured rather than assumed (see the heading): this
;; catches the *shape* of drift -- a missing :ID:, a dangling link, a
;; repeater under a completable parent -- and misses the *reasoning*
;; kind, where prose asserts behaviour the code no longer has.  Both read
;; as settled fact; only one is a string.

(defun claude-code-ide-org--lint-heading-ids (files)
  "Return a hash of every :ID: defined across FILES, mapped to its
heading's TODO keyword (or nil when it carries none).  The keyword is
what makes a `:BLOCKER:' check meaningful: org-depend blocks only on an
unfinished TODO, so a blocker naming a keyword-less heading is a silent
no-op."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (file files table)
      (when (file-exists-p file)
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert-file-contents file)
            (org-mode)
            (org-map-entries
             (lambda ()
               (let ((id (org-entry-get nil "ID")))
                 ;; `:no-keyword' rather than nil, so "absent" and
                 ;; "present but carrying no TODO keyword" stay
                 ;; distinguishable -- the :BLOCKER: check turns on
                 ;; exactly that difference.
                 (when id (puthash id (or (org-get-todo-state) :no-keyword)
                                   table))))
             ;; Scope nil, not `file': `org-map-entries' resolves `file'
             ;; through `buffer-file-name', which a temp buffer has not
             ;; got, and silently maps over nothing.
             nil nil)))))))

(defun claude-code-ide-org--lint-file (file known-ids)
  "Return a list of finding strings for FILE.  KNOWN-IDS is the hash
from `claude-code-ide-org--lint-heading-ids'."
  (let ((name (file-name-nondirectory file))
        findings)
    (cl-flet ((report (severity line fmt &rest args)
                ;; Severity is what makes this usable as a gate. An
                ;; `error' is a violation that breaks tooling now -- an
                ;; unreachable heading, a link to nothing. A `warn' is a
                ;; convention a *new* heading must satisfy but which
                ;; cannot be retrofitted honestly: back-dating :CREATED:
                ;; on a heading archived before the rule existed would be
                ;; fabricating a fact, not fixing one. Without the split
                ;; the report carries the same dozen lines forever and
                ;; stops being read, which is the failure 5ff5a4b8
                ;; measured.
                (push (cons severity
                            (format "%s:%d: %s" name line
                                    (apply #'format fmt args)))
                      findings)))
      (with-temp-buffer
        (let ((org-inhibit-startup t))
          (insert-file-contents file)
          (org-mode)
          ;; Per-heading structural conventions.
          (org-map-entries
           (lambda ()
             (let* ((line (line-number-at-pos))
                    (level (org-current-level))
                    (id (org-entry-get nil "ID"))
                    (created (org-entry-get nil "CREATED"))
                    (todo (org-get-todo-state))
                    (title (org-get-heading t t t t)))
               (cond
                ((> level 3)
                 (report 'error line "level-%d heading; the file has three levels \
(category, task, epic-child): %s" level title))
                ((= level 1)
                 (when id (report 'error line "level-1 category carries :ID: -- \
categories are structure, not tasks: %s" title))
                 (when created
                   (report 'error line "level-1 category carries :CREATED:: %s" title))
                 (when todo
                   (report 'error line "level-1 category carries TODO keyword %s: %s"
                           todo title))
                 (when (org-get-tags nil t)
                   (report 'error line "level-1 category carries tags: %s" title)))
                (t
                 (unless id (report 'error line "heading has no :ID:: %s" title))
                 (unless created
                   (report 'warn line "heading has no :CREATED:: %s" title))))
               ;; A repeating task never reaches DONE, so a completable
               ;; ancestor never can either -- this is the check that
               ;; caught 38b92521 frozen via its :BLOCKER:.
               (when (org-get-repeat)
                 (save-excursion
                   (while (org-up-heading-safe)
                     (when (org-get-todo-state)
                       (report 'error line "repeater under completable ancestor \
%S -- that ancestor can never reach DONE: %s"
                               (org-get-heading t t t t) title)))))
               ;; A :BLOCKER: is only enforcement if it would actually
               ;; block: the target must exist AND carry a keyword, and
               ;; the blocked heading's own state must be one org-depend
               ;; evaluates.
               (let ((blocker (org-entry-get nil "BLOCKER")))
                 (when blocker
                   (when (equal todo "MAYBE")
                     (report 'warn line ":BLOCKER: on a MAYBE heading is dormant \
-- blocking is evaluated against the blocked heading's own state: %s" title))
                   (dolist (target (claude-code-ide-org--lint-blocker-ids blocker))
                     (cond
                      ((not (gethash target known-ids nil))
                       (report 'error line ":BLOCKER: names unknown :ID: %s: %s"
                               target title))
                      ((eq :no-keyword (gethash target known-ids))
                       (report 'error line ":BLOCKER: names keyword-less heading %s \
-- org-depend blocks only on an unfinished TODO, so this is a silent no-op: %s"
                               target title))))))))
           nil nil)
          ;; Link targets, scanned over the text rather than per heading:
          ;; a link can sit anywhere in a body.
          (goto-char (point-min))
          (while (re-search-forward "\\[\\[id:\\([^]]+\\)\\]" nil t)
            (let ((target (match-string 1)))
              ;; Prose in these files shows the link syntax itself
              ;; (`[[id:...]]'), which is documentation, not a target.
              (unless (or (not (string-match-p "\\`[0-9a-f]\\{8\\}-" target))
                          (gethash target known-ids nil))
                (report 'error (line-number-at-pos)
                        "id: link resolves to nothing: %s" target))))
          (goto-char (point-min))
          (while (re-search-forward "\\[\\[file:\\([^]]*plans/[^]]+\\)\\]" nil t)
            (let ((path (expand-file-name (match-string 1))))
              (unless (or (not (string-suffix-p ".md" path))
                          (file-exists-p path))
                (report 'error (line-number-at-pos)
                        "plan link points at a missing file: %s"
                        (match-string 1))))))
          (setq findings
                (append (reverse (claude-code-ide-org--lint-org-native name))
                        findings))))
    (nreverse findings)))

(defun claude-code-ide-org--lint-org-native (name)
  "Return org's own `org-lint' findings for the current buffer, as
\(SEVERITY . MESSAGE) pairs tagged with NAME.

Running org-lint is the point: it ships 61 checkers for org *syntax*,
and reimplementing any of them here would be exactly the mistake
TODO.org :ID: c084553c exists to prevent -- building bespoke machinery
without first exhausting what org already offers.  The division of
labour is clean, because the two ask different questions: org-lint asks
whether this is valid org, and the checks around it ask whether it obeys
*this project's* conventions, which no built-in could know.

Reported as warnings rather than errors because several checkers are
declared low-trust upstream and hedge their wording; a gate that blocks
on a maybe is a gate people learn to bypass.

The one exclusion is org-lint's Unknown-ID check, and it is an
artifact rather than a disagreement: that checker resolves id: links
through `org-id-locations', which is populated in a live session and
empty under `emacs --batch -Q'.  Unfiltered it reports every id: link in
the file -- 373 of them on 2026-08-14.  The id check that runs instead
resolves ids from the linted files themselves, so it works in batch,
which is where a gate has to work."
  (require 'org-lint)
  (let (findings)
    (dolist (report (org-lint--generate-reports (current-buffer)
                                                org-lint--checkers))
      (let ((line (aref (cadr report) 0))
            (message (aref (cadr report) 2)))
        (unless (string-prefix-p "Unknown ID" message)
          (push (cons 'warn (format "%s:%s: org-lint: %s" name line message))
                findings))))
    (nreverse findings)))

(defun claude-code-ide-org--lint-blocker-ids (value)
  "Return the ids named by a :BLOCKER: property VALUE.
Accepts org-depend's `ids(A B C)' form and the bare-id form this repo
has also used; anything else yields nil rather than a guess."
  (let ((inner (if (string-match "\\`[ \t]*ids(\\([^)]*\\))" value)
                   (match-string 1 value)
                 value)))
    (seq-filter (lambda (s) (string-match-p "[0-9a-f]\\{8\\}-" s))
                (split-string inner "[ \t\n]+" t))))

(defun claude-code-ide-org-lint (&optional files reference-files)
  "Return every structural finding across FILES, defaulting to the
tracked org files.  A nil return means the conventions hold.

REFERENCE-FILES are scanned for `:ID:'s but are not themselves linted,
so a link *out* of the linted set still resolves.  Without it every
cross-file link reads as dangling, and a report that always carries the
same lines stops being read -- the failure 5ff5a4b8 recorded for
evidence lines, arriving here by a different route."
  (let* ((files (or files (claude-code-ide-org--tracked-files)))
         (files (seq-filter #'file-exists-p files))
         (known (claude-code-ide-org--lint-heading-ids
                 (append files (seq-filter #'file-exists-p
                                           (or reference-files nil))))))
    (apply #'append
           (mapcar (lambda (f) (claude-code-ide-org--lint-file f known)) files))))

(defun claude-code-ide-org-lint-report (&optional files reference-files)
  "Print `claude-code-ide-org-lint' findings and exit non-zero if any.
Entry point for `bin/lint-org'; prints a positive line when clean, so a
silent run can never be mistaken for a passing one."
  (let* ((findings (claude-code-ide-org-lint files reference-files))
         (errors (seq-filter (lambda (f) (eq 'error (car f))) findings))
         (warnings (seq-filter (lambda (f) (eq 'warn (car f))) findings)))
    (dolist (f (append errors warnings))
      (princ (format "%s: %s\n"
                     (if (eq 'error (car f)) "error" "warn ")
                     (cdr f))))
    (princ (format "lint-org: %d error(s), %d warning(s)\n"
                   (length errors) (length warnings)))
    (when errors (kill-emacs 1))))

;;; MCP tool registration -------------------------------------------------

(with-eval-after-load 'claude-code-ide

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-clock-in
   :name "org_clock_in"
   :description (concat
                 "Record the start of work on an org-mode task, identified by "
                 "its :ID: property. Always call this when transitioning a task "
                 "to DOING state. Queues the event for human review; it does NOT "
                 "open a clock or change the file. Nothing reaches an org file "
                 "until a person runs the review-and-apply command, so do not "
                 "expect a later read to reflect it.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the target org heading.")
           (:name "note"
            :type string
            :optional t
            :description "Short 3-10 word description of what is being started, e.g. \"clarify backend schema design\". Recorded for later review; becomes the label on this span's :LOGBOOK: annotation.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-clock-out
   :name "org_clock_out"
   :description (concat
                 "Record the end of work on the task most recently started "
                 "with org_clock_in. Always call this when transitioning away "
                 "from DOING (to DONE, WAIT, or CANCELLED). Takes no id -- it "
                 "closes whatever this session last started. Queues the event "
                 "for human review; it does NOT close a clock or change the "
                 "file.")
   :args '((:name "note"
            :type string
            :optional t
            :description "Short 3-10 word description of what was accomplished in this span, e.g. \"user authentication code review\". Recorded for later review.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-set-todo
   :name "org_set_todo"
   :description (concat
                 "Record a TODO keyword change on an org-mode heading by its "
                 ":ID: property. Valid states: TODO NEXT PLANNING DOING "
                 "REVIEW WAIT MAYBE DONE CANCELLED. REVIEW is EXPERIMENTAL "
                 "(TODO.org :ID: c954f650): it means work is finished and "
                 "handed back to the human for judgement, as distinct from "
                 "WAIT, which means blocked on someone else. Use it where you "
                 "would otherwise leave a heading DOING at the end of a work "
                 "increment. Queues the event for human review; it "
                 "does NOT change the heading. The file keeps its current "
                 "keyword until a person applies the queued event, so a later "
                 "read showing the old state is expected, not a failure. "
                 "When setting DOING, also call org_clock_in. "
                 "When leaving DOING, call org_clock_out first. "
                 "PLANNING auto-promotes to DOING when ExitPlanMode fires -- "
                 "no separate org_set_todo call needed.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the target org heading.")
           (:name "state"
            :type string
            :description "TODO keyword to set: TODO NEXT PLANNING DOING REVIEW WAIT MAYBE DONE CANCELLED.")
           (:name "note"
            :type string
            :optional t
            :description "Short 3-10 word reason for the transition, e.g. \"request credentials from DBA\" or \"plan approved, resuming implementation\". Becomes the note on org's native state-change log line.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-archive
   :name "org_archive"
   :description (concat
                 "Archive an org-mode heading by its :ID: property, "
                 "respecting the #+ARCHIVE: directive in effect. "
                 "Use for DONE tasks tagged :code:, which archive to DONE.org::* Done.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the heading to archive.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-refile
   :name "org_refile"
   :description (concat
                 "Move an org-mode heading (and its subtree) so it becomes "
                 "the last child of a different heading, both identified by "
                 "their :ID: property. Works across files. Bypasses the "
                 "interactive refile-target prompt entirely. There is no "
                 "way to refile to a file's top level with no parent "
                 "heading — the target must itself have an :ID:.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the heading to move.")
           (:name "target_id"
            :type string
            :description "The :ID: property value of the heading to move it under (the new parent).")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-capture
   :name "org_capture"
   :description (concat
                 "Quick-add a new heading from TITLE via org-capture, in one "
                 "call instead of hand-writing a heading and then calling "
                 "org-id-get-create separately. The heading is written with "
                 "an :ID: and a :CREATED: stamp but NO TODO keyword — set "
                 "its state afterwards with org_set_todo, which queues the "
                 "transition for review so org logs it natively. Use TARGET "
                 "to place it; run org_outline first if you need to see what "
                 "categories exist. Returns a confirmation containing the "
                 "new heading's real :ID: and where it landed. Writes "
                 "immediately when the target file is free; when the human "
                 "has unsaved changes in it, the heading is queued for "
                 "review instead and the reply says \"Queued capture\". The "
                 "returned :ID: is usable either way — org_set_todo and "
                 "org_clock_in accept an :ID: whose capture is still "
                 "pending.")
   :args '((:name "title"
            :type string
            :description "The heading text for the new heading.")
           (:name "target"
            :type string
            :optional t
            :description "Where to put it: an :ID: to file it under that heading, or the exact title of a top-level category. Omit to append at the end of the capture file.")
           (:name "tags"
            :type string
            :optional t
            :description "Comma-separated org tags for the new heading, e.g. \"code,research\".")
           (:name "note"
            :type string
            :optional t
            :description "Short 3-10 word reason for capturing this, recorded on the queued event when the write defers.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-amend
   :name "org_amend"
   :description (concat
                 "Append a block of prose to the body of an existing heading, "
                 "identified by its :ID:. Prefer this over the Edit tool for "
                 "adding body text to a tracked org heading: Edit writes the "
                 "file behind Emacs's back, while this writes through Emacs "
                 "when the file is free and queues the text for human review "
                 "when the human has unsaved changes in that buffer, so an "
                 "interjection never collides and is never lost. The text "
                 "lands at the end of the heading's own body, after any "
                 "drawers and before its first child. Positional, not "
                 "contextual: it appends wherever the body now ends, with no "
                 "conflict detection.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the heading to amend.")
           (:name "text"
            :type string
            :description "The prose block to append. May be multiple lines.")
           (:name "note"
            :type string
            :optional t
            :description "Short 3-10 word reason for the amendment, recorded on the queued event when the write defers.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-query
   :name "org_query"
   :description (concat
                 "Search org-mode headings across "
                 "`claude-code-ide-org-query-files' (or org-agenda-files) using "
                 "org-ql's plain-string query syntax. Predicates: todo:KEYWORD "
                 "(e.g. todo:WAIT), tags:TAG1,TAG2 (comma = OR), priority:A, "
                 "heading:\"text\". Prefix any predicate with ! to negate it "
                 "(e.g. !todo:DONE). Separate predicates with spaces to combine "
                 "with AND, e.g. \"todo:NEXT tags:code\". Returns one line per "
                 "match: TODO state, heading, tags, :ID:, and file — or a "
                 "message if nothing matches. Prefer this over reading whole "
                 "files for cross-file questions like what's blocked or what "
                 "changed this week.")
   :args '((:name "query"
            :type string
            :description "org-ql plain-string query, e.g. \"todo:WAIT\", \"tags:research,code\", \"priority:A\", \"!todo:DONE\".")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-outline
   :name "org_outline"
   :description (concat
                 "Compact structural index of tracked org files: one line per "
                 "heading with its level (by indent), TODO keyword, title, "
                 ":ID:, and tags. Marks [blocked] when a :BLOCKER: names a "
                 "heading that is not finished, and [blocked?] when a "
                 "dependency exists but cannot be resolved. Read-only. "
                 "Use this before creating a heading, to see what already "
                 "exists and where it belongs, and instead of reading a whole "
                 "org file to find something — the index is roughly 40x "
                 "smaller. Complements org_query: that one filters by "
                 "predicate and returns a flat list, this one shows structure. "
                 "IDs are full and can be passed straight to the other tools.")
   :args '((:name "scope"
            :type string
            :optional t
            :description "An :ID: to index only that subtree, or a file name for one file. Omit for every tracked file.")
           (:name "max_depth"
            :type string
            :optional t
            :description "Cap the outline level reported, e.g. \"2\". Omit for no limit.")
           (:name "active_only"
            :type string
            :optional t
            :description "\"true\" to omit DONE and CANCELLED headings. Omit to include everything.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-sort-children
   :name "org_sort_children"
   :description (concat
                 "Sort the children of an org-mode heading, identified by its "
                 ":ID: property, in place. Does not affect the heading itself "
                 "or its siblings — only its direct children are reordered.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the parent heading whose children should be sorted.")
           (:name "sort-type"
            :type string
            :description "One of: alpha, todo-order, priority, scheduled, deadline, clock-time.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-move-sibling
   :name "org_move_sibling"
   :description (concat
                 "Move an org-mode heading, identified by its :ID: property, "
                 "up or down relative to its siblings (headings at the same "
                 "level under the same parent). Returns an error string if "
                 "there is no sibling in that direction to move past.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the heading to move.")
           (:name "direction"
            :type string
            :description "\"up\" or \"down\".")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-clock-report
   :name "org_clock_report"
   :description (concat
                 "Summarize clocked time as an org clocktable report — the same "
                 "machinery behind org-clock-report/column view — so \"what did "
                 "I work on this week\" is one tool call instead of eyeballing "
                 "LOGBOOK entries by hand. Scope to a single heading's subtree "
                 "via id, or omit id to cover every file in "
                 "`claude-code-ide-org-query-files' (or org-agenda-files). "
                 "Give either block (a named range: today, yesterday, thisweek, "
                 "lastweek, thismonth, lastmonth, thisyear, lastyear, untilnow) "
                 "or an explicit tstart/tend pair (org timestamp strings), not "
                 "both — block takes precedence if both are given. With "
                 "neither, the report is unrestricted: all clocked time in "
                 "scope. Returns the clocktable's headline/time breakdown and "
                 "total as plain text. Never creates or modifies any file.")
   :args '((:name "id"
            :type string
            :optional t
            :description "Optional :ID: property of a heading to scope the report to its subtree. Omit to cover all tracked files.")
           (:name "block"
            :type string
            :optional t
            :enum ["today" "yesterday" "thisweek" "lastweek" "thismonth" "lastmonth" "thisyear" "lastyear" "untilnow"]
            :description "Optional named range: today, yesterday, thisweek, lastweek, thismonth, lastmonth, thisyear, lastyear, or untilnow.")
           (:name "tstart"
            :type string
            :optional t
            :description "Optional explicit range start, as an org timestamp string (e.g. \"[2026-07-21 Tue]\"). Ignored if block is given.")
           (:name "tend"
            :type string
            :optional t
            :description "Optional explicit range end, as an org timestamp string. Ignored if block is given.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-log-background-plan
   :name "org_log_background_plan"
   :description (concat
                 "Record a completed background-planning pass on an org-mode "
                 "heading, identified by its :ID: property: insert a Plan-file "
                 "link (idempotent). Never transitions TODO state and never "
                 "touches the clock.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the target org heading.")
           (:name "plan_file"
            :type string
            :description "Absolute path to the plan markdown file, e.g. ~/.claude/plans/<slug>.md.")
           (:name "session_id"
            :type string
            :description "Synthetic id for this write, never the orchestrating session's own real session id, e.g. <orchestrating-session-id>-bg1.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-pending-updates
   :name "org_pending_updates"
   :description (concat
                 "Summarize queued-but-unapplied org updates, grouped by "
                 "heading. Read-only: changes nothing and applies nothing. "
                 "Use this to answer \"what is waiting?\" after calling "
                 "org_set_todo/org_clock_in/org_clock_out, since those queue "
                 "an event rather than editing the file — a later read showing "
                 "the old state is expected, and this is how you tell that "
                 "apart from a failure. Shows the same items, in the same "
                 "order and with the same staleness marks, that "
                 "M-x claude-code-ide-org-review would open on. Counts "
                 "*proposals*, not queue lines: clock and guidepost events "
                 "are attribution scaffolding that nothing consumes, so the "
                 "files always hold many more lines than there are items.")
   :args '((:name "session_id"
            :type string
            :optional t
            :description "Limit the report to one session's queue. Omit for every session."))))
