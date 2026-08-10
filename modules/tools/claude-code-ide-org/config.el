;;; tools/claude-code-ide-org/config.el -*- lexical-binding: t; -*-
;;
;; MCP tool wrappers exposing org-mode clock, state, and archive
;; operations to Claude Code via claude-code-ide.
;;
;; All tools locate headings by their :ID: property, which means every
;; heading Claude is expected to act on must have one.  Add IDs with
;; M-x org-id-get-create, or configure org-id-link-to-org-use-id so
;; they are created automatically on link creation.

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
  "When non-nil, check for open CLOCK/:SESSIONS: intervals left
over from a previous day (e.g. after a crash or system shutdown
prevented the Stop hook from pausing them) and report them via the
SessionStart hook so Claude can ask you for the actual stop time."
  :type 'boolean
  :group 'claude-code-ide-org)

(defcustom claude-code-ide-org-working-hours '(9 . 18)
  "Cons of (START-HOUR . END-HOUR), 24-hour clock, your normal
working hours.  Used only to inform the educated guess offered when
recovering a stale open interval: absent a better signal, the guess
defaults to the end of working hours on the day the interval opened."
  :type '(cons integer integer)
  :group 'claude-code-ide-org)

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
;; variable for how nested calls (e.g. session-pause calling the
;; clock-out wrapper) compose without one clobbering the other's
;; attribution.
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
from another wrapper (e.g. `claude-code-ide-org-session-pause' calling
`claude-code-ide-org-clock-out') keeps the outer, more specific
attribution instead of the inner call clobbering it.")

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
;; - The :SESSIONS: drawer (this module's own, separate from :LOGBOOK:)
;;   is the bracketing history: a plain timestamped log of every pause
;;   and resume, so the full wall-clock arc of the task — including the
;;   gaps — stays visible even though the CLOCK entries themselves no
;;   longer cover it.

(defun claude-code-ide-org--append-to-drawer (drawer-name line)
  "Append LINE to the :DRAWER-NAME: drawer of the heading at point.
Creates the drawer immediately after the heading's planning line
and property drawer if it does not already exist.  Adapted from
org-clock.el's own `org-clock-find-position', which solves the same
find-or-create-drawer problem for :LOGBOOK:."
  (org-back-to-heading t)
  (let* ((beg (line-beginning-position))
         (end (save-excursion (outline-next-heading) (point)))
         (drawer-re (concat "^[ \t]*:" (regexp-quote drawer-name) ":[ \t]*$"))
         found)
    (goto-char beg)
    (while (and (not found) (re-search-forward drawer-re end t))
      (let ((element (org-element-at-point)))
        (when (org-element-type-p element 'drawer)
          (goto-char (or (org-element-contents-end element) (line-end-position)))
          (unless (bolp) (insert "\n"))
          (insert line "\n")
          (setq found t))))
    (unless found
      (goto-char beg)
      (org-end-of-meta-data)
      (unless (bolp) (insert "\n"))
      (insert ":" drawer-name ":\n" line "\n:END:\n"))))

(defvar claude-code-ide-org--log-session-id nil
  "Dynamically let-bound around `claude-code-ide-org-session-pause'/
`-resume's body to the calling Claude Code session's session-id
string, when known, so `claude-code-ide-org--log-session-event' can
record which session paused/resumed a clock. Left nil for a manual/
test call or any invocation with no session context — the :SESSIONS:
line is then written exactly as it always was, with no session
suffix. Same dynamic-binding convention as `claude-code-ide-org--log-
source' above, for the same reason: composes correctly if one of
these wrappers is ever called from inside another.")

(defvar claude-code-ide-org--clock-owner-session-id nil
  "Session ID of the Claude Code session whose turn boundary most
recently opened the currently-running clock via
`claude-code-ide-org-session-resume', or nil if unknown/not session-
aware. Consulted by `claude-code-ide-org-session-pause'/`-resume' to
avoid pausing or stealing another session's actively-running clock —
see the commentary on those two functions for the concurrency bug this
guards against (TODO.org :ID: 337f7fb2-b9e9-4c02-82dd-d88e60df364b).
Cleared whenever `claude-code-ide-org-session-pause' actually closes a
clock, so a later pause/resume with no matching session context falls
back to the original unconditional behavior — the correct default for
the ordinary single-session case, not merely a stopgap. Purely
in-memory: resets naturally on Emacs restart, which is fine since a
fresh Emacs never has a clock already running.")

(defvar claude-code-ide-org--planning-owner-session-id nil
  "Session ID of the Claude Code session that most recently set a
heading to PLANNING via `claude-code-ide-org-set-todo', or nil if
unknown/not session-aware. Consulted by
`claude-code-ide-org--promote-planning-to-doing' so that one session's
`ExitPlanMode' never promotes a different, concurrent session's
still-in-progress PLANNING heading purely because it happens to own
the single global clock (TODO.org :ID:
b95b9fba-f78e-48fe-8546-988709cce309). Same single-global-value shape
as `claude-code-ide-org--clock-owner-session-id' — org only ever has
one running clock, so \"last session to set PLANNING\" is all that's
meaningful. Cleared after a successful promotion. Purely in-memory:
resets naturally on Emacs restart.")

(defun claude-code-ide-org--log-session-event (event)
  "Append a timestamped EVENT line to the :SESSIONS: drawer of the
heading at point.  EVENT is a short label such as \"Resumed\" or
\"Paused\".  Appends the session-id from the dynamically-bound
`claude-code-ide-org--log-session-id', in parentheses, when it is
non-nil."
  (claude-code-ide-org--append-to-drawer
   "SESSIONS"
   (format "- %s %s%s" event (format-time-string "[%Y-%m-%d %a %H:%M]")
           (if claude-code-ide-org--log-session-id
               (format " (session %s)" claude-code-ide-org--log-session-id)
             ""))))

;;; Wrappers --------------------------------------------------------------

(defun claude-code-ide-org-clock-in (id &optional note)
  "Clock in to the org heading whose :ID: property equals ID.

NOTE is a short (3-10 word) description of what is being started. It is
deliberately *unused here*: its only job is to ride the tool call into
the event queue, where `bin/hooks/queue-append' reads it off
`tool_input' and the review-and-apply command later spends it (TODO.org
:ID: 32272061-1d78-4726-b13b-90338edb2ba5). Accepting and ignoring it is
the point -- writing it into the live buffer now would produce exactly
the unreviewed record the queue design exists to avoid, and there is no
correct place for it in a :LOGBOOK: until a human confirms the interval
it belongs to. See clock-template.org for the conventions it feeds.
Opens a new CLOCK entry in the heading's LOGBOOK drawer and starts
the Emacs clock timer.  Also logs a \"Resumed\" entry to the
heading's :SESSIONS: drawer.  Saves every buffer touched: `org-clock-in'
auto-closes whatever clock was already running first, which mutates
*that* heading's buffer too when it lives in a different file than the
one being clocked into — the same bug shape that already bit
`claude-code-ide-org-archive' and `claude-code-ide-org-clock-out'
(reporting success while a modified buffer went unsaved)."
  (let ((claude-code-ide-org--log-source (or claude-code-ide-org--log-source "org_clock_in")))
    (claude-code-ide-org--at-id
     id
     (lambda ()
       (let ((heading (org-get-heading t t t t))
             (previous-buffer (and (org-clocking-p) (marker-buffer org-clock-marker))))
         (org-clock-in)
         (claude-code-ide-org--log-session-event "Resumed")
         (save-buffer)
         (when (and previous-buffer
                    (buffer-live-p previous-buffer)
                    (not (eq previous-buffer (current-buffer))))
           (with-current-buffer previous-buffer
             (save-buffer)))
         (format "Clocked in: \"%s\"" heading))))))

(defconst claude-code-ide-org--minimum-clock-seconds 60
  "Shortest interval a CLOCK line is allowed to record, in seconds.

One minute, because that is the finest distinction a CLOCK timestamp can
express: `[2026-08-10 Mon 12:46]--[2026-08-10 Mon 12:46]' is what a
forty-second span looks like written down, and it reads as `=>  0:00' --
which a clocktable sums as nothing at all, reporting no activity for
activity that did happen.

This is a deliberate policy, not arithmetic: enforcing the floor invents
up to fifty-nine seconds that did not elapse.  The trade is accepted
because the alternative misreports short work as zero, and because a
minute is already the resolution of the record -- there is no honest way
to write down less.  Confined to the write path so it is applied once,
where the interval is created, and never re-applied to history.")

(defun claude-code-ide-org--clock-out-floor-time ()
  "Return the end time to clock out at, honouring the one-minute floor.

Nil -- meaning \"now\", org's own default -- unless clocking out this
instant would record an interval shorter than
`claude-code-ide-org--minimum-clock-seconds', in which case return the
start time plus that minimum.

Passed to `org-clock-out's own AT-TIME argument rather than fixing up
the CLOCK line afterwards.  Every previous attempt in this module to
adjust an interval by editing drawer text after the fact has eventually
destroyed something (TODO.org :ID:s ba8249c1, b74e0f19); handing org the
end time up front means org writes a correct line the first time and
there is nothing to repair."
  (let ((start (and (org-clocking-p) org-clock-start-time)))
    (when start
      (let ((elapsed (float-time (time-subtract (current-time) start))))
        (when (< elapsed claude-code-ide-org--minimum-clock-seconds)
          (time-add start (seconds-to-time
                           claude-code-ide-org--minimum-clock-seconds)))))))

(defun claude-code-ide-org-clock-out (&optional note)
  "Clock out of the currently running org clock.

NOTE is carried for the event queue and otherwise unused here -- see
`claude-code-ide-org-clock-in' for why that is deliberate.

On success the returned string names the closed heading's :ID: as
\"Clocked out: \\\"HEADING\\\" (id: ID)\".  This tool takes no id
argument -- the running clock is the only thing that can say which
heading is being closed -- so without it the queue event written by
`bin/hooks/queue-append' has a null id and a clock_out read in isolation
cannot name its heading.  Reporting the id the clock *actually* closed
is authoritative in a way a caller-supplied argument would not be: it
cannot disagree with what happened.  The \"Clocked out:\" prefix is
unchanged, which is all `bin/clock-notify' matches on.
Closes the open CLOCK entry with an end timestamp and computes the
duration, never recording less than
`claude-code-ide-org--minimum-clock-seconds' — see
`claude-code-ide-org--clock-out-floor-time'.  Also logs a \"Paused\"
entry to the heading's :SESSIONS: drawer.  Saves the buffer.  Safe to
call when no clock is running.

Deliberately does NOT consolidate afterwards any more.  It used to,
so drawers stayed collapsed on the fly rather than accumulating
per-turn churn.  That rewrote the whole drawer on every clock-out,
which destroyed a reviewed, human-confirmed interval roughly five
minutes after apply wrote it (TODO.org :ID:
b74e0f19-5a26-4c83-9d70-8e1c5a2f6b04), and had silently deleted
non-CLOCK lines before that (:ID: ba8249c1).  Rewriting an entire
drawer as a side effect of closing one interval is a large blast
radius for a cosmetic benefit, and the churn it existed to suppress
goes away with the queue refactor.  `claude-code-ide-org-consolidate-history'
remains available to call deliberately."
  (let ((claude-code-ide-org--log-source (or claude-code-ide-org--log-source "org_clock_out")))
    (condition-case err
        (if (not (org-clocking-p))
            "No clock is currently running."
          (let ((heading org-clock-heading)
                (buffer (marker-buffer org-clock-marker))
                id)
            (org-with-point-at org-clock-marker
              (claude-code-ide-org--log-session-event "Paused")
              (setq id (org-entry-get nil "ID")))
            ;; org-clock-out-remove-zero-time-clocks (t in this user's
            ;; Doom config, not this project's own setting) deletes the
            ;; CLOCK line outright when the interval reads as zero.
            ;; Suppressed for this call only -- never globally, since a
            ;; human's own interactive org-clock-out should keep org's
            ;; normal behavior. Belt and braces alongside the floor
            ;; below: with a minimum of one minute nothing should reach
            ;; org as zero-length anyway, but a deletion is unrecoverable
            ;; and the binding costs nothing.
            (let ((org-clock-out-remove-zero-time-clocks nil))
              (org-clock-out nil nil (claude-code-ide-org--clock-out-floor-time)))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (save-buffer)))
            (if id
                (format "Clocked out: \"%s\" (id: %s)" heading id)
              (format "Clocked out: \"%s\"" heading))))
      (error (format "Error: %s" (error-message-string err))))))

(defun claude-code-ide-org-session-pause (&optional session-id)
  "Pause the running clock, if any, unless it's owned by a different
Claude Code session than SESSION-ID.  Alias for
`claude-code-ide-org-clock-out', intended to be called directly
via `emacsclient -e' (not registered as an MCP tool) by a Stop
hook, so a task automatically pauses the moment Claude finishes
responding and control returns to the user.

SESSION-ID nil (the default — a manual/test call, or a Claude Code
version whose hook payload omits it) reproduces the exact original
unconditional behavior: always pauses whatever clock is running,
regardless of which session, if any, opened it.  That is the correct
fallback for the ordinary single-session case, not merely a stopgap.

When SESSION-ID is given and does not match
`claude-code-ide-org--clock-owner-session-id' (and an owner IS
recorded), this is a no-op that leaves the other session's running
clock untouched, rather than pausing work that isn't this session's to
pause.  On an actual pause, clears the owner variable, so a later
pause with no session context — or once the clock has moved on to
something else entirely — falls back to the permissive default above."
  (let ((claude-code-ide-org--log-source (or claude-code-ide-org--log-source "session-pause"))
        (claude-code-ide-org--log-session-id (or claude-code-ide-org--log-session-id session-id)))
    (if (and session-id
             claude-code-ide-org--clock-owner-session-id
             (not (equal session-id claude-code-ide-org--clock-owner-session-id)))
        "Clock is owned by a different session; not pausing."
      (prog1 (claude-code-ide-org-clock-out)
        (setq claude-code-ide-org--clock-owner-session-id nil)))))

(defun claude-code-ide-org--clock-history-head-done-p ()
  "Non-nil if the most recently clocked-out task in
`org-clock-history' is now in a DONE-type (terminal) TODO state —
e.g. it was marked DONE or CANCELLED after being paused, before the
next `org-clock-in-last' call had a chance to resume it.  This is
what `claude-code-ide-org-session-resume' checks to avoid reopening
a clock on a task that has already finished."
  (let ((marker (car org-clock-history)))
    (and marker (marker-buffer marker)
         (org-with-point-at marker
           (org-entry-is-done-p)))))

(defun claude-code-ide-org-session-resume (&optional session-id)
  "Resume clocking on the most recently paused task, if any, via
`org-clock-in-last'.  Intended to be called directly via
`emacsclient -e' (not registered as an MCP tool) by a
UserPromptSubmit hook, so a paused task resumes the moment the
user sends the next prompt.  Safe to call when already clocking,
when there is no clock history to resume, or when the most
recently paused task has since reached a DONE-type state — all
three are no-ops.  The DONE-type check matters because marking a
task DONE closes its clock and pushes it onto `org-clock-history'
just like an ordinary pause does; without the check, any later
turn boundary with nothing else to resume would silently reopen a
clock on that already-finished heading.  If the resumed task turns
out to be the wrong *active* one instead (the user's next prompt is
about something else entirely), the existing org_clock_in tool
self-corrects: org-clock-in always closes whatever clock is
currently running before opening a new one, so the mistaken resume
just leaves a short, low-cost stray CLOCK interval on the wrong
heading rather than silently losing time or blocking anything.

SESSION-ID nil (the default) reproduces the exact original
unconditional behavior.  When SESSION-ID is given and a clock is
already running that's owned by a *different* session
(`claude-code-ide-org--clock-owner-session-id'), this is an
additional no-op — don't steal another session's actively-running
clock just because this session's turn boundary happened to arrive.
On an actual resume, records SESSION-ID as the new owner (nil if this
call itself has no session context, which is exactly correct: a later
pause/resume with no session context should still behave as before)."
  (let ((claude-code-ide-org--log-source (or claude-code-ide-org--log-source "session-resume"))
        (claude-code-ide-org--log-session-id (or claude-code-ide-org--log-session-id session-id)))
    (condition-case err
        (cond
         ((and (org-clocking-p)
               session-id
               claude-code-ide-org--clock-owner-session-id
               (not (equal session-id claude-code-ide-org--clock-owner-session-id)))
          "Clock is owned by a different session; not resuming.")
         ((org-clocking-p) "Already clocking; nothing to resume.")
         ((null org-clock-history) "No paused task to resume.")
         ((claude-code-ide-org--clock-history-head-done-p)
          "Most recently paused task is already DONE; nothing to resume.")
         (t
          (org-clock-in-last)
          (if (not (org-clocking-p))
              "org-clock-in-last did not start a clock."
            (org-with-point-at org-clock-marker
              (claude-code-ide-org--log-session-event "Resumed"))
            (setq claude-code-ide-org--clock-owner-session-id session-id)
            (let ((buffer (marker-buffer org-clock-marker)))
              (when (buffer-live-p buffer)
                (with-current-buffer buffer (save-buffer))))
            (format "Resumed: \"%s\"" org-clock-heading))))
      (error (format "Error: %s" (error-message-string err))))))

;;; Stale interval recovery --------------------------------------------------
;;
;; org-clock-persist is set to `history' (not `t'/`clock') in this
;; project's Doom config, so a crash or restart does NOT auto-resume
;; the in-memory clock state — meaning an open interval left by a
;; crash can only be found by scanning the actual TEXT of tracked org
;; files for an unclosed CLOCK line or an unclosed "Resumed" :SESSIONS:
;; entry, never by checking org-clocking-p.  Checked at the start of
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

(defun claude-code-ide-org--guess-stop-time (start-time)
  "Educated guess for when work actually stopped, given the open
interval's START-TIME, based on `claude-code-ide-org-working-hours'.
Defaults to the end of working hours on the day work started;
clamped to at least an hour after START-TIME if that would
otherwise put the guess before the interval even opened."
  (let* ((decoded (decode-time start-time))
         (end-hour (cdr claude-code-ide-org-working-hours))
         (guess (encode-time 0 0 end-hour
                              (nth 3 decoded) (nth 4 decoded) (nth 5 decoded))))
    (if (time-less-p guess start-time)
        (time-add start-time 3600)
      guess)))

(defun claude-code-ide-org--entry-open-interval ()
  "If the entry at point has an open CLOCK line and/or an unclosed
:SESSIONS: \"Resumed\" entry, return a plist (:logbook-open
TIME-OR-NIL :sessions-open TIME-OR-NIL).  Both nil means nothing is
open here.  Does not rely on org-clocking-p — see commentary above."
  (let ((end (save-excursion (outline-next-heading) (point)))
        logbook-open sessions-open)
    (save-excursion
      (when (re-search-forward "^[ \t]*CLOCK: \\(\\[[^]]+\\]\\)[ \t]*$" end t)
        (setq logbook-open (claude-code-ide-org--parse-org-timestamp (match-string 1)))))
    (save-excursion
      (let (last-event last-ts)
        (while (re-search-forward "^[ \t]*- \\(Resumed\\|Paused\\) \\(\\[[^]]+\\]\\)" end t)
          (setq last-event (match-string 1) last-ts (match-string 2)))
        (when (equal last-event "Resumed")
          (setq sessions-open (claude-code-ide-org--parse-org-timestamp last-ts)))))
    (when (or logbook-open sessions-open)
      (list :logbook-open logbook-open :sessions-open sessions-open))))

(defun claude-code-ide-org-find-stale-open-intervals ()
  "Scan `claude-code-ide-org--tracked-files' for open CLOCK/:SESSIONS:
intervals whose open timestamp predates today.  Returns nil if
`claude-code-ide-org-session-recovery-enabled' is nil.  Otherwise a
list of plists: (:id ID :heading HEADING :file FILE :logbook-open
TIME-OR-NIL :sessions-open TIME-OR-NIL :guess TIME)."
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
                   (let* ((lb (plist-get interval :logbook-open))
                          (se (plist-get interval :sessions-open))
                          (earliest (cond ((and lb se) (if (time-less-p lb se) lb se))
                                          (lb lb)
                                          (t se))))
                     (unless (claude-code-ide-org--today-p earliest)
                       (push (list :id id
                                   :heading (org-get-heading t t t t)
                                   :file file
                                   :logbook-open lb
                                   :sessions-open se
                                   :guess (claude-code-ide-org--guess-stop-time earliest))
                             results))))))
             "ID={.}" 'file))))
      (nreverse results))))

(defun claude-code-ide-org--format-stale-interval-report (findings)
  "Format FINDINGS (as returned by
`claude-code-ide-org-find-stale-open-intervals') into a plain-text
report for Claude to relay to the user as a question."
  (mapconcat
   (lambda (f)
     (format (concat "\"%s\" (:ID: %s, in %s) has an unclosed %s open since "
                      "%s that was never paused — most likely a crash or "
                      "system shutdown before Claude Code's Stop hook could "
                      "close it. Ask the user what time they actually "
                      "stopped work that day; offer this educated guess "
                      "(based on working hours %d:00–%d:00): %s. Once "
                      "confirmed or corrected, call claude-code-ide-org-close-open-interval "
                      "via emacsclient with that timestamp.")
             (plist-get f :heading) (plist-get f :id)
             (file-name-nondirectory (plist-get f :file))
             (cond ((and (plist-get f :logbook-open) (plist-get f :sessions-open))
                    "CLOCK entry and :SESSIONS: interval")
                   ((plist-get f :logbook-open) "CLOCK entry")
                   (t ":SESSIONS: interval"))
             (format-time-string "%Y-%m-%d"
                                  (or (plist-get f :logbook-open) (plist-get f :sessions-open)))
             (car claude-code-ide-org-working-hours) (cdr claude-code-ide-org-working-hours)
             (format-time-string "[%Y-%m-%d %a %H:%M]" (plist-get f :guess))))
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

(defun claude-code-ide-org--wait-headings-context ()
  "Return a list of one-line descriptions, one per WAIT-state
heading found across `claude-code-ide-org--tracked-files', or nil if
none. Scans each tracked file via `find-file-noselect'; any buffer
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
  (let (results)
    (dolist (file (claude-code-ide-org--tracked-files))
      (when (file-exists-p file)
        (let* ((already-open (find-buffer-visiting file))
               (buffer (or already-open (find-file-noselect file))))
          (with-current-buffer buffer
            (org-map-entries
             (lambda ()
               (when (equal (org-get-todo-state) "WAIT")
                 (push (format "WAIT: \"%s\" (:ID: %s, in %s)"
                               (org-get-heading t t t t)
                               (or (org-entry-get nil "ID") "none")
                               (file-name-nondirectory file))
                       results)))
             nil 'file))
          (unless already-open
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))
    (nreverse results)))

(defun claude-code-ide-org-session-context ()
  "Return a plain-text summary of \"what was I last doing\": the
currently clocked-in heading, if any, followed by one line per
WAIT-state heading across `claude-code-ide-org--tracked-files'.
Returns the empty string when there is nothing to report (no clock
running and no WAIT headings), so callers can treat an empty result
as \"nothing worth injecting\"."
  (let* ((clocked (claude-code-ide-org--clocked-heading-context))
         (waits (claude-code-ide-org--wait-headings-context))
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

(defun claude-code-ide-org--statusline-task-string ()
  "Return a short, pre-formatted description of the \"current default
org task\" for the statusLine, or the empty string if there is
neither a running clock nor any clock history to fall back to. Uses
the currently-running clock's marker if `org-clocking-p', else `(car
org-clock-history)'. The :ID: is truncated to 8 characters and the
heading name to 30 (with an ellipsis), matching a git-commit-style
short hash. Total clocked time is summed over the heading's whole
subtree via `org-clock-sum', matching `org_clock_report''s own
:ID:-scoped behavior."
  (let ((marker (if (org-clocking-p) org-clock-marker (car org-clock-history))))
    (if (not (and marker (markerp marker) (marker-buffer marker)))
        ""
      (org-with-point-at marker
        (let* ((id (or (org-entry-get nil "ID") ""))
               (short-id (if (> (length id) 8) (substring id 0 8) id))
               (name (org-get-heading t t t t))
               (short-name (if (> (length name) 30)
                               (concat (substring name 0 29) "…")
                             name))
               (status-label (if (org-clocking-p) "clocked in" "clocked out"))
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
  "Close whatever open CLOCK/:SESSIONS: interval exists on the
heading whose :ID: equals ID, using TIMESTAMP-STRING (an org
timestamp string, e.g. \"[2026-07-27 Mon 17:45]\") as the recovered
stop time.  Closes an open CLOCK line (computing its duration) and/or
appends a \"Paused ... (recovered)\" :SESSIONS: entry, whichever is
actually open.  Consolidates the heading's now-closed history
afterward, same as `claude-code-ide-org-clock-out' — see that
function's docstring for why this can never itself error here.
Saves the buffer.  Does not touch the live clock — this is purely a
text-level fix for a stale interval, not related to whatever (if
anything) is currently clocking."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (let ((end (save-excursion (outline-next-heading) (point)))
           (stop-time (claude-code-ide-org--parse-org-timestamp timestamp-string))
           closed-logbook closed-sessions)
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
       (save-excursion
         (let (last-event)
           (while (re-search-forward "^[ \t]*- \\(Resumed\\|Paused\\) \\[" end t)
             (setq last-event (match-string 1)))
           (when (equal last-event "Resumed")
             (claude-code-ide-org--append-to-drawer
              "SESSIONS" (format "- Paused %s (recovered)" timestamp-string))
             (setq closed-sessions t))))
       (save-buffer)
       (when (or closed-logbook closed-sessions)
         (claude-code-ide-org-consolidate-history id))
       (cond
        ((and closed-logbook closed-sessions)
         (format "Closed open CLOCK and :SESSIONS: interval on \"%s\" at %s"
                 (org-get-heading t t t t) timestamp-string))
        (closed-logbook
         (format "Closed open CLOCK on \"%s\" at %s"
                 (org-get-heading t t t t) timestamp-string))
        (closed-sessions
         (format "Closed open :SESSIONS: interval on \"%s\" at %s"
                 (org-get-heading t t t t) timestamp-string))
        (t "Nothing open to close."))))))

;;; Historical consolidation --------------------------------------------------
;;
;; A one-time (for now — see TODO.org's "Auto-consolidate SESSIONS/LOGBOOK
;; on the fly") retrospective cleanup of the per-turn write churn described
;; in the "Session tracking" commentary above: each pause/resume writes a
;; matching :SESSIONS: pair and :LOGBOOK: CLOCK line, so an ordinary work
;; session accumulates dozens of few-minute entries. This section collapses
;; :SESSIONS: to one min-to-max span per calendar day, and rounds/merges
;; :LOGBOOK: CLOCK intervals, without ever touching whatever (if anything)
;; is still actually open — that reflects live clock state, not history.

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
the drawer name, matching `org-clock-find-position's own convention
via `org-element-at-point' — see `claude-code-ide-org--append-to-drawer'
— so prose that merely mentions \":DRAWER-NAME:\" is never mistaken
for an actual drawer."
  (org-back-to-heading t)
  (let ((subtree-end (save-excursion (outline-next-heading) (point)))
        (marker-re (concat "^[ \t]*:" (regexp-quote drawer-name) ":[ \t]*$")))
    (save-excursion
      (when (re-search-forward marker-re subtree-end t)
        (when (org-element-type-p (org-element-at-point) 'drawer)
          (forward-line 1)
          (let ((content-beg (point)))
            (when (re-search-forward "^[ \t]*:END:[ \t]*$" subtree-end t)
              (list content-beg (line-beginning-position)))))))))

(defun claude-code-ide-org--parse-clock-lines (text)
  "Parse TEXT (a :LOGBOOK: drawer's body) into a plist: :open, the
raw text of a still-open CLOCK line if TEXT has one, else nil;
:closed, a list of (START . END) time-value conses for every closed
CLOCK line; and :other, every remaining non-blank line — native
state-change notes with their continuation lines, timestamp-range
annotations, anything this parser doesn't model — kept verbatim
(original indentation included) in original order.  :other is what
makes consolidation lossless for non-CLOCK drawer content (TODO.org
:ID: ba8249c1-28cd-4ff1-918b-4b8439345d9a)."
  (let (open closed other)
    (dolist (raw (split-string text "\n"))
      (let ((line (string-trim raw)))
        (cond
         ((string-empty-p line))
         ((string-match "\\`CLOCK: \\(\\[[^]]+\\]\\)--\\(\\[[^]]+\\]\\)" line)
          ;; Capture both groups before parsing either — `claude-code-ide-org--
          ;; parse-org-timestamp' calls `org-time-string-to-time', which does
          ;; its own internal regexp matching and would otherwise clobber the
          ;; match data the second `match-string' call relies on (the same
          ;; footgun `claude-code-ide-org-close-open-interval' already works
          ;; around).
          (let ((start-str (match-string 1 line))
                (end-str (match-string 2 line)))
            (push (cons (claude-code-ide-org--parse-org-timestamp start-str)
                        (claude-code-ide-org--parse-org-timestamp end-str))
                  closed)))
         ((string-match "\\`CLOCK: \\[[^]]+\\]\\'" line)
          (setq open line))
         (t (push raw other)))))
    (list :open open :closed closed :other (nreverse other))))

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
closed CLOCK intervals re-emitted newest first, like org's own CLOCK
ordering, with their endpoints exactly as recorded. A still-open CLOCK
line, if present, is left completely untouched and kept first, since it
reflects live clock state, not history. Every non-CLOCK line (native
state-change notes and their continuations, annotations) is preserved
verbatim after the CLOCK block — position among the rebuilt lines is
cosmetic, survival is not (TODO.org :ID: ba8249c1).

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
is now prevented at the source instead — see
`claude-code-ide-org--clock-out-floor-time', which stops a sub-minute
interval ever being written, rather than deleting it afterwards."
  (let* ((parsed (claude-code-ide-org--parse-clock-lines text))
         (open (plist-get parsed :open))
         (other (plist-get parsed :other))
         (lines (mapcar (lambda (iv) (claude-code-ide-org--format-clock-line (car iv) (cdr iv)))
                         (reverse (plist-get parsed :closed)))))
    (concat (if open (concat open "\n") "")
            (mapconcat #'identity lines "\n")
            (if lines "\n" "")
            (mapconcat #'identity other "\n")
            (if other "\n" ""))))

(defun claude-code-ide-org--parse-session-lines (text)
  "Parse TEXT (a :SESSIONS: drawer body) into a plist: :events, an
ordered list of plists each with :label (\"Resumed\" or \"Paused\"),
:time (a time value), and :suffix (any trailing annotation after the
timestamp, e.g. \" (recovered)\", or \"\"); and :other, every
non-blank line that is not a Resumed/Paused entry (e.g. the
\"Background-planned\" write-backs from `org_log_background_plan'),
kept verbatim in original order — same losslessness rule as
`claude-code-ide-org--parse-clock-lines' (TODO.org :ID:
ba8249c1-28cd-4ff1-918b-4b8439345d9a)."
  (let (events other)
    (dolist (raw (split-string text "\n"))
      (let ((line (string-trim raw)))
        (cond
         ((string-empty-p line))
         ((string-match "\\`- \\(Resumed\\|Paused\\) \\(\\[[^]]+\\]\\)\\(.*\\)\\'" line)
          ;; Same match-data-clobbering hazard as `claude-code-ide-org--parse-
          ;; clock-lines' above — capture every group before parsing any of them.
          (let ((label (match-string 1 line))
                (ts-str (match-string 2 line))
                (suffix (match-string 3 line)))
            (push (list :label label
                        :time (claude-code-ide-org--parse-org-timestamp ts-str)
                        :suffix suffix)
                  events)))
         (t (push raw other)))))
    (list :events (nreverse events) :other (nreverse other))))

(defun claude-code-ide-org--format-session-line (label time suffix)
  "Format LABEL (\"Resumed\"/\"Paused\"), TIME, and SUFFIX as a
:SESSIONS: entry line."
  (format "- %s %s%s" label (format-time-string "[%Y-%m-%d %a %H:%M]" time) suffix))

(defun claude-code-ide-org--consolidate-sessions-text (text)
  "Given the raw body TEXT of a :SESSIONS: drawer, collapse the
Resumed/Paused entries for each calendar day into a single
min-to-max pair (\"Resumed\" at the day's earliest timestamp,
\"Paused\" at its latest — whatever the entries' original labels).
A trailing, unmatched \"Resumed\" — today's still-open interval — is
left completely untouched, kept as the final line after the
consolidated days. Lines that are not Resumed/Paused entries at all
(e.g. \"Background-planned\" write-backs) are preserved verbatim,
between the consolidated days and the open tail (TODO.org :ID:
ba8249c1-28cd-4ff1-918b-4b8439345d9a)."
  (let* ((parsed (claude-code-ide-org--parse-session-lines text))
         (events (plist-get parsed :events))
         (other (plist-get parsed :other))
         (open-tail (when (and events (equal (plist-get (car (last events)) :label) "Resumed"))
                      (car (last events))))
         (closed (if open-tail (butlast events) events))
         (days (make-hash-table :test 'equal))
         day-order
         lines)
    (dolist (ev closed)
      (let ((day (format-time-string "%Y-%m-%d" (plist-get ev :time))))
        (unless (gethash day days) (push day day-order))
        (push ev (gethash day days))))
    (setq day-order (nreverse day-order))
    (dolist (day day-order)
      (let* ((day-events (sort (gethash day days)
                                (lambda (a b) (time-less-p (plist-get a :time) (plist-get b :time)))))
             (min-ev (car day-events))
             (max-ev (car (last day-events))))
        (push (claude-code-ide-org--format-session-line
               "Resumed" (plist-get min-ev :time) (plist-get min-ev :suffix))
              lines)
        (unless (eq min-ev max-ev)
          (push (claude-code-ide-org--format-session-line
                 "Paused" (plist-get max-ev :time) (plist-get max-ev :suffix))
                lines))))
    (setq lines (nreverse lines))
    (setq lines (append lines other))
    (when open-tail
      (setq lines (append lines
                           (list (claude-code-ide-org--format-session-line
                                  (plist-get open-tail :label)
                                  (plist-get open-tail :time)
                                  (plist-get open-tail :suffix))))))
    (concat (mapconcat #'identity lines "\n") (if lines "\n" ""))))

(defun claude-code-ide-org-consolidate-history (id)
  "Consolidate the heading with :ID: equal to ID's historical
:SESSIONS: and :LOGBOOK: entries in place: collapse :SESSIONS: to
one min-to-max span per calendar day, round :LOGBOOK: CLOCK
intervals to the nearest 5-minute mark, and merge any that become
adjacent or overlapping after rounding. A still-open CLOCK line or
trailing unmatched \"Resumed\" entry — today's live interval — is
left completely untouched; this only rewrites already-closed
history. Saves the buffer. Not registered as an MCP tool: intended
as a one-off maintenance operation via `emacsclient', and as the
shared implementation a future on-the-fly version would call right
after every clock-out."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (let ((heading (org-get-heading t t t t))
           logbook-changed sessions-changed)
       (let ((bounds (claude-code-ide-org--drawer-content-bounds "LOGBOOK")))
         (when bounds
           (let* ((old (buffer-substring (nth 0 bounds) (nth 1 bounds)))
                  (new (claude-code-ide-org--consolidate-logbook-text old)))
             (unless (equal old new)
               (delete-region (nth 0 bounds) (nth 1 bounds))
               (goto-char (nth 0 bounds))
               (insert new)
               (setq logbook-changed t)))))
       (let ((bounds (claude-code-ide-org--drawer-content-bounds "SESSIONS")))
         (when bounds
           (let* ((old (buffer-substring (nth 0 bounds) (nth 1 bounds)))
                  (new (claude-code-ide-org--consolidate-sessions-text old)))
             (unless (equal old new)
               (delete-region (nth 0 bounds) (nth 1 bounds))
               (goto-char (nth 0 bounds))
               (insert new)
               (setq sessions-changed t)))))
       (save-buffer)
       (cond
        ((and logbook-changed sessions-changed)
         (format "Consolidated :LOGBOOK: and :SESSIONS: on \"%s\"" heading))
        (logbook-changed (format "Consolidated :LOGBOOK: on \"%s\"" heading))
        (sessions-changed (format "Consolidated :SESSIONS: on \"%s\"" heading))
        (t (format "Nothing to consolidate on \"%s\"" heading)))))))

(defun claude-code-ide-org-set-todo (id state &optional note)
  "Set the TODO keyword of the heading with :ID: equal to ID to STATE.
STATE must be one of: TODO NEXT PLANNING DOING WAIT MAYBE DONE CANCELLED.
PLANNING auto-promotes to DOING when `ExitPlanMode' fires, via
`claude-code-ide-org--promote-planning-to-doing'.
Saves the buffer afterwards.  If org-blocker-hook (e.g. org-depend's
:BLOCKER: property) refuses the change, `org-todo' silently leaves
the heading in its prior state; this checks the actual resulting
state and reports that instead of blindly echoing STATE back.

STATE is almost always supplied by Claude through this non-interactive
tool, not typed by a human at the keyboard.  `org-todo' runs with
`org-inhibit-logging' bound to t unconditionally here, for every
STATE, not just ones whose `#+TODO:' marker is `@' -- confirmed live
(see TODO.org :ID: 04d0e7d5-ab6b-4972-925d-d517484c7595) that even a
plain `!' timestamp-only marker defers its native log-line insertion
through the same `org-add-log-note'/`post-command-hook' machinery `@'
does, and that deferred call blocks indefinitely when triggered
non-interactively (via `emacsclient -e', exactly this tool's own call
path) with nobody present to satisfy whatever it is waiting on --
`!' is not actually safe on its own for a programmatic caller, contrary
to the original assumption behind this wrapper. A genuine hand-edit
made directly in the Emacs buffer (`M-x org-todo' or a keyboard
TODO-cycle) never goes through this wrapper at all, so both `!' and
`@' still log normally there, for the one case where a human is
actually present.

NOTE is a short (3-10 word) reason for the transition, carried for the
event queue and unused here -- see `claude-code-ide-org-clock-in' for
why that is deliberate.  At apply time it becomes the `\\\\' continuation
on org's native `- State \"X\" from \"Y\" [ts]' line, which is a path
already confirmed to work: `org-store-log-note' takes the note text from
the current buffer's contents, so a non-empty note buffer yields the
continuation and an empty one yields a bare State line.

The success reply names the state the heading held *before* the change,
as `TODO state set to DOING (was NEXT): \"...\"'.  That clause is not
cosmetic: `bin/hooks/queue-append' parses it back out to record a `from'
field on the queued `todo' event, which is what lets the review command
detect at apply time that reality has moved past a queued transition
(TODO.org :ID: f9f61c04-150b-4ee7-96c9-582cf2bda95a).  The hook is a
bash script with no Emacs access by design -- writing the queue without
a running Emacs is the whole premise of the refactor -- so the prior
state has to travel back in the reply, exactly as `org_clock_out's
heading :ID: already does.  A heading with no keyword at all reports
`(was none)' rather than an empty string, so the parse stays
unambiguous."
  (let ((claude-code-ide-org--log-source (or claude-code-ide-org--log-source "org_set_todo")))
    (claude-code-ide-org--at-id
     id
     (lambda ()
       ;; Read before `org-todo', while the heading still holds it.
       (let ((previous (org-get-todo-state)))
         (let ((org-inhibit-logging t)) (org-todo state))
         ;; Re-resolved fresh by :ID: (a property-search, exactly like
         ;; `claude-code-ide-org--at-id' itself), never by trusting
         ;; "current point" or a marker captured before org-todo ran.
         ;; Confirmed live (not reproducible in the ERT/batch
         ;; environment, which never loads the user's personal Doom
         ;; config) that a saved marker does not reliably track this
         ;; heading's position across the single-NEXT-per-level trigger
         ;; hooks editing a SIBLING heading earlier in the buffer --
         ;; instrumented trace showed the marker's raw position number
         ;; never changed while the text at that position did, most
         ;; likely `ws-butler-mode' (whitespace cleanup) replacing a
         ;; wider region than a plain insert. Re-resolving by :ID: is
         ;; immune to that regardless of root cause, and is exactly how
         ;; every regression test already verifies state here.
         (let* ((marker (org-id-find id 'marker))
                (actual (and marker (org-with-point-at marker (org-get-todo-state))))
                (heading (and marker (org-with-point-at marker (org-get-heading t t t t)))))
           (if (equal actual state)
               (progn
                 (save-buffer)
                 (format "TODO state set to %s (was %s): \"%s\""
                         state (or previous "none") heading))
             (format "Error: requested state %s but heading \"%s\" is still %s — likely blocked (check :BLOCKER: / org-blocker-hook)"
                     state heading actual))))))))

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

(defun claude-code-ide-org-capture (title)
  "Quick-add TITLE as a new top-level TODO heading via `org-capture'.
Targets `claude-code-ide-org--capture-target-file', with a real,
freshly-generated :ID: property.  See the commentary above this
section for why the template is built fresh per call and why `%i'
rather than `%?' is used.  Returns \"Captured: \\=\"TITLE\\=\" (ID:
...)\" on success so the caller can immediately clock in / set state
on the new heading via org_clock_in / org_set_todo, or an
\"Error: ...\" string.  Never signals an error to the MCP layer."
  (condition-case err
      (let* ((new-id (org-id-new))
             (org-capture-templates
              (list (list "z" "Claude quick-capture (org_capture MCP tool)"
                          'entry
                          (list 'file #'claude-code-ide-org--capture-target-file)
                          (format "* TODO %%i\n:PROPERTIES:\n:ID:       %s\n:END:\n" new-id)
                          :immediate-finish t))))
        (org-capture-string title "z")
        (org-id-add-location new-id (expand-file-name (claude-code-ide-org--capture-target-file)))
        (format "Captured: \"%s\" (ID: %s)" title new-id))
    (error (format "Error: %s" (error-message-string err)))))

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

(defun claude-code-ide-org--trigger-auto-clock-in (change-plist)
  "For `org-trigger-hook': the moment any heading's TODO state becomes
DOING or PLANNING -- via `claude-code-ide-org-set-todo', a hand-edit
made directly in Emacs, or any other path at all -- automatically open
a clock on it via `org-clock-in', unless a clock is already running on
that exact heading. Guarded against re-entrancy by
`claude-code-ide-org--auto-clock-in-active'. CHANGE-PLIST is the
plist `org-todo' passes to every `org-trigger-hook' function; see
`org-trigger-hook's own docstring for its shape. Never calls
`org-clock-in' or reads `org-clock-marker' except from inside this
hook -- i.e. never at load or registration time."
  (when (and (member (plist-get change-plist :to) '("DOING" "PLANNING"))
             (not claude-code-ide-org--auto-clock-in-active))
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

(defun claude-code-ide-org--maybe-record-planning-owner (payload-path)
  "Read the `org_set_todo' `PostToolUse' hook payload JSON from
PAYLOAD-PATH (a temp-file path written by
bin/hooks/posttooluse-record-planning-owner) and, when its
tool_input.state field is \"PLANNING\", record the payload's
session_id in `claude-code-ide-org--planning-owner-session-id'. Any
other requested state, or any problem reading/parsing PAYLOAD-PATH, is
a no-op -- this must never error or block the hook it runs under. No
check on whether the underlying `org_set_todo' transition actually
succeeded: a phantom owner recorded for a blocked/failed transition is
harmless, since `claude-code-ide-org--promote-planning-to-doing' only
ever matches a heading whose live state is exactly PLANNING."
  (condition-case nil
      (let* ((json-object-type 'alist)
             (payload (json-read-file payload-path))
             (tool-input (alist-get 'tool_input payload))
             (state (alist-get 'state tool-input))
             (session-id (alist-get 'session_id payload)))
        (when (equal state "PLANNING")
          (setq claude-code-ide-org--planning-owner-session-id session-id)))
    (error nil)))

(defun claude-code-ide-org--promote-planning-to-doing (session-id)
  "For the `ExitPlanMode' `PostToolUse' hook
(bin/hooks/exitplanmode-promote-planning): if a clock is currently
running on a heading whose TODO state is exactly PLANNING, and that
heading's PLANNING was either set by SESSION-ID itself or has no known
owner (`claude-code-ide-org--planning-owner-session-id' is nil),
promote it to DOING in place -- same clock interval, no close/reopen --
append a LOGBOOK \"Auto-promoted\" note, clear the owner var, save the
buffer, and return a success string. No-ops (returning a descriptive
string, never erroring) when: nothing is clocking; the clocked
heading's state isn't PLANNING; or the clocked heading's PLANNING is
owned by a different, known session -- the cross-session guard this
function exists for (TODO.org :ID:
b95b9fba-f78e-48fe-8546-988709cce309, design decision 4). Deliberately
does not gate on plan approval vs. rejection -- there is no reliable
signal to gate on (see the same TODO.org entry's decision 6); a stray
promotion after a rejected plan is low-cost and self-corrects the next
time the heading's real state is set explicitly."
  (if (not (org-clocking-p))
      "No clock running; nothing to promote."
    (let ((clocked-state (org-with-point-at org-clock-marker
                            (org-get-todo-state))))
      (cond
       ((not (equal clocked-state "PLANNING"))
        (format "Clocked heading is in state %s, not PLANNING; nothing to promote."
                (or clocked-state "(none)")))
       ((and claude-code-ide-org--planning-owner-session-id
             (not (equal session-id claude-code-ide-org--planning-owner-session-id)))
        "Clocked PLANNING heading belongs to a different session; not promoting.")
       (t
        (let ((heading (org-with-point-at org-clock-marker
                          (let ((org-inhibit-logging t)) (org-todo "DOING"))
                          (claude-code-ide-org--append-to-drawer
                           "LOGBOOK"
                           (claude-code-ide-org--format-log-state-line
                            "DOING" "PLANNING"
                            "Auto-promoted: ExitPlanMode fired on the owning session."))
                          (save-buffer)
                          (org-get-heading t t t t))))
          (setq claude-code-ide-org--planning-owner-session-id nil)
          (format "Promoted \"%s\" from PLANNING to DOING." heading)))))))

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
    (let ((new-next-heading (org-get-heading t t t t)))
      (claude-code-ide-org--map-siblings
       (lambda ()
         (when (equal (org-get-todo-state) "NEXT")
           (let ((org-inhibit-logging t)) (org-todo "TODO"))
           (claude-code-ide-org--append-to-drawer
            "LOGBOOK"
            (claude-code-ide-org--format-log-state-line
             "TODO" "NEXT"
             (format "Auto-demoted: superseded by sibling \"%s\" becoming NEXT."
                     new-next-heading)))))))))

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
Inserted after the property drawer and any :SESSIONS:/:LOGBOOK:
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
:ID: property equals ID: insert a Plan-file link (idempotent, see
`claude-code-ide-org--insert-plan-link') and append a \"Background-
planned\" entry to the heading's :SESSIONS: drawer tagged with
SESSION-ID -- a synthetic id, never the orchestrating session's own
real session id (e.g. \"<real-session-id>-bg1\"), so unattended
background research time is never misattributed as that session's own
interactive work.  Never transitions TODO state and never touches the
clock or either PLANNING/clock owner variable -- the single shared
clock cannot represent true parallelism honestly, so this tool
structurally cannot produce a CLOCK/:LOGBOOK: entry."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (claude-code-ide-org--insert-plan-link plan-file)
     (let ((claude-code-ide-org--log-session-id session-id))
       (claude-code-ide-org--log-session-event "Background-planned"))
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

(defcustom claude-code-ide-org-guidepost-gap-threshold 900
  "Seconds between consecutive guideposts below which they collapse
into one span for review, in `claude-code-ide-org--aggregate-guideposts'.

Purely a presentation control: the queue files themselves always keep
every raw event, so raising or lowering this never destroys anything and
never needs a migration. The default of 15 minutes is a starting guess,
explicitly expected to be retuned once real queue data exists -- the
right value is an empirical question about how this project's sessions
actually cluster, not something to settle in advance."
  :type 'integer
  :group 'claude-code-ide-org)

(defconst claude-code-ide-org--queue-kinds
  '("todo" "clock_in" "clock_out" "pause" "resume")
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
  (let ((table (make-hash-table :test 'equal))
        (file (claude-code-ide-org--queue-watermark-file session-id)))
    (when (file-readable-p file)
      (let ((data (ignore-errors
                    (json-parse-string
                     (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-string))
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))))
        (dolist (ts (alist-get 'applied data))
          (puthash ts t table))))
    table))

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
recorded beside the log, never in it."
  (let ((applied (claude-code-ide-org--queue-applied session-id)))
    (dolist (ts ts-strings) (puthash ts t applied))
    (claude-code-ide-org--atomic-write
     (claude-code-ide-org--queue-watermark-file session-id)
     (json-encode `((applied . ,(let (all)
                                  (maphash (lambda (k _) (push k all)) applied)
                                  (sort all #'string<))))))))

(defun claude-code-ide-org--queue-events (&optional session-id)
  "Return pending (unapplied) queue events, oldest first.
With SESSION-ID, read only that session's queue; otherwise read every
session's, merged and re-sorted by timestamp. Events already applied are
omitted. Unparseable lines are skipped silently -- see
`claude-code-ide-org--queue-parse-line'."
  (let (events)
    (dolist (sid (if session-id (list session-id)
                   (claude-code-ide-org--queue-session-ids)))
      (let ((file (claude-code-ide-org--queue-file sid))
            (applied (claude-code-ide-org--queue-applied sid)))
        (when (file-readable-p file)
          (dolist (line (split-string
                         (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))
                         "\n" t))
            (let ((event (claude-code-ide-org--queue-parse-line line)))
              (when (and event
                         (not (gethash (plist-get event :ts-string) applied)))
                (push event events)))))))
    (sort (nreverse events)
          (lambda (a b) (time-less-p (plist-get a :ts) (plist-get b :ts))))))

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
guidepost would silently attribute to the wrong heading."
  (let ((by-session (make-hash-table :test 'equal))
        (groups (make-hash-table :test 'equal))
        order)
    ;; Partition first: attribution is only meaningful within one session's
    ;; own ordered stream, never across the interleaving of several.
    (dolist (event (claude-code-ide-org--queue-events session-id))
      (push event (gethash (plist-get event :session-id) by-session)))
    (maphash
     (lambda (_sid events)
       (let ((current nil))
         (dolist (event (nreverse events))
           (let* ((kind (plist-get event :kind))
                  (own-id (plist-get event :id))
                  (id (cond
                       ((equal kind "clock_in") (setq current own-id))
                       ((equal kind "clock_out")
                        (prog1 (or own-id current) (setq current nil)))
                       (own-id own-id)
                       (t current))))
             (unless (member id order) (push id order))
             (push event (gethash id groups))))))
     by-session)
    (mapcar (lambda (id)
              (cons id
                    (sort (nreverse (gethash id groups))
                          (lambda (a b)
                            (time-less-p (plist-get a :ts) (plist-get b :ts))))))
            (nreverse order))))

(defun claude-code-ide-org--aggregate-guideposts (events &optional threshold)
  "Collapse EVENTS' timestamps into (START . END) spans for review.
Consecutive timestamps separated by less than THRESHOLD seconds (default
`claude-code-ide-org-guidepost-gap-threshold') join one span; a larger
gap starts a new one. A lone timestamp yields a zero-width span, which
is honest -- one interaction point is not evidence of a duration.

These spans are review scaffolding only. They are rendered as *active*
timestamps so org's own agenda picks them up (confirmed live, TODO.org
:ID: c084553c-0621-4a96-9fa1-f32850aeec6a), and they inform the human's
composition of CLOCK: entries -- they never become one. Nothing here
rounds: `claude-code-ide-org--consolidate-logbook-text's 5-minute
rounding silently drops any interval under ~2.5 minutes that misses a
boundary, which is precisely the confidently-wrong record this design
exists to prevent.

Not built on `claude-code-ide-org--merge-time-intervals': that merges
only touching or overlapping intervals, with no gap tolerance, which is
a different question from clustering points that are merely near each
other."
  (let ((gap (or threshold claude-code-ide-org-guidepost-gap-threshold))
        (times (sort (mapcar (lambda (e) (plist-get e :ts)) events)
                     #'time-less-p))
        spans start previous)
    (dolist (time times)
      (cond
       ((null start) (setq start time previous time))
       ((<= (float-time (time-subtract time previous)) gap)
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
            (when (equal (plist-get event :kind) "todo")
              (push (list :type 'state :id id
                          :ts (plist-get event :ts)
                          :from (plist-get event :from)
                          :to (plist-get event :state)
                          :note (plist-get event :note)
                          :events (list event))
                    items)))
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
    (sort (nreverse items)
          (lambda (a b)
            (time-less-p (or (plist-get a :ts) (plist-get a :start))
                         (or (plist-get b :ts) (plist-get b :start)))))))

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
legacy event would train the reader to ignore the flag."
  (let ((from (plist-get item :from)))
    (when from
      (let ((current (claude-code-ide-org--review-current-state (plist-get item :id))))
        (and (not (eq current 'unresolved))
             ;; "none" is how the queue spells "the heading carried no
             ;; keyword", which `org-get-todo-state' spells as nil.
             (not (equal (if (equal from "none") nil from) current)))))))

(defun claude-code-ide-org--review-format-annotation (item)
  "Return the :LOGBOOK: annotation line for ITEM.
Active timestamps for a human span -- those reach `org-agenda', which is
the entire point -- and inactive for a subagent's, which should not."
  (let* ((agent (plist-get item :agent))
         (fmt (if agent "[%Y-%m-%d %a %H:%M]" "<%Y-%m-%d %a %H:%M>"))
         (note (plist-get item :note)))
    (format "- %s--%s%s"
            (format-time-string fmt (plist-get item :start))
            (format-time-string fmt (plist-get item :end))
            (if (and note (not (string-empty-p note))) (concat " " note) ""))))

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
    (unless (time-equal-p start end)
      (let ((org-clock-out-remove-zero-time-clocks nil))
        (org-clock-in nil start)
        ;; Never close a clock we did not open. If `org-clock-in' aborted
        ;; for any reason, calling `org-clock-out' here would close
        ;; whatever else happens to be running, at our end time. Failing
        ;; loudly is the only safe response -- the alternative is a
        ;; plausible-looking interval on the wrong heading.
        (unless (org-clocking-p)
          (error "org-clock-in did not open a clock; refusing to clock out"))
        (org-clock-out nil nil end))))
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
      (let ((result
             (claude-code-ide-org--at-id
              (plist-get item :id)
              (lambda ()
                (pcase (plist-get item :type)
                  ('clock (claude-code-ide-org--review-apply-clock item))
                  ('state (claude-code-ide-org--review-apply-state item)))
                (save-buffer)
                nil))))
        ;; --at-id returns an "Error: ..." string rather than throwing.
        (and (stringp result) result)))))

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
  "Apply ITEMS in order. Returns a plist (:applied N :errors ERRORS)."
  (let (applied errors)
    (dolist (item items)
      (let ((error (claude-code-ide-org--review-apply-item item)))
        (if error (push error errors) (push item applied))))
    (claude-code-ide-org--review-record-applied applied)
    (list :applied (length applied) :errors (nreverse errors))))

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
(dolist (binding '(("m" . claude-code-ide-org-review-mark)
                   ("u" . claude-code-ide-org-review-unmark)
                   ("t" . claude-code-ide-org-review-toggle)
                   ("e" . claude-code-ide-org-review-edit-interval)
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

Three behaviours worth knowing:

  \\[claude-code-ide-org-review-apply] is the only consequential key.  It writes real org state and saves
  the buffers.  Items apply oldest first and independently: if one fails
  it is reported and the rest still go.

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
      ;; column state lines reserve.
      ('clock (format "  clock   %s%s   %s"
                      (claude-code-ide-org--review-format-annotation item)
                      (if (plist-get item :suggested) "  (suggested)" "  (agent)")
                      note)))))

(defun claude-code-ide-org--review-render ()
  "Render `claude-code-ide-org--review-items' into the current buffer."
  (let ((inhibit-read-only t)
        (items claude-code-ide-org--review-items)
        (last-id nil))
    (erase-buffer)
    (insert "Pending org updates.  m/u mark, t toggle, e edit, RET goto, "
            "x apply marked, g refresh, q quit\n\n")
    (if (null items)
        (insert "  Nothing pending.\n")
      (dolist (item items)
        (unless (equal (plist-get item :id) last-id)
          (setq last-id (plist-get item :id))
          (insert (format "\n%s\n"
                          (or (claude-code-ide-org--at-id
                               last-id (lambda () (org-get-heading t t t t)))
                              last-id))))
        (insert (propertize
                 (format "  [%s] %s\n"
                         (if (plist-get item :marked) "x" " ")
                         (claude-code-ide-org--review-describe item))
                 'claude-code-ide-org-item item))))
    (goto-char (point-min))))

(defun claude-code-ide-org--review-set-mark (marked)
  "Set the current line's item :marked to MARKED and re-render.

Marking a stale state item asks for confirmation first, and records the
answer on the item as :stale-confirmed.  This is the deliberate override
`claude-code-ide-org--review-apply-item' requires: the design's premise
is that the human is the validation step, so a stale transition must be
refusable by default and still applicable on purpose -- but never by
default, and never without having been told.  A `y-or-n-p' is safe here
in a way it is not elsewhere in this module: this is a genuinely
interactive command with a human at the keyboard, not an
`emacsclient -e' call with nobody present to answer."
  (let ((item (claude-code-ide-org--review-item-at-point))
        (line (line-number-at-pos)))
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
    (claude-code-ide-org--review-render)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun claude-code-ide-org-review-mark ()
  "Mark the item at point for applying."
  (interactive)
  (claude-code-ide-org--review-set-mark t))

(defun claude-code-ide-org-review-unmark ()
  "Unmark the item at point."
  (interactive)
  (claude-code-ide-org--review-set-mark nil))

(defun claude-code-ide-org-review-toggle ()
  "Toggle the mark on the item at point."
  (interactive)
  (let ((item (claude-code-ide-org--review-item-at-point)))
    (unless item (user-error "No review item on this line"))
    (claude-code-ide-org--review-set-mark (not (plist-get item :marked)))))

(defun claude-code-ide-org-review-goto ()
  "Jump to the org heading the item at point belongs to."
  (interactive)
  (let ((item (claude-code-ide-org--review-item-at-point)))
    (unless item (user-error "No review item on this line"))
    (let ((id (plist-get item :id)))
      (org-id-goto id))))

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
      (plist-put item :start start-time)
      (plist-put item :end end-time)
      ;; An edited interval is a confirmed one, not a suggestion.
      (plist-put item :suggested nil)
      (claude-code-ide-org--review-render))))

(defun claude-code-ide-org-review-refresh ()
  "Rebuild the review buffer from the queue, discarding marks."
  (interactive)
  (setq claude-code-ide-org--review-items
        (claude-code-ide-org--review-items-from-queue))
  (claude-code-ide-org--review-render))

(defun claude-code-ide-org-review-apply ()
  "Apply every marked item, then refresh."
  (interactive)
  (let ((marked (seq-filter (lambda (i) (plist-get i :marked))
                            claude-code-ide-org--review-items)))
    (unless marked (user-error "Nothing marked"))
    (let ((result (claude-code-ide-org--review-apply marked)))
      (claude-code-ide-org-review-refresh)
      (message "Applied %d item(s)%s"
               (plist-get result :applied)
               (if (plist-get result :errors)
                   (format "; %d failed: %s"
                           (length (plist-get result :errors))
                           (string-join (plist-get result :errors) "; "))
                 "")))))

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

;;; MCP tool registration -------------------------------------------------

(with-eval-after-load 'claude-code-ide

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-clock-in
   :name "org_clock_in"
   :description (concat
                 "Clock in to an org-mode task, identified by its :ID: property. "
                 "Always call this when transitioning a task to DOING state. "
                 "Opens a CLOCK entry and starts the Emacs clock timer.")
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
                 "Clock out of the currently running org-mode clock. "
                 "Always call this when transitioning away from DOING "
                 "(to DONE, WAIT, or CANCELLED). "
                 "Closes the open CLOCK entry and computes the duration.")
   :args '((:name "note"
            :type string
            :optional t
            :description "Short 3-10 word description of what was accomplished in this span, e.g. \"user authentication code review\". Recorded for later review.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-set-todo
   :name "org_set_todo"
   :description (concat
                 "Set the TODO keyword on an org-mode heading by its :ID: property. "
                 "Valid states: TODO NEXT PLANNING DOING WAIT MAYBE DONE CANCELLED. "
                 "When setting DOING, also call org_clock_in. "
                 "When leaving DOING, call org_clock_out first. "
                 "PLANNING auto-promotes to DOING when ExitPlanMode fires, "
                 "reusing the same clock interval -- no separate org_clock_in needed.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the target org heading.")
           (:name "state"
            :type string
            :description "TODO keyword to set: TODO NEXT PLANNING DOING WAIT MAYBE DONE CANCELLED.")
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
                 "Quick-add a new TODO heading from TITLE via org-capture, in "
                 "one call instead of hand-writing a heading via the text "
                 "skill and then calling org-id-get-create separately. "
                 "Targets `claude-code-ide-org-capture-file' (or "
                 "`org-default-notes-file' when unset). Returns a "
                 "confirmation string containing the new heading's real "
                 ":ID:, so the caller can immediately clock in / set state "
                 "on it with org_clock_in / org_set_todo.")
   :args '((:name "title"
            :type string
            :description "The heading text for the new TODO.")))

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
                 "link (idempotent) and append a synthetic :SESSIONS: entry. "
                 "Never transitions TODO state and never touches the clock.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the target org heading.")
           (:name "plan_file"
            :type string
            :description "Absolute path to the plan markdown file, e.g. ~/.claude/plans/<slug>.md.")
           (:name "session_id"
            :type string
            :description "Synthetic id for this write, never the orchestrating session's own real session id, e.g. <orchestrating-session-id>-bg1."))))
