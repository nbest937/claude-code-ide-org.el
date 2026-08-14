# claude-code-ide-org

Doom Emacs module exposing org-mode operations to Claude Code as MCP tools,
plus org-mode skills for Claude Code sessions.

The goal is natural-language manipulation of `.org` files from within Emacs,
via `claude-code-ide`, without needing to internalise Emacs chord sequences.

A second, co-equal goal — never spelled out until now, though a large share
of this project's actual work has gone toward it — is trustworthy tracking
of where attention/time actually went on tracked tasks. What "trustworthy"
requires in practice (interval granularity, how much manual confirmation is
acceptable, what reports actually need to come out the other end) is
deliberately left open here, not pinned to whatever CLOCK-drawer mechanics
happen to exist at a given point: it should be driven by concrete reporting
needs, most of which haven't been fully articulated yet. See "Direction"
below for the current best guess at how these two goals combine.

---

## Direction (not yet implemented)

**This section describes a proposed target, not current behavior.**
Everything else in this file documents what is actually built and verified;
this section is the opposite — a UX vision this project is moving toward,
captured in TODO.org (`:ID: b5f7c5c7-7ad6-4c68-9cce-3479db1f1644`) but not
yet designed in Elisp, not implemented, and not approved as final. Treat it
as a hypothesis to evaluate — including whether it's the right one — not a
spec to execute against; a sub-task of that same heading
(`:ID: c084553c-0621-4a96-9fa1-f32850aeec6a`) exists specifically to check
whether org itself already offers a better mechanism before anything here
gets built.

