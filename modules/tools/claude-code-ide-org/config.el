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

(defun claude-code-ide-org--log-session-event (event)
  "Append a timestamped EVENT line to the :SESSIONS: drawer of the
heading at point.  EVENT is a short label such as \"Resumed\" or
\"Paused\"."
  (claude-code-ide-org--append-to-drawer
   "SESSIONS"
   (format "- %s %s" event (format-time-string "[%Y-%m-%d %a %H:%M]"))))

;;; Wrappers --------------------------------------------------------------

(defun claude-code-ide-org-clock-in (id)
  "Clock in to the org heading whose :ID: property equals ID.
Opens a new CLOCK entry in the heading's LOGBOOK drawer and starts
the Emacs clock timer.  Also logs a \"Resumed\" entry to the
heading's :SESSIONS: drawer.  Saves the buffer afterwards."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (let ((heading (org-get-heading t t t t)))
       (org-clock-in)
       (claude-code-ide-org--log-session-event "Resumed")
       (save-buffer)
       (format "Clocked in: \"%s\"" heading)))))

(defun claude-code-ide-org-clock-out ()
  "Clock out of the currently running org clock.
Closes the open CLOCK entry with an end timestamp and computes the
duration.  Also logs a \"Paused\" entry to the heading's :SESSIONS:
drawer.  Saves the buffer afterwards.  Safe to call when no clock
is running."
  (condition-case err
      (if (not (org-clocking-p))
          "No clock is currently running."
        (let ((heading org-clock-heading)
              (buffer (marker-buffer org-clock-marker)))
          (org-with-point-at org-clock-marker
            (claude-code-ide-org--log-session-event "Paused"))
          (org-clock-out)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (save-buffer)))
          (format "Clocked out: \"%s\"" heading)))
    (error (format "Error: %s" (error-message-string err)))))

(defun claude-code-ide-org-session-pause ()
  "Pause the running clock, if any.  Alias for
`claude-code-ide-org-clock-out', intended to be called directly
via `emacsclient -e' (not registered as an MCP tool) by a Stop
hook, so a task automatically pauses the moment Claude finishes
responding and control returns to the user."
  (claude-code-ide-org-clock-out))

(defun claude-code-ide-org-session-resume ()
  "Resume clocking on the most recently paused task, if any, via
`org-clock-in-last'.  Intended to be called directly via
`emacsclient -e' (not registered as an MCP tool) by a
UserPromptSubmit hook, so a paused task resumes the moment the
user sends the next prompt.  Safe to call when already clocking or
when there is no clock history to resume — both cases are no-ops.
If the resumed task turns out to be the wrong one (the user's next
prompt is about something else entirely), the existing org_clock_in
tool self-corrects: org-clock-in always closes whatever clock is
currently running before opening a new one, so the mistaken resume
just leaves a short, low-cost stray CLOCK interval on the wrong
heading rather than silently losing time or blocking anything."
  (condition-case err
      (cond
       ((org-clocking-p) "Already clocking; nothing to resume.")
       ((null org-clock-history) "No paused task to resume.")
       (t
        (org-clock-in-last)
        (if (not (org-clocking-p))
            "org-clock-in-last did not start a clock."
          (org-with-point-at org-clock-marker
            (claude-code-ide-org--log-session-event "Resumed"))
          (let ((buffer (marker-buffer org-clock-marker)))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer (save-buffer))))
          (format "Resumed: \"%s\"" org-clock-heading))))
    (error (format "Error: %s" (error-message-string err)))))

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
  "Files to scan for stale open intervals (and, later, org_query)."
  (or claude-code-ide-org-query-files org-agenda-files))

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

(defun claude-code-ide-org-close-open-interval (id timestamp-string)
  "Close whatever open CLOCK/:SESSIONS: interval exists on the
heading whose :ID: equals ID, using TIMESTAMP-STRING (an org
timestamp string, e.g. \"[2026-07-27 Mon 17:45]\") as the recovered
stop time.  Closes an open CLOCK line (computing its duration) and/or
appends a \"Paused ... (recovered)\" :SESSIONS: entry, whichever is
actually open.  Saves the buffer.  Does not touch the live clock —
this is purely a text-level fix for a stale interval, not related to
whatever (if anything) is currently clocking."
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

(defun claude-code-ide-org-set-todo (id state)
  "Set the TODO keyword of the heading with :ID: equal to ID to STATE.
STATE must be one of: TODO NEXT DOING WAIT MAYBE DONE CANCELLED.
Saves the buffer afterwards.  If org-blocker-hook (e.g. org-depend's
:BLOCKER: property) refuses the change, `org-todo' silently leaves
the heading in its prior state; this checks the actual resulting
state and reports that instead of blindly echoing STATE back."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (org-todo state)
     (let ((actual (org-get-todo-state))
           (heading (org-get-heading t t t t)))
       (if (equal actual state)
           (progn
             (save-buffer)
             (format "TODO state set to %s: \"%s\"" state heading))
         (format "Error: requested state %s but heading \"%s\" is still %s — likely blocked (check :BLOCKER: / org-blocker-hook)"
                 state heading actual))))))

(defun claude-code-ide-org-archive (id)
  "Archive the org heading whose :ID: property equals ID.
Uses the #+ARCHIVE: directive in effect at the heading (file-level
or per-heading :ARCHIVE: property).  For :code: tasks this should
resolve to DONE.org::* Done per your project file headers."
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (let ((heading (org-get-heading t t t t)))
       (org-archive-subtree)
       (save-buffer)
       (format "Archived: \"%s\"" heading)))))

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
            :description "The :ID: property value of the target org heading.")))

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-clock-out
   :name "org_clock_out"
   :description (concat
                 "Clock out of the currently running org-mode clock. "
                 "Always call this when transitioning away from DOING "
                 "(to DONE, WAIT, or CANCELLED). "
                 "Closes the open CLOCK entry and computes the duration.")
   :args '())

  (claude-code-ide-make-tool
   :function #'claude-code-ide-org-set-todo
   :name "org_set_todo"
   :description (concat
                 "Set the TODO keyword on an org-mode heading by its :ID: property. "
                 "Valid states: TODO NEXT DOING WAIT MAYBE DONE CANCELLED. "
                 "When setting DOING, also call org_clock_in. "
                 "When leaving DOING, call org_clock_out first.")
   :args '((:name "id"
            :type string
            :description "The :ID: property value of the target org heading.")
           (:name "state"
            :type string
            :description "TODO keyword to set: TODO NEXT DOING WAIT MAYBE DONE CANCELLED.")))

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
            :description "org-ql plain-string query, e.g. \"todo:WAIT\", \"tags:research,code\", \"priority:A\", \"!todo:DONE\"."))))
