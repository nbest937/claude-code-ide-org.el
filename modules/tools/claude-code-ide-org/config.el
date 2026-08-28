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

(defvar claude-code-ide-org--last-error-backtrace nil
  "Details of the most recent error `claude-code-ide-org--at-id' swallowed.

A plist (:id ID :message MSG :backtrace STRING), or nil.  Overwritten by
each conversion, so it answers \"what went wrong just now\" rather than
keeping a history -- `claude-code-ide-org--review-apply' snapshots it per
item, which is where a history is actually wanted.")

(defun claude-code-ide-org--at-id (id fn)
  "Find the org heading whose :ID: property equals ID.
Switch to its buffer, move point to the heading, and call FN with
no arguments.  Return FN's value, or an error string if the ID
cannot be resolved or FN signals an error."
  (require 'org-id)
  (let ((marker (claude-code-ide-org--id-find id 'marker)))
    (if (not marker)
        (format "Error: no org heading found with :ID: \"%s\"" id)
      (condition-case err
          (org-with-point-at marker
            (funcall fn))
        (error
         ;; Record where it actually failed. This function converts every
         ;; error into a string, which is what lets callers report a
         ;; failure without unwinding a batch -- but it also means a
         ;; failure arrives as prose with no stack and no identity, and
         ;; the caller cannot tell a typo'd :ID: from a bug three frames
         ;; down. Measured cost, 2026-08-24: five apply failures reading
         ;; "Before first headline at position 1" and nothing else, which
         ;; survived three wrong hypotheses before anyone could act on
         ;; them.
         (setq claude-code-ide-org--last-error-backtrace
               (list :id id
                     :message (error-message-string err)
                     :backtrace (ignore-errors
                                  (backtrace-to-string (backtrace-get-frames)))))
         (format "Error: %s" (error-message-string err)))))))

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
  ;; The meta-work category is a legal target and resolves to no
  ;; heading, so it is accepted here without a lookup. Nothing is
  ;; created: the day node is minted when this event is *applied*, and
  ;; dated from the event's own timestamp (TODO.org :ID: 9575e65b).
  ;; Queuing stays what it has always been -- a line appended to a file.
  (if (claude-code-ide-org--day-node-target-p id)
      (format "Queued clock_in on the meta-work day node for today; pending review. The node itself is created when this is applied, dated from this event, so a late apply still files the work under today.")
    (claude-code-ide-org--tolerating-pending-capture id
      (lambda (title)
        (format "Queued clock_in on \"%s\"; pending review." title))
      (lambda ()
        (claude-code-ide-org--at-id
         id
         (lambda ()
           (format "Queued clock_in on \"%s\"; pending review."
                   (org-get-heading t t t t))))))))

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

;;; The daily ceremony prompt (TODO.org :ID: aa1ba915) ---------------------
;;
;; "Can the ceremony be scheduled so a prompt arrives each day?"  Both
;; schedulers were measured and neither fits: `CronCreate' is
;; session-only and in-memory, and the `schedule' skill runs in the
;; cloud, where localhost:45571 -- and therefore every tool in this
;; project -- is unreachable.  And the first step cannot be delegated at
;; all, because apply must run inside a genuinely interactive command.
;;
;; So what is buildable is the *prompt*, and the mechanism already
;; exists: SessionStart, which fires at the first opportunity each day,
;; injects `additionalContext', and stays silent when there is nothing
;; to say.  This rides alongside the stale-interval report rather than
;; adding a second hook.

(defun claude-code-ide-org--ceremony-stamp-file ()
  "Path of the stamp recording when the ceremony was last performed.

One file whose *mtime* carries the date, not one file per day.  A
dated-filename scheme accumulates forever and needs a reaper; an mtime
is already a date and is already maintained by the act of writing."
  (expand-file-name "ceremony-last-run"
                    claude-code-ide-org-queue-directory))

(defun claude-code-ide-org--ceremony-done-today-p ()
  "Non-nil when the ceremony stamp was last written today.

*This is the question the heading had to settle*, and the alternatives
were rejected on one test: does the signal mean \"the ceremony was
performed\" or merely \"something happened\"?  The existence of a day
node conflates them -- a node is created by any meta-work clock-in.  So
does a drop in the pending count, which falls whenever anyone applies a
single item.  An explicit stamp means only what it says."
  (let ((file (claude-code-ide-org--ceremony-stamp-file)))
    (and (file-exists-p file)
         (claude-code-ide-org--today-p
          (file-attribute-modification-time (file-attributes file))))))

(defun claude-code-ide-org-mark-ceremony-done ()
  "Record that today's ceremony has been performed, silencing the prompt.

Interactive and explicit.  It is deliberately *not* called from the
apply path: apply is one step of the ceremony, not the whole of it, and
stamping there would silence the prompt for the days when someone
applies a couple of items and archives nothing."
  (interactive)
  (let ((file (claude-code-ide-org--ceremony-stamp-file)))
    (make-directory (file-name-directory file) t)
    (write-region "" nil file nil 'quiet)
    (when (called-interactively-p 'any)
      (message "Ceremony marked done for today."))
    file))

(defun claude-code-ide-org--ceremony-reviewed-today-p ()
  "Non-nil when a review pass was actually run today.

*Derived, not remembered* (TODO.org :ID: 806ff394).  Since :ID: 961f15b6
the review command opens a real clock on the attention heading, so a
CLOCK line dated today is *evidence that the pass ran* -- created by
running the command, which is the act itself rather than a promise to
record it afterwards.

This is what removes the model from the nag guard.  The prompt used to
depend on a session remembering to call
`claude-code-ide-org-mark-ceremony-done' an hour and many turns after
being told to, which is the shape this project has already measured
failing (:ID: 2758f3a0, 41 of 45, every miss on re-mention)."
  (let ((marker (claude-code-ide-org--review-attention-target)))
    (when marker
      (org-with-point-at marker
        (let ((end (save-excursion (org-end-of-subtree t) (point)))
              found)
          (save-excursion
            (while (and (not found)
                        (re-search-forward "^[ \t]*CLOCK: \\(\\[[^]]+\\]\\)" end t))
              (when (claude-code-ide-org--today-p
                     (claude-code-ide-org--parse-org-timestamp (match-string 1)))
                (setq found t))))
          found)))))

(defun claude-code-ide-org--ceremony-status ()
  "Return a plist of what the ceremony has waiting: (:pending N :drifted N
:archivable N), or nil when the ceremony has already run today.

Counts only.  Deciding what to do about them is the human's, which is
why this returns numbers and the formatter below asks a question."
  ;; Two independent ways to be quiet, and they answer different
  ;; questions on purpose (TODO.org :ID: 806ff394).  The stamp says *the
  ;; ceremony was completed* -- a claim only a human can make, since it
  ;; spans steps nothing observes.  The clock says *a pass was run*,
  ;; which is derived from the act itself and cannot be forgotten.
  ;; Either is reason enough not to ask again today; only the first is
  ;; reason to believe the ceremony is done, which is why the report
  ;; below states when that last happened rather than implying it.
  (unless (or (claude-code-ide-org--ceremony-done-today-p)
              (claude-code-ide-org--ceremony-reviewed-today-p))
    (let ((pending (length (claude-code-ide-org--review-items-from-queue)))
          (drifted (nth 1 (claude-code-ide-org--consolidate-drawers-1 t)))
          (archivable 0))
      (dolist (file (claude-code-ide-org--tracked-files))
        ;; Only the *source* files can have anything to archive; a
        ;; DONE.org heading is already where archiving would put it.
        (when (and (file-exists-p file)
                   (not (string-equal (file-name-nondirectory file) "DONE.org")))
          (with-current-buffer (find-file-noselect file)
            (org-map-entries
             (lambda ()
               (when (member (org-get-todo-state)
                             claude-code-ide-org--outline-finished-keywords)
                 (setq archivable (1+ archivable))))
             nil 'file))))
      (list :pending pending :drifted drifted :archivable archivable
            :last-done (let ((f (claude-code-ide-org--ceremony-stamp-file)))
                         (when (file-exists-p f)
                           (format-time-string
                            "%Y-%m-%d %a"
                            (file-attribute-modification-time
                             (file-attributes f)))))))))

(defun claude-code-ide-org--format-ceremony-report (status)
  "Format STATUS into a line for Claude to relay as a question.

*Asks; never proposes*, on the same footing as the stale-interval
report (TODO.org :ID: 7771fc63).  It states counts, which are facts, and
asks whether to run the pass, which is a decision.  It must not announce
an intention to act: the first step of the ceremony cannot be performed
by an agent at all, so an agent saying it will do it would be wrong
before it was unwelcome."
  ;; STATUS is nil whenever the ceremony has already run today, which is
  ;; the *common* case rather than an edge one -- so this guard is what
  ;; keeps `--session-start-hook-json' from erroring on an ordinary
  ;; second session of the day and taking the stale-interval report down
  ;; with it.  Found by the test, not by reading.
  (let* ((pending (or (plist-get status :pending) 0))
         (drifted (or (plist-get status :drifted) 0))
         (archivable (or (plist-get status :archivable) 0)))
    (when (and status (> (+ pending drifted archivable) 0))
      (concat
       (format (concat "Today's review-and-planning pass has not been run yet. "
                       "Waiting: %d queued item(s) pending review, %d :LOGBOOK: "
                       "drawer(s) out of order, %d finished heading(s) not yet "
                       "archived. The ceremony was last marked complete %s. ")
               pending drifted archivable
               ;; Stated, never implied.  This prompt goes quiet as soon
               ;; as a pass is *run*, which is not the same as the
               ;; ceremony being *finished* -- so the date it was last
               ;; finished has to be visible or silence would read as
               ;; completion (TODO.org :ID: 806ff394).
               (or (plist-get status :last-done) "never"))
       "Ask the user whether they want to run it now; do not announce that you "
       "will, and do not run any part of it unasked. Apply is theirs alone -- "
       "M-x claude-code-ide-org-review -- because org's state-change logging "
       "only completes inside a genuinely interactive command. After they "
       "apply, the remaining steps are yours if they ask: "
       "claude-code-ide-org-consolidate-all-drawers, then "
       "claude-code-ide-org-normalize-heading-separation, then archiving. "
       "When the pass is finished, call claude-code-ide-org-mark-ceremony-done "
       "so this stops asking until tomorrow."))))

(defun claude-code-ide-org--session-start-hook-json ()
  "Return the SessionStart hook JSON payload: an empty object if there is
nothing to report, otherwise one whose additionalContext carries every
stale open interval and, if today's ceremony has not been run, what it
has waiting.

*Two reports, one hook, one payload.*  They are independent questions --
a stale clock is an unclean death, the ceremony is a routine -- but both
want the same moment and the same manners, and `additionalContext' is a
single string.  Adding a second SessionStart hook would double the
Emacs round-trip at every session start to say the same thing twice as
often.  Either half may be absent; the payload is empty only when both
are."
  (let* ((findings (claude-code-ide-org-find-stale-open-intervals))
         (stale (and findings
                     (claude-code-ide-org--format-stale-interval-report findings)))
         (ceremony (claude-code-ide-org--format-ceremony-report
                    (claude-code-ide-org--ceremony-status)))
         (parts (delq nil (list stale ceremony))))
    (if (null parts)
        "{}"
      (json-encode
       `((hookSpecificOutput
          . ((hookEventName . "SessionStart")
             (additionalContext . ,(mapconcat #'identity parts "\n\n")))))))))

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
;; currently clocked-in heading (if any) plus every WAITING-state heading
;; across `claude-code-ide-org--tracked-files' (the same file list
;; stale-interval-recovery and org_query already use), collapsed into a
;; single plain-text string. Turns "what was I working on" from a
;; question into something Claude already knows walking in — a standing,
;; automatic instance of what `claude-code-ide-org-query' answers on
;; demand via "todo:WAITING".

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

(defun claude-code-ide-org--queue-heading-divergence ()
  "Return a hash of heading :ID: -> what the queue currently says about it.

Each value is a plist: :queued-state, the keyword named by that
heading\'s most recent *pending* `todo\' event, or nil when it has none;
and :latest, the timestamp of its most recent pending event of any kind.

Exists so `claude-code-ide-org--attention-headings-context\' can compare
the file against the queue rather than against the clock (TODO.org :ID:
e0904e93).  Pending only, deliberately -- an applied event is by
definition one the file already agrees with, so counting it would
report a divergence at the exact moment it was resolved."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (group (claude-code-ide-org--queue-events-by-id))
      (when (car group)
        (let (queued-state queued-ts latest)
          (dolist (event (cdr group))
            (let ((ts (plist-get event :ts)))
              (when (or (null latest) (time-less-p latest ts))
                (setq latest ts))
              (when (and (equal (plist-get event :kind) "todo")
                         (or (null queued-ts) (time-less-p queued-ts ts)))
                (setq queued-state (plist-get event :state)
                      queued-ts ts))))
          (puthash (car group)
                   (list :queued-state queued-state :latest latest)
                   table))))
    table))

(defun claude-code-ide-org--attention-headings-context ()
  "Return a list of one-line descriptions, one per heading across
`claude-code-ide-org--tracked-files\' that a *starting* session should be
told about, or nil if none. Three kinds:

- WAITING -- blocked, or waiting on someone.
- A DOING leaf the file and the queue disagree about, or that the queue
  has been silent on since before today -- an increment somebody walked
  away from.
- A heading the queue has already moved to DOING which the file does not
  show yet.

*Keyed on file-versus-queue divergence, not on the clock* (TODO.org
:ID: e0904e93). This used to report a DOING leaf as \"DOING, not
clocked\" whenever it was not `org-clock-marker\'\'s heading. After the
2026-08-11 cutover nothing holds a live clock outside a review pass, so
every DOING leaf matched every time and the line went constant -- and a
report that always says the same thing stops being read, which defeats
the only purpose this one has. The word \"clocked\" went with it: it
named a mechanism this project no longer runs, so it could only
mislead a reader trying to act on the line.

Divergence meets that standard by construction, because it goes silent
exactly when the file and the queue agree. Both directions are real and
both were observed on 2026-08-21: befaed0a sat DOING in the file with a
DONE queued and unapplied, while c6fc6f46 carried no keyword at all
while a session actively worked it, its DOING still sitting in the
queue. The old predicate reported the first as merely \"not clocked\"
and said nothing whatever about the second.

Quiet-since-before-today is the abandonment test, matching
`claude-code-ide-org-write-session-start-report\'\'s own self-limiting
rule so that both reports answer \"first thing each day\" the same way.

A DOING *container* (`claude-code-ide-org--container-heading-p\') is
still excluded, for the reason the old comment gave: a container in
DOING is a true and unremarkable statement about the project, so
reporting it would add one permanent, never-changing line.

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
  (let ((divergence (claude-code-ide-org--queue-heading-divergence))
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
                      (queue (and heading-id (gethash heading-id divergence)))
                      (queued-state (plist-get queue :queued-state))
                      (latest (plist-get queue :latest))
                      (label
                       (cond
                        ((equal state "WAITING") "WAITING")
                        ((and (equal state "DOING")
                              (not (claude-code-ide-org--grouping-heading-p)))
                         (cond
                          ((and queued-state (not (equal queued-state "DOING")))
                           (format "DOING in file, queued -> %s, not yet applied"
                                   queued-state))
                          ((null latest)
                           "DOING in file, nothing ever queued for it")
                          ((not (claude-code-ide-org--today-p latest))
                           (format "DOING in file, nothing queued since %s"
                                   (format-time-string "%Y-%m-%d %H:%M" latest))))))))
                 (when label
                   (push (format "%s: \"%s\" (:ID: %s, in %s)"
                                 label
                                 (org-get-heading t t t t)
                                 (or heading-id "none")
                                 (file-name-nondirectory file))
                         results))
                 ;; The other direction. Emitted here rather than in a
                 ;; second pass because this is the one place the
                 ;; heading's title and file are already in hand -- a
                 ;; queued id alone cannot name itself.
                 (when (and heading-id
                            (equal queued-state "DOING")
                            (not (equal state "DOING")))
                   (push (format
                          "queued DOING, not yet applied: \"%s\" (:ID: %s, in %s; file says %s)"
                          (org-get-heading t t t t)
                          heading-id
                          (file-name-nondirectory file)
                          (or state "no keyword"))
                         results))))
             nil 'file))
          (unless already-open
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))
    (nreverse results)))

(defun claude-code-ide-org--nomination-candidates-context ()
  "One line per container that has live members and no NEXT among them.

*Nominating, not promoting* (TODO.org :ID: 62b65ad0).  A trigger used to
set NEXT on a container's sole remaining TODO by itself.  It was retired
because a `NEXT' it wrote could be wrong and was invisible: three of
roughly eight top-level promotions ended up parked as MAYBE.  Choosing
the next action is judgement, so this states the fact and leaves the
choice -- the same contract the stale-interval and ceremony reports
already follow, and the reason they are trusted.

Reports a *container* only, which is the whole point: GTD's invariant is
that a live project always has a next action, and a project here is a
story or a slice, never a filing category.  Handles both, since their
members differ in kind: a story's are child headings, a slice's are
`[[id:...]]' links resolved through the referent index.

Says how many candidates there are but never picks one.  A sole
candidate is named, because there naming it costs nothing and no
judgement is being pre-empted; several are counted, because that is
exactly the case no rule can decide."
  (let ((index (claude-code-ide-org--slice-referent-index))
        (results nil))
    (dolist (file (claude-code-ide-org--tracked-files))
      (when (file-exists-p file)
        (let* ((already-open (find-buffer-visiting file))
               (buffer (or already-open (find-file-noselect file))))
          (with-current-buffer buffer
            (org-with-wide-buffer
             (goto-char (point-min))
             (while (re-search-forward org-heading-regexp nil t)
               (let ((kw (org-get-todo-state)))
                 (when (and kw
                            (not (member kw claude-code-ide-org--outline-finished-keywords)))
                   ;; No `--grouping-heading-p' guard, deliberately.
                   ;; Having live members IS being a container: the
                   ;; children scan below returns nil for a leaf and
                   ;; `--slice-members' returns nil for a non-slice, so
                   ;; the `states' test already excludes everything the
                   ;; predicate would have. Measured 2026-08-26 --
                   ;; removing the guard changed no test, which is what
                   ;; a redundant guard looks like. Keeping it would have
                   ;; doubled the descendant scan and implied a coverage
                   ;; the suite could not actually demonstrate.
                   (let ((states (claude-code-ide-org--member-keywords index)))
                     (when (and states
                                (not (member "NEXT" (mapcar #'car states)))
                                (assoc "TODO" states))
                       (let ((todos (seq-filter (lambda (s) (equal (car s) "TODO")) states)))
                         ;; Stripped over the assembled line. Every
                         ;; component read from the buffer carries text
                         ;; properties -- `org-get-heading' most visibly --
                         ;; and `format' propagates them, so an MCP client
                         ;; would be handed a `#("..." 0 11 (...))'
                         ;; literal. Same trap `--outline-line' documents;
                         ;; caught here by reading the live output rather
                         ;; than by a test, since batch Emacs runs no
                         ;; font-lock and the fixtures come back clean.
                         (push (substring-no-properties
                                (format "no next action in \"%s\" (:ID: %s): %s"
                                       (org-get-heading t t t t)
                                       (or (org-entry-get nil "ID") "none")
                                       (if (= 1 (length todos))
                                           (format "one candidate, \"%s\"" (cdr (car todos)))
                                         (format "%d candidates" (length todos)))))
                               results)))))))))
          (unless already-open
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))
    (nreverse results)))

(defun claude-code-ide-org--member-keywords (index)
  "Return (KEYWORD . TITLE) for each live member of the container at point.

A slice's members are links and a story's are child headings, so this
resolves the two differently and returns the same shape either way.
INDEX is a `claude-code-ide-org--slice-referent-index' hash, used only
for the slice case.

Returns *every* keyworded member, finished ones included, and leaves
liveness to the caller. A filter stood here and was removed 2026-08-26
after breaking it changed no test: the caller selects TODO members
anyway, so a DONE member could never reach the output. Three redundant
guards were written into this function on the first pass and all three
were found the same way -- by breaking them and watching the suite stay
green."
  (let ((raw
         (if (claude-code-ide-org--slice-p)
             (delq nil
                   (mapcar (lambda (member)
                             (gethash (downcase (car member)) index))
                           (claude-code-ide-org--slice-members)))
           (let ((end (save-excursion (org-end-of-subtree t t)))
                 (acc nil))
             (save-excursion
               (org-back-to-heading t)
               (forward-line 1)
               (while (re-search-forward org-heading-regexp end t)
                 (let ((kw (org-get-todo-state)))
                   (when kw (push (cons kw (org-get-heading t t t t)) acc)))))
             (nreverse acc)))))
    raw))

(defun claude-code-ide-org-session-context ()
  "Return a plain-text summary of \"what was I last doing\": the
currently clocked-in heading, if any, followed by one line per heading
worth flagging at session start across
`claude-code-ide-org--tracked-files' -- WAITING headings and abandoned
DOING leaves, per `claude-code-ide-org--attention-headings-context'.
Returns the empty string when there is nothing to report, so callers
can treat an empty result as \"nothing worth injecting\"."
  (let* ((clocked (claude-code-ide-org--clocked-heading-context))
         (waits (claude-code-ide-org--attention-headings-context))
         (nominations (claude-code-ide-org--nomination-candidates-context))
         (lines (append (when clocked (list clocked)) waits nominations)))
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
         (qmarker (and qs (ignore-errors (claude-code-ide-org--id-find (car qs) 'marker))))
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
                  ;; Latent rather than live: both endpoints are parsed
                  ;; from org timestamp strings and so already carry
                  ;; minute precision, which makes raw subtraction exact
                  ;; here today. Routed through the shared helper anyway,
                  ;; so the invariant holds by construction if either
                  ;; input ever gains seconds.
                  (minutes (claude-code-ide-org--clock-minutes start-time stop-time)))
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

(defun claude-code-ide-org--clock-minutes (start end)
  "Minutes org would record for a CLOCK line running START to END.

*Both endpoints are truncated to the minute before subtracting*, which
is what org does -- a CLOCK line stores minute-precision timestamps and
its `=>  H:MM\' is those two stamps subtracted.  Summing raw seconds and
rounding gives a different answer whenever the seconds fall either side
of a minute boundary, and it is the wrong one: the line then contradicts
the timestamps printed beside it on that same line.

Measured 2026-08-21, before this existed: *56 of 353 CLOCK lines in
TODO.org and DONE.org disagreed with their own timestamps* -- 35
printing a minute less than their stamps imply, 21 a minute more.  A
clocktable does not read the `=>' field at all, so `org_clock_report'
silently reported different totals than the drawer a human was reading.

Also the reason `claude-code-ide-org--review-written-summary\' could
promise \"what apply will really write\" and be wrong for a quarter of
runs: apply writes through native `org-clock-in\'/`org-clock-out\', so
org computes the duration this way and the preview did not."
  (/ (round (float-time (time-subtract (claude-code-ide-org--truncate-to-minute end)
                                       (claude-code-ide-org--truncate-to-minute start))))
     60))

(defun claude-code-ide-org--truncate-to-minute (time)
  "Return TIME with its seconds discarded, as org records timestamps."
  (let ((d (decode-time time)))
    (encode-time 0 (nth 1 d) (nth 2 d) (nth 3 d) (nth 4 d) (nth 5 d) (nth 8 d))))

(defun claude-code-ide-org--format-clock-line (start end)
  "Format START and END (time values) as a closed CLOCK line,
matching org's own \"CLOCK: [start]--[end] =>  H:MM\" convention.

The total comes from `claude-code-ide-org--clock-minutes\', so it agrees
with the two timestamps this same call prints, by construction."
  (let ((minutes (claude-code-ide-org--clock-minutes start end)))
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

(defconst claude-code-ide-org--clock-line-regexp
  "\\`[ \t]*CLOCK: \\[\\([^]]+\\)\\]--\\[\\([^]]+\\)\\][ \t]*=>[ \t]*[0-9]+:[0-9][0-9][ \t]*\\'"
  "Matches a closed CLOCK line, capturing both org timestamps.")

(defconst claude-code-ide-org--annotation-line-regexp
  "\\`[ \t]*- \\[\\([^]]+\\)\\]--\\[\\([^]]+\\)\\]\\(.*\\)\\'"
  "Matches a queue-written :LOGBOOK: annotation, capturing its note.")

(defun claude-code-ide-org--recompute-logbook-text (text guideposts since)
  "Return TEXT, a :LOGBOOK: drawer body, with its CLOCK lines recomputed.

Each closed CLOCK line starting at or after SINCE is replaced by one
line per *busy interval* inside its own window, derived from GUIDEPOSTS
by `claude-code-ide-org--busy-intervals'.  Everything else in the drawer
is passed through untouched.

This is TODO.org :ID: 507754ba, and it is the conservative half of the
two options that heading had.  It corrects what was recorded; it does
not go looking for work that never got a line.  Recorded time falls from
41.32 h to 19.95 h across 110 post-cutover lines, which is the
overcount :ID: 226ed53b measured, now removed from the accumulated
record rather than only from future writes.

*Endpoints are rewritten, not just the `=>' total.*  Tempting to edit
only the total and leave the timestamps, since that is a one-token
change and looks conservative -- but `org-clock-sum' and every
clocktable derive duration from the *timestamps* and ignore the
rendered total, so that edit would be purely cosmetic and the reports
would keep their overcount.

*The window runs to END + 60 seconds.*  Org records CLOCK endpoints
truncated to the minute, so a line reading `[11:24]' can have its
closing guidepost at 11:24:35.  A window ending at the recorded minute
excludes it, and the turn is then closed at the window bound instead --
losing up to 59 seconds off its tail.  Measured across the real files:
48.45 h with the extension against 47.93 h without, so about half an
hour in aggregate and one drawer that changes at all.

*This is a precision fix, not a rescue*, and an earlier draft of this
docstring said otherwise -- that without it 39 of 110 lines recomputed
to zero.  That was true of a *superseded* implementation which paired
`resume' -> `pause' within each session and so had no bound to fall
back on.  `claude-code-ide-org--busy-intervals' closes an open turn at
BOUND, which caps the damage at under a minute.  Corrected rather than
deleted, because the stale version justified the code far more strongly
than the evidence does.

*A line with no recoverable guideposts is left exactly as it is*, not
zeroed.  Absence of evidence in the queue is not evidence the work did
not happen -- the events may predate the queue or have been written by
a subagent's own paired clock_in/clock_out, which is authoritative and
has no guideposts at all.

*A line whose window holds no busy time loses its CLOCK line but keeps
its annotation.*  Writing `=>  0:00' would claim an interval that was
never observed, which this code refuses everywhere else; deleting the
annotation too would destroy the heading attribution, which is the one
thing review actually contributed and which no guidepost carries.  So
the evidence survives and only the false duration goes.

Idempotent: a rewritten line's window contains exactly the busy
interval that produced it, so a second pass reproduces it unchanged."
  (let* ((lines (split-string text "\n"))
         (fmt "[%Y-%m-%d %a %H:%M]")
         out)
    (while lines
      ;; Every group is read out of the match data BEFORE anything else
      ;; runs, because `--parse-org-timestamp' does its own
      ;; `string-match' and clobbers it. Deciding whether the line
      ;; qualifies requires parsing, so the decision cannot come first.
      (let* ((line (car lines))
             (clock-p (string-match claude-code-ide-org--clock-line-regexp line))
             (g1 (and clock-p (match-string 1 line)))
             (g2 (and clock-p (match-string 2 line)))
             (start (and g1 (claude-code-ide-org--parse-org-timestamp (concat "[" g1 "]"))))
             (end (and g2 (claude-code-ide-org--parse-org-timestamp (concat "[" g2 "]")))))
        (if (not (and start end (not (time-less-p start since))))
            (progn (push line out) (setq lines (cdr lines)))
          (let* ((next (cadr lines))
                 (note (and next
                            (string-match claude-code-ide-org--annotation-line-regexp next)
                            (equal (match-string 1 next) g1)
                            (equal (match-string 2 next) g2)
                            (match-string 3 next)))
                 (inside (and start end
                              (seq-filter
                               (lambda (e)
                                 (let ((ts (plist-get e :ts)))
                                   (and (not (time-less-p ts start))
                                        (time-less-p ts (time-add end 60)))))
                               guideposts)))
                 (busy (and inside
                            (claude-code-ide-org--apply-idle-floor
                             (claude-code-ide-org--busy-intervals inside end)))))
            (cond
             ;; Nothing in the queue speaks to this line. Leave it whole.
             ((null inside) (push line out) (when note (push next out)))
             ;; Busy time found: one CLOCK line per interval, each with
             ;; its own copy of the annotation so the pair stays adjacent
             ;; under `--consolidate-logbook-text's timestamp sort.
             (busy
              (dolist (iv busy)
                (push (claude-code-ide-org--format-clock-line (car iv) (cdr iv)) out)
                (when note
                  (push (format "- %s--%s%s"
                                (format-time-string fmt (car iv))
                                (format-time-string fmt (cdr iv))
                                note)
                        out))))
             ;; No busy time: drop the CLOCK line, keep the annotation.
             (t (when note (push next out))))
            (setq lines (if note (cddr lines) (cdr lines)))))))
    (mapconcat #'identity (nreverse out) "\n")))

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

(defun claude-code-ide-org-recompute-accumulated-clock-lines (&optional since dry-run)
  "Recompute every CLOCK line at or after SINCE across the tracked files.

SINCE defaults to the 2026-08-11 cutover, before which no queue exists
to recompute from.  With DRY-RUN non-nil nothing is written and no
buffer is saved; the report is produced either way and is the thing to
read before running it for real.

Each heading's :LOGBOOK: is rewritten by
`claude-code-ide-org--recompute-logbook-text' -- see there for what is
and is not touched.  This is the applying half of TODO.org :ID:
507754ba.

Reads history through
`claude-code-ide-org--queue-historical-guideposts', which spans the
archive as well as the live queues and ignores watermarks.  Every line
being corrected was written from events a review pass has already
consumed, and the oldest of them live in archived files -- so both
halves of that are load-bearing, and getting either wrong shrinks lines
toward zero without any sign that something went missing.

Buffers are saved, but `claude-code-ide-org-consolidate-history' is
deliberately NOT run afterwards: the rewrite already emits each CLOCK
line immediately followed by its annotation, and re-sorting a drawer
this has just restructured would be a second transformation with
nothing verifying the composition."
  (interactive (list nil (not current-prefix-arg)))
  (let* ((since (or since (claude-code-ide-org--parse-org-timestamp "[2026-08-11 Tue 00:00]")))
         (guideposts (claude-code-ide-org--queue-historical-guideposts))
         (headings 0) (changed 0) (files 0))
    (dolist (file (claude-code-ide-org--tracked-files))
      (when (file-readable-p file)
        (let* ((already-open (find-buffer-visiting file))
               (buffer (or already-open (find-file-noselect file)))
               (touched nil))
          (with-current-buffer buffer
            (let ((buffer-read-only nil))
              (save-excursion
                (goto-char (point-min))
                (while (re-search-forward org-heading-regexp nil t)
                  (let ((bounds (claude-code-ide-org--drawer-content-bounds "LOGBOOK")))
                    (when bounds
                      (setq headings (1+ headings))
                      (let* ((old (buffer-substring-no-properties (nth 0 bounds) (nth 1 bounds)))
                             (new (claude-code-ide-org--recompute-logbook-text
                                   old guideposts since)))
                        (unless (equal old new)
                          (setq changed (1+ changed) touched t)
                          (unless dry-run
                            (delete-region (nth 0 bounds) (nth 1 bounds))
                            (goto-char (nth 0 bounds))
                            (insert new))))))))
              (when (and touched (not dry-run))
                (setq files (1+ files))
                (save-buffer))))
          (unless already-open
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))
    (let ((report (format "%s %d heading(s) with a :LOGBOOK: scanned, %d rewritten%s"
                          (if dry-run "Dry run:" "Recomputed:")
                          headings changed
                          (if dry-run "" (format ", %d file(s) saved" files)))))
      (when (called-interactively-p 'any) (message "%s" report))
      report)))

(defun claude-code-ide-org-consolidate-all-drawers (&optional dry-run)
  "Consolidate every :LOGBOOK: drawer across the tracked files.

With DRY-RUN non-nil nothing is written and the report says what would
change.  A bare `M-x' passes t, so the destructive form has to be asked
for with a prefix argument.

*From Lisp the default is reversed and that is deliberate but sharp*:
`(claude-code-ide-org-consolidate-all-drawers)' with no argument
*writes*.  This matches `claude-code-ide-org-recompute-accumulated-clock-lines',
whose signature has the same shape, so the two do not disagree -- but a
caller reading only the interactive behaviour will guess wrong.  Pass
the argument explicitly either way.

*Why this exists at all, since `claude-code-ide-org-consolidate-on-apply'
is already t* (TODO.org :ID: 7ae6562d).  That setting fires only on a
heading an apply pass actually *writes to*.  A drawer disturbed by
anything else -- a hand `C-c C-x C-i', `--trigger-auto-clock-in' firing
on a hand-set DOING -- keeps its disorder, and nothing ever returns to
repair it.  Measured 2026-08-24: 43 of 60 multi-entry drawers in
DONE.org were out of order, and over half of everything archived *since*
consolidate-on-apply shipped.  TODO.org looked healthy only because
apply keeps revisiting those headings.

*The drift is structural, not a bug.*  Org inserts CLOCK lines
newest-first, `--append-to-drawer' appends before `:END:', and the
ascending order :ID: af7d3687 chose is neither -- so any writer outside
apply leaves a drawer disordered by construction.  Reversing the sort to
match org would end the drift and was rejected: it discards the
narrative order af7d3687 asked for, breaks that heading's byte-identical
fixed-point test against `clock-template.org', and flips every tie the
stable sort exists to preserve.  This is a *coverage* fix, which keeps
what was asked for, rather than an *ordering* one, which would not.

*Run it before archiving.*  Archiving is the last moment a heading is
ever touched, so a drawer that is disordered when it moves stays that
way permanently -- which is how DONE.org got into the state above.  That
makes this a companion to the archive step (:ID: cbe282ec) rather than a
ritual of its own.

Reuses `claude-code-ide-org--consolidate-logbook-text' unchanged, which
is already idempotent and pinned lossless by its own tests, so running
this twice is a no-op and running it on a healthy file changes nothing."
  (interactive (list (not current-prefix-arg)))
  (let* ((counts (claude-code-ide-org--consolidate-drawers-1 dry-run))
         (headings (nth 0 counts))
         (changed (nth 1 counts))
         (files (nth 2 counts))
         (report (format "%s %d drawer(s) scanned, %d %s%s"
                         (if dry-run "Dry run:" "Consolidated:")
                         headings changed
                         (if dry-run "would be reordered" "reordered")
                         (if dry-run "" (format ", %d file(s) saved" files)))))
    (when (called-interactively-p 'any) (message "%s" report))
    report))

(defun claude-code-ide-org--consolidate-drawers-1 (dry-run)
  "Do the work of `claude-code-ide-org-consolidate-all-drawers'.
Returns (HEADINGS CHANGED FILES) rather than a sentence, so a caller
that wants the *number* of drifted drawers -- the ceremony report does
(TODO.org :ID: aa1ba915) -- can have it without parsing prose back out
of a message string."
  (let ((headings 0) (changed 0) (files 0))
    (dolist (file (claude-code-ide-org--tracked-files))
      (when (file-readable-p file)
        (let* ((already-open (find-buffer-visiting file))
               (buffer (or already-open (find-file-noselect file)))
               (touched nil))
          (with-current-buffer buffer
            ;; Bound, not cleared: the user's own read-only guard is
            ;; restored the moment this returns, however it returns.
            ;; Binding at all follows :ID: 97b030a4's reasoning -- this
            ;; is a write the human asked for by name.
            (let ((buffer-read-only nil))
              (save-excursion
                (goto-char (point-min))
                (while (re-search-forward org-heading-regexp nil t)
                  (let ((bounds (claude-code-ide-org--drawer-content-bounds "LOGBOOK")))
                    (when bounds
                      (setq headings (1+ headings))
                      (let* ((old (buffer-substring-no-properties
                                   (nth 0 bounds) (nth 1 bounds)))
                             (new (claude-code-ide-org--consolidate-logbook-text old)))
                        (unless (equal old new)
                          (setq changed (1+ changed) touched t)
                          (unless dry-run
                            (delete-region (nth 0 bounds) (nth 1 bounds))
                            (goto-char (nth 0 bounds))
                            (insert new))))))))
              (when (and touched (not dry-run))
                (setq files (1+ files))
                (save-buffer))))
          ;; A file this command opened is closed again; one the user
          ;; already had open is left exactly as found.
          (unless already-open
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))
    (list headings changed files)))

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
     (cond
      ((not (member state org-todo-keywords-1))
       (format "Error: %s is not a TODO keyword in this file (have: %s)"
               state (string-join org-todo-keywords-1 " ")))
      ;; A transition to the state already held is a no-op: there is
      ;; nothing for apply to do, and org's own logging has no state
      ;; change to record. Left to queue, it is offered at review,
      ;; marked, and only then fails -- hours after the context that
      ;; would explain it (TODO.org :ID: cc0c17a7). Four occurrences in
      ;; one day, every one from writing a keyword into a heading at
      ;; creation and then setting the same state through this tool.
      ;;
      ;; Refused with an `Error:' prefix because that is the mechanism,
      ;; not because it is a failure in the ordinary sense: the reply is
      ;; the only channel this tool has, and `bin/hooks/queue-append'
      ;; decides whether to write an event by testing that prefix. The
      ;; wording therefore has to carry what the prefix does not -- that
      ;; the requested state is the state on disk, which is success by
      ;; any reading except the queue's.
      ((equal state (org-get-todo-state))
       (format "Error: no change -- \"%s\" already holds %s, so nothing was queued"
               (org-get-heading t t t t) state))
      (t
       (format "Queued todo -> %s (was %s): \"%s\"; pending review."
               state
               (or (org-get-todo-state) "none")
               (org-get-heading t t t t)))))))))

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
  (let ((marker (claude-code-ide-org--id-find id 'marker))
        (target-marker (claude-code-ide-org--id-find target-id 'marker)))
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
  "The distinct :CATEGORY: values in use across FILE.

*Was the titles of FILE's level-1 headings* until 2026-08-27, when
TODO.org :ID: 29439196 dissolved that tier. A level-1 heading is now a
task, so offering those titles as capture targets would invite filing a
heading *under another task* by name -- both a nesting nobody asked for
and an address-by-title, which this project forbids everywhere else.

Kept as the answer to \"what categories exist?\", which is what
`org_capture's schema sends a reader here for. Read from the drawer
rather than `org-entry-get', which computes a fallback and would report
the file name as a category on every uncategorised heading."
  (with-current-buffer (find-file-noselect file)
    (let (cats)
      (org-with-wide-buffer
       (goto-char (point-min))
       (while (re-search-forward "^[ \t]*:CATEGORY:[ \t]+\\(\\S-.*?\\)[ \t]*$" nil t)
         (let ((c (substring-no-properties (match-string 1))))
           (unless (member c cats) (push c cats)))))
      (nreverse cats))))

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
     ;; No target: the top of the capture file. *Prepend*, not append --
     ;; TODO.org :ID: 29439196 flattened the category tier, and with no
     ;; heading to file under, recency is the ordering that remains. It
     ;; is also what the user asked for: newest first.
     ((null target)
      (list :spec (list 'file default) :file default :where "top of file"))
     ((claude-code-ide-org--id-find target)
      (list :spec (list 'id target)
            :file (car (claude-code-ide-org--id-find target))
            :where (format "under :ID: %s" target)))
     (t (error "target %S is not a known :ID:. Since 2026-08-27 a category \
is a :CATEGORY: property rather than a heading, so there is nothing to file \
*under* by name -- omit the target to prepend at the top of %s and pass \
category instead"
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
                     :immediate-finish t
                     ;; Prepend only for a bare file target. TODO.org
                     ;; :ID: 29439196 flattened the categories, so a
                     ;; targetless capture lands at file level and
                     ;; recency is the ordering that remains -- newest
                     ;; first, which is what the user asked for. An
                     ;; `(id ...)' target is untouched: prepending there
                     ;; would make a new child the FIRST child, which is
                     ;; a different decision nobody has taken.
                     :prepend (eq (car-safe spec) 'file)))))
    (org-capture-string title "z")))

(cl-defun claude-code-ide-org-capture (title &optional target tags note)
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
`claude-code-ide-org--reply-captured'.  Never signals to the MCP layer.

TARGET is optional again as of 2026-08-27, and the reason it was ever
required has been deleted rather than overridden.

It was required from 2026-08-20 because appending at the end of the
capture file meant a *level-1* heading, and level 1 was the category
tier: such a capture violated the convention on three counts and had to
be refiled by hand — the manual step this tool exists to remove
(TODO.org :ID: 97696fc2).  TODO.org :ID: 29439196 dissolved that tier.
Level 1 is now exactly where a task belongs, so the shape the guard
existed to prevent is the shape a capture should produce.

Omitting TARGET therefore prepends at the top of the capture file, and
`:CATEGORY:' is set afterwards or not at all.  Naming an :ID: still
files underneath it.  What is no longer accepted is a category *title*:
those are property values now, not headings, so there is nothing to file
under by that name — and accepting one would mean filing a heading under
another task, addressed by title, which this project forbids everywhere
else."
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

(defun claude-code-ide-org--replace-body (text)
  "Replace the prose body of the heading at point with TEXT.

*Prose only, and that is a structural guarantee rather than care taken.*
`claude-code-ide-org--heading-body-bounds' begins after
`org-end-of-meta-data', which skips every leading drawer -- measured
2026-08-26 against `:PROPERTIES:', `:LOGBOOK:' and `:PLAN:' in
combination.  So there is no reachable input to this function that
destroys a drawer; the region it can write to starts below all of them.
That is what makes wholesale revision safe enough to offer at all.

A heading with no body yet has no bounds, in which case there is nothing
to replace and the caller should append instead."
  (let ((bounds (claude-code-ide-org--heading-body-bounds)))
    (when bounds
      (delete-region (nth 1 bounds) (nth 2 bounds))
      (goto-char (nth 1 bounds))
      (insert (string-trim (or text "")))
      t)))

(defun claude-code-ide-org-amend (id text &optional note replace)
  "Append TEXT to the body of the heading with :ID: ID.

With REPLACE non-nil, *replace* the body's prose with TEXT instead of
appending to it (TODO.org :ID: 3063c3e5).

*Why revision is offered despite being destructive.*  Append-only forces
every body to be a transcript: each correction, each outcome summary,
each \"this turned out to be wrong\" lands furthest from where a reader
starts.  The objection append-only answered -- losing how a body
evolved -- does not need answering here, because *git already holds
every revision*.  The discipline is simply to commit before revising,
which is the same argument `plans/' already rests on.  Decided by the
user 2026-08-20.

*What it cannot touch.*  Only the prose below every drawer; see
`claude-code-ide-org--replace-body'.  `:PROPERTIES:', `:LOGBOOK:' and a
`:PLAN:' drawer are all outside the region by construction, so revising
a finished heading cannot destroy the plan it was wrapped with.

*What an open heading's body is for*, since that is what revision makes
achievable: the problem, the latest intended approach, and relevant
verified facts -- the current state of the question, not the stream of
consciousness of how it got there.

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
  ;; Resolve `[[id:...]]' links first, so a fabricated UUID is refused
  ;; rather than written and caught later by `bin/lint-org'. An
  ;; 8-character prefix is *expanded* here, which is the point: the
  ;; writer supplies what they reliably know and the tail is looked up.
  ;; Nine fabrications across two sessions preceded this, every one with a
  ;; correct prefix and a wrong tail, and a memory forbidding it
  ;; throughout.
  (let ((resolved (claude-code-ide-org-resolve-id-links text)))
    (unless (car resolved) (setq id nil))
    (when (car resolved) (setq text (cdr resolved)))
    (if (null id) (cdr resolved)
  (let ((marker (ignore-errors (claude-code-ide-org--id-find id 'marker))))
    (if (not marker)
        ;; A capture queued this session has an :ID: but no heading yet,
        ;; so this resolution fails -- truthfully and uselessly: "no org
        ;; heading found" reads as a typo when `org_capture' returned
        ;; that id seconds earlier. `org_set_todo' and `org_clock_in'
        ;; have tolerated the state since the silent-drop regression;
        ;; amend never did (TODO.org :ID: 798bb7a1), hit on 2026-08-27
        ;; while filing a heading about it.
        ;;
        ;; Amend genuinely cannot proceed -- there is no body to write
        ;; into -- so this stays a refusal, and says which refusal it is.
        ;; The check belongs HERE and not around the `--at-id' below:
        ;; amend resolves the id early to choose write-through versus
        ;; queue, so a guard further down is unreachable. `--id-find's
        ;; own docstring says exactly that, and a first attempt put it
        ;; there anyway.
        (let ((pending (claude-code-ide-org--pending-capture id)))
          (if pending
              (format "Error: \"%s\" is a capture queued this session and not \
yet applied, so it has no body to amend. Apply the queue, then amend."
                      (plist-get pending :title))
            (format "Error: no org heading found with :ID: \"%s\"" id)))
      (let* ((file (buffer-file-name (marker-buffer marker)))
             (title (org-with-point-at marker
                      (org-no-properties (org-get-heading t t t t)))))
        (set-marker marker nil)
        (if (claude-code-ide-org--file-busy-p file)
            ;; Revision defers exactly as an append does.  It must:
            ;; racing a human's unsaved edits is the one case where
            ;; replacing a body could destroy work git has never seen.
            (format "%s\"%s\" (%d line%s%s); pending review."
                    claude-code-ide-org--reply-queued-amend
                    title
                    (length (split-string (or text "") "\n"))
                    (if (= 1 (length (split-string (or text "") "\n"))) "" "s")
                    (if replace ", replacing the body" ""))
          (let* ((replaced nil)
                 (result
                  (claude-code-ide-org--at-id
                   id
                   (lambda ()
                     (if replace
                         (setq replaced
                               (claude-code-ide-org--replace-body text))
                       (claude-code-ide-org--end-of-body)
                       ;; Blank line before, so the amendment reads as its own
                       ;; paragraph rather than running into whatever the body
                       ;; already ended with.
                       (insert "\n\n" (string-trim (or text "")) "\n"))
                     ;; A heading with no body has nothing to replace, so
                     ;; the revision degrades to an append rather than
                     ;; silently doing nothing.
                     (when (and replace (not replaced))
                       (claude-code-ide-org--end-of-body)
                       (insert "\n\n" (string-trim (or text "")) "\n"))
                     (save-buffer)
                     nil))))
            (or (and (stringp result) result)
                (format "%s\"%s\"%s"
                        (if replace "Revised: " claude-code-ide-org--reply-amended)
                        title
                        (if (and replace (not replaced))
                            " (had no body; appended instead)" "")))))))))))

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
plain-string query, e.g. \"todo:WAITING\", \"tags:research,code\"
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
  (let ((loc (claude-code-ide-org--id-find id)))
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

  [blocked: a1b2c3d4 ...]   the named blockers that are not finished
  [blocked?: a1b2c3d4 ...]  a dependency exists that cannot be resolved --
              an id that no longer points anywhere; bare `[blocked?]' for a
              form naming no ids at all (`previous-sibling'). Deliberately
              not silent: unresolvable is not the same as satisfied, and
              collapsing them is how the first version went wrong in the
              other direction.

*The ids are named rather than merely flagged since 2026-08-26* (TODO.org
:ID: 8183fc7c, the user's proposal).  A bare `[blocked]' says *something*
unfinished blocks this and sends the reader off to find out what, which
defeats an index whose whole job is answering structural questions
without opening the file.  Naming them makes every dependency traversable
in the index itself, and it is what makes `[blocked?]' actionable at all:
it used to say a dependency could not be resolved without saying which.

Only the *offending* ids are listed -- the unfinished ones for
`[blocked]', the unresolvable ones for `[blocked?]' -- not the whole
declaration.  A satisfied blocker is not news, and a slice with 24
members would otherwise print all 24 forever.

Prefixes, not full ids, at this project's 8 characters.  Measured before
committing to it: 17 headings carry a `:BLOCKER:' across both files, 44
ids in total, so the whole-corpus outline grows by roughly 440 characters
against 20,264 -- *+2.2%*, against an index some 65x smaller than the
files it stands in for."
  (let ((raw (org-entry-get nil "BLOCKER")))
    (when raw
      (let* ((ids (claude-code-ide-org--outline-blocker-ids raw))
             (pairs (mapcar (lambda (id)
                              (cons id (claude-code-ide-org--outline-id-finished-p id)))
                            ids))
             (open (mapcar #'car (seq-filter (lambda (p) (eq (cdr p) 'open)) pairs)))
             (unresolved (mapcar #'car (seq-filter (lambda (p) (null (cdr p))) pairs))))
        (cond (open (format "  [blocked: %s]"
                            (mapconcat #'claude-code-ide-org--id-prefix open " ")))
              (unresolved (format "  [blocked?: %s]"
                                  (mapconcat #'claude-code-ide-org--id-prefix
                                             unresolved " ")))
              ((null ids) "  [blocked?]")
              (t nil))))))

(defconst claude-code-ide-org--id-prefix-minimum 4
  "Shortest :ID: prefix a tool will try to expand.

Uniqueness, not length, is what makes a prefix safe:
`claude-code-ide-org--expand-id-prefix' refuses an ambiguous one rather
than guessing.  So this is a floor on *effort*, not on correctness --
below it a prefix is so likely to collide that expanding is a waste.

Measured over this corpus 2026-08-27, 282 ids: two characters collide in
73 groups, three in 4, and **four in none** -- the same as eight. Raised
from a hard-coded 8 because the user reports using short prefixes
constantly, and there was never a reason beyond the convention's own
citation width.")

(defconst claude-code-ide-org--id-prefix-length 8
  "How many characters of an :ID: this project cites.
One constant so the outline, the review buffer and anything else that
abbreviates an id cannot drift apart about it.")

(defun claude-code-ide-org--id-prefix (id)
  "Return the first `claude-code-ide-org--id-prefix-length' chars of ID."
  (if (and (stringp id) (> (length id) claude-code-ide-org--id-prefix-length))
      (substring id 0 claude-code-ide-org--id-prefix-length)
    id))

(defun claude-code-ide-org--outline-line (active-only max-depth &optional indent-offset)
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
         (concat (make-string (* 2 (+ (1- level) (or indent-offset 0))) ?\s)
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

(defun claude-code-ide-org--outline-slice-members ()
  "Reference lines for the slice at point, or nil when it is not one.

TODO.org :ID: 8183fc7c.  Scoped to a slice, `org_outline' used to return
a single line for two dozen members -- a *wrong answer*, not a missing
feature, since a slice is structure and the tool is advertised as the way
to see structure without reading the file.

*Members render as references, never as children.*  A slice may name one
task inside another story, so indenting them under it would assert a
containment that does not exist.  The `->' marker and the referent's own
file are what say \"look over there\" rather than \"contained here\".

*Every member is listed, including dropped ones*, and that is the whole
reason this is not simply the blocker list one screen up.  A member whose
checkbox cookie was deleted is deliberately absent from `:BLOCKER:' --
blocking on a deferred member would hold the slice open forever for work
it explicitly decided not to do -- so a blocker-derived view silently
loses the record of having considered and dropped something, which the
conventions say a list must not lose.  Here it reads `(dropped)'.

Likewise unfiltered by ACTIVE-ONLY, which is why this takes no such
argument: a slice's member list *is* its definition, and hiding the
finished half would misreport what the slice is.  The statistics cookie
already carries the progress."
  (when (claude-code-ide-org--slice-p)
    (let ((members (claude-code-ide-org--slice-members)))
      (when members
        ;; Built only for a slice, and only once: it scans every tracked
        ;; file, so paying for it on ordinary scoped calls would tax the
        ;; common case for the rare one.
        (let ((index (claude-code-ide-org--slice-referent-index)))
          (mapcar
           (lambda (member)
             (let* ((id (car member))
                    (mark (cdr member))
                    (ref (gethash (downcase id) index))
                    (loc (claude-code-ide-org--id-find id)))
               (concat "  -> "
                       (if mark (format "[%s] " mark) "(dropped) ")
                       (if (car ref) (concat (car ref) " ") "")
                       (or (cdr ref) "(unresolved referent)")
                       (format "  {%s}" id)
                       (if loc
                           (format "  (%s)" (file-name-nondirectory (car loc)))
                         ""))))
           members))))))

(defun claude-code-ide-org--outline-map (active-only max-depth scope &optional grouped)
  "Collect index lines over SCOPE, an `org-map-entries' scope value.

With GROUPED, return (CATEGORY . LINE) pairs and indent every line one
level further, leaving room for the synthetic category header the caller
emits.  Without it, return plain lines exactly as before."
  (let (lines)
    (org-map-entries
     (lambda ()
       (let ((line (claude-code-ide-org--outline-line
                    active-only max-depth (and grouped 1))))
         (when line
           (push (if grouped
                     (cons (claude-code-ide-org--outline-category) line)
                   line)
                 lines))))
     nil scope)
    (nreverse lines)))

(defun claude-code-ide-org--outline-category ()
  "The `:CATEGORY:' governing the heading at point, inherited, or nil.

Inherited on purpose: a story stamps its children, and a child of a
story should group with its parent rather than appear uncategorised.
Uses `org-entry-get' WITH inheritance and then rejects org's computed
fallback -- absent any property org answers the file name, or a literal
question-mark triple, so a bare presence test always succeeds
(TODO.org :ID: 29439196)."
  (let ((v (org-entry-get nil "CATEGORY" t))
        (file (and (buffer-file-name)
                   (file-name-base (buffer-file-name)))))
    (and v (not (equal v "???")) (not (equal v file)) v)))

(defun claude-code-ide-org--outline-group (pairs)
  "Render (CATEGORY . LINE) PAIRS as category headers with members under.

*The rendered shape is deliberately identical to the pre-2026-08-27
outline*, where a category was a real heading: a bare unindented line
with its tasks indented beneath.  Only the source changed, from position
in the tree to a declared property -- which is TODO.org :ID: 979e02b6's
whole thesis applied to the tool itself.

Groups appear in first-seen order, so the outline still reflects the
file rather than imposing an alphabetical order the file does not have.
Uncategorised headings collect under a final `(no :CATEGORY:)' group
rather than being dropped or silently attached to the previous one."
  (let (order table out)
    (dolist (pair pairs)
      (let ((cat (or (car pair) "(no :CATEGORY:)")))
        (unless (assoc cat table)
          (push cat order)
          (push (cons cat nil) table))
        (push (cdr pair) (cdr (assoc cat table)))))
    (dolist (cat (nreverse order) (nreverse out))
      (push cat out)
      (dolist (line (nreverse (cdr (assoc cat table))))
        (push line out)))))

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
         ((and scope (claude-code-ide-org--id-find scope))
          (let ((lines (claude-code-ide-org--at-id
                        scope
                        (lambda ()
                          ;; Members first, while the buffer is still
                          ;; wide: `--outline-map' narrows to the tree.
                          ;; Only the *scoped* call expands them -- in a
                          ;; whole-file outline every member already has
                          ;; a line where it lives, and the statistics
                          ;; cookie reports the size, so expanding there
                          ;; would print each member twice.
                          (let ((members (claude-code-ide-org--outline-slice-members)))
                            (append (claude-code-ide-org--outline-map
                                     active depth 'tree)
                                    members))))))
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
              (let ((lines (claude-code-ide-org--outline-group
                            (claude-code-ide-org--outline-map
                             active depth (list file) 'grouped))))
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

(defcustom claude-code-ide-org-auto-clock-in-on-doing t
  "Whether a heading becoming DOING or PLANNING opens a clock by itself.

On.  A heading set to DOING or PLANNING by hand -- `C-c C-t', `S-right',
the agenda's `t' -- opens a clock on it, so work done at the keyboard is
timed without having to remember `C-c C-x C-i'.

*Off between 2026-08-18 and 2026-08-19, and the reason it could come
back is worth keeping.*  The defect was never that a clock existed
outside the queue: a human's own bare CLOCK line is the expected shape
\(TODO.org :ID: 4f8500e6).  It was *double counting* -- :ID: 38b92521's
drawer claimed 3:59 for a session spanning 3:22, because a
trigger-opened clock and a queue-derived span covered the same period on
the same heading.  Step 2(b) shortened the written lines without making
them non-overlapping, so it did not help.  What fixed it is
`claude-code-ide-org--subtract-intervals' (:ID: dadc08cf): apply now
subtracts whatever this trigger already recorded before writing, so the
two mechanisms compose instead of summing.

*The argument that took it away, kept because it is the argument that
could take it away again.*  The 2026-08-11 cutover considered retiring
this trigger and explicitly kept it, on the grounds that \"a human's own
`C-c C-t' still opens a clock\" (DONE.org's deviation table).  TODO.org
:ID: 226ed53b then objected that a clock opened by the trigger is in no
queue, so no review pass can see it, confirm it, or correct it -- the
same divergence CLAUDE.md warns about for a state change driven through
`emacsclient'.  The paragraph above is where that objection was
answered rather than merely overruled: invisibility to review was never
the defect, double counting was, and `--subtract-intervals' removes the
double counting without removing the trigger.

*What setting this to nil would cost*, since off is now the road not
taken: `C-c C-t' to DOING would stop starting timing, and attention on a
hand-edited heading would have to be claimed deliberately with `C-c C-x
C-i' -- which works either way, and writes a bare CLOCK line with no
annotation, the shape that marks an interval as the user's own rather
than the agent's (TODO.org :ID: 4f8500e6, :ID: b8e6007a).

Three things go quiet when it is nil, none of them a break:
`claude-code-ide-org--blocker-clock-running-p' would only ever fire for
a clock the user opened by hand or the brief one apply opens;
`claude-code-ide-org--clocked-heading-context' would return nil, so
`SessionStart' would lose its \"Currently clocked in\" line; and the
clock-status file would rest at idle between review passes.  The
statusline was already moved off the live clock (:ID: 290b6fc5), so that
last one costs nothing either way."
  :type 'boolean
  :group 'claude-code-ide-org)

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
never at load or registration time.

*Routinely reached, and it was briefly not.*  Between 2026-08-18 and
2026-08-19, with `claude-code-ide-org-auto-clock-in-on-doing' nil, the
only running clocks left were one the user opened by hand and the brief
one apply opens and closes around each interval it writes -- so the
common case this was built for, a trigger-opened clock still running
when DONE was requested, did not arise.  With the trigger on by default
again it is the ordinary case.

*Measured in batch 2026-08-26* (TODO.org :ID: 6a21e08b), because the
consequence is easy to state backwards: `C-c C-t' to DOING opens a clock
via the trigger, and `C-c C-t' to DONE on that same heading is then
*refused here* -- the keyword stays DOING and `org-block-entry-blocking'
names the heading.  `org-clock-out-when-done' does not rescue it, since
`org-blocker-hook' runs before any after-state-change hook.  So the
hand-edit path is close the clock, then set DONE, in that order.  A hand
`C-c C-x C-i' followed by DONE reaches this the same way, and is the
sequence a human is most likely to get wrong unaided.

The epic's plan said this \"goes quiet: nothing opens a clock outside
apply\".  That is too strong and is corrected here rather than in the
plan, because this is where someone will read it: `org-clock-in' is a
user-facing command and no part of this change takes it away."
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

(defconst claude-code-ide-org--slice-member-regexp
  "^[ \t]*- \\(?:\\[\\([ Xx-]\\)\\] \\)?\\[\\[id:\\([^]]+\\)\\]"
  "Matches one member line of a slice's checkbox list.

Group 1 is the checkbox mark, absent for a cancelled or deferred member
whose cookie has been deleted.  Group 2 is the link target.

Requiring an `id:' link is what keeps the revision links out: a slice
also carries a plain list of `orgit-rev:' links for the prompt that drove
it, and those are list items with no cookie, which would otherwise be
indistinguishable from a deferred member.")

(defun claude-code-ide-org--slice-p ()
  "Non-nil when the heading at point is a slice.

Declared by a `:KIND: slice' property.  A slice cannot be *derived* the
way an epic can -- \"has a checkbox list of id links\" is not a
structural fact, since an ordinary body may hold one for reference -- so
unlike `claude-code-ide-org--container-heading-p', which reads structure,
this reads a declaration.  TODO.org :ID: 8ca6541d argues that at length.

*A tag was tried first and lasted an hour.*  It was that heading's own
proposal and it looked right: sanctioned by the conventions, natively
agenda-matchable.  Then the tags on the first real slice were deleted as
inadvertent, and the assertion built on them went silently inert --
`bin/lint-org' reported zero errors because nothing was a slice any more,
which is indistinguishable from nothing being wrong.  A detector whose
removal is invisible is the wrong detector.

`:KIND:' rather than a coined name: 8ca6541d had already observed that no
`:KIND:', `:TYPE:' or equivalent property exists in this repo, naming the
gap while listing four heading classes each detected by a different
bespoke mechanism.  This is the first one to declare itself, and the
property is deliberately general enough for the others.

Not inherited -- `org-entry-get' without the inherit flag -- so a
subheading of a slice is not one."
  (equal "slice" (org-entry-get nil "KIND")))

(defconst claude-code-ide-org--statistics-cookie-regexp
  "\\[[0-9]*\\(?:%\\|/[0-9]*\\)\\]"
  "Matches an org statistics cookie: `[/]', `[2/5]', `[%]' or `[40%]'.
Shared by the inserter and by `bin/lint-org's cookie rules, so the two
cannot disagree about what counts as a cookie already being present.")

(defun claude-code-ide-org--ensure-statistics-cookie-at-point ()
  "Insert `[/]' immediately after the keyword at point, when absent.
Returns non-nil when one was inserted.

`org-update-statistics-cookies' updates a cookie in place and will not
create one -- verified 2026-08-26 -- so a headline that never got `[/]'
typed into it is inert to every later refresh. This closes that, and is
deliberately separate from recomputing: it establishes the slot, org
fills it.

*Position is the convention, read off the corpus rather than chosen.*
Measured 2026-08-28: 13 of the 14 cookies in TODO.org and DONE.org sit
immediately after the keyword, and the single trailing one was written
by an earlier version of this function. A trailing cookie is also the
part a narrow agenda window truncates away, which defeats the reason a
container carries one -- that its progress is readable without
unfolding it.

`org-edit-headline' takes the headline text without keyword or tags and
preserves both, so prefixing here cannot disturb either. That matters:
org requires tags to end the headline, and appending to the raw line
yields `... :code: [/]', which org does not read as a cookie at all."
  (let ((title (org-get-heading t t t t)))
    (unless (string-match-p claude-code-ide-org--statistics-cookie-regexp
                            (or title ""))
      (org-edit-headline (concat "[/] " title))
      t)))

(defun claude-code-ide-org--category-property-p ()
  "Non-nil when the heading at point literally carries a `:CATEGORY:'.

Distinct from `(org-entry-get nil \"CATEGORY\")', which *computes* a
category: absent a property it returns the file name, or `\"???\"' in a
buffer visiting no file. So the obvious presence test can never fail,
and a lint rule written on it is inert.

That fallback is not incidental to this project -- it is the whole
finding behind TODO.org :ID: 29439196. Across 274 headings the agenda's
category column held exactly two distinct values, `TODO' and `DONE',
because it was showing file names."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point))))
      (and (re-search-forward "^[ \t]*:CATEGORY:[ \t]+\\S-" end t) t))))

(defun claude-code-ide-org--grouping-heading-p ()
  "Non-nil when the heading at point is a grouping -- a container or a
slice -- rather than a unit of work in its own right.

*The union exists because two callers were asking the wrong question.*
`claude-code-ide-org--trigger-auto-clock-in' and the since-retired
sole-TODO promotion trigger both consulted
`claude-code-ide-org--container-heading-p', whose argument is about
*meaning* -- a grouping's time and its next action live in its members,
not in it -- while the predicate itself tests a *mechanism*, namely
whether keyworded headings sit underneath.  Those were the same thing
until a slice existed.  A slice's members are `[[id:...]]' links in a
checkbox list rather than descendants, so the mechanism answers nil
while the argument applies with full force: every referent carries its
own clock, and every referent is a better next action than the slice.
TODO.org :ID: 95c27fca measured it -- `(:container-p nil :auto-clock-in
t :would-clock t)' against the first real slice.

*Why a third predicate rather than teaching one of the two.*
`--container-heading-p' documents itself as derived from structure
\"rather than declared in a property someone has to remember to
maintain\", and `--slice-p' documents itself as reading a declaration
because a slice cannot be derived.  Both are right about themselves.
Widening either would make it contradict its own docstring, which is the
failure mode this repo spent 2026-08-26 cleaning up (:ID: 6a21e08b).  So
the union goes in a third name, and \"grouping\" is not a coinage: it is
already CLAUDE.md's word for exactly this union, in the sentence \"a
grouping is either emergent or declared\".

*Not every `--container-heading-p' caller should become this one.*
`bin/lint-org's statistics-cookie rule deliberately still asks the
narrow question, because there the subject really is TODO *children* --
a slice carries a checkbox cookie over links instead, which is a
different convention and not this one's business."
  (or (claude-code-ide-org--container-heading-p)
      (claude-code-ide-org--slice-p)))

(defun claude-code-ide-org--slice-members ()
  "Return the slice-at-point's members as a list of (ID . MARK).

MARK is the checkbox character, or nil for a member whose cookie has
been deleted.  Scans the heading's own body only, stopping at the first
subheading."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (or (point) (point-max))))
          (members nil))
      (while (re-search-forward claude-code-ide-org--slice-member-regexp end t)
        ;; MARK is nil only when group 1 did not match at all -- an
        ;; *absent* cookie.  An empty `[ ]' is a cookie like any other and
        ;; its member still blocks; conflating the two cost a wrong
        ;; blocker set of 12 ids instead of 20 the first time this ran.
        (push (cons (match-string-no-properties 2)
                    (match-string-no-properties 1))
              members))
      (nreverse members))))

(defun claude-code-ide-org--slice-blocker-ids ()
  "Return the ids the slice at point should block on.

Exactly the members that still carry a checkbox cookie.  A member whose
cookie was deleted is cancelled or deferred, and deferral is the case
that matters: a deferred member is *unfinished*, so blocking on it would
hold the slice open forever for work it explicitly decided not to do.
Cookie and blocker are therefore the same set by construction, which is
what the lint assertion checks."
  (delete-dups
   (mapcar #'car
           (seq-filter (lambda (m) (cdr m)) (claude-code-ide-org--slice-members)))))

(defconst claude-code-ide-org--slice-checkbox-by-keyword
  '(("DONE"      . "X")
    ("DOING"     . "-")
    ("REVIEW"    . "-")
    ("PLANNING"  . "-")
    ("WAITING"   . "-")
    ("TODO"      . " ")
    ("NEXT"      . " ")
    ("CANCELLED" . nil)
    ("MAYBE"     . nil))
  "How a member's checkbox follows from its referent's TODO keyword.

Total, and derived rather than chosen -- there is no judgement in a
slice's checkbox.  `DONE'/`CANCELLED'/`DOING'/`REVIEW' were given by the
user; the rest follow the same logic.  `PLANNING' and `WAITING' are `-'
because work started and a clock opened; `MAYBE' has no cookie because
deferral is treated exactly as cancellation -- the member keeps its line
and stops counting, in either direction.

A nil cdr means the cookie is *deleted*, leaving a plain `- ' item.")

(defun claude-code-ide-org--slice-referent-index ()
  "Hash of full :ID: to (KEYWORD . TITLE) across the tracked files.

One scan rather than an `org-id-find' per member: a slice of twenty
members would otherwise open and search files twenty times to render one
heading."
  (let ((table (make-hash-table :test 'equal))
        (kw-re (concat "\\`\\(" (mapconcat #'regexp-quote
                                           (mapcar #'car claude-code-ide-org--slice-checkbox-by-keyword)
                                           "\\|")
                       "\\)\\_>")))
    ;; Archives included: a slice keeps naming its members after they are
    ;; archived, so a referent index blind to DONE.org would render them
    ;; "(unresolved referent)" (TODO.org :ID: 020d3688).
    (dolist (file (claude-code-ide-org--id-scannable-files) table)
      (when (file-exists-p file)
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert-file-contents file)
            (goto-char (point-min))
            (let (pending)
              (while (not (eobp))
                (cond
                 ((looking-at "^\\*+ +\\(.*\\)$")
                  (let* ((raw (match-string-no-properties 1))
                         (kw (and (string-match kw-re raw) (match-string 1 raw)))
                         (title (if kw (substring raw (match-end 1)) raw)))
                    (setq title (string-trim (replace-regexp-in-string
                                              "[ \t]+:[[:alnum:]_@#%:]+:[ \t]*\\'" "" title)))
                    ;; Strip the referent's own statistics cookie. Copying
                    ;; `[0/1]' into a slice's checkbox list does not carry
                    ;; the referent's progress across -- org reads it as a
                    ;; cookie belonging to *that list item* and recomputes
                    ;; it against the slice's own structure. Measured: a
                    ;; leaf member became `[0/0]', and a member with three
                    ;; nested members kept `[0/3]' only because its
                    ;; referent happened to have three unfinished children
                    ;; too. Either way the number reports the slice and
                    ;; reads as the referent, which is worse than absent.
                    (setq title (replace-regexp-in-string
                                 "\\`\\[[0-9]*\\(?:%\\|/[0-9]*\\)\\][ \t]*" "" title))
                    (setq pending (cons kw title))))
                 ((and pending (looking-at "^[ \t]*:ID:[ \t]+\\(\\S-+\\)[ \t]*$"))
                  (puthash (downcase (match-string-no-properties 1)) pending table)
                  (setq pending nil)))
                (forward-line 1)))))))))

(defun claude-code-ide-org--refresh-slice-members-at-point (index)
  "Rewrite the slice-at-point's member lines from INDEX.  Returns a count.

Each line is regenerated as `- [BOX] LINK KEYWORD TITLE': the checkbox
from the referent's keyword, and the keyword and title copied fresh.  The
link itself is left alone -- it is the one part that cannot go stale --
and so is the ordering.

A member whose id is not in INDEX, or whose referent carries no keyword,
is skipped rather than guessed at.  Both are already errors in
`bin/lint-org', and a regenerator that invented a state for them would
paper over exactly what that error exists to surface.

*Everything after the link is replaced*, so a member line carries no
annotation of its own.  That is the convention rather than a limitation
of this function: the line is a rendering, and anything hand-written on
it would be destroyed at the next apply anyway."
  (save-excursion
    (org-back-to-heading t)
    ;; A *marker*, not a position. Each rewrite changes the line's length,
    ;; and a fixed integer end would drift: the first replacement here was
    ;; longer than what it replaced, which pushed the second member line
    ;; past the bound and left it silently unrefreshed.
    (let ((end (copy-marker (save-excursion (outline-next-heading) (or (point) (point-max)))))
          (changed 0)
          (skipped nil))
      (while (re-search-forward
              "^\\([ \t]*\\)- \\(\\[[ Xx-]\\] \\)?\\(\\[\\[id:\\([^]]+\\)\\]\\[[^]]*\\]\\]\\)\\(.*\\)$"
              end t)
        (let* ((indent (match-string-no-properties 1))
               (link (match-string-no-properties 3))
               (id (downcase (match-string-no-properties 4)))
               (entry (gethash id index))
               (kw (car entry))
               (title (cdr entry)))
          ;; A member with no entry, or an entry carrying no keyword, is
          ;; skipped -- and used to be skipped *silently*, leaving the
          ;; placeholder text standing as though it were the referent's
          ;; real title. That is the "a slice line disagrees with its
          ;; referent" failure the conventions exist to prevent, arriving
          ;; through a door they do not describe (TODO.org :ID: 798bb7a1).
          ;;
          ;; Counted rather than repaired: the honest rendering of a
          ;; heading whose `todo' event is still queued is not something
          ;; this function can invent, so it reports instead.
          (unless (and entry kw)
            (push id skipped))
          (when (and entry kw)
            (let* ((box (cdr (assoc kw claude-code-ide-org--slice-checkbox-by-keyword)))
                   (new (concat indent "- " (if box (format "[%s] " box) "")
                                link " " kw " " title))
                   (old (match-string-no-properties 0)))
              (unless (equal old new)
                ;; LITERAL is t, so NEW goes in verbatim.  Passing it
                ;; through `regexp-quote' as well would insert the
                ;; backslashes into the file -- visible immediately on a
                ;; title like "[0/3] Make the daily ceremony ...".
                (replace-match new t t)
                (setq changed (1+ changed)))))))
      (set-marker end nil)
      (cons changed (nreverse skipped)))))

(defun claude-code-ide-org-refresh-slice (&optional id)
  "Regenerate every slice's checklist from its referents.

The counterpart to applying the queue, and the reason it exists: apply
changes referents' keywords in bulk, and a slice's member lines are
*copies* of those keywords.  Nothing else makes a slice stale, and
nothing detects it when it happens -- `bin/lint-org' compares the
`:BLOCKER:' against the checkbox list, which both go stale together, and
`org-update-statistics-cookies' recomputes the cookie from checkboxes
that have not changed.  Measured 2026-08-25 (TODO.org :ID: 0acc1df2).

Rewrites member lines, then the statistics cookie, then the `:BLOCKER:'
-- in that order, because each depends on the one before: a member going
`CANCELLED' loses its cookie, which changes both the count and the
blocker set.

With ID, refreshes that slice only.  Returns a human-readable summary."
  (interactive)
  (require 'org-id)
  (let ((index (claude-code-ide-org--slice-referent-index))
        ;; Same reasoning as the apply path (TODO.org :ID: 97b030a4): the
        ;; user's `buffer-read-only' guards against their own stray
        ;; keystrokes, and `M-x claude-code-ide-org-refresh-slice' is not
        ;; one. This is a ceremony step run immediately after apply --
        ;; the daily sequence tells the human to run it there -- so a
        ;; read-only buffer failing it would reproduce the exact incident
        ;; the apply-path binding was added for, one command later.
        (inhibit-read-only t)
        (slices 0) (lines 0) (blockers 0) (unrendered nil))
    (dolist (file (claude-code-ide-org--tracked-files))
      (when (file-exists-p file)
        (with-current-buffer (find-file-noselect file)
          (org-with-wide-buffer
           (goto-char (point-min))
           (while (re-search-forward org-heading-regexp nil t)
             (when (and (claude-code-ide-org--slice-p)
                        (or (null id)
                            (equal (downcase (or (org-entry-get nil "ID") ""))
                                   (downcase id))))
               (setq slices (1+ slices))
               (let ((result (claude-code-ide-org--refresh-slice-members-at-point index)))
                 (setq lines (+ lines (car result)))
                 (setq unrendered (append unrendered (cdr result))))
               ;; Insert the cookie before updating it, because
               ;; `org-update-statistics-cookies' only ever *updates* one
               ;; that is already in the headline -- measured 2026-08-26,
               ;; TODO.org :ID: 28415ca8. A slice whose creator did not
               ;; type `[/]' by hand was therefore refreshed on every
               ;; apply, silently, forever: this call found nothing to
               ;; recompute and said so to nobody. Found on :ID: 979e02b6
               ;; by the user, six days and one whole slice after
               ;; :ID: c44c2119 got one only because somebody remembered.
               ;;
               ;; Self-healing rather than a creation-time rule, which is
               ;; the point: a discipline that depends on remembering is
               ;; the thing this repo keeps discovering it cannot have.
               (claude-code-ide-org--ensure-statistics-cookie-at-point)
               (org-update-statistics-cookies nil)
               (when (claude-code-ide-org--refresh-slice-blocker-at-point)
                 (setq blockers (1+ blockers))))))
          (when (buffer-modified-p) (save-buffer)))))
    (concat
     (format "%d slice%s refreshed, %d member line%s rewritten, %d blocker%s updated"
             slices (if (= slices 1) "" "s")
             lines (if (= lines 1) "" "s")
             blockers (if (= blockers 1) "" "s"))
     ;; Named, not merely counted. "1 skipped" sends the reader hunting
     ;; through a 27-member list; the id says which line is still showing
     ;; its placeholder, and the reason says what will fix it.
     (when unrendered
       (format ".  %d member%s left unrendered because %s keywordless on \
disk -- a queued capture or `todo' event, not yet applied: %s"
               (length unrendered)
               (if (= 1 (length unrendered)) "" "s")
               (if (= 1 (length unrendered)) "it is" "they are")
               (mapconcat #'claude-code-ide-org--id-prefix unrendered " "))))))

(defun claude-code-ide-org-refresh-slice-blocker (&optional id)
  "Write the `:BLOCKER:' of the slice with :ID: ID from its checkbox list.

Interactively, or with ID nil, refreshes every slice in the tracked
files.  Derived rather than authored, for the same reason every other
field on a member line is: a hand-maintained blocker list is a second
copy of the checklist that can disagree with it.

Returns a human-readable summary."
  (interactive)
  (require 'org-id)
  (if id
      (claude-code-ide-org--at-id
       id (lambda () (claude-code-ide-org--refresh-slice-blocker-at-point)))
    (let ((n 0) (changed 0))
      (dolist (file (claude-code-ide-org--tracked-files))
        (when (file-exists-p file)
          (with-current-buffer (find-file-noselect file)
            (org-with-wide-buffer
             (goto-char (point-min))
             (while (re-search-forward org-heading-regexp nil t)
               (when (claude-code-ide-org--slice-p)
                 (setq n (1+ n))
                 (when (claude-code-ide-org--refresh-slice-blocker-at-point)
                   (setq changed (1+ changed))))))
            (when (buffer-modified-p) (save-buffer)))))
      (format "%d slice%s scanned, %d updated" n (if (= n 1) "" "s") changed))))

(defun claude-code-ide-org--refresh-slice-blocker-at-point ()
  "Set or clear the slice-at-point's `:BLOCKER:'.  Non-nil if it changed."
  (let* ((ids (claude-code-ide-org--slice-blocker-ids))
         (new (and ids (format "ids(%s)" (mapconcat #'identity ids " "))))
         (old (org-entry-get nil "BLOCKER")))
    (unless (equal old new)
      ;; Removed rather than emptied when a slice has no blocking
      ;; members: `ids()' would read as a declaration that nothing blocks,
      ;; which the lint would then have to tell apart from "not built yet".
      (if new (org-entry-put nil "BLOCKER" new) (org-entry-delete nil "BLOCKER"))
      t)))

(defun claude-code-ide-org--trigger-auto-clock-in (change-plist)
  "For `org-trigger-hook': the moment any heading's TODO state becomes
DOING or PLANNING, automatically open a clock on it via `org-clock-in',
unless a clock is already running on that exact heading, or the heading
is a container \(`claude-code-ide-org--container-heading-p'). Guarded
against re-entrancy by `claude-code-ide-org--auto-clock-in-active'.

*On by default.*  The first thing tested is
`claude-code-ide-org-auto-clock-in-on-doing', whose standard value is t
and whose live value is t, so in normal operation this function does
fire.  Read that variable's docstring for the argument on both sides --
it is the one place the decision is made.

*This paragraph said the opposite for a week* (TODO.org :ID: 6a21e08b,
fixed 2026-08-26).  The variable was nil between 2026-08-18 and
2026-08-19 (:ID: 226ed53b, step 2(c)); `eca3a77' put it back and updated
the `defcustom' but not its readers, leaving this docstring asserting
inertness of a live function -- the most misleading available way to be
stale, and one no test and no lint can see.

The hook registration is unconditional and the gate is inside the
function, so setting the variable nil leaves a registered no-op rather
than unregistering anything.  That is deliberate: it keeps the tests
exercising a real configuration a user can select, whichever way the
variable is set.
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
  (when (and claude-code-ide-org-auto-clock-in-on-doing
             (member (plist-get change-plist :to) '("DOING" "PLANNING"))
             (not claude-code-ide-org--auto-clock-in-active)
             (not (claude-code-ide-org--grouping-heading-p)))
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

(defun claude-code-ide-org--format-log-state-line (new-state old-state cause &optional time)
  "Format a single :LOGBOOK: line matching org's own native
`org-log-note-headings' \"state\" template (\"State %-12s from %-12s
%t\"), but with CAUSE as the note text instead of one typed
interactively. Used by automatic transitions that already know exactly
why they fired, so they can produce output indistinguishable from a
real interactively-logged state change without ever going through
org's own note-prompt machinery.

TIME backdates the stamp, defaulting to now.  A transition that should
have been recorded when something else happened -- a container entering
DOING because a child did, noticed only afterwards -- is otherwise
unrecordable at its real time, since the queue stamps an event when it
is written rather than when it was true."
  (format "- State %-12s from %-12s %s \\\\\n  %s"
          (format "\"%s\"" new-state)
          (format "\"%s\"" old-state)
          (format-time-string "[%Y-%m-%d %a %H:%M]" time)
          cause))

(defun claude-code-ide-org--trigger-demote-conflicting-next (change-plist)
  "For `org-trigger-hook': GTD's \"single next action\" per level. The
moment any heading's TODO state becomes NEXT, demote every OTHER
heading in the same sibling group that is currently NEXT back to TODO,
with an explanatory :LOGBOOK: note. No-op unless CHANGE-PLIST's :to is
\"NEXT\". Demoting a sibling re-enters `org-todo' (hence this hook)
for that sibling -- safe by construction, because the nested call's
:to is \"TODO\" and this function no-ops on anything but \"NEXT\". The
nested `org-todo' call is wrapped in `org-inhibit-logging' so org's own
native logging (an interactive note-prompt, if TODO or NEXT is ever
marked `@' in the future) never fires for this programmatic
transition; `claude-code-ide-org--format-log-state-line' supplies an
equivalent line by hand instead."
  (when (and (equal (plist-get change-plist :to) "NEXT")
             ;; Only inside a container. A top-level heading has no
             ;; sibling group worth the name: its "siblings" are every
             ;; other task in the file, so demoting among them asserts
             ;; one next action for the whole corpus. TODO.org :ID:
             ;; 62b65ad0 decided that `NEXT' belongs to a container's
             ;; *members* -- the children of a story, the referents of a
             ;; slice -- and never to a container itself, because that is
             ;; what GTD means by the next action of a project.
             ;; Having a parent IS the test: a keyworded heading with a
             ;; parent makes that parent a container by
             ;; `--container-heading-p''s own definition.
             (save-excursion (org-back-to-heading t) (org-up-heading-safe)))
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




(with-eval-after-load 'org
  (add-hook 'org-blocker-hook #'claude-code-ide-org--blocker-clock-running-p)
  (add-hook 'org-trigger-hook #'claude-code-ide-org--trigger-auto-clock-in)
  (add-hook 'org-trigger-hook #'claude-code-ide-org--trigger-demote-conflicting-next))

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
settled, and the heading above schedules a re-measure.

*This no longer defends any duration*, since 2026-08-18 (TODO.org :ID:
226ed53b).  A span used to be written as one CLOCK line end to end, so
where this threshold fell decided how much idle got recorded as work;
that is what made its 1200s derivation load-bearing.  Apply now writes
one line per run of `resume' -> `pause' work inside the span
\(`claude-code-ide-org--span-work-runs'), and `claude-code-ide-org-span-
idle-floor' is the only value that decides which idle survives.  What is
left here is *grouping and display*: how many items a human is shown and
how wide each one reads.  Raising or lowering it now moves lines around
the review buffer without moving a single recorded minute."
  :type 'integer
  :group 'claude-code-ide-org)

(defcustom claude-code-ide-org-span-idle-floor 120
  "Seconds of idle inside a span that apply absorbs rather than splits on.

A span groups guideposts for review; the work inside one is the runs
where a `resume' was followed by a `pause'.  Apply writes one CLOCK line
per run (`claude-code-ide-org--span-work-runs'), and two runs separated
by less than this many seconds are merged into one line instead.
Strictly less: a gap of exactly this many seconds splits, so the value
reads as \"idle up to but not including two minutes is not worth
recording as an interruption\".

Why a floor at all, rather than maximum fidelity.  Measured over the
post-cutover corpus on 2026-08-18: splitting at every idle gap turns one
span into 54 CLOCK lines, against 39 at two minutes.

*Two minutes buys less legibility than planning expected, and is kept
anyway.*  The plan predicted 2-4 lines per span; measured, 120s gives a
median of 5, p90 16 and max 39 across 40 pooled spans.  A sweep says
raising it does not pay: 300s gives median 3 and max 15 but writes
30.89 h against 120s's 23.05 h, re-absorbing nearly 8 h of the idle this
exists to stop recording.  Legibility is the only thing a larger floor
buys and accuracy is the whole point, so the trade goes this way -- and
this is a `defcustom' for anyone whose drawers say otherwise.

Note the floor is *not* what keeps `=>  0:00' out of the drawer, though
an earlier draft of this docstring said so.  It merges across short
idle, and a sub-minute turn isolated by more than the floor on both
sides survives the merge as its own run.  55 of 412 turn-pairs render
inside a single minute; `claude-code-ide-org--span-work-runs' drops
those on its own, by rendering them.

It is *not* a rounding control and cannot delete an interval: absorbed
idle is only ever added to a run that already exists.  The rounding that
did delete one (:ID: b74e0f19) is not coming back through here."
  :type 'integer
  :group 'claude-code-ide-org)

(defcustom claude-code-ide-org-span-minimum-interval 0
  "Seconds below which an interval is dropped rather than written.

The counterpart to `claude-code-ide-org-span-idle-floor', and the
reason both now exist: that one is a floor on the *gap* between runs,
this one a floor on the *run*.  Before this variable there was no
number to set for the second -- what kept short intervals out of the
drawer was two rendering conditions in
`claude-code-ide-org--apply-idle-floor' (endpoints inside one minute,
or a duration rounding to `=>  0:00'), which are consequences of the
clock format rather than a policy anyone chose.  A knob that cannot be
turned is not a knob, so this names the policy without yet changing it.

*Zero is deliberate and means \"exactly today's behaviour\"* -- the two
rendering conditions still apply and still drop everything under a
minute, so a fresh install writes what it wrote before.  The value is a
reporting decision, not an implementation one, and it belongs to the
September review of what these drawers are for (TODO.org
:ID: 96a51c2f).

What that review needs is measured, so it does not have to be measured
again.  Scoped to the 283 post-cutover CLOCK lines standing on
2026-08-20 (36.88 h) -- the population this floor would actually
govern, since pre-cutover lines were written by the old aggregator and
are not being rewritten:

  | floor | lines dropped | share of lines | time dropped | share of time |
  |-------+---------------+----------------+--------------+---------------|
  |   60s |             0 |           0.0% |        0 min |         0.00% |
  |  120s |            67 |          23.7% |       67 min |         3.03% |
  |  180s |           115 |          40.6% |      163 min |         7.37% |
  |  300s |           180 |          63.6% |      392 min |        17.71% |

120s is the favourable trade -- a quarter of the lines for 3% of the
recorded time -- and 300s is not, taking nearly two thirds of the lines
for 18%.  60s drops nothing, confirming the two rendering conditions
already cover that range.  Setting this to 120 would also make the pair
read as one rule: idle under two minutes is not an interruption, work
under two minutes is not an interval.

*The estimate moves, which is the argument for re-measuring rather than
citing this table in September.*  TODO.org :ID: 96a51c2f carried
\"6.5% of recorded time, a third of the lines\" for the same 120s value,
measured on 2026-08-18.  Two days of work later the same measurement
gives 3.03% and a quarter.  Neither is wrong; the corpus grew and the
mix shifted.  Re-derive against the month, as that heading instructs."
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
  "Return SESSION-ID's already-applied events, a hash of `ts' -> apply time.
Empty when nothing has been applied. The value is the timestamp of the
*apply pass* that consumed the event, in the queue's own
`%Y-%m-%dT%H:%M:%S%z' format -- or the empty string for an entry written
before this field existed.

A *set* rather than a high-water mark, deliberately. A watermark can
only describe a contiguous prefix, and review is not contiguous: a human
applies the two items they care about and leaves the rest, whose events
sit earlier in the same file. A watermark then cannot advance at all --
observed 2026-08-07, where a real apply wrote no watermark whatsoever and
every applied item would have been re-proposed, and re-applied, on the
next pass. Per-event is the honest model for per-item review.

*Why each entry carries when it was consumed* (TODO.org :ID: 21c91613).
On 2026-08-24 an apply had to be undone, and the ledger could not say
which events belonged to which pass -- so \"un-apply the pass of 17:17\"
had to be reconstructed from an `org_pending_updates' report that
happened to have been captured minutes earlier. With the stamp it is a
filter. The obvious cheaper fix, a `.applied.bak' snapshot, was
considered and refused: it can only undo the *most recent* pass, which
is precisely the case that incident was not -- a third, correct apply
had already landed on top.

*Both on-disk shapes are read.* Entries written before the field existed
are a bare JSON array of `ts' strings, and each yields \"\" -- not a
fabricated time. The same ethos as the retired stale-clock guess: a
plausible wrong timestamp is worse than a visibly absent one, because it
survives being read back as fact. The upgrade happens on the next write,
since the file is rewritten wholesale every time."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry (alist-get 'applied
                              (claude-code-ide-org--queue-watermark-data session-id)))
      (if (consp entry)
          ;; New shape: a JSON object, so `json-parse-string' with
          ;; :object-type `alist' hands back (symbol . string) cells.
          (puthash (format "%s" (car entry)) (or (cdr entry) "") table)
        ;; Legacy shape: a bare array element, already a string.
        (puthash entry "" table)))
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
    ;; An empty set serializes as `{}', never `null'.  Elisp spells the
    ;; empty list, the empty object and JSON null all as nil, so
    ;; `json-encode' would happily emit `null' and this reader would
    ;; happily accept it -- the round-trip works only because both ends
    ;; are lossy in the same direction.  No other JSON stack is: the
    ;; common `d.get("applied", {})' idiom does not fall back when the
    ;; key is present holding null, so the field would be an object
    ;; sometimes and null others, which is not a shape worth handing to
    ;; whatever eventually reports on these files.  An empty hash table
    ;; is how you say "empty, and still an object" here.
    ;;
    ;; `applied' became an object rather than an array when each entry
    ;; started carrying the time of the pass that consumed it; the
    ;; reader still accepts the older array.  Both fields are now the
    ;; same shape, which is the point -- one serialization idiom, not
    ;; two that drift.
    `((applied . ,(let (all)
                    (maphash (lambda (k v) (push (cons (intern k) v) all)) applied)
                    (if all
                        (sort all (lambda (a b)
                                    (string< (symbol-name (car a))
                                             (symbol-name (car b)))))
                      (make-hash-table))))
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

(defun claude-code-ide-org--queue-mark-applied (session-id ts-strings &optional applied-at)
  "Add TS-STRINGS to SESSION-ID's set of applied events.
Unions with whatever is already recorded, so a partial apply followed by
another partial apply accumulates rather than replacing.

APPLIED-AT is the timestamp recorded against each of TS-STRINGS,
defaulting to now.  *The unit is a pass, not an event*, which is why the
caller computes it rather than this function: \"un-apply the pass of
17:17\" is only a filter if every event consumed together carries the
*same* stamp, and a `now' taken here would differ across the sessions
`claude-code-ide-org--review-record-applied' loops over.  The default is
for a one-shot caller with no pass to speak of.

An event already recorded keeps its original stamp.  Re-marking is not a
second consumption -- the event was consumed once, by the pass named --
and overwriting would quietly rewrite history the field exists to
preserve.

Never truncates or rewrites the queue file itself: the session that owns
it may still be appending, and racing an appending writer is exactly the
class of bug this refactor exists to remove. Applied state is therefore
recorded beside the log, never in it.

Round-trips the `dismissed' map untouched. It shares this file, and
writing only `applied' would erase every dismissal the moment anything
was applied -- see `claude-code-ide-org--queue-watermark-data'."
  (let ((applied (claude-code-ide-org--queue-applied session-id))
        (stamp (or applied-at (format-time-string "%Y-%m-%dT%H:%M:%S%z"))))
    (dolist (ts ts-strings)
      (unless (gethash ts applied) (puthash ts stamp applied)))
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

(defun claude-code-ide-org--queue-historical-guideposts ()
  "Return every pause/resume guidepost ever written, oldest first.

Reads the live queue files *and the archive subdirectory*, ignoring
watermarks entirely.  This is a question about history, not about what
is pending, and it is the only kind of question for which the archive
must be read.

`claude-code-ide-org--queue-events' cannot answer it, even with
INCLUDE-CONSUMED: it enumerates sessions via
`claude-code-ide-org--queue-session-ids', which calls `directory-files'
on the queue directory *non-recursively*, so an archived session simply
does not exist as far as it is concerned.  Measured 2026-08-18: 11 live
files against 7 archived, and the recompute in
`claude-code-ide-org-recompute-accumulated-clock-lines' saw 41 drawers
to rewrite through that path against 44 through this one.

The three it missed are the failure this whole function exists to
prevent, and they are worse than they sound: archiving happens to the
*oldest* sessions first, so the events it hides are precisely the ones
backing the oldest CLOCK lines.  A recompute reading only live queues
would find no evidence for them and shrink or zero them -- silently,
plausibly, and in the direction that looks like the correction working."
  (let ((dirs (list claude-code-ide-org-queue-directory
                    (expand-file-name "archive" claude-code-ide-org-queue-directory)))
        events)
    (dolist (dir dirs)
      (when (file-directory-p dir)
        (dolist (file (directory-files dir t "\\.jsonl\\'" t))
          (when (file-readable-p file)
            (dolist (line (split-string
                           (with-temp-buffer (insert-file-contents file) (buffer-string))
                           "\n" t))
              (let ((event (claude-code-ide-org--queue-parse-line line)))
                (when (and event
                           (claude-code-ide-org--review-guidepost-p event)
                           (not (plist-get event :agent-id)))
                  (push event events))))))))
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

(defun claude-code-ide-org--aggregate-guideposts (events &optional threshold
                                                          exclusions)
  "Collapse EVENTS' timestamps into (START . END) spans for review.

EXCLUSIONS is a list of (START . END) intervals treated exactly like a
permission block: a timestamp strictly inside one is dropped, and one
lying wholly between two timestamps splits the span rather than being
clustered through.  Permission blocks are found in EVENTS themselves;
EXCLUSIONS is for intervals whose evidence is somewhere else, which
today means the `clock_in'/`clock_out' brackets that already have an
owner (TODO.org :ID: eaeeb4ee).  Without it an unattributed span
clusters straight across the brackets that partition it and the same
minutes are offered twice.
Consecutive timestamps separated by less than THRESHOLD seconds (default
`claude-code-ide-org-guidepost-gap-threshold') join one span; a larger
gap starts a new one. A lone timestamp yields a zero-width span, which
is honest -- one interaction point is not evidence of a duration.

These spans are review scaffolding only. They inform the human's
composition of CLOCK: entries, and nothing here rounds.

They are rendered as *inactive* timestamps, and the claim that they were
active -- and so reached org's agenda (TODO.org :ID: c084553c) -- stood
here until 2026-08-18 having been falsified in the file itself: it is
`claude-code-ide-org--review-format-annotation' that renders a span, and
it dropped the active branch outright when :ID: b8e6007a established
that the queue records *agent* activity, which the agenda must not
absorb.  Corrected rather than deleted, because the stale sentence read
as a settled decision about the agenda and would have outlived anyone
noticing.

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
         (blocks (append (claude-code-ide-org--block-intervals events)
                         exclusions))
         ;; A guidepost inside a permission block is not evidence of
         ;; work: the agent was stalled waiting on a human for the whole
         ;; of it. Dropping those timestamps is what splits the span,
         ;; and it is decided here rather than offered at review because
         ;; a block is not ambiguous the way a commit-less gap is -- it
         ;; is a mechanically certain fact that nothing was running.
         ;; (TS . KIND) rather than bare timestamps: the gap between two
         ;; guideposts means opposite things depending on which kinds
         ;; bracket it, and the old code discarded `:kind' here -- which is
         ;; how a long turn came to be unmeasurable (TODO.org :ID: 226ed53b).
         (points (sort (mapcar (lambda (e) (cons (plist-get e :ts)
                                                 (plist-get e :kind)))
                               (seq-remove
                                (lambda (e)
                                  (and blocks
                                       (claude-code-ide-org--time-within-any-p
                                        (plist-get e :ts) blocks)))
                                events))
                       (lambda (a b) (time-less-p (car a) (car b)))))
         spans start previous previous-kind)
    (dolist (point points)
      (let ((time (car point)) (kind (cdr point)))
        (cond
         ((null start) (setq start time previous time previous-kind kind))
         ;; A block between two timestamps breaks the span even when the
         ;; two are closer together than the gap threshold -- otherwise a
         ;; 54-minute wait bracketed by guideposts a minute apart on each
         ;; side would be clustered straight through.
         ((and (or (<= (float-time (time-subtract time previous)) gap)
                   ;; A `resume' -> `pause' gap is a turn *running*, not a
                   ;; pause between turns, so it never splits however long
                   ;; it is. This is the whole fix: guideposts mark turn
                   ;; boundaries, so a single long turn emits only its own
                   ;; two, and the threshold -- derived from `pause' ->
                   ;; `resume' latency (:ID: 96a51c2f) -- would otherwise
                   ;; read the strongest evidence of continuous work as
                   ;; absence, collapsing the turn to two zero-width spans.
                   ;;
                   ;; Gated on the *adjacency kinds*, deliberately, not on
                   ;; pairing a resume to "its" pause: with `resume,
                   ;; resume, pause' there is no non-arbitrary matching,
                   ;; and pairing would produce overlapping intervals. A
                   ;; missing `:kind' fails this test and so stays
                   ;; splittable, which is what the bare-`:ts' fixture in
                   ;; config-test.el expects.
                   (and (equal previous-kind "resume") (equal kind "pause")))
               ;; Non-strict on both sides: the two timestamps either side
               ;; of a block are normally the block's own endpoints -- a
               ;; `block_start' is the last event before the wait and a
               ;; `block_end' the first after it, since no guidepost fires
               ;; while a turn is stalled. A strict test therefore never
               ;; fires in the case this exists for. Left outside the kind
               ;; gate: a block is a certain fact about nothing running,
               ;; and outranks the adjacency.
               (not (seq-find (lambda (iv)
                                (and (not (time-less-p (car iv) previous))
                                     (not (time-less-p time (cdr iv)))))
                              blocks)))
          (setq previous time previous-kind kind))
         (t (push (cons start previous) spans)
            (setq start time previous time previous-kind kind)))))
    (when start (push (cons start previous) spans))
    (nreverse spans)))

(defconst claude-code-ide-org--run-opening-kinds
  '("resume" "clock_in" "block_end")
  "Event kinds at which the agent *starts* running.

`resume' is the original member and the only one for a long time: a
`UserPromptSubmit' wakes the agent.  The other two were added 2026-08-22
with TODO.org :ID: eaeeb4ee, and both mark the same physical fact.

A `clock_in' is the agent declaring it has begun work on a named
heading, which is a stronger statement than a guidepost makes -- the
guidepost says a turn started, the `clock_in' says what it started on.
A `block_end' is the moment a permission prompt was answered and the
tool finally ran.

Kept as data rather than folded into
`claude-code-ide-org--span-work-runs' because
`claude-code-ide-org--span-kinds-known-p' has to ask the same question
about the same set, and the two drifting apart would silently disable
run-splitting for exactly the events the other half had just learned to
read.")

(defconst claude-code-ide-org--run-closing-kinds
  '("pause" "clock_out" "block_start")
  "Event kinds at which the agent *stops* running.

The mirror of `claude-code-ide-org--run-opening-kinds': `pause' is a
`Stop', `clock_out' is the agent declaring the work finished, and
`block_start' is the instant a permission prompt appeared and the turn
stalled.

`block_start' is what makes a permission wait subtract rather than
count.  Note that it is a *closer* while `block_end' is an opener, which
reads backwards until you hold it the right way round: the block is the
hole, so the run ends where the block begins.")

(defun claude-code-ide-org--run-boundary-kind (kind)
  "Return `open' or `close' for KIND, or nil when it is neither.

Normalising to two symbols is what lets one adjacency rule serve three
kinds of evidence -- turn guideposts, explicit clock brackets, and
permission blocks -- instead of three near-copies of it."
  (cond ((member kind claude-code-ide-org--run-opening-kinds) 'open)
        ((member kind claude-code-ide-org--run-closing-kinds) 'close)))

(defun claude-code-ide-org--span-kinds-known-p (events)
  "Non-nil when EVENTS carry the `:kind' that run-splitting reads.

The split is a statement about which adjacencies were work, so it is
only makeable when the adjacencies are labelled.  Real guideposts always
are -- `claude-code-ide-org--review-guidepost-p' admits an event only by
its kind -- but an item assembled by hand (a fixture, a caller
constructing a plist) may carry `:ts' alone, and for those the honest
answer is \"cannot tell\", which apply turns back into the single
whole-span line it wrote before this existed."
  (and (seq-find (lambda (e)
                   (claude-code-ide-org--run-boundary-kind
                    (plist-get e :kind)))
                 events)
       t))

(defun claude-code-ide-org--span-work-runs (events &optional floor)
  "Return the runs of work inside EVENTS as a list of (START . END).

A run is a `resume' -> `pause' adjacency: the agent was running from the
prompt that woke it until the turn ended.  Everything else between two
guideposts is the human thinking, and used to be recorded as work
because a span was written end to end -- 39.10 h against 21.59 h of
actual turn time over the post-cutover corpus, a ~45% overcount
\(TODO.org :ID: 226ed53b).

Runs separated by less than FLOOR seconds (default
`claude-code-ide-org-span-idle-floor') are merged, absorbing that idle
rather than writing two lines around it.  Strictly less, so a gap of
exactly FLOOR splits.

Three deliberate silences, each of which looks like a bug from the
outside:

- A `resume' -> `resume' adjacency contributes nothing.  Work almost
  certainly happened across it -- two `UserPromptSubmit' with no `Stop'
  between them is what an interrupt or a queued follow-up looks like --
  but there is no non-arbitrary way to pair those resumes, and inventing
  an endpoint is exactly what this change exists to stop.  There are 9
  such adjacencies in the corpus and they are TODO.org :ID: 09c134c4's
  question, not this function's.
- A run whose *rendered* endpoints are the same minute is dropped.  Org
  timestamps are minute-precision, so such a run writes `=>  0:00' --
  \"an interval that was never observed\", which
  `claude-code-ide-org--review-apply-clock' already refuses.  The floor
  alone does not prevent this: a sub-minute turn isolated by more than
  FLOOR of idle on both sides survives the merge as its own run.  55 of
  412 turn-pairs in the corpus render inside one minute.  That is a
  narrower set than \"under a minute\", which is 128 -- 09:00:50 to
  09:01:10 is 20 seconds and still renders 0:01 -- and the rendered
  count is the one that matters, since rendering is what decides.
- EVENTS with no usable adjacency yield nil, and the caller writes an
  annotation with no CLOCK line -- the same answer a zero-width span has
  always got, for the same reason.

Pure, and takes EVENTS rather than an item, so apply, the review
buffer's \"writes N\" summary and the corpus measurement all read one
implementation.  Sorts defensively: callers hand it a span's `:events',
which are filtered from an already-sorted list, but nothing in the type
says so."
  (let ((points (sort (mapcar (lambda (e)
                                (cons (plist-get e :ts)
                                      (claude-code-ide-org--run-boundary-kind
                                       (plist-get e :kind))))
                              events)
                      (lambda (a b) (time-less-p (car a) (car b)))))
        runs previous)
    (dolist (point points)
      (when (and previous
                 (eq (cdr previous) 'open)
                 (eq (cdr point) 'close))
        (push (cons (car previous) (car point)) runs))
      (setq previous point))
    ;; The blocks come from EVENTS themselves, so a caller that hands
    ;; over a bracket's events gets the wait subtracted without having
    ;; to know it was there.  Harmless where there are none: the
    ;; barrier list is empty and the floor behaves exactly as before.
    (claude-code-ide-org--apply-idle-floor
     (nreverse runs) floor (claude-code-ide-org--block-intervals events))))

(defun claude-code-ide-org--renders-as-nothing-p (interval fmt)
  "Non-nil when INTERVAL would write a CLOCK line saying nothing.

Two conditions, and neither implies the other -- which is why they are
named here once and used twice, to promote and to drop, instead of
being spelled out at each site and drifting apart.

An interval of 50 seconds inside one minute renders `[09:00]--[09:00]\'
but rounds to `=>  0:01\'; one of 20 seconds across a minute boundary
renders `[08:14]--[08:15]\' but rounds to `=>  0:00\'.  Testing only the
endpoints was the first version of the drop, and it wrote nine `0:00\'
lines into the real org files during the 507754ba recompute.  Testing
only the duration was the first version of the *promotion* and left a
34-second run to be dropped while promoting an 11-second one."
  (or (equal (format-time-string fmt (car interval))
             (format-time-string fmt (cdr interval)))
      (zerop (round (/ (float-time (time-subtract (cdr interval) (car interval)))
                       60)))))

(defun claude-code-ide-org--apply-idle-floor (intervals &optional floor barriers)
  "Merge INTERVALS separated by less than FLOOR, then drop rendered zeros.

BARRIERS is a list of (START . END) intervals across which two runs are
never merged however small the gap.  It exists for permission blocks
(TODO.org :ID: eaeeb4ee): the floor absorbs idle on the theory that a
short gap between turns is not worth a second CLOCK line, but a block is
a mechanically certain fact that nothing was running, and the measured
case is 1m51s -- comfortably under the default floor, so without this
the two sides of a permission wait merge straight back together and the
wait is credited as work.  The gap rule and the barrier rule disagree
only inside FLOOR, which is precisely where a block needs to win.

The shared tail of every path that turns raw guidepost intervals into
CLOCK lines -- `claude-code-ide-org--span-work-runs' for what apply
writes, and `claude-code-ide-org--recompute-logbook-text' for correcting
what was already written.  Extracted so the two cannot drift: a record
corrected by one and extended by the other would otherwise be
inconsistent with itself, fragmenting old spans more finely than new
ones simply because different code wrote them.

FLOOR defaults to `claude-code-ide-org-span-idle-floor'.  Strictly less
than, so a gap of exactly FLOOR splits.

An interval is then dropped when it would write `=>  0:00' -- \"an
interval that was never observed\" -- or when its *rendered* endpoints
share a minute.  The floor alone prevents neither: a sub-minute turn
isolated by more than FLOOR survives the merge, and closing an unmatched
turn at its window bound can produce a zero-width interval outright.

*Both conditions are needed, and neither implies the other.*  An
interval of 50 seconds inside one minute renders `[09:00]--[09:00]' but
rounds to `=>  0:01'; one of 20 seconds across a minute boundary renders
`[08:14]--[08:15]' but rounds to `=>  0:00'.  Testing only the endpoints
was the first version, and it wrote nine `0:00' lines into the real
files during the 507754ba recompute before the diff was read.

A third condition, `claude-code-ide-org-span-minimum-interval', drops
anything shorter than a set duration.  It defaults to 0 and so does
nothing until someone sets it; the two rendering conditions above are
what actually hold the line today.  Named separately because they are
different kinds of rule -- those two fall out of the clock format, that
one is a choice about what is worth recording."
  (let ((floor (or floor claude-code-ide-org-span-idle-floor))
        (fmt "[%Y-%m-%d %a %H:%M]")
        merged)
    (dolist (interval (sort (copy-sequence intervals)
                            (lambda (a b) (time-less-p (car a) (car b)))))
      (let ((last (car merged)))
        (if (and last
                 (< (float-time (time-subtract (car interval) (cdr last))) floor)
                 (not (seq-find (lambda (b)
                                  (and (not (time-less-p (car b) (cdr last)))
                                       (not (time-less-p (car interval) (cdr b)))))
                                barriers)))
            (when (time-less-p (cdr last) (cdr interval))
              (setcdr last (cdr interval)))
          (push (cons (car interval) (cdr interval)) merged))))
    ;; Promote before dropping, and the order is the whole point. A run
    ;; with a *positive* duration was observed: 28 seconds of agent time
    ;; is work that happened, and org's minute-precision timestamps are
    ;; the only reason it renders `=>  0:00'. Extending its end to one
    ;; minute records the observation at the coarsest granularity the
    ;; format can carry, which is a rounding error; discarding it is a
    ;; false statement that nothing happened, which is the erasure :ID:
    ;; 293ac49e was filed against.
    ;;
    ;; A run of *zero* width is left alone and falls through to be
    ;; dropped below. Nothing was observed there -- it is a lone
    ;; guidepost with nothing to bracket it -- and promoting it would
    ;; invent a minute of work out of a single timestamp, which is
    ;; exactly the class of guess :ID: 7771fc63 retired.
    ;;
    ;; Instituted 2026-08-24 at the user's request, after they edited a
    ;; number of 0-minute spans up to 1 minute by hand at review. Doing
    ;; it here rather than at review means the floor applies to every
    ;; path that writes a CLOCK line, and nobody has to remember it.
    ;; The trigger must mirror *both* rendering conditions below, not
    ;; one. A 34-second run rounds to `0:01' -- `round' goes to nearest,
    ;; so 34/60 is 1, not 0 -- and would survive the duration test while
    ;; still being dropped for rendering `[11:17]--[11:17]'. Testing
    ;; only the duration promoted an 11-second run and silently left a
    ;; 34-second one to be discarded, which is the exact shape of bug
    ;; the two-condition drop was written for in the first place.
    (setq merged
          (mapcar (lambda (iv)
                    (if (and (time-less-p (car iv) (cdr iv))
                             (claude-code-ide-org--renders-as-nothing-p iv fmt))
                        (cons (car iv) (time-add (car iv) 60))
                      iv))
                  merged))
    (seq-remove (lambda (iv)
                  (or (claude-code-ide-org--renders-as-nothing-p iv fmt)
                      (< (float-time (time-subtract (cdr iv) (car iv)))
                         claude-code-ide-org-span-minimum-interval)))
                (nreverse merged))))

(defun claude-code-ide-org--busy-intervals (events &optional bound)
  "Return the union of intervals in which ANY turn was running, over EVENTS.

A *depth counter*, not per-session pairing: `resume' increments,
`pause' decrements, and the agent counts as busy while the depth is
above zero.  Returns ascending, disjoint (START . END) conses.

This is the union rule (TODO.org :ID: 7d739afd) rather than a sum, and
the counter is what makes it free.  Two sessions working 10:00-10:20 and
10:10-10:30 are one 30-minute stretch of elapsed busy time, not 40
minutes; the depth goes 1, 2, 1, 0 and closes exactly once.

It also repairs a failure that per-session pairing cannot (TODO.org
:ID: 9202b39d).  A background job's first turn has its `resume' in the
launching session's queue file and its `pause' in the job's, so pairing
within a session loses the turn outright -- measured at 37 minutes on a
single CLOCK line, which then \"corrected\" to 0:00 with nothing to
flag it.  The counter never asks which file an event came from, so the
pair survives.

Two asymmetries are deliberate:

- *Depth clamps at zero* rather than going negative.  A stream can
  legitimately open on a `pause' whose `resume' belongs to another
  session, which is exactly the background-job case above; without the
  clamp a later `resume' would be swallowed bringing depth back to
  zero.
- *An interval still open at the end closes at BOUND*, or is dropped if
  BOUND is nil.  An unmatched `resume' means a turn that had not ended
  when the record was taken; running it to the last event would invent
  an endpoint, and running it forever is worse.  Callers working inside
  a known window pass that window's end.

Contrast `claude-code-ide-org--span-work-runs', which pairs adjacencies
and answers \"what should apply write for this one span\".  This answers
\"when was anything running at all\", and only the second question has a
sensible answer across sessions."
  (let ((points (sort (mapcar (lambda (e) (cons (plist-get e :ts) (plist-get e :kind)))
                              events)
                      (lambda (a b) (time-less-p (car a) (car b)))))
        (depth 0) open intervals)
    (dolist (point points)
      (if (equal (cdr point) "resume")
          (progn (when (zerop depth) (setq open (car point)))
                 (setq depth (1+ depth)))
        (setq depth (max 0 (1- depth)))
        (when (and (zerop depth) open)
          (push (cons open (car point)) intervals)
          (setq open nil))))
    (when (and open bound) (push (cons open bound) intervals))
    (nreverse intervals)))

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

(defun claude-code-ide-org--span-events (events agent &optional session)
  "Return EVENTS belonging to lane AGENT that bear on a span's shape.

Guideposts *and* permission-block markers.  The block markers are the
2026-08-22 correction (TODO.org :ID: eaeeb4ee): every caller used to
filter with `claude-code-ide-org--review-guidepost-p' alone, which
admits `pause' and `resume' and nothing else, so the block events were
gone before `claude-code-ide-org--aggregate-guideposts' looked for them
and `claude-code-ide-org--block-intervals' returned nil on every real
call.  The permission-block feature (:ID: f4e628ce) was therefore inert
in production for as long as it had existed, while its tests passed --
they hand the block events straight to `--aggregate-guideposts' and so
never crossed the filter that was dropping them.

AGENT selects the lane: nil means the main session, which is the only
lane whose events carry no `agent_id'.  SESSION, when given, additionally
restricts to one session's file -- required whenever EVENTS spans more
than one, since every main lane shares a nil `agent_id' and would
otherwise pool."
  (seq-filter (lambda (e)
                (and (or (claude-code-ide-org--review-guidepost-p e)
                         (member (plist-get e :kind)
                                 '("block_start" "block_end")))
                     (equal (plist-get e :agent-id) agent)
                     (or (null session)
                         (equal (plist-get e :session-id) session))))
              events))

(defun claude-code-ide-org--events-within (events start end agent &optional session)
  "Return lane AGENT/SESSION's span events from EVENTS inside START..END.

Strictly inside: the bracket's own endpoints are supplied by the caller,
and a guidepost landing exactly on one would double the boundary."
  (seq-filter (lambda (e)
                (let ((ts (plist-get e :ts)))
                  (and (time-less-p start ts) (time-less-p ts end))))
              (claude-code-ide-org--span-events events agent session)))

(defun claude-code-ide-org--lane-clock-pairs (events)
  "Pair EVENTS' `clock_in'/`clock_out' per lane, oldest first.

Returns a list of (OPEN CLOSE) event pairs.  A lane is `agent_id' when
the event came from a subagent and the main session otherwise -- the
same partition `claude-code-ide-org--queue-events-by-id' uses, and for
the same reason: subagents share their parent's `session_id', so a
single `open' variable would let concurrent agents close each other's
brackets (TODO.org :ID: 0d789b68).

An unmatched `clock_in' yields no pair and is deliberately left
unconsumed.  It is the lane's anchor for work that is still running, and
inventing an end for it is the class of guess :ID: 7771fc63 retired.  A
`clock_out' with no open `clock_in' is likewise dropped rather than
extended backwards."
  (let ((lanes (make-hash-table :test 'equal))
        pairs)
    (dolist (event (sort (seq-filter
                          (lambda (e)
                            (member (plist-get e :kind)
                                    '("clock_in" "clock_out")))
                          (copy-sequence events))
                         (lambda (a b)
                           (time-less-p (plist-get a :ts) (plist-get b :ts)))))
      ;; The session is part of the lane key, not just the agent. Two
      ;; sessions' main lanes both carry a nil `agent_id', so keying on
      ;; the agent alone lets one session's `clock_out' close another's
      ;; bracket -- which only shows up once this function is run over
      ;; the full multi-session history, as the subdivision path below
      ;; must.
      (let ((lane (cons (plist-get event :session-id)
                        (or (plist-get event :agent-id) :main))))
        (if (equal (plist-get event :kind) "clock_in")
            (puthash lane event lanes)
          (let ((open (gethash lane lanes)))
            (when open
              (push (list open event) pairs)
              (remhash lane lanes))))))
    (nreverse pairs)))

(defun claude-code-ide-org--lane-clock-intervals (events &optional agent)
  "Return (START . END) intervals for EVENTS' clock brackets.

With AGENT non-nil, only that lane's; with AGENT nil, only the main
session's.  Pass `all' for every lane regardless.

These are the intervals that already have an owner, which is what makes
them subtractable: anything inside one is accounted for by the bracket's
own review item, so a span clustered over the same minutes would offer
them a second time."
  (delq nil
        (mapcar (lambda (pair)
                  (let ((open (nth 0 pair)))
                    (when (or (eq agent 'all)
                              (equal (plist-get open :agent-id) agent))
                      (cons (plist-get open :ts)
                            (plist-get (nth 1 pair) :ts)))))
                (claude-code-ide-org--lane-clock-pairs events))))

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
  (let* ((history (claude-code-ide-org--queue-events session-id t))
         ;; Hoisted out of the per-group loop 2026-08-24. Computed
         ;; inside it, this ran once per heading -- 53 groups against
         ;; ~250 events, each call re-filtering and re-sorting the whole
         ;; history. The answer does not vary by group, so it was
         ;; O(groups x history) for a constant.
         (main-brackets (claude-code-ide-org--lane-clock-intervals history nil))
         (all-brackets (claude-code-ide-org--lane-clock-intervals history 'all))
         items)
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
          ;; Explicit brackets: pair each lane's own clock_in/clock_out.
          ;;
          ;; Every lane, including the main session's -- and that `every'
          ;; is the 2026-08-22 fix (TODO.org :ID: eaeeb4ee). This loop
          ;; used to require an `agent_id', on the reasoning that a main
          ;; -lane bracket may span human idle and so must have its
          ;; duration reconstructed from guideposts rather than taken
          ;; whole. The reasoning is sound and is kept below; requiring
          ;; the agent_id *here* was the wrong place to enforce it,
          ;; because guideposts are turn boundaries and a bracket opened
          ;; and closed inside one turn contains none. Measured on the
          ;; 2026-08-21 queue: four headings clocked across fifteen
          ;; minutes with no `pause' or `resume' anywhere between the
          ;; first clock_in and the last clock_out, producing no review
          ;; item at all, while an hour of their work was offered as one
          ;; unassigned span and landed on an unrelated heading.
          (dolist (pair (claude-code-ide-org--lane-clock-pairs events))
            (let* ((open (nth 0 pair))
                   (close (nth 1 pair))
                   (agent (plist-get open :agent-id))
                   (start (plist-get open :ts))
                   (end (plist-get close :ts)))
              (push (list :type 'clock :id id
                          :start start :end end
                          ;; The pair's *own* note, not the first
                          ;; clock_in note in the group. A heading
                          ;; clocked twice in a session has two notes
                          ;; describing two different pieces of work,
                          ;; and the old `(car ...)' over the whole
                          ;; group labelled both spans with the first.
                          :note (or (plist-get open :note)
                                    (plist-get close :note))
                          :agent agent
                          ;; A subagent's interval is authoritative end
                          ;; to end: it ran unattended, so there is no
                          ;; idle inside to subtract, and `:suggested'
                          ;; nil is what stops apply re-deriving runs.
                          ;;
                          ;; A main-lane bracket is authoritative for
                          ;; *attribution* and not for duration -- the
                          ;; human may have sat inside it for an hour.
                          ;; `:suggested' t sends it through
                          ;; `--span-work-runs', which now reads the
                          ;; bracket's own endpoints as run boundaries,
                          ;; so a bracket with no guideposts inside
                          ;; yields one run covering it and a bracket
                          ;; full of them is subdivided as before.
                          :suggested (if agent nil t)
                          :origin 'bracketed
                          ;; Read from the *full* history, applied
                          ;; events included, and this is not a
                          ;; refinement -- it is what makes subdivision
                          ;; work at all. Emission stays pending-only
                          ;; (the group above is pending), but the
                          ;; guideposts that subdivide a bracket are
                          ;; usually applied long before the bracket
                          ;; itself is, because a `pause'/`resume' pair
                          ;; reaches the review buffer as a span on the
                          ;; day it happens while the bracket sat
                          ;; unconsumed. Measured on the 2026-08-21
                          ;; queue: with the pending group alone the day
                          ;; node's bracket saw no guideposts inside it
                          ;; and offered 48 minutes as one unbroken run,
                          ;; against ~11 of actual turn time. Same
                          ;; lesson as `--review-suggest-heading', which
                          ;; reads the full history for the same reason.
                          :events (cons open
                                        (append
                                         (claude-code-ide-org--events-within
                                          history start end agent
                                          (plist-get open :session-id))
                                         (list close))))
                    items)))
          ;; Human spans: cluster whatever guideposts the brackets above
          ;; did not already account for. Before 2026-08-22 this was the
          ;; only path that produced a main-lane interval; it now covers
          ;; the residue, which in practice means an unmatched
          ;; `clock_in' whose work is still running and has no closing
          ;; bracket to be partitioned by.
          (let* ((covered main-brackets)
                 (guideposts (seq-remove
                              (lambda (e)
                                (claude-code-ide-org--time-within-any-p
                                 (plist-get e :ts) covered))
                              (claude-code-ide-org--span-events events nil)))
                 (label (car (delq nil
                                   (mapcar (lambda (e)
                                             (and (equal (plist-get e :kind) "clock_in")
                                                  (plist-get e :note)))
                                           events)))))
            (dolist (span (claude-code-ide-org--aggregate-guideposts
                           guideposts nil covered))
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
           ;; Every bracket in the *pending* queue, whatever heading or
           ;; lane it belongs to, is subtracted from the orphan stream.
           ;; Without this the fix above mints the double-count it is
           ;; meant to remove: on 2026-08-21 the `resume' at 13:07:10 and
           ;; the `pause' at 13:24:41 are both orphans -- the lane is
           ;; empty at both moments -- and they are *adjacent* in the
           ;; orphan stream, because everything between them is bracketed
           ;; and so attributed elsewhere. A `resume' -> `pause'
           ;; adjacency never splits however long the gap, so the span
           ;; would straddle all four brackets by construction and offer
           ;; their fifteen minutes a second time.
           (bracketed all-brackets)
           (guideposts (claude-code-ide-org--span-events orphans nil)))
      (dolist (span (claude-code-ide-org--aggregate-guideposts
                     guideposts nil bracketed))
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
divides them into \"being worked\" and everything else, and WAITING, TODO
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
from correction.  See TODO.org :ID: 3d0487f4.

A *container* is never the answer, however active it looks (TODO.org
:ID: 62c6b1be).  Being in DOING is a true and unremarkable statement
about a container -- `claude-code-ide-org--attention-headings-context'
already excludes them from the session-start report on exactly that
ground -- and its plausibility therefore never expires: it stays true
for as long as any child is open, so it wins every span in between.
Measured 2026-08-21, four spans totalling 24 minutes were assigned to
one `[0/1]' container that no session had worked on for a day.  On the
same date all three DOING headings in TODO.org were containers, so
every answer this function could return was wrong by construction."
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
    ;; Resolved once, at the end, rather than per event: the loop runs
    ;; over every queued `todo' and this reads a file.
    (unless (claude-code-ide-org--grouping-id-p active)
      active)))

(defun claude-code-ide-org--grouping-id-p (id)
  "Non-nil when ID resolves to a grouping heading -- a container or a
slice (`claude-code-ide-org--grouping-heading-p').

Renamed from `--container-id-p' 2026-08-26 (TODO.org :ID: 95c27fca)
along with the question it asks: a slice is no more suggestible as the
owner of an unassigned span than a container is, and for the same
reason -- the time belongs to a member.

Resolves through `org-id-find' the way
`claude-code-ide-org--review-heading-title' does, and releases the
marker the same way.  Nil for an ID that resolves to nothing: an
unresolvable id is not a container, and answering t would suppress a
suggestion on the strength of a lookup failure."
  (when id
    (let ((marker (ignore-errors (claude-code-ide-org--id-find id 'marker))))
      (when marker
        (prog1 (org-with-point-at marker
                 (claude-code-ide-org--grouping-heading-p))
          (set-marker marker nil))))))

(defun claude-code-ide-org--review-current-state (id)
  "Return the TODO keyword heading ID holds right now, or nil.
Resolves by :ID: through `org-id-find', the same property search every
other read here uses.  Returns the symbol `unresolved' -- distinct from
nil, which is a real answer meaning \"no keyword\" -- when the :ID:
names nothing, so a caller can tell \"heading has no keyword\" from
\"heading is gone\"."
  (let ((marker (ignore-errors (claude-code-ide-org--id-find id 'marker))))
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

(defun claude-code-ide-org--review-format-annotation (item &optional start end)
  "Return the :LOGBOOK: annotation line for ITEM.

START and END override ITEM's own endpoints, which is how apply labels
each of the several CLOCK lines a span can now write: one annotation per
line, at that line's endpoints, rather than one envelope annotation the
lines under it do not match.  That keeps the pairing
`claude-code-ide-org--consolidate-logbook-text' depends on -- it sorts
every drawer entry by its first timestamp, and a CLOCK line and the
annotation describing it stay adjacent only because they share one.
Omit both and the item's own `:start'/`:end' are used, which is what the
review buffer wants: it is describing the span, not a line.

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
  (let* ((fmt (if (plist-get item :active)
                  "<%Y-%m-%d %a %H:%M>"
                "[%Y-%m-%d %a %H:%M]"))
         (note (claude-code-ide-org--review-annotation-label item)))
    (format "- %s--%s%s"
            (format-time-string fmt (or start (plist-get item :start)))
            (format-time-string fmt (or end (plist-get item :end)))
            (if (and note (not (string-empty-p note))) (concat " " note) ""))))

(defun claude-code-ide-org--review-intervals-to-write (item)
  "Return the (START . END) intervals apply will write for ITEM.

One interval per run of work when ITEM is a *suggestion* whose backing
events are labelled, and otherwise the single interval ITEM displays.

The `:suggested' condition is the load-bearing half, not a performance
guard.  `claude-code-ide-org-review-edit-interval' sets `:suggested' nil
precisely to record that a human drew these endpoints, and apply's
standing claim is that it writes exactly the endpoints the human
confirmed.  Re-deriving runs from the events under a confirmed interval
would throw those endpoints away and substitute the reconstruction the
human had just corrected -- the one case where this feature would make
the record less true rather than more.  The same clause is what keeps a
subagent's own paired `clock_in'/`clock_out' intact: that interval is
authoritative, and has no guideposts inside it to run-split anyway."
  (if (and (plist-get item :suggested)
           (claude-code-ide-org--span-kinds-known-p (plist-get item :events)))
      (claude-code-ide-org--span-work-runs (plist-get item :events))
    (list (cons (plist-get item :start) (plist-get item :end)))))

(defun claude-code-ide-org--recorded-intervals-at-point ()
  "Return the closed CLOCK intervals already in this heading's :LOGBOOK:.

Ascending (START . END) conses.  An *open* CLOCK line is ignored: it has
no end, so nothing can be subtracted from it, and it belongs to a clock
still running rather than to history."
  (let ((bounds (claude-code-ide-org--drawer-content-bounds "LOGBOOK"))
        intervals)
    (when bounds
      (dolist (line (split-string
                     (buffer-substring-no-properties (nth 0 bounds) (nth 1 bounds))
                     "\n"))
        (when (string-match claude-code-ide-org--clock-line-regexp line)
          ;; Both groups read before parsing: `--parse-org-timestamp'
          ;; runs its own `string-match' and clobbers the match data.
          (let* ((g1 (match-string 1 line))
                 (g2 (match-string 2 line))
                 (s (claude-code-ide-org--parse-org-timestamp (concat "[" g1 "]")))
                 (e (claude-code-ide-org--parse-org-timestamp (concat "[" g2 "]"))))
            (when (and s e) (push (cons s e) intervals))))))
    (sort (nreverse intervals) (lambda (a b) (time-less-p (car a) (car b))))))

(defun claude-code-ide-org--subtract-intervals (runs recorded)
  "Return RUNS with every part already covered by RECORDED removed.

The union rule (TODO.org :ID: 7d739afd) applied one level up: there it
was two agent sessions overlapping, here it is the agent's reconstructed
span against a CLOCK line the human wrote by hand.  Both are true at
once -- the human was attending and the agent was running -- but org
sums every CLOCK line in a drawer identically, so writing both makes
every clocktable overcount by the overlap.

Subtracting rather than skipping the whole run is deliberate.  Skipping
would discard real agent time that falls *outside* the human's interval,
which is the undercount the same union rule rejects in the other
direction.  A run straddling a recorded interval therefore comes back as
two pieces, which is what actually happened.

This also subsumes the exact-match idempotency that
`claude-code-ide-org--logbook-has-interval-p' used to provide: a replay
finds its own previously written line in RECORDED, subtracts to nothing,
and writes nothing.  Generalised rather than removed -- the old check
could only recognise an interval it had written verbatim, and a
re-derived run whose endpoints moved by a second slipped straight past
it."
  (let (out)
    (dolist (run runs)
      (let ((pieces (list run)))
        (dolist (rec recorded)
          (setq pieces
                (apply #'append
                       (mapcar
                        (lambda (p)
                          (cond
                           ;; Disjoint: untouched.
                           ((or (not (time-less-p (car rec) (cdr p)))
                                (not (time-less-p (car p) (cdr rec))))
                            (list p))
                           ;; Otherwise keep whatever lies outside REC.
                           (t (append
                               (when (time-less-p (car p) (car rec))
                                 (list (cons (car p) (car rec))))
                               (when (time-less-p (cdr rec) (cdr p))
                                 (list (cons (cdr rec) (cdr p))))))))
                        pieces))))
        (setq out
              (append out
                      (if (equal pieces (list run))
                          ;; Untouched: pass through exactly. A run that
                          ;; overlapped nothing must reach the writer as
                          ;; it was -- including a zero-width one, which
                          ;; the writer annotates without a CLOCK line.
                          ;; Filtering here instead swallowed that
                          ;; annotation.
                          pieces
                        ;; Cut: drop any remnant too short to render.
                        ;; Floor 0 so the pieces are never merged back
                        ;; across the hole just cut, which would undo the
                        ;; subtraction; this call is only here for the
                        ;; rendered-zero half of that function.
                        (claude-code-ide-org--apply-idle-floor pieces 0))))))
    out))

(defun claude-code-ide-org--review-apply-clock (item)
  "Write ITEM's CLOCK: intervals and their :LOGBOOK: annotations at point.
Uses raw `org-clock-in'/`org-clock-out' with both endpoints supplied up
front, never the consolidating wrapper, and binds
`org-clock-out-remove-zero-time-clocks' nil so a short confirmed
interval survives. Each pair is written back to back so no clock is ever
left open across a state change -- `claude-code-ide-org--blocker-clock-
running-p' would refuse a -> DONE transition if one were.

*One line per run of work, not one per span* (TODO.org :ID: 226ed53b).
A span is a cluster of guideposts and includes the human's thinking
between turns; writing it end to end recorded that thinking as work, and
over the post-cutover corpus that was 39.10 h recorded against 21.59 h
of turns.  `claude-code-ide-org--review-intervals-to-write' decides what
comes out, and it declines to split anything a human confirmed.

An item with no run to write still gets its annotation.  That is the
zero-width case generalised rather than a new rule: the guideposts are
real evidence that something happened, and the absent CLOCK line is the
same refusal to claim a duration nobody observed."
  (let* ((start (plist-get item :start))
         (end (plist-get item :end))
         (observed (claude-code-ide-org--review-intervals-to-write item))
         (runs (claude-code-ide-org--subtract-intervals
                observed
                (claude-code-ide-org--recorded-intervals-at-point))))
    (dolist (run runs)
      (claude-code-ide-org--review-write-one-interval item (car run) (cdr run)))
    ;; Nothing observed at all means no CLOCK line, so the span would
    ;; vanish from the drawer entirely -- the evidence would be silently
    ;; dropped rather than deliberately not-claimed, so it is annotated.
    ;;
    ;; Gated on OBSERVED rather than RUNS, and the difference is the
    ;; whole of a replay: a second apply observes the same runs and
    ;; subtracts every one of them as already recorded. Keyed on RUNS
    ;; that case would write an envelope annotation spanning the lot,
    ;; which is a line no first pass ever writes -- caught by the
    ;; per-run idempotency test finding three annotations where it
    ;; expected two.
    (unless observed
      (claude-code-ide-org--append-to-drawer
       "LOGBOOK" (claude-code-ide-org--review-format-annotation item start end)))))

(defun claude-code-ide-org--review-write-one-interval (item start end)
  "Write one CLOCK: line for START--END plus ITEM's annotation, at point."
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
  ;; Content-based idempotency moved to the caller, as interval
  ;; subtraction: a replay finds its own previously written line among
  ;; the recorded intervals and subtracts to nothing (TODO.org :ID:
  ;; 78f485a8). That matters because partial failure is NORMAL here --
  ;; the `unwind-protect' below cancels mid-item, so a retry is the
  ;; expected case rather than the exotic one, and it must land only the
  ;; runs that did not.
  (unless (time-equal-p start end)
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
            (when (org-clocking-p) (org-clock-cancel)))))))
  ;; One annotation per line, at that line's endpoints. Its own
  ;; exact-line idempotency (`--append-to-drawer') therefore keys on the
  ;; same interval the CLOCK line does, so a replay skips both together
  ;; rather than skipping one and duplicating the other.
  (claude-code-ide-org--append-to-drawer
   "LOGBOOK" (claude-code-ide-org--review-format-annotation item start end)))

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

(defun claude-code-ide-org--resolve-item-target (item)
  "Return the :ID: ITEM should be applied against.

Ordinarily ITEM's own `:id'.  When that names the `:DATE_TREE:' category
instead of a heading, the meta-work day node for ITEM's own timestamp is
returned, created if it does not exist yet (TODO.org :ID: 9575e65b).

Creation is deliberately here rather than at queue time: a queued tool
changes nothing, and a node minted for a clock event the human later
dismisses would be exactly the empty-node problem the on-demand design
exists to prevent."
  (let ((id (plist-get item :id)))
    (if (claude-code-ide-org--day-node-target-p id)
        (claude-code-ide-org-resolve-day-node
         (or (plist-get item :start) (plist-get item :ts))
         'create)
      id)))

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
          ;; Apply is the one path where a read-only buffer must not
          ;; stop the write, and the reason is about *authorisation*
          ;; rather than convenience. The user sets `buffer-read-only'
          ;; to guard against their own stray keystrokes while reading a
          ;; file; pressing `x' in the review buffer is the opposite of
          ;; a stray keystroke. The guard was never meant to stand
          ;; between them and a command they just invoked.
          ;;
          ;; Hit for real 2026-08-25: a pass reported "Applied 0
          ;; item(s); 1 failed", and the failure was
          ;; `Buffer is read-only: #<buffer TODO.org>' on a day node --
          ;; caused by an assistant *correctly* restoring the flag after
          ;; borrowing it for an `org_amend'. Doing the convention right
          ;; is what broke the pass.
          ;;
          ;; Deliberately narrower than TODO.org :ID: c8a97d9d's general
          ;; proposal that every file-touching tool bind this. A tool
          ;; call arrives unannounced and there is a real argument for
          ;; letting the flag stop it; apply has no such ambiguity.
          ;;
          ;; A binding, not a `setq': the flag is restored when this
          ;; scope exits, including on a non-local exit, so a failure
          ;; part-way through cannot leave the buffer writable.
          (inhibit-read-only t)
          (claude-code-ide-org--log-source
           (or claude-code-ide-org--log-source "org_review_apply")))
      ;; A capture is the one item whose :ID: names a heading that does
      ;; not exist yet -- it is what *creates* it -- so it cannot run
      ;; inside `--at-id' the way every other kind does.
      (if (eq (plist-get item :type) 'capture)
          (claude-code-ide-org--review-apply-capture item)
      (let ((result
             (claude-code-ide-org--at-id
              ;; A category target becomes a real day node here, and
              ;; only here. Dated from the event rather than from now,
              ;; so meta-work clocked Monday and applied Friday creates
              ;; Monday's node on Friday -- the same rule
              ;; `org-archive-subtree' follows in filing by CLOSED
              ;; rather than by archive time.
              (claude-code-ide-org--resolve-item-target item)
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

(defun claude-code-ide-org--review-describe-failure (item error)
  "Return ERROR annotated with ITEM's identity, and log any backtrace.

The error string alone is what five identical `Before first headline'
messages looked like on 2026-08-24: true, useless, and indistinguishable
from each other.  Naming the item costs nothing and is the difference
between a mystery and a defect report.

The backtrace goes to *Messages* rather than into the returned string:
the return value is rendered in the review buffer, where a stack would
bury the summary, while *Messages* is where someone looks after being
told something failed."
  (let ((bt claude-code-ide-org--last-error-backtrace))
    (when (plist-get bt :backtrace)
      (message "org-review: %s on %s item %s (%s)\n%s"
               (plist-get bt :message)
               (plist-get item :type)
               (or (plist-get item :id) "(no id)")
               (format-time-string
                "%H:%M:%S" (or (plist-get item :ts) (plist-get item :start)))
               (plist-get bt :backtrace)))
    (format "%s [%s %s %s]"
            error
            (plist-get item :type)
            (let ((id (plist-get item :id)))
              (if id (claude-code-ide-org--short-id id) "unassigned"))
            (format-time-string
             "%H:%M" (or (plist-get item :ts) (plist-get item :start))))))

(defun claude-code-ide-org--review-record-applied (applied-items)
  "Record every event behind APPLIED-ITEMS as applied, per session.

Marks exactly the events that were consumed -- no more. A skipped item's
events stay pending regardless of where they sit relative to applied
ones, which is what makes applying a subset safe and makes re-applying
an already-applied item impossible.

*One stamp for the whole pass*, computed here and pushed down, because
the pass is the unit anyone will ever want to undo (TODO.org :ID:
21c91613).  Taking the time inside the per-session loop below would give
each session its own value and answer a subtly different question."
  (let ((by-session (make-hash-table :test 'equal))
        (applied-at (format-time-string "%Y-%m-%dT%H:%M:%S%z")))
    (dolist (item applied-items)
      (dolist (event (plist-get item :events))
        (push (plist-get event :ts-string)
              (gethash (plist-get event :session-id) by-session))))
    (maphash (lambda (session-id ts-strings)
               (when session-id
                 (claude-code-ide-org--queue-mark-applied
                  session-id ts-strings applied-at)))
             by-session)))

(defun claude-code-ide-org--review-settle-separation (applied-items)
  "Restore heading separation once APPLIED-ITEMS have all landed.

*Chosen over a lint rule, and the heading that asked for one is where
the reasoning belongs* (TODO.org :ID: 601c885c).  Three options were
recorded there -- an error, a warning that never escalates, or a
pre-commit hook that runs the normaliser -- and all three *report* a
condition whose repair is one idempotent command.  Eighteen warnings
telling a human to run `claude-code-ide-org-normalize-heading-separation'
is eighteen lines of noise standing in for one call.

The fourth option is available only because the same heading measured
where the drift comes from: it is *structural*, arriving every time the
queue is applied, because apply appends without the trailing lines.  A
defect produced by apply can be repaired by apply.  Nothing is left to
assert, so nothing needs a rule.

*What this does not cover*, stated so the gap is not mistaken for
completeness: `org_amend' causes the same drift and is not an apply, so
prose added between passes stays unseparated until the next one.  That
is acceptable because applies are frequent, and it is the residue to
revisit if it ever stops being true.

Deliberately after `--review-settle-slices': that one rewrites member
lines and can itself disturb separation, so normalising must see its
output rather than the other way round.  Errors are swallowed for the
same reason they are there -- bookkeeping after the work must not turn a
landed pass into a failed one."
  (when applied-items
    (condition-case err
        (claude-code-ide-org-normalize-heading-separation nil nil)
      (error (message "Heading separation after apply failed: %s"
                      (error-message-string err))))))

(defun claude-code-ide-org--review-settle-slices (applied-items)
  "Regenerate every slice once APPLIED-ITEMS have all landed.

*The third step of the ceremony that nobody invoked* (TODO.org :ID:
a0abf97d).  A slice's member lines are copies of its referents'
keywords, and apply is the only thing that changes those in bulk -- so a
slice is stale by default between passes, and silently: `bin/lint-org'
compares the `:BLOCKER:' against the checkbox list, and
`refresh-slice' regenerates both, so the two agree with each other while
disagreeing with the tree.

*After the batch, not per item*: a mid-batch refresh sees
half-applied state.  Worse here than there -- a member whose `todo'
event has not landed yet is *keywordless on disk*, which leaves its line
unrewritten AND manufactures a `:BLOCKER:' lint error naming a
keyword-less heading (:ID: 798bb7a1, observed the same day).

*Every slice, not only ones this batch touched.*  `refresh-slice' is
idempotent and there is one live slice; a touched-only variant would
need the batch to report which ids it wrote, which is machinery bought
before the distinction costs anything.

Errors are swallowed deliberately.  This is bookkeeping *after* the
work; a slice that cannot be regenerated must not turn a successful
apply into a failed one, and the staleness it leaves is the status quo
ante rather than new damage."
  (when applied-items
    (condition-case err
        (claude-code-ide-org-refresh-slice)
      (error (message "Slice refresh after apply failed: %s"
                      (error-message-string err))))))


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
it.

Settles slices and heading separation after the loop rather than per
item, so each sees the batch's finished state rather than a
half-applied intermediate one.

*A batch-scoped suppression flag stood here until 2026-08-26* (TODO.org
:ID: 62b65ad0).  It existed only to hold the sole-TODO promotion back
until the batch finished; retiring that promotion left nothing to
suppress, and the flag, its re-entrancy companion and the settle pass
that re-ran what it skipped all went with it -- 163 lines whose whole
purpose was guarding a trigger that wrote to the file on its own."
  (claude-code-ide-org--review-projected-staleness items)
  (let (applied errors)
    (progn
      (dolist (item items)
        (setq claude-code-ide-org--last-error-backtrace nil)
        (let ((error (claude-code-ide-org--review-apply-item item)))
          (if error
              ;; Name the item. A bare error string cannot say WHICH of
              ;; five failures it belongs to, and the review buffer shows
              ;; them as one run-on line -- so the human sees the same
              ;; sentence five times and learns nothing about which
              ;; heading, kind or timestamp produced it.
              (push (claude-code-ide-org--review-describe-failure item error)
                    errors)
            (push item applied)))))
    (claude-code-ide-org--review-settle-slices applied)
    (claude-code-ide-org--review-settle-separation applied)
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
             ;; Restricted to events still pending, which the
             ;; denominator also counts. An item's `:events' may include
             ;; *applied* ones since 2026-08-22 (TODO.org :ID: eaeeb4ee):
             ;; a bracket is subdivided by guideposts read from the full
             ;; history, and those are usually applied long before the
             ;; bracket is. Counting them here printed "248 of 186",
             ;; which reads as a corrupt queue rather than as the
             ;; scaffolding note it is trying to be.
             (pending (let ((h (make-hash-table :test 'equal)))
                        (dolist (e events h)
                          (puthash (cons (plist-get e :session-id)
                                         (plist-get e :ts-string))
                                   t h))))
             (backing (seq-filter
                       (lambda (e)
                         (gethash (cons (plist-get e :session-id)
                                        (plist-get e :ts-string))
                                  pending))
                       (delete-dups
                        (apply #'append
                               (mapcar (lambda (i) (plist-get i :events))
                                       items)))))
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
            ;; `--at-id' RETURNS its failure as a string rather than
            ;; signalling, so an `or' around it never falls through and the
            ;; message lands where a title belongs.  That is exactly the
            ;; defect :ID: c2132d3f fixed for the review buffer, reachable
            ;; here through the one path it did not cover: an *unassigned*
            ;; span carries `:id' nil until a human presses `a', which is
            ;; routine rather than a fault -- so this is the case that shows
            ;; up most.  Reported live as
            ;; `Error: no org heading found with :ID: "nil"' standing as a
            ;; group title (:ID: 98700ea3).
            ;;
            ;; `--review-heading-title' is used instead because it returns
            ;; *nil* when an id does not resolve, which is what makes a
            ;; `cond' able to tell the three cases apart at all.
            (let ((title (and last-id
                              (claude-code-ide-org--review-heading-title last-id))))
              ;; Branch on what the id *is*, not on whether org-id
              ;; happens to resolve it. There are four kinds, and the
              ;; last two both used to fall into "unresolvable" -- which
              ;; is true of neither (TODO.org :ID: 2b050e7a; the first
              ;; instance was :ID: 98700ea3, which fixed one branch and
              ;; left the shape).
              (push (cond
                     ((null last-id)
                      "\n(unassigned -- press `a' in the review buffer to choose a heading)")
                     (title (format "\n%s  {%s}" title last-id))
                     ;; A capture's :ID: names a heading that does not
                     ;; exist YET -- that is the whole job of a capture,
                     ;; and apply is what creates it. Calling that
                     ;; unresolvable reads as a fault in the item the
                     ;; human is about to approve.
                     ((claude-code-ide-org--pending-capture last-id)
                      (format "\n(new heading, created when this is applied)  {%s}"
                              last-id))
                     (t (format "\n(unresolvable :ID:)  {%s}" last-id)))
                    lines)))
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

\\{claude-code-ide-org-review-mode-map}"
  ;; Wrap rather than truncate, buffer-locally.
  ;;
  ;; The user had been toggling this by hand on every review buffer
  ;; (observed 2026-08-24: `truncate-lines' globally t, buffer-locally
  ;; nil in the live *org-review* buffer -- the signature of
  ;; `toggle-truncate-lines'). Every line here is prose the human has to
  ;; read to decide something -- an annotation label, a heading title, a
  ;; reason an item writes nothing -- and a truncated line hides exactly
  ;; the part that carries the decision.
  ;;
  ;; `word-wrap' is set alongside, and not merely inherited: with
  ;; truncation off but word-wrap nil the break lands mid-word, which is
  ;; worse to read than either extreme. Both are buffer-local, so a
  ;; global preference for truncation is untouched everywhere else.
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

(defun claude-code-ide-org--review-item-at-point ()
  "Return the review item on the current line, or nil."
  (get-text-property (line-beginning-position) 'claude-code-ide-org-item))

(defun claude-code-ide-org--review-written-summary (item)
  "Return a short phrase naming what apply will really write for ITEM,
or nil when that is exactly the interval ITEM already displays.

The review buffer shows a *span* -- the cluster of guideposts, idle
included -- and apply writes only the runs of work inside it.  Over the
corpus the median span writes about 46% of what it displays.  A human
pressing `x' on a line reading `2:52' while `1:19' is what lands has
confirmed a number that exists nowhere, which is a worse failure than
the overcount it replaced: the overcount was at least visible in the
drawer afterwards.

Says `writes nothing' rather than falling silent when no run survives.
That is a real outcome -- a span of `resume' -> `resume' adjacencies, or
of turns too short to render a minute -- and it is the one a human most
needs to see before marking, since the item will otherwise look applied
and leave no CLOCK line behind."
  (when (and (plist-get item :suggested)
             (claude-code-ide-org--span-kinds-known-p (plist-get item :events)))
    (let* ((runs (claude-code-ide-org--span-work-runs (plist-get item :events)))
           ;; Per run, the way org will compute it -- NOT the sum of raw
           ;; seconds rounded once at the end. Two different errors are
           ;; avoided: each run's own seconds no longer round across a
           ;; minute boundary, and the runs no longer pool their
           ;; remainders into a minute org will never write, since org
           ;; writes each line separately.
           (minutes (apply #'+ (mapcar (lambda (r)
                                         (claude-code-ide-org--clock-minutes
                                          (car r) (cdr r)))
                                       runs))))
      (if runs
          (format "writes %d:%02d in %d" (/ minutes 60) (% minutes 60) (length runs))
        (concat "writes nothing"
                (claude-code-ide-org--review-nothing-reason item))))))

(defun claude-code-ide-org--span-turn-seconds (events)
  "Return (SECONDS . TURNS) for the raw `resume' -> `pause' adjacencies
in EVENTS, before any floor merging or rendered-zero filtering.

Deliberately separate from `claude-code-ide-org--span-work-runs', which
answers \"what gets written\".  This answers \"was there anything there
at all\", and the two differ exactly where a human needs to be told why:
a real 11-second turn has turn time and writes nothing, while a span of
unpaired resumes has neither."
  (let ((points (sort (mapcar (lambda (e) (cons (plist-get e :ts) (plist-get e :kind)))
                              events)
                      (lambda (a b) (time-less-p (car a) (car b)))))
        (seconds 0) (turns 0) previous)
    (dolist (point points)
      (when (and previous
                 (equal (cdr previous) "resume")
                 (equal (cdr point) "pause"))
        (setq turns (1+ turns)
              seconds (+ seconds (float-time (time-subtract (car point) (car previous))))))
      (setq previous point))
    (cons seconds turns)))

(defun claude-code-ide-org--review-nothing-reason (item)
  "Return a parenthesised reason ITEM will write no CLOCK line.

TODO.org :ID: 31f766ab is the heading: the review buffer offers items
whose only possible answer is `d', and -- worse -- two quite different
things look identical when rendered at org's minute precision.  A real
28-second turn and a span holding one lone guidepost both print
`[15:20]--[15:20]'.

Measured over the post-cutover corpus, per session as the review buffer
actually builds items: 4 such items in 57 spans, 2 of each kind.  Rare,
but the cost the heading names is not the keystroke -- it is that
repeated no-op items train the eye to skim, which is the failure
`claude-code-ide-org-write-session-start-report' avoids by staying
silent when it has nothing to say.

An item that explains itself is not skimmed the same way, so the reason
is spelled out at the point of decision rather than the item being
suppressed.  Suppression was considered and rejected for both kinds:
dropping short spans discards real work, which is what :ID: 293ac49e was
filed against; and hiding the trailing in-flight span needs a liveness
signal, whose only available form is queue-file mtime with an hour's
idle threshold -- so a crashed session's last span would vanish for an
hour, which is worse than the annoyance it fixes.  The in-flight case is
self-resolving anyway: the next `pause' grows the cluster and the item
stops being degenerate."
  (let* ((events (plist-get item :events))
         (turns (claude-code-ide-org--span-turn-seconds events))
         (seconds (car turns)))
    (cond
     ;; One interaction point, not an interval. The honest zero.
     ((time-equal-p (plist-get item :start) (plist-get item :end))
      " (a single point, not an interval)")
     ;; Retired 2026-08-24 and kept as a guard rather than deleted.
     ;; This used to report real turn time that org's minute precision
     ;; could not show -- the case a human then edited up to a minute by
     ;; hand. `claude-code-ide-org--apply-idle-floor' now promotes any
     ;; positive run to one minute, so a span with turn time always
     ;; writes something and can no longer reach this function at all.
     ;; If it ever does, the two are disagreeing and that is worth
     ;; saying out loud rather than falling through to "no completed
     ;; turn", which would be false.
     ((> (cdr turns) 0)
      (format " (%ds of turns but nothing written -- unexpected since the one-minute floor; please report)" (round seconds)))
     ;; Guideposts, but never a resume followed by a pause -- TODO.org
     ;; :ID: 09c134c4's question, surfaced rather than silently counted
     ;; as zero.
     (t " (no completed turn in it)"))))

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
           (format "%sspan    %s  %s%s"
                   (if (plist-get item :id) "? " "! ")
                   (claude-code-ide-org--review-format-annotation item)
                   (if (plist-get item :id)
                       (format "-> %s  %s"
                               (claude-code-ide-org--short-id (plist-get item :id))
                               (or (claude-code-ide-org--review-heading-title
                                    (plist-get item :id))
                                   "(unknown heading)"))
                     "UNASSIGNED -- press `a' to choose a heading")
                   (let ((written (claude-code-ide-org--review-written-summary item)))
                     (if written (concat "  " written) "")))
         (format "  clock   %s%s%s"
                 (claude-code-ide-org--review-format-annotation item)
                 (if (plist-get item :suggested) "  (suggested)" "  (agent)")
                 (let ((written (claude-code-ide-org--review-written-summary item)))
                   (if written (concat "  " written) "")))))
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
  "Return ID's heading title, or nil when ID resolves to nothing.

A `:DATE_TREE:' category target answers with its own title plus what it
will become, since it names no heading *yet*: the day node is created at
apply, from the item's own timestamp. Without this the group heading
rendered the first eight characters of the category title and called it
unresolved -- literally \"Review a  (unresolved)\" -- because the render
assumed every id is a UUID and `claude-code-ide-org--short-id' truncates
to eight (TODO.org :ID: 9575e65b, reported by the user)."
  (when id
    (if (claude-code-ide-org--day-node-target-p id)
        (format "%s -- that day\'s meta-work node, created at apply" id)
    (let ((marker (ignore-errors (claude-code-ide-org--id-find id 'marker))))
      (when marker
        (prog1 (org-with-point-at marker
                 (org-no-properties (org-get-heading t t t t)))
          (set-marker marker nil)))))))

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
      ;; A gap covering the *whole* span prints the span's own two
      ;; timestamps back at the reader, one line under the line that
      ;; already shows them, and reads as a bug rather than as evidence
      ;; (TODO.org :ID: a279216c, reported twice by the user).
      ;;
      ;; The line still appears, and that is deliberate: it is
      ;; :ID: 5ff5a4b8's empty case, and suppressing it entirely would
      ;; restore the "nothing found is indistinguishable from nobody
      ;; looked" defect that heading exists to fix. Only the redundant
      ;; timestamps are dropped. An *interior* gap keeps them, because
      ;; there the times are the information -- they say which stretch
      ;; inside the span was empty.
      ;;
      ;; Not fixed by raising `claude-code-ide-org-span-evidence-gap':
      ;; that threshold filters interior gaps by significance, and using
      ;; it here would hide the empty case silently, for short spans
      ;; only.
      (let ((whole (and (time-equal-p (car gap) start)
                        (time-equal-p (time-add (car gap) (cdr gap)) end))))
        (push (cons (car gap)
                    (if whole
                        (format "%7s(no evidence found in this window)" "")
                      (format "%7s(nothing for %s, %s-%s)" ""
                              (claude-code-ide-org--format-duration (cdr gap))
                              (format-time-string "%H:%M" (car gap))
                              (format-time-string
                               "%H:%M" (time-add (car gap) (cdr gap))))))
              entries)))
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
          (let* ((marker (and last-id (ignore-errors (claude-code-ide-org--id-find last-id 'marker))))
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
        (stale 0) (unassigned 0))
    (dolist (item claude-code-ide-org--review-items)
      (let ((want (funcall fn item)))
        (if (and want (not (claude-code-ide-org--review-markable-p item)))
            ;; Count the two refusals separately. They are different
            ;; problems with different answers, and reporting both as
            ;; "stale" sent the user to dismiss six spans that were
            ;; merely unassigned -- three of which carried real recorded
            ;; time (observed 2026-08-24, "13 stale item(s)" when seven
            ;; were stale and six wanted `a').
            (if (and (plist-get item :unassigned) (null (plist-get item :id)))
                (setq unassigned (1+ unassigned))
              (setq stale (1+ stale)))
          (plist-put item :marked want))))
    (claude-code-ide-org--review-render)
    (claude-code-ide-org--review-goto-line line)
    (when (> (+ stale unassigned) 0)
      (message "%s left unmarked%s"
               (string-join
                (delq nil
                      (list (and (> stale 0) (format "%d stale" stale))
                            (and (> unassigned 0)
                                 (format "%d unassigned" unassigned))))
                ", ")
               (concat
                (and (> stale 0) " -- mark stale ones individually to confirm")
                (and (> unassigned 0)
                     (format "%s press `a' to assign a heading"
                             (if (> stale 0) ";" " --"))))))))

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
      (let ((marker (ignore-errors (claude-code-ide-org--id-find id 'marker))))
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
      ;; Honour the bracket style. `--parse-org-timestamp' is
      ;; `org-time-string-to-time', which reads <...> and [...]
      ;; identically and returns a bare time -- so the one signal a human
      ;; can give about what KIND of time this is was being discarded at
      ;; parse, and the annotation re-rendered inactive regardless.
      ;;
      ;; Reported 2026-08-24: the user edited [16:00]--[16:00] to
      ;; <16:00>--<16:31> to say "I thought about the design for those 31
      ;; minutes". The times were kept and the assertion was dropped.
      ;;
      ;; Two different things go through `e' and only the human can tell
      ;; them apart: correcting an agent interval's bounds (still agent
      ;; activity, inactive) and asserting an interval as one's own
      ;; attention (human activity, active -- the case
      ;; `--review-format-annotation' reserves active timestamps for, and
      ;; which :ID: b8e6007a established there was no way to reach).
      ;; Inactive stays the default, since an accidental active timestamp
      ;; reaches org-agenda.
      (plist-put item :active (and (string-prefix-p "<" (string-trim start))
                                   (string-prefix-p "<" (string-trim end))))
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
decision, not part of the batch already confirmed.

*A remainder may never extend past the endpoint the human just set.*
The events before ITEM's new start and the events after its new end are
clustered separately, and that separation is the whole rule -- clustered
together they can form one span bridging the window ITEM now occupies.
That is not hypothetical since clustering became kind-aware: narrowing
to a slice *inside* a single turn leaves that turn's `resume' and
`pause' on opposite sides, and a `resume' -> `pause' adjacency is
precisely the one `claude-code-ide-org--aggregate-guideposts' now
refuses to split at any gap.  The remainder offered back would then
strictly contain the interval the human had just drawn -- the same time
counted twice, once confirmed and once as a leftover, with the leftover
looking like the more complete of the two.

`config-test.el's two existing narrowing tests cannot see this: both
assert on event *counts*, which are conserved either way, and both
narrow to a boundary that happens to leave the leftovers all on one
side."
  (let ((threshold claude-code-ide-org-guidepost-gap-threshold)
        (before (seq-filter (lambda (e) (time-less-p (plist-get e :ts)
                                                     (plist-get item :start)))
                            events))
        (after (seq-filter (lambda (e) (time-less-p (plist-get item :end)
                                                    (plist-get e :ts)))
                           events)))
    (dolist (span (append (claude-code-ide-org--aggregate-guideposts before threshold)
                          (claude-code-ide-org--aggregate-guideposts after threshold)))
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
         (let* ((marker (ignore-errors (claude-code-ide-org--id-find id 'marker)))
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
    (let ((ranked (mapcar (lambda (r) (cons (nth 0 r) (nth 1 r)))
                          (sort rows
                                (lambda (a b)
                                  (cond ((/= (nth 2 a) (nth 2 b)) (< (nth 2 a) (nth 2 b)))
                                        ((/= (nth 3 a) (nth 3 b)) (< (nth 3 a) (nth 3 b)))
                                        (t (> (nth 4 a) (nth 4 b))))))))
          (category (claude-code-ide-org--datetree-category-title)))
      ;; The meta-work category, offered first and by *title*, because it
      ;; is the one destination `org-id' cannot supply: a category
      ;; carries no :ID: by convention, and `bin/lint-org' enforces that,
      ;; so the loop above can never reach it however it is ranked
      ;; (TODO.org :ID: 9575e65b).
      ;;
      ;; First rather than ranked, and that is a claim about this list's
      ;; actual population: a span that got here is one no heading could
      ;; be guessed for, and the recurring reason a span has no plausible
      ;; heading is that the work was not on a heading at all -- review,
      ;; planning, deciding what to do next. Ranking it among headings
      ;; would bury the answer to the commonest case behind dozens of
      ;; wrong ones.
      ;;
      ;; The id here is the category *title*, not a UUID, and that is
      ;; deliberate: apply resolves it to the day node for the item's own
      ;; timestamp, so assigning a span from last Monday files it under
      ;; last Monday. Nothing needs to know the day node's id, and
      ;; nothing stores it.
      (if category
          (cons (cons (format "%-18s %s  {meta-work: files under that day's node}"
                              "(the day it happened)" category)
                      category)
                ranked)
        ranked))))

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
      (let* ((marker (ignore-errors (claude-code-ide-org--id-find (plist-get item :id) 'marker)))
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
;;; The human's review attention (TODO.org :ID: 961f15b6) ------------------
;;
;; The review pass is the one activity this project has never measured and
;; the one it most depends on -- nothing reaches an org file without it.
;;
;; Human attention and agent activity are *different quantities*, not the
;; same one measured twice, so the union-overlapping-intervals convention
;; (:ID: 7d739afd) simply does not reach them and they are separate
;; totals.  Two consequences, both measured 2026-08-26 rather than
;; assumed:
;;
;;   - `org-clock-in' writes an INACTIVE timestamp and there is no
;;     configuration that changes it.  So the two quantities cannot be
;;     told apart by bracket style in a clocktable, and separation has to
;;     be structural: a heading of their own.
;;   - A clocktable with `:step day' reports per-day totals from CLOCK
;;     lines on one ordinary heading, so that heading needs no
;;     `:DATE_TREE:' -- which is what makes structural separation cheap
;;     enough to prefer, rather than doubling the datetree scaffolding
;;     the lint had to learn.
;;
;; Not queued, deliberately.  The queue exists because concurrent agent
;; sessions cannot touch a live buffer safely; a human running an
;; interactive command in Emacs has none of those constraints and is
;; already inside the interactive session the whole design routes toward.

(defcustom claude-code-ide-org-review-attention-heading "Review attention"
  "Exact title of the heading the human's review time is clocked against.

A plain heading, not a `:DATE_TREE:' category.  Per-day reporting comes
from a clocktable's `:step day', measured 2026-08-26, so the tree buys
nothing here and costs the scaffolding `e30d52d7' had to teach the lint.

Set to nil to disable review-attention clocking entirely."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'claude-code-ide-org)

(defvar claude-code-ide-org--review-attention-marker nil
  "Marker for the heading this session's review pass is clocked against.
Non-nil exactly while a human review interval is open.")

(defun claude-code-ide-org--review-attention-target (&optional create)
  "Return a marker for the review-attention heading, creating it with CREATE.

Created as a level-2 heading under the meta-work category, since it is
meta-work by definition and this project reserves level 1 for
categories."
  (let ((title claude-code-ide-org-review-attention-heading)
        (file (claude-code-ide-org--capture-target-file)))
    (when (and title file (file-readable-p file))
      (with-current-buffer (find-file-noselect file)
        (org-with-wide-buffer
         (goto-char (point-min))
         (let (found)
           (while (and (not found) (re-search-forward org-heading-regexp nil t))
             (beginning-of-line)
             (if (equal (org-get-heading t t t t) title)
                 (setq found (point-marker))
               (end-of-line)))
           (or found
               (when create
                 (let ((buffer-read-only nil))
                   (goto-char (point-min))
                   ;; END of the category's subtree, not the line after
                   ;; its headline.  The first version inserted at
                   ;; headline+1, which is the category's own
                   ;; `:PROPERTIES:' drawer -- so the new heading was
                   ;; wedged between the category and its drawer and
                   ;; *inherited* it.  On the real file that handed
                   ;; `:DATE_TREE:' and `:ARCHIVE:' to this heading,
                   ;; which cost the category its archive routing and
                   ;; made `org-datetree-find-date-create' build a
                   ;; second, nested datetree.  Eleven lint errors, and
                   ;; the user's file, on the first real invocation.
                   ;;
                   ;; `org-end-of-subtree' cannot land inside a drawer
                   ;; or a body, so the class of bug is gone rather than
                   ;; the instance.
                   (if (re-search-forward "^\\* Review and planning$" nil t)
                       (progn (org-back-to-heading t)
                              (org-end-of-subtree t t))
                     (goto-char (point-max)))
                   (unless (bolp) (insert "\n"))
                   (insert "** " title "\n")
                   (forward-line -1)
                   (org-id-get-create)
                   (org-entry-put (point) "CREATED"
                                  (format-time-string "[%Y-%m-%d %a %H:%M]"))
                   (save-buffer)
                   (point-marker))))))))))

(defun claude-code-ide-org-review-attention-start ()
  "Open a clock on the review-attention heading.  Idempotent within a pass."
  (when (and claude-code-ide-org-review-attention-heading
             (not claude-code-ide-org--review-attention-marker))
    (let ((marker (claude-code-ide-org--review-attention-target 'create)))
      (when marker
        (setq claude-code-ide-org--review-attention-marker marker)
        (org-with-point-at marker
          (let ((buffer-read-only nil))
            (org-clock-in)))
        marker))))

(defun claude-code-ide-org-review-attention-stop (&optional reason)
  "Close the review-attention clock, if this session opened one.

REASON is recorded on an *active*-timestamped annotation beside the
interval.  Active because that is the one part of a `:LOGBOOK:' entry
that can be -- the `CLOCK:' line above it cannot -- and because an
active timestamp is what puts the human's own time in the agenda
\(TODO.org :ID: b8e6007a reserved exactly that for intervals a human
logs themselves)."
  (when claude-code-ide-org--review-attention-marker
    (let ((marker claude-code-ide-org--review-attention-marker)
          (start org-clock-start-time))
      (setq claude-code-ide-org--review-attention-marker nil)
      (when (org-clocking-p)
        (org-with-point-at marker
          (let ((buffer-read-only nil))
            (org-clock-out)
            (when start
              (claude-code-ide-org--append-to-drawer
               "LOGBOOK"
               (format "- <%s>--<%s> %s"
                       (format-time-string "%Y-%m-%d %a %H:%M" start)
                       (format-time-string "%Y-%m-%d %a %H:%M")
                       (or reason "review pass"))))
            (save-buffer))))
      t)))

(defun claude-code-ide-org--review-attention-on-quit (&rest _)
  "Stop the attention clock when the review buffer stops being visible.

Advice on `quit-window' rather than a rebinding of `q'.  `q' here is
`special-mode's `quit-window', which *buries*; rebinding it to kill
would change a key every `special-mode' buffer in Emacs shares, to serve
a clock.  And burying is not a lesser form of closing -- it is how a
person actually leaves this buffer, so it is the event to watch."
  (when (and claude-code-ide-org--review-attention-marker
             (derived-mode-p 'claude-code-ide-org-review-mode))
    (claude-code-ide-org-review-attention-stop "review pass (buffer buried)")))

(advice-add 'quit-window :before #'claude-code-ide-org--review-attention-on-quit)

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
      ;; The command *is* the event (TODO.org :ID: 961f15b6): it is the
      ;; documented and only entry point to the pass, it cannot be
      ;; invoked by accident, and starting here needs no utterance and
      ;; cannot be forgotten -- unlike the "tell you to clock me in"
      ;; contract, which depends on remembering a sentence at both ends.
      (claude-code-ide-org-review-attention-start)
      ;; Buffer-local, and it runs with the buffer current just before
      ;; the kill.  This is the second of three layers: burying is
      ;; handled by advice on `quit-window', and `kill-emacs-hook'
      ;; already runs `--clock-out-if-clocking'.
      (add-hook 'kill-buffer-hook
                (lambda ()
                  (claude-code-ide-org-review-attention-stop
                   "review pass (buffer killed)"))
                nil t)
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

(defcustom claude-code-ide-org-plan-drawer-since
  (encode-time 0 0 0 24 8 2026)
  "Date from which a finished heading is expected to carry a `:PLAN:' drawer.

Headings closed before this are exempt, because the convention did not
exist and wrapping them is `cbe282ec\'s backlog rather than a defect.
Defaults to 2026-08-24, the day the drawer lifecycle was adopted
\(TODO.org :ID: 8bcd56f4).

A `defcustom\' rather than a constant so a different checkout, or this
one after the backlog is swept, can move the line without editing the
check."
  :type '(repeat integer)
  :group 'claude-code-ide-org)

(defcustom claude-code-ide-org-repeater-body-max 25
  "Body lines a heading carrying a repeater may hold before the lint warns.

A repeater never reaches DONE -- its keyword resets and its SCHEDULED
stamp advances -- so no event in the `:PLAN:\' lifecycle ever prunes its
body, and a ritual heading accumulates prose forever (TODO.org :ID:
ff92700e).

25 is calibrated against the case that actually went wrong, and it
*fires on nothing today* -- the three repeaters that exist hold 3, 7 and
9 body lines.  It is a forward-looking guard, on the same footing as the
:PLAN: rule, and the honest claim is that it would have caught :ID:
cbe282ec at 47 lines shortly before that heading had to be split three
ways by hand.

An earlier draft of this docstring claimed it flagged an 80-line
repeater. That measurement was wrong -- it counted drawer contents as
body prose, which is exactly what `claude-code-ide-org--lint-body-prose
-lines' exists to avoid, and the real figure was 7.  Recorded because
the mistake is instructive: a body-size rule written against a
body-size measurement that does not match the rule's own counter is a
rule calibrated to nothing.

The cap is a *forcing function*, not a style rule.  Length is the
symptom; the cause is that a recurring heading is where cross-cutting
prose gets written down, because it is the heading being edited at the
time and there is nowhere else obvious.  The cure is to move that prose
to a rule file, a linked heading or a one-time task -- which is what
splitting :ID: cbe282ec three ways did by hand."
  :type 'integer
  :group 'claude-code-ide-org)

(defun claude-code-ide-org--lint-body-prose-lines ()
  "Count the heading-at-point's own body lines, excluding drawer contents.

Shared by the two rules that ask about body size so they cannot disagree
about what a body line is."
  (save-excursion
    (org-back-to-heading t)
    (let ((limit (save-excursion (outline-next-heading) (point)))
          (lines 0)
          (in-drawer nil))
      (org-end-of-meta-data t)
      (while (< (point) limit)
        (let ((text (string-trim (buffer-substring-no-properties
                                  (line-beginning-position)
                                  (line-end-position)))))
          (cond
           ((string-match-p "\\`:[A-Za-z_]+:\\'" text) (setq in-drawer t))
           ((equal text ":END:") (setq in-drawer nil))
           ((or in-drawer (string-empty-p text)) nil)
           (t (setq lines (1+ lines)))))
        (forward-line 1))
      lines)))

(defun claude-code-ide-org--lint-substantial-body-p ()
  "Non-nil when the heading at point has a body worth wrapping.

\"Substantial\" is ten or more lines of actual prose: drawers, planning
lines and their contents do not count, and neither does a body that is
only a plan link.  The threshold exists so the rule never fires on a
one-line heading, where a `:PLAN:\' drawer would be ceremony rather than
structure.

Counts from the end of the metadata to the next heading of any level --
`outline-next-heading\', never a regexp of ours, for the reason recorded
on `claude-code-ide-org--heading-body-bounds\'."
  (>= (claude-code-ide-org--lint-body-prose-lines) 10))

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

(defun claude-code-ide-org--lint-routing-categories (files)
  "Return the level-1 headings across FILES that carry `:ARCHIVE:'.

These are the categories: a level-1 heading with an archive target is
the thing this project means by one, and the property is what makes it
routable rather than merely top-level.  Measured 2026-08-19: all seven
level-1 headings in TODO.org carry it and none of DONE.org's seven do,
because the latter are archive *targets* rather than sources -- so the
set is collected across every linted file and matched by title, which
lets a target be recognised by the source it mirrors.

Returned as a list of titles rather than a count, so
`claude-code-ide-org--lint-file' can tell a mirror from a stray."
  (let (titles)
    (dolist (file files (nreverse titles))
      (when (file-exists-p file)
        (with-temp-buffer
          (let ((org-inhibit-startup t))
            (insert-file-contents file)
            (org-mode)
            (org-map-entries
             (lambda ()
               (when (and (= 1 (org-current-level))
                          (org-entry-get nil "ARCHIVE"))
                 (let ((title (org-get-heading t t t t)))
                   (unless (member title titles) (push title titles)))))
             ;; Scope nil, not `file', for the reason documented on
             ;; `claude-code-ide-org--lint-heading-ids' above: a temp
             ;; buffer has no `buffer-file-name', so `file' scope maps
             ;; over nothing and reports that as success.
             nil nil)))))))

(defun claude-code-ide-org--datetree-node-role (depth title)
  "Return `year\', `month\' or `day\' when TITLE at DEPTH levels below a
:DATE_TREE: heading is one of org-datetree\'s own scaffolding nodes, and
nil for anything else.

Gated on org\'s literal title shapes, not on depth alone, and that is the
whole point of the function.  A `:DATE_TREE:\' category holds real tasks
beside its tree -- the ritual repeater TODO.org :ID: cd1e974e institutes
sits at depth 1, exactly where the year node does -- so a depth-only test
would waive :ID: and :CREATED: for every one of them.  That is the same
over-application shape the retired sole-TODO promotion kept running
into: a predicate reading position without asking what kind of heading
it is looking at.

The patterns are org\'s own, lifted from the `comparefun\' regexes
`org-datetree-find-date-create\' passes for the year/month/day grouping
(org-datetree.el, verified against the straight checkout 2026-08-21):
a four-digit year, `YYYY-MM Month\', `YYYY-MM-DD Dayname\'.  Org\'s other
groupings -- quarter (`YYYY-QN\') and ISO week (`YYYY-WNN\') -- are
deliberately absent: this project uses year/month/day, and a tree in
another grouping should fail the lint rather than be quietly accepted by
a rule nobody chose."
  (pcase depth
    (1 (and (string-match-p "\\`[12][0-9]\\{3\\}\\'" title) 'year))
    (2 (and (string-match-p "\\`[12][0-9]\\{3\\}-[01][0-9] [[:alpha:]]" title) 'month))
    (3 (and (string-match-p "\\`[12][0-9]\\{3\\}-[01][0-9]-[0123][0-9] [[:alpha:]]" title) 'day))))

(defun claude-code-ide-org--lint-file (file known-ids &optional categories)
  "Return a list of finding strings for FILE.  KNOWN-IDS is the hash
from `claude-code-ide-org--lint-heading-ids'.  CATEGORIES is the list
from `claude-code-ide-org--lint-routing-categories'."
  (let ((name (file-name-nondirectory file))
        ;; Level of the innermost enclosing :DATE_TREE: heading, or nil.
        ;; Tracked as state across the map because `org-map-entries'
        ;; walks in document order, so an anchor is always seen before
        ;; its descendants and a heading at or above the anchor's level
        ;; has left the subtree.
        (datetree-level nil)
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
                    (title (org-get-heading t t t t))
                    (datetree-role
                     (progn
                       ;; Left the subtree: a sibling of the anchor, or
                       ;; anything shallower, ends it.
                       (when (and datetree-level (<= level datetree-level))
                         (setq datetree-level nil))
                       (and datetree-level
                            (claude-code-ide-org--datetree-node-role
                             (- level datetree-level) title)))))
               ;; Non-inherited: an inherited lookup would make every
               ;; descendant of the anchor read as an anchor itself.
               (when (org-entry-get nil "DATE_TREE") (setq datetree-level level))
               (cond
                ;; Org writes year and month nodes bare -- no property
                ;; drawer at all -- and they are scaffolding rather than
                ;; work, so :ID: and :CREATED: are not theirs to carry.
                ;; The day node deliberately does NOT land here: it is
                ;; the heading this project clocks against, every tool
                ;; addresses headings by :ID:, and a day node without one
                ;; exists and is unreachable (TODO.org :ID: e30d52d7).
                ((memq datetree-role '(year month)) nil)
                ;; `and'-ed rather than tested inside the branch: a day
                ;; node must fall THROUGH to the :ID:/:CREATED: clause
                ;; below, and a cond branch that matched and did nothing
                ;; would silently exempt the one heading here that most
                ;; needs linting.
                ((and (> level 3) (not (eq datetree-role 'day)))
                 ;; Revised 2026-08-21 (TODO.org :ID: e30d52d7). The
                 ;; three-level claim recorded on :ID: 3bd3402b -- 624
                 ;; headings, zero at level 4 -- was true of a file with
                 ;; no datetree in it, and a datetree is category, year,
                 ;; month, day before any task exists. So the assertion
                 ;; is now scoped rather than dropped: three levels
                 ;; outside a :DATE_TREE: subtree, and inside one exactly
                 ;; the scaffolding plus its day node. A level-4 heading
                 ;; anywhere else is still an error, and so is anything
                 ;; below a day node -- nothing is filed under one, since
                 ;; the day node is the thing time is assigned to.
                 (report 'error line "level-%d heading; the file has three levels \
(category, task, epic-child) outside a :DATE_TREE: subtree, and inside one only \
year/month scaffolding and its day node: %s" level title))
                ((= level 1)
                 ;; *Inverted 2026-08-27* (TODO.org :ID: 29439196). Level 1
                 ;; used to be the category tier -- structure, forbidden to
                 ;; carry :ID:, :CREATED:, a keyword or tags. Flattening
                 ;; moved the grouping onto the task as :CATEGORY:, so
                 ;; level 1 is now where the *work* lives and must carry
                 ;; exactly what every other task does. The old rule is
                 ;; preserved in `.claude/rules/org-conventions.md', since
                 ;; a reader of older commits will meet it.
                 ;;
                 ;; The `:DATE_TREE:' anchor is the one structural level-1
                 ;; heading left: org-datetree's year/month/day nodes are
                 ;; an irreducible tree and need a container to nest in.
                 ;; It is exempted by carrying the property, not by title,
                 ;; so a rename cannot silently un-exempt it.
                 (if (org-entry-get nil "DATE_TREE")
                     (progn
                       (when todo
                         (report 'error line
                                 "the :DATE_TREE: anchor carries TODO keyword %s: %s"
                                 todo title))
                       (when id
                         (report 'error line
                                 "the :DATE_TREE: anchor carries :ID:: %s" title)))
                   ;; An ordinary level-1 task.
                   (unless id
                     (report 'error line "level-1 task has no :ID:: %s" title))
                   ;; `warn', matching what a deeper heading gets. A
                   ;; missing :CREATED: is not retrofittable -- nobody
                   ;; knows when a 2026-07 heading was written -- and
                   ;; erroring would have turned 13 pre-convention
                   ;; DONE.org headings into blockers overnight purely
                   ;; because flattening moved them to level 1. An :ID:
                   ;; IS retrofittable, so that one stays an error.
                   (unless created
                     (report 'warn line "level-1 task has no :CREATED:: %s" title))
                   ;; A task without a category is unfiled: nothing in the
                   ;; tree says where it belongs any more, which is exactly
                   ;; what the flattening traded away. Warn rather than
                   ;; error -- a freshly captured heading may legitimately
                   ;; not have one yet.
                   ;; Read the drawer, not `org-entry-get'. Org
                   ;; *computes* CATEGORY -- falling back to the file
                   ;; name, or "???" in a buffer with no file -- so it
                   ;; is never nil and a presence test through it always
                   ;; passes. That fallback is the same one that made the
                   ;; agenda's category column carry two distinct values
                   ;; across 274 headings, which is what prompted
                   ;; :ID: 29439196 in the first place. Measured, not
                   ;; assumed: a bare heading answers "???".
                   (unless (claude-code-ide-org--category-property-p)
                     (report 'warn line "level-1 task has no :CATEGORY:: %s" title))))
                (t
                 (unless id (report 'error line "heading has no :ID:: %s" title))
                 (unless created
                   (report 'warn line "heading has no :CREATED:: %s" title))))
               ;; A title with no word characters at all is punctuation
               ;; mistaken for structure. `* *' -- markdown's horizontal
               ;; rule -- is the shape that occurred: org read the
               ;; leading asterisk as a headline and the rest as its
               ;; title. Checked at every level, since the same typo
               ;; nested is no more intentional.
               (unless (string-match-p "[[:word:]]" (or title ""))
                 (report 'error line
                         "heading title has no word characters, so it is \
probably punctuation read as structure: %S" title))
               ;; A tag repeated on one heading cannot be deliberate.
               ;; `org-get-tags' does not deduplicate -- verified
               ;; 2026-08-20, it returns ("code" "code") -- so the
               ;; comparison is real rather than always-true. Produced
               ;; here by a hand-edit that appended a tag to a headline
               ;; that already carried it; org-lint does not look.
               (let ((tags (org-get-tags nil t)))
                 (unless (= (length tags) (length (delete-dups (copy-sequence tags))))
                   (report 'error line "heading repeats a tag %S: %s"
                           tags title)))
               ;; A heading that has acquired TODO-carrying children is a
               ;; container, and a container states its progress in a
               ;; statistics cookie so the count is visible without
               ;; unfolding it. Gated on the heading carrying a keyword
               ;; of its own: a level-1 category has TODO children by
               ;; definition and is structure, not a task.
               ;;
               ;; Presence only, not accuracy -- org recomputes the
               ;; numbers itself (`org-update-statistics-cookies'), and a
               ;; check that recomputed them here would be asserting
               ;; against org's own arithmetic rather than against the
               ;; convention.
               ;;
               ;; An `error' rather than a `warn' on two grounds: it is
               ;; honestly retrofittable, since the count is derived from
               ;; structure and not a fact about the past the way
               ;; :CREATED: is; and it can only fire on the commit that
               ;; gives a heading its *first* child, which is exactly
               ;; when the convention needs stating.
               (when (and todo
                          (claude-code-ide-org--container-heading-p)
                          (not (string-match-p
                                claude-code-ide-org--statistics-cookie-regexp
                                (or title ""))))
                 (report 'error line "heading has TODO children but no statistics \
cookie -- add [/] and run `org-update-statistics-cookies': %s" title))
               ;; A slice states its progress the same way, over its
               ;; checkbox list of members rather than over children --
               ;; so it needs its own clause, not a widened predicate.
               ;; The rule above asks `--container-heading-p' and a slice
               ;; has no children to satisfy it with, which is why
               ;; :ID: 979e02b6 sat cookie-less through a whole slice's
               ;; life with three separate mechanisms declining to
               ;; mention it (TODO.org :ID: 28415ca8).
               ;;
               ;; Kept as a second clause rather than folded into the
               ;; first: `--grouping-heading-p' is the right predicate
               ;; where the question is about *meaning*, and here the two
               ;; rules genuinely differ in what they count.
               (when (and (claude-code-ide-org--slice-p)
                          (not (string-match-p
                                claude-code-ide-org--statistics-cookie-regexp
                                (or title ""))))
                 (report 'error line "slice has no statistics cookie -- add [/]; \
`M-x claude-code-ide-org-refresh-slice' now does this itself: %s" title))
               ;; A finished heading with a substantial body carries a
               ;; :PLAN: drawer (TODO.org :ID: 8bcd56f4): the prospective
               ;; half wrapped away, the debrief left as the body.
               ;;
               ;; *Scoped by CLOSED: date, and that scoping is the whole
               ;; of whether this rule is usable.* Measured 2026-08-24:
               ;; unscoped it fires on 124 headings at once -- 30 in
               ;; TODO.org and 94 in DONE.org -- which is exactly the
               ;; drowning :ID: e30d52d7 had to rescue this lint from
               ;; once already. A report carrying 124 permanent findings
               ;; is one nobody reads, which is the failure 5ff5a4b8
               ;; measured. Scoped to headings closed on or after the
               ;; convention landed it fires zero times today and grows
               ;; only with new work.
               ;;
               ;; The scoping is only *possible* because :ID: f4b07fc0
               ;; backfilled 58 CLOCK-derived CLOSED: markers hours
               ;; earlier. Before that, "closed after date X" was not a
               ;; question this file could answer.
               ;;
               ;; A heading with no CLOSED: at all is exempt rather than
               ;; reported: it was closed before the marker existed, so
               ;; its date is unknown, and 39 headings in DONE.org are in
               ;; that position permanently. `warn' rather than `error'
               ;; on the standing rule above -- it is a convention a new
               ;; heading must satisfy, and wrapping a body is a judgement
               ;; about where the seam falls, not a mechanical repair.
               (when (and todo
                          (member todo claude-code-ide-org--outline-finished-keywords)
                          (claude-code-ide-org--lint-substantial-body-p)
                          (not (claude-code-ide-org--find-drawer "PLAN")))
                 (let ((closed (org-entry-get nil "CLOSED")))
                   (when (and closed
                              (not (time-less-p
                                    (claude-code-ide-org--parse-org-timestamp closed)
                                    claude-code-ide-org-plan-drawer-since)))
                     (report 'warn line "finished heading with a substantial body and no :PLAN: drawer -- wrap the prospective half with org_wrap_plan: %s" title))))
               ;; A repeater's body is never pruned, because every
               ;; pruning event in the :PLAN: lifecycle is tied to
               ;; reaching DONE and a repeater never does (TODO.org
               ;; :ID: ff92700e). Nothing else in the convention will
               ;; ever collect it, so the lint is the only thing that
               ;; can notice. It fires on nothing today; it would have
               ;; caught :ID: cbe282ec at 47 lines, shortly before that
               ;; heading had to be split three ways by hand.
               (when (and (org-get-repeat)
                          (> (claude-code-ide-org--lint-body-prose-lines)
                             claude-code-ide-org-repeater-body-max))
                 (report 'warn line "repeater with a %d-line body (max %d) -- \
a repeater never reaches DONE, so nothing ever prunes it; move the durable \
prose to a rule file, a linked heading or a one-time task: %s"
                         (claude-code-ide-org--lint-body-prose-lines)
                         claude-code-ide-org-repeater-body-max title))
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
               ;; A slice's `:BLOCKER:' must name exactly the members that
               ;; still carry a checkbox cookie.  The two halves are
               ;; deliberately redundant -- the checkbox list is the human
               ;; one and the blocker the machine-readable one -- and
               ;; redundancy without a check is just two things that can
               ;; disagree.  TODO.org :ID: 29439196 made exactly that
               ;; objection to link lists ("one edit point nobody
               ;; revisits"); this assertion is the answer to it.
               ;;
               ;; An error rather than a warning: the correct value is
               ;; computable from the body, so a mismatch is never a
               ;; judgement call, and
               ;; `claude-code-ide-org-refresh-slice-blocker' fixes it
               ;; without asking anything.
               (when (claude-code-ide-org--slice-p)
                 (let* ((want (claude-code-ide-org--slice-blocker-ids))
                        (have (claude-code-ide-org--lint-blocker-ids
                               (or (org-entry-get nil "BLOCKER") "")))
                        (missing (seq-difference want have))
                        (extra (seq-difference have want)))
                   (when missing
                     (report 'error line "slice :BLOCKER: omits %d checked member%s \
(%s) -- run claude-code-ide-org-refresh-slice-blocker: %s"
                             (length missing) (if (= 1 (length missing)) "" "s")
                             (mapconcat (lambda (i) (substring i 0 8)) missing " ")
                             title))
                   (when extra
                     (report 'error line "slice :BLOCKER: names %d id%s that is not a \
checked member (%s) -- a cancelled or deferred member must not block: %s"
                             (length extra) (if (= 1 (length extra)) "" "s")
                             (mapconcat (lambda (i) (substring i 0 8)) extra " ")
                             title))))
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
    (let ((categories (claude-code-ide-org--lint-routing-categories files)))
      (apply #'append
             (mapcar (lambda (f) (claude-code-ide-org--lint-file f known categories))
                     files)))))

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

;;; :PLAN: drawer wrapping (TODO.org :ID: 3063c3e5)
;;
;; The cheap half of body revision, and the only half the completion
;; transition needs. `org_amend' already appends *below* a :PLAN: drawer
;; sitting at the top of a body, so the debrief needs no new tool at all
;; (measured on :ID: cc0c17a7). What is missing is wrapping: put the
;; prospective body inside a drawer beside :PROPERTIES: and :LOGBOOK:,
;; so a folded heading shows the debrief and nothing else.
;;
;; Two insertions at computable positions, deliberately -- NOT a range
;; replacement. Both of 2026-08-21's file corruptions were range bugs,
;; and neither was caught by `bin/lint-org', which sees structure and
;; not prose. The nastier one used a `startswith("*")' test to find the
;; next heading and matched a *bold prose line* instead, orphaning 117
;; lines. Nothing here asks whether a line looks like a heading: org's
;; own `outline-next-heading' decides, so a line org would not parse as
;; a heading cannot be treated as one.

(defun claude-code-ide-org--heading-body-bounds ()
  "Return (OPEN BEG END) delimiting the body of the heading at point.

BEG is the first body character and END is just past the last, with
trailing blank lines excluded so a `:END:' inserted at END lands against
the last real line.  END stops at the next heading of *any* level, so a
parent's body ends at its first child rather than swallowing the
subtree.

OPEN is where a `:PLAN:' marker goes, and it is not BEG: it sits
immediately after the last metadata drawer, before any blank line
separating that drawer from the prose.  So the blank line ends up
*inside* the drawer and `:PLAN:' abuts the preceding `:END:', matching
the layout :ID: cc0c17a7 established as the trial vehicle.  Keeping the
blank rather than consuming it is what preserves the insert-only
property -- moving it would be a deletion, and deletion is how the two
2026-08-21 corruptions happened.

Returns nil when the heading has no body -- there is nothing to wrap,
which is a fact for the caller to report rather than an error."
  (save-excursion
    (org-back-to-heading t)
    (let ((limit (save-excursion
                   ;; org's own notion of the next heading. Never a
                   ;; regexp of ours: see the corruption noted above.
                   (outline-next-heading)
                   (if (and (eobp) (not (org-at-heading-p))) (point-max) (point)))))
      (org-end-of-meta-data t)
      (let ((beg (point))
            (end limit)
            open)
        ;; Walk back over the blank lines `org-end-of-meta-data' skipped,
        ;; to find where the metadata drawers actually stop.
        (save-excursion
          (goto-char beg)
          (skip-chars-backward " \t\n")
          (unless (bolp) (forward-line 1) (beginning-of-line))
          (setq open (point)))
        ;; Walk back over trailing blank lines.
        (save-excursion
          (goto-char end)
          (skip-chars-backward " \t\n" beg)
          (unless (bolp) (forward-line 1) (beginning-of-line))
          (setq end (max beg (point))))
        (and (< beg end) (list open beg end))))))

(defun claude-code-ide-org--plan-seam (beg end marker &optional empty-ok)
  "Return the position in BEG..END where the line containing MARKER starts.

MARKER is matched literally and must appear exactly once in the region,
at the start of a line.  Anything else is an error rather than a best
guess: the seam decides which half of a body becomes invisible to
ordinary reading, and a silently-wrong seam is the one mistake here that
no later reader will catch, since `:PLAN:' is a drawer readers are told
to skip.

*The seam landing on the first body line is not an error condition; it
is an answer* (TODO.org :ID: f421c5c3).  It says the body is debrief all
the way up -- there is no prospective half -- which is what a heading
written outcome-first under this convention looks like, and six existing
headings are in exactly that position.  With EMPTY-OK non-nil this
returns BEG, and the caller wraps nothing into an *empty* `:PLAN:'
drawer, which records that the question was asked and answered.  Without
it the old error stands, so a caller that cannot represent the answer
still refuses rather than silently producing an empty drawer.

Uniqueness is still enforced in both modes.  EMPTY-OK relaxes only the
\"nothing to wrap\" case, never \"I could not tell which line you
meant\"."
  (save-excursion
    (goto-char beg)
    (let (hits)
      (while (search-forward marker end t)
        (push (line-beginning-position) hits))
      (cond
       ((null hits)
        (error "Seam marker not found in body: %s" marker))
       ((cdr hits)
        (error "Seam marker appears %d times; it must be unique: %s"
               (length hits) marker))
       ((and (= (car hits) beg) (not empty-ok))
        (error "Seam marker is the first body line; nothing would be wrapped"))
       (t (car hits))))))

(defun claude-code-ide-org-wrap-plan (id &optional until)
  "Wrap the prospective part of heading ID's body in a :PLAN: drawer.

With UNTIL nil the whole body is wrapped, which is the completion
transition for a heading whose body is still purely prospective.

With UNTIL given, only the text *above* the line containing it is
wrapped and everything from that line down stays as the body.  That is
the retroactive case: a body written before the convention existed
usually holds both halves already, and wrapping it whole would bury the
debrief inside the drawer -- the exact inversion the convention exists
to prevent.

Refuses when a :PLAN: drawer already exists, so a repeat is a no-op with
an explanation rather than a nested drawer.  Lossless by construction:
two insertions, no deletion, no reflow.  Returns a summary string."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (if (claude-code-ide-org--find-drawer "PLAN")
         (format "Error: \"%s\" already has a :PLAN: drawer; nothing done."
                 (org-get-heading t t t t))
       (let ((bounds (claude-code-ide-org--heading-body-bounds)))
         (if (null bounds)
             (format "Error: \"%s\" has no body to wrap."
                     (org-get-heading t t t t))
           ;; A body containing a bare `:END:' line cannot be wrapped,
           ;; and that is org's grammar rather than a limitation here:
           ;; `:END:' *is* the drawer terminator, `org-element's drawer
           ;; parser stops at the first line matching it, and nothing
           ;; escapes that -- not a comma, not a #+BEGIN_ block. Blocks
           ;; themselves are perfectly legal inside a drawer; it is
           ;; specifically the `:END:' line that cannot be contained,
           ;; which is why this tests for that and not for blocks.
           ;;
           ;; Measured 2026-08-24 on org 9.8.7 against :ID: cd1e974e,
           ;; whose body demonstrates a datetree subtree inside
           ;; #+BEGIN_EXAMPLE, :PROPERTIES:/:END: pair and all. Wrapping
           ;; it closed the :PLAN: drawer at the example's `:END:',
           ;; leaving the rest of the body -- including a literal
           ;; `SCHEDULED: <2026-08-22 Sat +1d>' -- outside the drawer at
           ;; body top level, where `org-get-repeat' found it and
           ;; bin/lint-org reported a repeater under a completable
           ;; ancestor. One error and five spurious warnings out of two
           ;; inserted lines, and the heading still looked fine.
           (if (save-excursion
                 (goto-char (nth 1 bounds))
                 (re-search-forward "^[ \t]*:END:[ \t]*$" (nth 2 bounds) t))
               (format "Error: \"%s\" has a bare :END: line in its body, which \
would close the :PLAN: drawer early -- :END: is org's drawer terminator and \
nothing escapes it. Not wrapped."
                       (org-get-heading t t t t))
           (let* ((open (nth 0 bounds))
                  (beg (nth 1 bounds))
                  (end (nth 2 bounds))
                  ;; EMPTY-OK: a seam on the first body line means "no
                  ;; prospective half", and an empty drawer is how that
                  ;; is recorded rather than an error the caller has no
                  ;; way to satisfy (TODO.org :ID: f421c5c3).
                  (stop (if until
                            (claude-code-ide-org--plan-seam beg end until t)
                          end))
                  (before (buffer-substring-no-properties open end)))
             ;; Close first, then open. Inserting at the later position
             ;; before the earlier one keeps BEG valid; doing it the
             ;; other way round would shift STOP by the length of the
             ;; opening marker and close the drawer one line late.
             (save-excursion
               (goto-char stop)
               (insert ":END:\n"))
             (save-excursion
               (goto-char open)
               (insert ":PLAN:\n"))
             (save-buffer)
             ;; Prove the move was lossless right here, against the text
             ;; read before the insertions, rather than trusting the
             ;; arithmetic. `bin/lint-org' cannot make this check: the
             ;; damage it would catch is structural and this one is
             ;; prose-level under a well-formed heading.
             (let* ((after (buffer-substring-no-properties
                            open (+ end (length ":PLAN:\n:END:\n"))))
                    (stripped (replace-regexp-in-string
                               "^:\\(PLAN\\|END\\):\n" "" after)))
               ;; `substring-no-properties', because `org-get-heading'
               ;; returns the fontified heading and the MCP layer
               ;; serializes its text properties as pages of
               ;; `(face (org-headline-done ...))' around the answer.
               ;; Same trap as `--outline-line' and the pending-updates
               ;; report; observed here on the first real call.
               (substring-no-properties
                (if (= stop beg)
                    (format "\"%s\" has no prospective half -- the seam is its \
first body line -- so an empty :PLAN: drawer records that, and the whole body \
stays visible as the debrief. Text preserved: %s."
                            (org-get-heading t t t t)
                            (if (equal stripped before) "yes" "NO -- INSPECT"))
                  (format "Wrapped %s of \"%s\" in :PLAN:%s. Text preserved: %s."
                          (if until "the body above the seam" "the whole body")
                          (org-get-heading t t t t)
                          (if until (format " (seam: %s)" until) "")
                          (if (equal stripped before) "yes" "NO -- INSPECT")))))))))))))

;;; CLOSED: backfill (TODO.org :ID: f4b07fc0)
;;
;; `#+STARTUP: logdone' only reached TODO.org on 2026-08-17, and the
;; newest :ARCHIVE_TIME: is that same day -- so every archived heading was
;; closed before the option existed and DONE.org held 97 finished
;; headings and zero CLOSED: markers.
;;
;; The `!' cookies in `#+TODO:' were logging state changes long before
;; that, so for many of those headings the closing moment *is* already in
;; the file, on a `- State "DONE" from "..." [ts]' line. Where it is, the
;; marker can be reconstructed from evidence rather than guessed.
;;
;; Where it is not, nothing is written. :ARCHIVE_TIME: is the obvious
;; candidate and is a *different fact wearing the right shape* -- when
;; the subtree moved, not when the work stopped. Writing it as CLOSED:
;; would produce a plausible timestamp that is not the one it claims to
;; be, which is the class of guess :ID: 7771fc63 retired for being wrong
;; more often than right.

(defun claude-code-ide-org--recorded-close-time ()
  "Return the latest close time logged for the heading at point, or nil.

Reads `- State \"DONE\"' and `- State \"CANCELLED\"' lines from the
heading's own :LOGBOOK:.  The *latest* wins: a heading reopened and
closed again was closed when it was closed last, and the earlier line
records a moment that a later one superseded.

Returns nil when no such line exists.  That is the answer for 38 of
DONE.org's 97 finished headings, and it must stay nil rather than fall
back to anything -- see this section's header."
  (let ((bounds (claude-code-ide-org--drawer-content-bounds "LOGBOOK"))
        latest)
    (when bounds
      (save-excursion
        (goto-char (nth 0 bounds))
        (while (re-search-forward
                "^- State \"\\(?:DONE\\|CANCELLED\\)\"[ \t]+from[ \t]+\"[^\"]*\"[ \t]+\\(\\[[^]]+\\]\\)"
                (nth 1 bounds) t)
          (let ((time (claude-code-ide-org--parse-org-timestamp (match-string 1))))
            (when (or (null latest) (time-less-p latest time))
              (setq latest time))))))
    latest))

(defun claude-code-ide-org-backfill-closed (&optional file dry-run)
  "Add a CLOSED: line to finished headings in FILE that can evidence one.

FILE defaults to the archive target.  With DRY-RUN non-nil nothing is
written and the buffer is not saved; the report is identical either way,
which is what makes the dry run worth trusting.

A heading is a candidate when its keyword is one of `org-done-keywords'
and it has no CLOSED: already.  The time comes from
`claude-code-ide-org--recorded-close-time', and a candidate with none is
counted and skipped, never filled from a substitute.

Insertion goes through org's own `org-add-planning-info', not through
text: CLOSED: is a *planning* line and has to sit between the heading and
its :PROPERTIES: drawer, which is org's rule to enforce rather than
ours.  Returns a summary string."
  (interactive)
  (let ((file (or file (claude-code-ide-org--capture-target-file)))
        (filled 0) (no-evidence 0) (already 0))
    (with-current-buffer (find-file-noselect file)
      (let ((buffer-read-only nil))
        (org-with-wide-buffer
         (goto-char (point-min))
         (while (re-search-forward org-heading-regexp nil t)
           (beginning-of-line)
           (let ((keyword (org-get-todo-state)))
             (when (member keyword org-done-keywords)
               (cond
                ((org-entry-get (point) "CLOSED") (setq already (1+ already)))
                (t (let ((time (claude-code-ide-org--recorded-close-time)))
                     (cond
                      ((null time) (setq no-evidence (1+ no-evidence)))
                      (t (setq filled (1+ filled))
                         (unless dry-run
                           (org-add-planning-info 'closed time)))))))))
           (end-of-line)))
        (when (and (not dry-run) (> filled 0))
          (save-buffer))))
    (format (concat "%s: %d filled from :LOGBOOK:, %d skipped (no recorded "
                    "close time), %d already had CLOSED:.%s")
            (file-name-nondirectory file) filled no-evidence already
            (if dry-run "  [dry run -- nothing written]" ""))))

;;; The meta-work day node (TODO.org :ID: 9575e65b)
;;
;; One function answers "which heading is the meta-work node for this
;; moment", computed when something needs the answer rather than run
;; ahead of time. Nothing stores the id and nothing schedules its
;; creation.
;;
;; *Dated from the event, never from "today"* -- option (c), decided by
;; the user 2026-08-21. The resolver runs at apply time, so it is pure
;; with respect to the queue and every write stays human-triggered; and
;; it takes its date from the timestamp the event already carries, so
;; work clocked at 23:00 Monday and applied Tuesday still lands on
;; Monday. That is the same principle `org-archive-subtree' follows in
;; filing by CLOSED rather than by archive time: file by when it
;; happened, not by when it was recorded.
;;
;; The rejected alternatives are worth knowing, because each looks
;; reasonable in isolation. Creating at *queue* time would hand Claude
;; the id inside the session, but breaks the invariant that a queued
;; tool changes nothing -- bought with a documented run of desync bugs
;; -- and mints a node even for a clock event the human later dismisses.
;; Creating at apply time dated "today" keeps the tools pure but files
;; Monday's work under Tuesday, which is the silent misattribution this
;; whole project exists to prevent.

(defconst claude-code-ide-org--day-node-format "%Y-%m-%d %A"
  "Title format for a datetree day node, matching org-datetree's own.")

(defun claude-code-ide-org--datetree-anchor-position ()
  "Move point to the `:DATE_TREE:' heading in this buffer; return it or nil.

Non-inherited, so only the heading that actually carries the property
answers -- an inherited lookup would make every descendant of the anchor
read as an anchor itself, which is the same mistake
`claude-code-ide-org--lint-file' guards against when tracking datetree
depth."
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (re-search-forward org-heading-regexp nil t))
      (beginning-of-line)
      (if (org-entry-get (point) "DATE_TREE")
          (setq found (point))
        (end-of-line)))
    (when found (goto-char found) found)))

(defun claude-code-ide-org-resolve-day-node (time &optional create)
  "Return the :ID: of the meta-work day node for TIME, or nil.

With CREATE non-nil the node is created if absent, stamped with a fresh
`:ID:' and a `:CREATED:' matching TIME, and the buffer saved.  Without
it nothing is written and nil means \"no node for that day yet\" -- which
is the answer the `SessionStart' side needs, since a session starting is
not evidence that any meta-work happened.

TIME is the *event's* timestamp, not the current time.  Passing
`current-time' here would reintroduce exactly the defect option (b) was
rejected for.

`:CREATED:' is stamped from TIME rather than from now, for the same
reason the node is: a node minted on Friday for Monday's work was
created, as a record, on Monday."
  (let ((file (claude-code-ide-org--capture-target-file)))
    (when (and file (file-readable-p file))
      (with-current-buffer (find-file-noselect file)
        (let ((buffer-read-only nil))
          (org-with-wide-buffer
           (when (claude-code-ide-org--datetree-anchor-position)
             (let* ((title (format-time-string
                            claude-code-ide-org--day-node-format time))
                    (existing (save-excursion
                                (claude-code-ide-org--find-day-node title))))
               (cond
                (existing (goto-char existing) (org-entry-get (point) "ID"))
                ((not create) nil)
                (t
                 ;; org's own idempotent find-or-create, scoped inside
                 ;; the anchor's subtree by `org-datetree-find-date-create's
                 ;; KEEP-RESTRICTION argument -- which is what makes the
                 ;; tree nest under the category instead of writing a
                 ;; second `* 2026' at level 1.
                 (org-narrow-to-subtree)
                 (require 'org-datetree)
                 (org-datetree-find-date-create
                  (list (nth 4 (decode-time time))
                        (nth 3 (decode-time time))
                        (nth 5 (decode-time time)))
                  'keep-restriction)
                 (let ((id (org-id-get-create)))
                   (org-entry-put (point) "CREATED"
                                  (format-time-string "[%Y-%m-%d %a %H:%M]" time))
                   (save-buffer)
                   id)))))))))))

(defun claude-code-ide-org--find-day-node (title)
  "Return the position of the day node titled TITLE under point's subtree.

Matched on the exact rendered title rather than by parsing dates back
out of headings: org-datetree writes one shape and this reads that same
shape, so the two cannot disagree about what a day node looks like."
  (save-excursion
    (org-narrow-to-subtree)
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (re-search-forward org-heading-regexp nil t))
        (beginning-of-line)
        (if (equal (org-get-heading t t t t) title)
            (setq found (point))
          (end-of-line)))
      (widen)
      found)))

(defun claude-code-ide-org--datetree-category-title ()
  "Return the title of the `:DATE_TREE:\' category, or nil when there is none."
  (let ((file (claude-code-ide-org--capture-target-file)))
    (when (and file (file-readable-p file))
      (with-current-buffer (find-file-noselect file)
        (org-with-wide-buffer
         (when (claude-code-ide-org--datetree-anchor-position)
           (substring-no-properties (org-get-heading t t t t))))))))

(defun claude-code-ide-org--day-node-target-p (target)
  "Non-nil when TARGET names the meta-work category rather than a heading.

The stable category *title* is the handle, deliberately: top-level
categories are few, human-curated and never move, which is the same risk
profile `claude-code-ide-org--capture-target-spec' already accepts a
title for.  It also means Claude never learns the daily UUID, which is
the point rather than a limitation -- a stored id is the thing that goes
stale, and there is nothing to update if nothing remembers."
  (and (stringp target)
       (let ((file (claude-code-ide-org--capture-target-file)))
         (and file (file-readable-p file)
              (with-current-buffer (find-file-noselect file)
                (org-with-wide-buffer
                 (and (claude-code-ide-org--datetree-anchor-position)
                      (equal (string-trim target)
                             (org-get-heading t t t t)))))))))

;;; Heading separation (TODO.org :ID: e1284bdb)
;;
;; Every heading's content ends with exactly two blank lines before the
;; next heading, which is what makes a *folded* outline readable: org
;; hides the blank line between a collapsed subtree and the following
;; headline unless there are at least `org-cycle-separator-lines' of
;; them, and that variable is 2 by default. So two blank lines in the
;; file buys exactly one visible line of air between folded headings,
;; and one blank line buys none.
;;
;; The number is not arbitrary and must not be "tidied" to one: at one,
;; the folded outline is a solid block of headlines with no grouping cue
;; at all, which is the state this repo was in -- 33% of TODO.org's
;; heading gaps conformed, and 9% of DONE.org's.

(defcustom claude-code-ide-org-heading-separator-lines 2
  "Blank lines to leave at the end of a heading, before the next one.

Defaults to 2 to match `org-cycle-separator-lines', which decides how
many are needed before org shows one of them in a folded outline.
Setting this below that variable makes the convention purely cosmetic in
the file and invisible where it was meant to be seen."
  :type 'integer
  :group 'claude-code-ide-org)

(defun claude-code-ide-org-normalize-heading-separation (&optional file dry-run)
  "Give every heading in FILE exactly N blank lines before the next one.

N is `claude-code-ide-org-heading-separator-lines'.  FILE defaults to
the archive target's source.  With DRY-RUN non-nil nothing is written.

Touches *only* the run of blank lines immediately preceding a heading.
Blank lines inside a body -- between paragraphs, inside a drawer, around
a source block -- are never counted or altered, because the region is
found by walking back from the next heading and stopping at the first
non-blank line.  That is the whole safety property: the edit cannot
reach text.

The final heading in the file is left alone.  There is no following
heading to separate it from, and normalising it would be a claim about
trailing whitespace at end of file rather than about outline
readability.

Returns a summary string."
  (interactive)
  (let ((file (or file (claude-code-ide-org--capture-target-file)))
        (want claude-code-ide-org-heading-separator-lines)
        (fixed 0) (already 0))
    (with-current-buffer (find-file-noselect file)
      (let ((buffer-read-only nil))
        (org-with-wide-buffer
         ;; Backwards, so each edit cannot shift the position of a
         ;; heading not yet visited.
         (goto-char (point-max))
         (let (heads)
           (while (re-search-backward org-heading-regexp nil t)
             (push (point) heads))
           ;; `heads' is now ascending; drop the first, which has no
           ;; predecessor to separate from, and walk the rest in reverse.
           (dolist (pos (nreverse (cdr heads)))
             (goto-char pos)
             (let ((end (point))
                   (blanks 0))
               (forward-line -1)
               (while (and (> (point) (point-min))
                           (string-empty-p (string-trim
                                            (buffer-substring-no-properties
                                             (line-beginning-position)
                                             (line-end-position)))))
                 (setq blanks (1+ blanks))
                 (forward-line -1))
               (forward-line 1)
               (if (= blanks want)
                   (setq already (1+ already))
                 (setq fixed (1+ fixed))
                 (unless dry-run
                   (delete-region (point) end)
                   (insert (make-string want ?\n))))))))
        (when (and (not dry-run) (> fixed 0))
          (save-buffer))))
    (format "%s: %d heading(s) re-separated, %d already had %d blank line(s).%s"
            (file-name-nondirectory file) fixed already want
            (if dry-run "  [dry run -- nothing written]" ""))))

;;; :ID: prefix expansion at the write boundary
;;
;; Nine fabricated UUIDs across two sessions (four on 2026-08-19, five on
;; 2026-08-25), every one with a correct 8-character prefix and a wrong
;; tail. A memory forbidding exactly this existed throughout and did not
;; prevent the second run of five.
;;
;; The reason it keeps happening is not carelessness about the rule. The
;; prefix is *reliably* remembered -- it is cited in prose constantly --
;; which makes the remaining 28 characters feel like part of the same
;; recollection. They are not, and nothing at the point of writing says
;; so.
;;
;; So this does not police the tail; it removes the need to produce one.
;; A link written `[[id:8ca6541d][8ca6541d]]' is expanded to the full
;; UUID on the way in. What the writer supplies is what they actually
;; know; what they cannot know is looked up. A full UUID that resolves to
;; nothing is refused outright, which catches the case where one was
;; typed anyway.
;;
;; Deliberately at the write boundary rather than at review or commit.
;; `bin/lint-org' already catches these, and did catch several -- but by
;; then the text is in the file, the fix is a second commit, and the
;; conversation that knew the right id has moved on.

(defconst claude-code-ide-org--id-link-regexp
  "\\[\\[id:\\([0-9a-fA-F][0-9a-fA-F-]*\\)\\]"
  "Matches the target of an `[[id:...]]' link, full or prefix.")


(defun claude-code-ide-org--id-scannable-files ()
  "Tracked files plus the archives they declare.

*An id is an id wherever it lives*, and `claude-code-ide-org--tracked-files'
answers a different question -- which files the agenda and the clock
reports cover. Those two were the same list until it mattered, and then
they were not.

TODO.org :ID: 020d3688: `org-agenda-files' is computed by scanning
`org-directory', and `~/org/claude-code-ide-org/' holds a symlink to
TODO.org *and nothing else* -- DONE.org was never linked. So the archive
was invisible to every consumer of `--tracked-files', and no id in it
resolved. Hit twice on 2026-08-26 by `org_amend' refusing a perfectly
good `[[id:b8e6007a]]' prefix, in a session that was documenting the
prefix convention at the time.

*Org's own `org-add-archive-files' does the derivation*, following each
file's `#+ARCHIVE:' and `:ARCHIVE:' declarations. This wrapper exists
only to undo its one side effect: it visits each file with
`org-get-agenda-file-buffer', which leaves real buffers behind, and this
runs on every `org_amend'. Buffers that were not already open are killed
again, matching what `--attention-headings-context' does and for the
same reason -- a tool call must not quietly populate the user's buffer
list.

A first version of this hand-rolled the derivation in about 35 lines,
before checking whether org had it. :ID: 0465c1d5 had named the right
family of mechanisms a month earlier -- `agenda-with-archives' and
`file-with-archives' -- and had even recorded the missing symlink as the
reason the archive was out of scope. Searching the tracker first would
have produced both the diagnosis and the tool."
  (require 'org-archive)
  (let* ((before (delq nil (mapcar #'buffer-file-name (buffer-list))))
         (files (org-add-archive-files (claude-code-ide-org--tracked-files))))
    (dolist (buf (buffer-list))
      (let ((name (buffer-file-name buf)))
        (when (and name (not (member name before))
                   (member (file-truename name)
                           (mapcar #'file-truename files)))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))))
    files))


(defun claude-code-ide-org--id-find (id &optional markerp)
  "Like `org-id-find\', but ID may be an 8-character prefix.

Every heading lookup in this file goes through here rather than calling
`org-id-find\' directly, and that indirection is the whole point.  The
first version of this fix expanded prefixes inside
`claude-code-ide-org--at-id\' only, and the commit message claimed it
therefore covered every tool taking an `id\' argument.  It did not:
`claude-code-ide-org-amend\' does its own `org-id-find\' *before*
reaching `--at-id\', so it failed on a prefix while `org_set_todo\'
accepted one -- found by using the feature minutes after shipping it.
Fourteen such call sites existed.

The length-and-hex guard runs before the table is built, so the common
case of a full uuid costs one `length\' call and no file scanning."
  (let ((prefix-unresolved nil))
   (when (and (stringp id)
              (<= claude-code-ide-org--id-prefix-minimum
                  (length id)
                  claude-code-ide-org--id-prefix-length)
              (string-match-p "\\`[0-9a-fA-F]+\\'" id))
    (let ((full (claude-code-ide-org--expand-id-prefix
                 id (claude-code-ide-org--id-index))))
      ;; Rescan once before giving up, naming our tracked files: an id
      ;; that arrived by hand edit or `git pull' is not in org's index
      ;; until something looks (TODO.org :ID: 020d3688).
      ;;
      ;; Only for `none'. An `ambiguous' prefix is not stale data --
      ;; rescanning can only ever find MORE matches, so it cannot help
      ;; and the scan is not cheap: it reads every tracked file and its
      ;; archives. Missing that distinction is what let a short prefix
      ;; spin the whole Emacs on 2026-08-27.
      (when (eq full 'none)
        (org-id-update-id-locations
         (claude-code-ide-org--id-scannable-files) t)
        (setq full (claude-code-ide-org--expand-id-prefix
                    id (claude-code-ide-org--id-index))))
      (if (stringp full)
          (setq id full)
        ;; Expansion was attempted and failed, so stop here rather than
        ;; handing `org-id-find' a bare prefix. It cannot match a full
        ;; uuid, and org's own miss path rescans every agenda file and
        ;; archive before returning nil -- a second full scan after the
        ;; one above, or a first one for an ambiguous prefix that no
        ;; amount of scanning can resolve.
        (setq prefix-unresolved t))))
   (unless prefix-unresolved
     (org-id-find id markerp))))

(defun claude-code-ide-org--id-index ()
  "Org's own id-to-file index, loaded if it is not already.

*This replaced a table of our own* (TODO.org :ID: 020d3688, 2026-08-27).
A `--known-id-table' re-read every tracked file from disk on *every*
`org_amend' to build a hash org already maintains in memory: 17.5 ms
against 0.57 us for a lookup, some 23,000x, to produce a strictly worse
answer.

Worse in three ways, each of which had cost something. It was built from
`--tracked-files', which is derived from `org-agenda-files' and so
silently omitted DONE.org -- the defect that made every id in the archive
unresolvable. Org's index has no such gap: `org-id-search-archives'
defaults to t, so archives are indexed as a matter of course. It knew
only ids matching a hex-shaped regexp. And it learned about a new heading
only on the next full re-read, where org's is updated by
`org-id-add-location' at the moment `org-id-get-create' runs.

Measured before switching: org's index is a strict *superset* -- nothing
in the hand-built table was missing from it, and it carried one id ours
did not (a fixture in `clock-template.org'). All 276 keys are lowercase,
so prefix matching needs no normalisation.

*The lesson is the one 0465c1d5 had already recorded and nobody read*:
this project keeps rebuilding org machinery beside org rather than on
it, and the rebuilt version is where the gaps live."
  (require 'org-id)
  (unless (and (bound-and-true-p org-id-locations)
               (hash-table-p org-id-locations))
    (org-id-locations-load))
  (and (hash-table-p org-id-locations) org-id-locations))

(defun claude-code-ide-org--expand-id-prefix (prefix table)
  "Return the single full :ID: in TABLE beginning with PREFIX, or a symbol.

`none' when nothing matches and `ambiguous' when more than one does.
Both are errors rather than guesses: an id chosen from two candidates is
the confidently-wrong record this project exists to avoid."
  (let (hits)
    (when table
      (maphash (lambda (id _) (when (string-prefix-p (downcase prefix) id)
                                (push id hits)))
               table))
    (cond ((null hits) 'none)
          ;; The candidates travel with the verdict. A short prefix is
          ;; ambiguous often enough that "try again" is a poor answer
          ;; when the tool is holding the very list you need to pick
          ;; from -- and lengthening a prefix blind is how a wrong tail
          ;; gets invented, which is the failure :ID: 478d6ec9 exists to
          ;; stop.
          ((cdr hits) (cons 'ambiguous (sort hits #'string<)))
          (t (car hits)))))

(defun claude-code-ide-org-resolve-id-links (text)
  "Return TEXT with `[[id:PREFIX]' links expanded, or an error string.

An 8-character prefix is expanded to the full :ID:.  A longer target is
verified and left alone.  Either way an unresolvable target is refused,
naming it, rather than written and caught later by `bin/lint-org'.

Returns a cons (t . EXPANDED) on success, or (nil . MESSAGE)."
  (let ((table (claude-code-ide-org--id-index))
        (rescanned nil)
        (case-fold-search t)
        (bad nil)
        (start 0)
        (out text))
    (while (string-match claude-code-ide-org--id-link-regexp out start)
      (let* ((target (match-string 1 out))
             (mb (match-beginning 1))
             (me (match-end 1))
             ;; The WHOLE match, not group 1. Restarting the scan at
             ;; `mb' would resume *inside* `[[id:', where the regexp
             ;; cannot match again -- so the loop would end early with
             ;; no error and an unresolvable link would be accepted
             ;; silently. Caught by the refuses-rather-than-guesses
             ;; test, which is exactly the failure it was written for.
             (m0 (match-beginning 0)))
        (setq start me)
        (cond
         ;; Already a full id that resolves: leave it.
         ((and table (gethash (downcase target) table)) nil)
         ;; A bare prefix: expand it.
         ((not (string-match-p "-" target))
          (let ((full (claude-code-ide-org--expand-id-prefix target table)))
            (cond
             ((stringp full)
              (setq out (concat (substring out 0 mb) full (substring out me)))
              (setq start (+ mb (length full))))
             ((eq (car-safe full) 'ambiguous)
              (push (format "%s (matches %d headings: %s)"
                            target (length (cdr full))
                            (mapconcat #'claude-code-ide-org--id-prefix
                                       (cdr full) " "))
                    bad))
             ;; Rescan once before refusing, exactly as `org-id-find'
             ;; does: org's index is updated in memory when a heading is
             ;; created *here*, but an id that arrived by `git pull' or
             ;; from another Emacs is unknown until something rescans.
             ;; Refusing a real id teaches the writer to stop using the
             ;; convention, which is how the last gap went unreported for
             ;; weeks (TODO.org :ID: 020d3688).
             ((not rescanned)
              (setq rescanned t)
              ;; Pass our own file list explicitly. Org rescans agenda
              ;; files, their archives and open buffers; this project's
              ;; tracked set is `claude-code-ide-org-query-files' when
              ;; that is set, which need not be any of those. Naming
              ;; them makes org's index a superset of ours by
              ;; construction rather than by coincidence.
              (org-id-update-id-locations
               (claude-code-ide-org--id-scannable-files) t)
              (setq table (claude-code-ide-org--id-index))
              (setq start m0))
             (t (push (format "%s (matches no heading)" target) bad)))))
         ;; A full-looking id that resolves to nothing: refuse.
         (t (push (format "%s (resolves to no heading)" target) bad)))))
    (if bad
        (cons nil (format "Error: unresolvable :ID: link(s): %s. \
Write the 8-character prefix -- [[id:eaeeb4ee][eaeeb4ee]] -- and it is expanded here."
                          (string-join (nreverse bad) "; ")))
      (cons t out))))

(with-eval-after-load 'claude-code-ide

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-wrap-plan
   :name "org_wrap_plan"
   :description (concat
                 "Wrap the prospective part of a heading's body in a :PLAN: "
                 "drawer, leaving the debrief as the body. Call this at the "
                 "moment a task is carried out: the planning content moves "
                 "beside :PROPERTIES: and :LOGBOOK: so a folded heading shows "
                 "the debrief alone. Writes immediately. Lossless -- two "
                 "insertions, nothing deleted or reflowed, and the reply says "
                 "whether the text was preserved. Refuses rather than guesses: "
                 "a heading that already has a :PLAN: drawer, a heading with no "
                 "body, and an `until' marker that is missing or appears more "
                 "than once are all errors. Use org_amend afterwards to add "
                 "debrief prose; it appends below the drawer.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the heading to wrap.")
           (:name "until"
            :type string
            :optional t
            :description "Literal text identifying the first body line that should STAY in the body, i.e. where the debrief begins. Must occur exactly once. Omit to wrap the whole body, which is right when the body is still purely prospective; supply it for a body written before this convention existed, which usually already holds both halves.")))

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
            :description "The :ID: property value of the target org heading. For cross-cutting meta-work -- review, planning, deciding what to do rather than doing it -- pass the exact title of the meta-work category (\"Review and planning\") instead of an :ID:, and the interval is filed against that day\'s node in its datetree. The day node is created when the event is applied and dated from this event, so a late apply still files the work under the day it happened. There is deliberately no way to learn the day node\'s own :ID:; the category title is the handle.")
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
                 "from DOING (to DONE, WAITING, or CANCELLED). Takes no id -- it "
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
                 "REVIEW WAITING MAYBE DONE CANCELLED. REVIEW is EXPERIMENTAL "
                 "(TODO.org :ID: c954f650): it means work is finished and "
                 "handed back to the human for judgement, as distinct from "
                 "WAITING, which means blocked on someone else. Use it where you "
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
            :description "TODO keyword to set: TODO NEXT PLANNING DOING REVIEW WAITING MAYBE DONE CANCELLED.")
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
                 "transition for review so org logs it natively. "
                 "Omit it to prepend at the top of the capture file. "
                 "Category is a :CATEGORY: property now, not a heading, so there is "
                 "nothing to file under by that name. "
                 "Returns a confirmation containing the "
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
            :description "Optional. An :ID: to file the new heading under that one. Omit it to prepend at the top of the capture file, which is where a task belongs since the level-1 category tier was retired. A category TITLE is no longer accepted -- categories are :CATEGORY: property values, not headings.")
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
                 "conflict detection. "
                 "With replace=true it REVISES instead: the body's prose is "
                 "replaced wholesale by the new text. Use that when a body "
                 "has become a transcript — when a correction, or the "
                 "outcome, belongs at the top rather than buried under "
                 "everything it supersedes. It rewrites only the prose below "
                 "every drawer, so :PROPERTIES:, :LOGBOOK: and a :PLAN: "
                 "drawer are outside the region it can write to and cannot be "
                 "destroyed. COMMIT FIRST: git is the undo, and it is the "
                 "only one.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the heading to amend.")
           (:name "text"
            :type string
            :description "The prose block. Appended by default; with replace=true it becomes the body's entire prose.")
           (:name "note"
            :type string
            :optional t
            :description "Short 3-10 word reason for the amendment, recorded on the queued event when the write defers.")
           (:name "replace"
            :type boolean
            :optional t
            :description "Replace the body's prose instead of appending to it. Destructive and irreversible except through git, so commit before using it. Drawers are never touched. On a heading with no body yet it simply appends, and says so.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-query
   :name "org_query"
   :description (concat
                 "Search org-mode headings across "
                 "`claude-code-ide-org-query-files' (or org-agenda-files) using "
                 "org-ql's plain-string query syntax. Predicates: todo:KEYWORD "
                 "(e.g. todo:WAITING), tags:TAG1,TAG2 (comma = OR), priority:A, "
                 "heading:\"text\". Prefix any predicate with ! to negate it "
                 "(e.g. !todo:DONE). Separate predicates with spaces to combine "
                 "with AND, e.g. \"todo:NEXT tags:code\". Returns one line per "
                 "match: TODO state, heading, tags, :ID:, and file — or a "
                 "message if nothing matches. Prefer this over reading whole "
                 "files for cross-file questions like what's blocked or what "
                 "changed this week.")
   :args '((:name "query"
            :type string
            :description "org-ql plain-string query, e.g. \"todo:WAITING\", \"tags:research,code\", \"priority:A\", \"!todo:DONE\".")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-outline
   :name "org_outline"
   :description (concat
                 "Compact structural index of tracked org files: one line per "
                 "heading with its level (by indent), TODO keyword, title, "
                 ":ID:, and tags. A whole-file listing is grouped under its "
                 ":CATEGORY: values, each a bare header line with its tasks "
                 "indented beneath. Marks [blocked: id ...] naming the "
                 "unfinished blockers, and [blocked?: id ...] naming ones "
                 "that cannot be resolved. Scoped to a slice, it also lists "
                 "the slice's members as -> references. Read-only. "
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
           (:name "sort_type"
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
