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