**The problem it responds to**: driving live org state (TODO keyword,
clock, `:LOGBOOK:`/`:SESSIONS:` logging) directly and synchronously from
Claude Code sessions — including concurrent and background ones — has
produced a sustained run of desync, ownership, and logging bugs (see
TODO.org's "Clock lifecycle & visibility" section). The pattern traces to
one mismatch: org's clock/logging model assumes one human at one buffer;
this project's actual workload is the opposite.

**The proposed shape**: Claude Code sessions stop touching the live buffer
for state/clock changes. Instead they append events to a plain, per-session
file — durable, cheap, no Emacs required to write. A human, at a moment of
their own choosing, reviews the accumulated events in a purpose-built Emacs
command and applies the approved ones for real, through org's own native
`org-todo`/`org-clock-in`/`org-clock-out`, run inside a genuinely
interactive command — so org's native state-change logging finally works
instead of needing to be suppressed.

**Confirmed, load-bearing constraint on this shape**: apply is *always*
human-triggered, never invoked by Claude programmatically. Not a style
preference — org's native logging only completes correctly inside a real
interactive session; a non-interactive `emacsclient -e` call hits the exact
hang this design exists to route around. Practical consequence: clock/
TODO-state accuracy is only ever as fresh as the last time a human ran the
review pass, not live. That is an accepted, deliberate trade of "Claude
does it all in real time" for "the record, once confirmed, is actually
correct" — not an oversight to fix later.

**What doesn't change**: read-only queries, tagging, capture, refile,
archive, and sort stay exactly as immediate and Emacs-chord-free as the
opening goal promises. This trade is scoped narrowly to state transitions
and clock start/stop — the two categories that have actually caused every
incident to date.

---

## Repository layout

```
modules/tools/claude-code-ide-org/
    config.el       ← MCP tool definitions and Elisp wrappers
    config-test.el  ← ERT tests for config.el
    packages.el     ← dependency notes (no additional packages)
bin/test            ← runs the ERT suite (emacs --batch)
bin/sync-plans      ← copies this project's Plan Mode documents from
                       ~/.claude/plans into plans/, so they have history;
                       `--check` reports drift without copying
plans/              ← the archived copy. NOT the working copy: Claude Code
                       owns ~/.claude/plans and Plan Mode writes there, so
                       that stays the file org headings link and a revision
                       edits. A plan is archived here iff some heading in
                       TODO.org or DONE.org links it
.githooks/pre-push  ← refuses a push while plans/ is stale
.claude/skills/
    org/SKILL.md        ← Claude Code skill for org-mode file editing
    org-dev/SKILL.md    ← Claude Code skill for reloading/verifying changes
                           to this project's own code (config.el, hooks,
                           bin/test) — see DONE.org's "org-dev skill" entry
.mcp.json           ← HTTP endpoint for the MCP tools server, so a `claude`
                       CLI in a plain shell (no Emacs) can reach org_* and
                       friends; see "Emacs integration" below
.warp/.mcp.json     ← the same endpoint again, for Warp's own agent
CLAUDE.md           ← this file
```

**`.warp/.mcp.json` is deliberate, not duplication — do not "clean it
up."** It is currently byte-for-byte identical to the root `.mcp.json`,
and Warp can read the root file directly, so a cleanup pass will reliably
propose deleting it. Both are kept on purpose: the separate file is
evidence this project has actually been verified working under Warp's own
agent, and it is a seam for the two clients to diverge later if the
`claude` CLI and Warp ever need different settings against the same tools
server. The investigation behind it is archived in DONE.org
(`:ID: 6a6d5b4e-0327-4578-a44a-356576870ceb`) — worth reading before
touching either file, because the proxy the files were originally meant to
support turned out to be unnecessary: the real bug was this project's HTTP
server answering `200` where the MCP spec requires `202 Accepted`.

**One-time setup, required for `.githooks/` to do anything:**

```sh
git config core.hooksPath .githooks
```

That setting lives in `.git/config`, which is not version controlled, so a
fresh clone silently has no hooks until it is run. The hooks themselves are
tracked precisely so they are reviewable and shared — putting them in
`.git/hooks/` instead would make them invisible local state, which is the
same problem the `plans/` archive exists to fix. Note that `core.hooksPath`
redirects *every* hook: check `.git/hooks/` holds nothing but `.sample`
files before setting it (it did here, 2026-08-11).

Run the tests with `bin/test`. They exercise the four wrapper functions
against scratch org files in a temp directory — no Doom, no real Emacs
config, no touching real org-id/clock state.

The module is symlinked into `~/.config/doom/modules/tools/claude-code-ide-org/`
and enabled in `~/.config/doom/init.el` under `:tools claude-code-ide-org`.

Both skills live under `.claude/skills/` and are auto-discovered by Claude
Code from there — no separate install step.

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

**Rule**: work on new features happens on a feature branch, named
`feature/short-name-of-task`, not directly on `main`. Applies to new
feature work specifically — bug fixes and small doc/TODO edits aren't
implied to require one just because this rule exists.

**Rule**: work planned via Claude Code's own Plan Mode gets a single
permanent link in its heading body — `[[file:~/.claude/plans/<slug>.md][Plan]]`
— added as soon as the first round of planning finishes (right after
`ExitPlanMode` is called and the plan file is finalized), not gated on the
heading later transitioning to `DOING`. This matters because approval and
the `DOING` transition don't always happen in the same beat as planning —
e.g. the user may deliberately stop right after a plan is written, before
deciding whether to implement it — and the link should exist the moment a
real plan file does, independent of what happens next. Revisions (re-
entering Plan Mode on the same task) edit that same plan file in place —
Claude Code reuses the existing plan file path for a continuation of the
same task — so the link is written once and never needs updating to point
at a new file. No transcription of the plan into org, ever; the link is the
record, and it is **not removed at `DONE`**. A task with no separate Plan
Mode session simply carries no link — that's expected, not a gap to fill
in.

**Rule**: before a `DONE` heading is archived, add a concise prose outcome
summary next to that link — what shipped, how it was verified, anything
that differed from the plan. `DONE.org`'s existing `*Verified, not just
implemented:*`/`*Implementation notes:*` style is the model to match.
Applies to delegated-subagent work too: ask for a one-paragraph outcome
summary in the subagent's final report, not per-checkbox status — there
are no checkboxes to report on.

---

## Org-mode conventions

### File header

Every `.org` file in a Claude Code project should start with:

```org
#+TODO: TODO NEXT PLANNING DOING WAIT MAYBE | DONE CANCELLED
#+TAGS: code comms research review
#+ARCHIVE: DONE.org::* Done
```

### TODO keyword semantics

| Keyword     | Meaning                          | Active? |
|-------------|----------------------------------|---------|
| `TODO`      | Not yet started                  | yes     |
| `NEXT`      | Decided, up next                 | yes     |
| `PLANNING`  | In Plan Mode, plan not yet approved | yes  |
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

### Top-level headings

Top-level (`*`) headings in `TODO.org` are categories/epics — pure
structure, grouping related tasks — not tasks in their own right. They
carry no `TODO` keyword, no tags, and no `:PROPERTIES:` drawer (so no
`:ID:` and no `:CREATED:`, overriding the general "every heading
creation" rule below for this one case specifically). Actual tracked
work lives as their level-2+ children, each with its own `:ID:` per the
usual rule. Don't put a `TODO`/`NEXT`/etc. keyword on a top-level
heading — if a top-level heading needs to represent actionable work
itself rather than just group children, demote it: give it an `:ID:`
and treat it like any other task, or nest it one level deeper under a
category heading instead.

### Dependencies between tasks

A heading that can't be marked `DONE` until another heading is done gets a
`:BLOCKER:` property naming the blocking heading's `:ID:` (org-depend's
native mechanism, not project-specific — see the org skill for the full
syntax, including the inverse `:TRIGGER:` property). Prefer this over a
prose "depends on ..." sentence whenever the blocking heading has a
stable `:ID:` — it's machine-checkable, a sentence isn't. Whether
anything currently *enforces* it (an `org-blocker-hook` function
consulting `:BLOCKER:`) is separate from whether it's worth recording;
this project's own `org-blocker-hook` function
(`claude-code-ide-org--blocker-clock-running-p`) only blocks on a
running clock today, not on `:BLOCKER:` — see "Enforce the transition
rules" in TODO.org.

---

## State transition rules

| Transition                | Side effect                         |
|---------------------------|-------------------------------------|
| `TODO`     → `NEXT`       | None                                |
| `TODO`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `NEXT`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `NEXT`     → `PLANNING`   | Open a CLOCK (call `org_clock_in`)  |
| `PLANNING` → `DOING`      | None — same clock interval continues, no close/reopen |
| `PLANNING` → `DONE`       | Close the CLOCK (call `org_clock_out`) |
| `PLANNING` → `WAIT`       | Close the CLOCK (call `org_clock_out`) |
| `PLANNING` → `CANCELLED`  | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `DONE`       | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `WAIT`       | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `CANCELLED`  | Close the CLOCK (call `org_clock_out`) |
| `WAIT`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| Any        → `MAYBE`      | None                                |

**Rule**: any transition *to* `DOING` or `PLANNING` must open a clock, with
one documented exception: `PLANNING` → `DOING` reuses the already-running
clock interval rather than closing and reopening it.
**Rule**: any transition *from* `DOING` or `PLANNING` must close the clock
first, except the `PLANNING` → `DOING` handoff above.
**Rule**: always use the MCP tools for state changes and clocking — do not
edit CLOCK entries or TODO keywords by hand when the tools are available.
**Rule**: entering `PLANNING` is a model judgment call made *before* calling
`EnterPlanMode`, never during — Plan Mode itself forbids non-readonly tool
calls, so `org_set_todo` cannot run once inside it. Leaving `PLANNING` is
*not* a model decision: a `PostToolUse` hook matched on `ExitPlanMode`
(`bin/hooks/exitplanmode-promote-planning`) promotes `PLANNING` → `DOING`
automatically the instant a plan is approved and execution begins. A "plan
and implement" prompt must still produce both transitions at their correct,
separate times, never a premature jump to `DOING`. When the user enters
Plan Mode directly (shift-tab, not a model-initiated `EnterPlanMode` call),
there is no window to set `PLANNING` first — the hook's "clocked heading
isn't PLANNING → no-op" branch is the **common** case then, not a bug.
**Known gap, accepted**: the `ExitPlanMode` hook fires whether the plan was
approved or rejected, with no reliable signal to distinguish the two (see
TODO.org :ID: b95b9fba-f78e-48fe-8546-988709cce309). A stray promotion after
a rejected plan is low-cost and self-corrects the next time the heading's
real state is set explicitly — not fixed.
**Cross-session guard**: the `ExitPlanMode` promotion only fires for the
session that set `PLANNING` on the currently-clocked heading, tracked via
`claude-code-ide-org--planning-owner-session-id` — same pattern as
`claude-code-ide-org--clock-owner-session-id` (see "Session tracking"
below), applied to this new hook.
**Rule**: when asked to start work on a task tracked as an org heading with
a `:ID:`, transition it to `DOING` via `org_set_todo` *before* beginning,
unless it's already `DOING`. This has to be a standing instruction, not a
hook — deciding "this conversation is now doing that task" is a judgment
call about intent, which only the model can make. Hooks can only enforce
the mechanics of a transition once it's triggered — `org-trigger-hook`/
`org-blocker-hook` are the intended safety net for that (opening the clock
the moment DOING is set, however it got set), but they are not built yet;
see "Enforce the transition rules" in TODO.org.
**Rule**: any time a new task is described in conversation, create an org
heading for it (with a `:ID:`) and set its initial TODO state, rather than
only tracking it in conversation memory. Same reasoning as above — this is
a judgment call about what counts as "a task," so it has to be a standing
instruction, not something a hook could infer.
**Rule**: any newly created org heading gets a `:CREATED:` property in its
property drawer, stamped with an inactive timestamp (`[YYYY-MM-DD Dow
HH:MM]`) at creation time, alongside its `:ID:`. Applies to every heading
creation, not just the "new task described in conversation" case above.
**Rule**: when a new org heading is created as the direct result of an
approved Plan Mode plan, write only that heading (title, tags, properties,
any Plan-file link, intro body) and stop — show it and get explicit
approval before transitioning it to `DOING` or touching anything else the
plan describes. Approving a Plan is not approval of the heading's exact
wording. The `ExitPlanMode` auto-promotion hook does not affect this rule:
it only ever promotes an *already-clocked, already-`PLANNING`* heading, and
never touches a newly created heading the plan describes creating. The
more general form of this rule — `ExitPlanMode` approval and "start
implementing" are always two separate checkpoints, not just for newly
created headings — lives in the org skill (`.claude/skills/org/SKILL.md`,
"Plan Mode checkpoint") rather than here, since it's a way-of-working for
Claude Code's Plan Mode generally, not an org-file convention specific to
this repo.

---

## MCP tools (`modules/tools/claude-code-ide-org/config.el`)

Most tools locate a single heading by its `:ID:` property.  Every heading
Claude is expected to act on must have one (`M-x org-id-get-create`).
`org_query` is the exception — it searches across files by query, not by ID.

| Tool                | Wraps                    | Notes                                  |
|---------------------|--------------------------|-----------------------------------------|
| `org_clock_in`      | `org-clock-in`           | Always call when entering DOING        |
| `org_clock_out`     | `org-clock-out`          | Always call when leaving DOING         |
| `org_clock_report`  | `org-clock-report`       | Clocktable summary; :ID:-scoped or all |
| `org_set_todo`      | `org-todo`               | Saves buffer after state change        |
| `org_archive`       | `org-archive-subtree`    | Respects `#+ARCHIVE:` directive        |
| `org_query`         | `org-ql-select`          | Cross-file search; not :ID:-scoped     |
| `org_capture`       | `org-capture`            | Quick-add a new TODO heading           |
| `org_refile`        | `org-refile`             | Move a subtree under a different parent |
| `org_move_sibling`  | `org-move-subtree-up/down` | Move a heading up/down among siblings |
| `org_sort_children` | `org-sort-entries`       | Sort a heading's direct children       |
| `org_log_background_plan` | custom (insert-plan-link) | Write-back for background-planned headings: inserts the Plan link. Still accepts `session_id`, but no longer records it — that went with `:SESSIONS:`; never touches TODO state or the clock |
| `org_pending_updates` | custom (queue reader)    | Read-only summary of queued-but-unapplied updates, grouped by heading. Counts *proposals*, not queue lines |

Text editing (via the org skill) is used for adding or changing tags,
generating new headings, and time reporting. `org_query` now covers
structured cross-file reads (e.g. "what's blocked," "everything :research:
and not DONE") that used to mean Claude reading whole files by hand.

**Read-only buffers:** none of these five tools bind `inhibit-read-only`,
so if the user has toggled a buffer read-only (`C-x C-q`) it fails
outright with a `buffer-read-only` error. The user only does this to
guard against their own stray keystrokes while viewing the file, not to
block Claude — clear it (`(setq buffer-read-only nil)` via
`emacsclient`) and proceed, no need to ask first. If they ever want a
specific buffer left alone, they'll say so explicitly; that overrides
this default for that instance only.

---

## Session tracking (`.claude/settings.json`, `bin/hooks/`)

Two separate timekeeping mechanisms, deliberately kept apart:

- **`:LOGBOOK:` CLOCK entries** (org's own, native mechanism) track *active
  Claude work time only*. A running clock is paused the moment Claude Code
  stops and is waiting on the user, and resumed the moment the user sends
  the next prompt. A DOING task can therefore accumulate many short CLOCK
  intervals instead of one long one spanning idle waiting time.
- **The `:SESSIONS:` drawer is retired** (2026-08-11, TODO.org
  `:ID: 9d2fcdad-9bf7-47b6-8018-223b13ec4577`). It used to hold the
  bracketing history — a timestamped log of every pause and resume, so
  the full wall-clock arc including the gaps stayed visible. All 49
  existing drawers were deleted and nothing writes one now. The
  per-session event queue holds the same pause/resume stream
  undecimated, survives without a running Emacs, and carries
  `session_id`/`agent_id`/`agent_type`/`source`, none of which the
  drawer recorded. Historical drawers are recoverable from git if that
  judgement turns out to be wrong.

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

**Resolved by the retirement above:** `:SESSIONS:` and `:LOGBOOK:` used
to end up in an unstable relative order, since whichever drawer already
existed was appended to in place while a fresh one landed right after the
property drawer. With only `:LOGBOOK:` left there is nothing to order.

### Stale interval recovery

A crash or system shutdown can kill Emacs (or the whole machine) before
the `Stop` hook gets a chance to pause a running interval, leaving a
CLOCK line open indefinitely. Because
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

**The report asks; it never proposes.** It states the timestamp the
interval opened at — a fact it has — and asks what time work actually
stopped, explicitly instructing the relaying session not to invent one.
`claude-code-ide-org-working-hours` and the educated guess it fed were
retired 2026-08-14 (TODO.org `:ID:` 7771fc63): the premise that absence
is predictable from the clock was measured and failed, with 11 of 19
long gaps beginning *inside* working hours. A wrong guess is worse than
none, because a plausible suggestion is harder to reject than no
suggestion at all.

**Configuration** (`defcustom`s; neither is set in
`~/.config/doom/config.el` today, so both run at their defaults):
- `claude-code-ide-org-session-recovery-enabled` (default `t`) — set nil
  to disable the whole check.
- `claude-code-ide-org-query-files` (default nil, falls back to
  `org-agenda-files`) — which files to scan. Shared with the still-MAYBE
  `org_query` tool in TODO.org for when it's eventually built.

**Recovery**: once the user confirms or corrects a stop time, call
`claude-code-ide-org-close-open-interval` (via `emacsclient`, not an MCP
tool — this is a text-level fix for a stale interval, unrelated to
whatever may currently be clocking) with the heading's `:ID:` and an org
timestamp string. It closes the open CLOCK line (its `:SESSIONS:`
entry is actually open (possibly both), computing the CLOCK duration and
half is inert now that no drawer exists).

**Won't do** (closed out 2026-08-14 with the guess heuristic itself,
TODO.org `:ID:` 7771fc63): using the system sleep/wake/shutdown log
(`pmset -g log` on macOS) as a more precise guess signal than working
hours. It was recorded as "not yet attempted" while a better guess still
seemed worth having; the decision that the report should not guess at
all removes the thing it was meant to improve. The original objection
stands anyway — the log is dominated by per-app power assertions rather
than clean sleep/wake transitions. Note this is *not* the same as
`:ID:` 1a5a5254, which proposes power assertions as a **review-time
attribution** signal; that one is about assigning a span to a heading,
not about guessing when a stale clock stopped, and is unaffected.

---

## Emacs integration (`~/.config/doom/config.el`)

Key settings in the user's Doom config:

```elisp
;; Auto-start the Emacs server — every MCP tool in this project goes
;; through emacsclient, so a reachable server is a hard prerequisite,
;; not just a convenience. Guarded so reloading config.el mid-session
;; doesn't hit server-start's "already running" prompt.
(unless (server-running-p)
  (server-start))

;; org-mode
(after! org
  (setq org-todo-keywords
        '((sequence "TODO" "NEXT" "PLANNING" "DOING" "WAIT" "MAYBE" "|" "DONE" "CANCELLED")))
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

(Only relevant if you ever run two separate Emacs.app processes at once:
the second one's `server-start` will hit the "already running" prompt,
since both claim the same default socket name — a non-issue for the
usual single-instance workflow.)

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
  Tag changes, new headings, and time report summaries don't require
  org-mode's internal state — they're straightforward text operations the
  org skill handles well. Keeping the MCP tool surface small reduces
  per-request token overhead. Cross-file reads used to fall in this bucket
  too, but were slow enough in practice (whole-file reads to answer
  one-line questions) to justify `org_query` as a dedicated tool instead.

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

