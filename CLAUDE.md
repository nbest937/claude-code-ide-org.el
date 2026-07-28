# claude-code-ide-org

Doom Emacs module exposing org-mode operations to Claude Code as MCP tools,
plus an org-mode skill file for Claude Code sessions.

The goal is natural-language manipulation of `.org` files from within Emacs,
via `claude-code-ide`, without needing to internalise Emacs chord sequences.

---

## Repository layout

```
modules/tools/claude-code-ide-org/
    config.el       ← MCP tool definitions and Elisp wrappers
    config-test.el  ← ERT tests for config.el
    packages.el     ← dependency notes (no additional packages)
bin/test            ← runs the ERT suite (emacs --batch)
org.skill           ← Claude Code skill for org-mode file editing
org-dev.skill       ← Claude Code skill for reloading/verifying changes
                       to this project's own code (config.el, hooks,
                       bin/test) — see TODO.org's "org-dev skill" entry
.mcp.json           ← HTTP endpoint for the MCP tools server, so a `claude`
                       CLI in a plain shell (no Emacs) can reach org_* and
                       friends; see "Emacs integration" below
CLAUDE.md           ← this file
```

Run the tests with `bin/test`. They exercise the four wrapper functions
against scratch org files in a temp directory — no Doom, no real Emacs
config, no touching real org-id/clock state.

The module is symlinked into `~/.config/doom/modules/tools/claude-code-ide-org/`
and enabled in `~/.config/doom/init.el` under `:tools claude-code-ide-org`.

The skill file is installed in the Claude Code project.

---

## Engineering practices

**Rule**: any new feature should be tested to the extent possible and
reasonably feasible before being considered done. Automated where the
feature has a mechanical surface to test against (elisp via `bin/test`/
`config-test.el`, shell scripts via direct invocation); a documented
manual verification pass otherwise. "Reasonably feasible" is doing real
work here — some things (e.g. a skill's *trigger-matching* against its
own description, as opposed to the accuracy of its documented content)
are inherently fuzzy and not worth forcing into a deterministic test;
say so explicitly rather than skipping verification silently.

---

## Org-mode conventions

### File header

Every `.org` file in a Claude Code project should start with:

```org
#+TODO: TODO NEXT DOING WAIT MAYBE | DONE CANCELLED
#+TAGS: code comms research review
#+ARCHIVE: DONE.org::* Done
```

### TODO keyword semantics

| Keyword     | Meaning                          | Active? |
|-------------|----------------------------------|---------|
| `TODO`      | Not yet started                  | yes     |
| `NEXT`      | Decided, up next                 | yes     |
| `DOING`     | Actively being worked on         | yes     |
| `WAIT`      | Blocked or waiting on someone    | yes     |
| `MAYBE`     | Someday / maybe                  | yes     |
| `DONE`      | Completed                        | no      |
| `CANCELLED` | Abandoned                        | no      |

Priority is expressed through keyword choice, not `[#A]`/`[#B]`/`[#C]` cookies.
Do not add priority cookies.

### Tags

| Tag          | Meaning                          |
|--------------|----------------------------------|
| `:code:`     | Software / technical work        |
| `:comms:`    | Communication, writing, outreach |
| `:research:` | Investigation, reading, learning |
| `:review:`   | Review, feedback, evaluation     |

Tags are free-form beyond these four; declare additional ones in `#+TAGS:`.

### Archiving convention

`DONE` tasks tagged `:code:` are archived to `DONE.org::* Done` via the
`#+ARCHIVE:` directive. Other tags use the same default unless overridden
with a per-heading `:ARCHIVE:` property.

---

## State transition rules

| Transition            | Side effect                         |
|-----------------------|-------------------------------------|
| `TODO`  → `NEXT`      | None                                |
| `TODO`  → `DOING`     | Open a CLOCK (call `org_clock_in`)  |
| `NEXT`  → `DOING`     | Open a CLOCK (call `org_clock_in`)  |
| `DOING` → `DONE`      | Close the CLOCK (call `org_clock_out`) |
| `DOING` → `WAIT`      | Close the CLOCK (call `org_clock_out`) |
| `DOING` → `CANCELLED` | Close the CLOCK (call `org_clock_out`) |
| `WAIT`  → `DOING`     | Open a CLOCK (call `org_clock_in`)  |
| Any     → `MAYBE`     | None                                |

**Rule**: any transition *to* `DOING` must open a clock.
**Rule**: any transition *from* `DOING` must close the clock first.
**Rule**: always use the MCP tools for state changes and clocking — do not
edit CLOCK entries or TODO keywords by hand when the tools are available.
**Rule**: when asked to start work on a task tracked as an org heading with
a `:ID:`, transition it to `DOING` via `org_set_todo` *before* beginning,
unless it's already `DOING`. This has to be a standing instruction, not a
hook — deciding "this conversation is now doing that task" is a judgment
call about intent, which only the model can make. Hooks can only enforce
the mechanics of a transition once it's triggered (see `org-trigger-hook`/
`org-blocker-hook` in TODO.org, which is the safety net if this rule is
ever forgotten: it opens the clock the moment DOING is set, however it got
set).
**Rule**: any time a new task is described in conversation, create an org
heading for it (with a `:ID:`) and set its initial TODO state, rather than
only tracking it in conversation memory. Same reasoning as above — this is
a judgment call about what counts as "a task," so it has to be a standing
instruction, not something a hook could infer.
**Rule**: any newly created org heading gets a `:CREATED:` property in its
property drawer, stamped with an inactive timestamp (`[YYYY-MM-DD Dow
HH:MM]`) at creation time, alongside its `:ID:`. Applies to every heading
creation, not just the "new task described in conversation" case above.

