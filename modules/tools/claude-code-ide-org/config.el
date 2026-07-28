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
            :description "The :ID: property value of the heading to archive."))))