---

## MCP tools (`modules/tools/claude-code-ide-org/config.el`)

All tools locate headings by their `:ID:` property.  Every heading Claude
is expected to act on must have one (`M-x org-id-get-create`).

| Tool            | Wraps                  | Notes                                 |
|-----------------|------------------------|---------------------------------------|
| `org_clock_in`  | `org-clock-in`         | Always call when entering DOING       |
| `org_clock_out` | `org-clock-out`        | Always call when leaving DOING        |
| `org_set_todo`  | `org-todo`             | Saves buffer after state change       |
| `org_archive`   | `org-archive-subtree`  | Respects `#+ARCHIVE:` directive       |

Text editing (via the org skill) is used for everything else: reading files,
adding or changing tags, generating new headings, time reporting.

---

## Session tracking (`.claude/settings.json`, `bin/hooks/`)

Two separate timekeeping mechanisms, deliberately kept apart:

- **`:LOGBOOK:` CLOCK entries** (org's own, native mechanism) track *active
  Claude work time only*. A running clock is paused the moment Claude Code
  stops and is waiting on the user, and resumed the moment the user sends
  the next prompt. A DOING task can therefore accumulate many short CLOCK
  intervals instead of one long one spanning idle waiting time.
- **The `:SESSIONS:` drawer** (this module's own, separate from `:LOGBOOK:`)
  is the bracketing history: a plain timestamped log of every pause and
  resume, so the full wall-clock arc of the task — including the gaps —
  stays visible even though the CLOCK entries no longer cover it.

Driven by two Claude Code hooks, configured in `.claude/settings.json`:

| Hook               | Script                        | Elisp entry point                    |
|---------------------|-------------------------------|---------------------------------------|
| `Stop`              | `bin/hooks/session-pause`     | `claude-code-ide-org-session-pause`   |
| `UserPromptSubmit`  | `bin/hooks/session-resume`    | `claude-code-ide-org-session-resume`  |

Both scripts are fire-and-forget: they call the elisp entry point via
`emacsclient -e`, ignore the result, and always exit 0, so a stopped or
unreachable Emacs server never blocks Claude Code itself. `session-pause`
is a thin alias for `org_clock_out`. `session-resume` calls org's own
`org-clock-in-last`, so it doesn't need to separately track *which* task
was paused — org's clock history already does.

**Known edge case:** if the user's next prompt is about a different task
than the one that got paused, `session-resume` still resumes the wrong
(last-paused) one. This self-corrects the moment Claude actually starts
the new task and calls `org_clock_in` on it — `org-clock-in` always closes
whatever clock is currently running first — so the cost is a short, stray
CLOCK interval on the wrong heading, not lost time or a stuck state.

**Known cosmetic quirk:** `:SESSIONS:` and `:LOGBOOK:` don't always end up
in a stable relative order — whichever drawer already exists gets found
and appended to in place, while a freshly-created one is always inserted
right after the property drawer, ahead of anything pre-existing. Harmless
(both remain fully valid, independently parseable drawers), just not
visually tidy.

### Stale interval recovery

A crash or system shutdown can kill Emacs (or the whole machine) before
the `Stop` hook gets a chance to pause a running interval, leaving a
CLOCK line or `:SESSIONS:` entry open indefinitely. Because
`org-clock-persist` is set to `history` (not `t`/`clock`) in the Doom
config, a restart does *not* auto-resume that in-memory clock state — so
detection works by scanning the actual *text* of tracked org files for an
unclosed `CLOCK:` line or an unclosed `Resumed` entry, never by checking
`org-clocking-p`.

Checked via a third hook, `SessionStart` → `bin/hooks/session-start-recovery-check`
→ `claude-code-ide-org-write-session-start-report`. Self-limiting to
"first thing each day": it only reports intervals whose open timestamp
predates today, so once closed (or if nothing was ever left open) it
stays quiet regardless of how many sessions start that day. The report is
injected as `additionalContext`, which Claude is expected to relay to the
user as a question — the hook itself has no way to literally prompt.

**Configuration** (both `defcustom`s, set in `~/.config/doom/config.el`):
- `claude-code-ide-org-session-recovery-enabled` (default `t`) — set nil
  to disable the whole check.
- `claude-code-ide-org-working-hours` (default `(9 . 18)`) — a
  `(START-HOUR . END-HOUR)` cons, 24-hour clock. Used only to inform the
  educated guess offered alongside the prompt: absent a better signal, the
  guess defaults to the end of working hours on the day the interval
  opened (clamped to at least an hour after the open time, if working
  hours would otherwise put the guess before the interval even started).
- `claude-code-ide-org-query-files` (default nil, falls back to
  `org-agenda-files`) — which files to scan. Shared with the still-MAYBE
  `org_query` tool in TODO.org for when it's eventually built.

**Recovery**: once the user confirms or corrects a stop time, call
`claude-code-ide-org-close-open-interval` (via `emacsclient`, not an MCP
tool — this is a text-level fix for a stale interval, unrelated to
whatever may currently be clocking) with the heading's `:ID:` and an org
timestamp string. It closes whichever of the CLOCK line / `:SESSIONS:`
entry is actually open (possibly both), computing the CLOCK duration and
appending a `Paused ... (recovered)` `:SESSIONS:` entry.

**Not yet attempted:** using the system sleep/wake/shutdown log (`pmset
-g log` on macOS) as a more precise guess signal than working hours alone
— it's specific to exactly the crash/shutdown scenario this feature
exists for, but the log is dominated by per-app power assertions rather
than clean sleep/wake transitions, and needs a much tighter filter than a
first attempt turned up. Worth revisiting if the working-hours-only guess
proves too coarse in practice.

---

## Emacs integration (`~/.config/doom/config.el`)

Key settings in the user's Doom config:

```elisp
;; org-mode
(after! org
  (setq org-todo-keywords
        '((sequence "TODO" "NEXT" "DOING" "WAIT" "MAYBE" "|" "DONE" "CANCELLED")))
  (setq org-clock-out-when-done t)
  (setq org-clock-persist 'history)
  (setq org-archive-location "DONE.org::* Done"))
(add-hook 'kill-emacs-hook #'org-clock-out)
(add-hook 'suspend-hook    #'org-clock-out)

;; claude-code-ide
(use-package! claude-code-ide
  :config
  (claude-code-ide-emacs-tools-setup)
  (setq claude-code-ide-terminal-backend 'vterm)
  (global-auto-revert-mode 1))
```

No explicit clock-persistence-restore call is needed above — see the design
note below. The user's live config additionally pins
`claude-code-ide-mcp-server-port` and wires standalone Warp/CLI access
(HTTP tools-server session registration + IDE-companion autostart, backing
`.mcp.json`). That's general claude-code-ide infrastructure, not specific
to org-mode, so it's intentionally not reproduced here.

The `vterm` backend requires the `:term vterm` Doom module (enabled in
`init.el`). Its native module is compiled with cmake against the
homebrew `libvterm` (the bundled libvterm build needs GNU libtool,
which is not installed); the resulting `vterm-module.so` lives in the
straight repo dir and is symlinked into the straight build dir.

`claude-code-ide` is declared in `~/.config/doom/packages.el`:

```elisp
(package! claude-code-ide
  :recipe (:host github :repo "manzaltu/claude-code-ide.el"))
```

Clock-out on session end is handled at the Emacs level (hooks above), not
by hooking into Claude Code session lifecycle events.

---

## Design notes

- **Why MCP tools over text editing for clock/state/archive?**
  Native org functions handle LOGBOOK formatting, timestamp arithmetic, and
  internal state (the running clock timer) correctly and atomically. Text
  editing risks malformed CLOCK entries or stale timer state.

- **Why text editing for everything else?**
  Tag changes, new headings, time report summaries, and file reads don't
  require org-mode's internal state — they're straightforward text operations
  the org skill handles well. Keeping the MCP tool surface small reduces
  per-request token overhead.

- **Why IDs rather than heading titles?**
  Titles are not unique and can change. `:ID:` properties are stable
  references that survive renames and refiling.

- **Why short snake_case tool names rather than upstream's convention?**
  Upstream `claude-code-ide` registers each MCP tool's name as the verbatim
  elisp function name (e.g. `claude-code-ide-mcp-xref-find-references`).
  This module deliberately diverges: elisp identifiers follow elisp
  convention (full `claude-code-ide-org-` package prefix), while
  model-facing tool names follow MCP convention — short snake_case with an
  `org_` namespace prefix (e.g. `org_clock_in`). snake_case is the
  prevailing style for MCP tools, the `org_` prefix names the domain the
  model actually cares about, and shorter names reduce per-request schema
  overhead.

- **Why no explicit clock-persistence-restore call in the Doom config?**
  Older org-mode required calling `(org-clock-persist-load)` yourself after
  setting `org-clock-persist`. Upstream renamed it to `org-clock-load`, and
  — more importantly — `org.el` now registers it on `org-mode-hook` itself,
  so calling either name explicitly inside `(after! org ...)` is not just
  outdated but actively breaks org-mode: `after!` fires the instant
  `org.el` calls `(provide 'org)`, which is *before* `org-clock.el` (where
  that function lives) has ever loaded, producing a void-function error
  that aborts org-mode initialization for the first file you open in a
  session. Don't add it back.

- **Folding / structural manipulation (not yet implemented)**
  Deferred pending MVP usage. Candidates for future iteration: `org_refile`,
  `org_move_sibling`, `org_query`, `org_sort_children`.
