# Parallelize background planning across the NEXT/TODO backlog

Tracks TODO.org `:ID: d8444673-b047-4755-b62c-d03df738f16a`.

## Context

The project currently plans one heading at a time, interactively. The user
wants to kick off Plan-Mode-style research for several open `NEXT`/`TODO`
headings at once via background agents, so a batch of plan files can be
produced without serializing on a human driving each one turn by turn.

The blocking constraint (already discovered and written up in the TODO
body, confirmed live multiple times the same day) is that this project's
clock and PLANNING-ownership state are single global in-memory variables
(`claude-code-ide-org--clock-owner-session-id`,
`claude-code-ide-org--planning-owner-session-id`) — there is exactly one
org clock, shared across every session touching the file. N simultaneous
`PLANNING` owners is structurally impossible, not just risky. So the
*research* (read-only, writes only to `~/.claude/plans/<slug>.md`) is safe
to parallelize; only the *write-back* into `TODO.org` (Plan link +
provenance) needs to stay serialized and never touch TODO state or the
clock at all.

Three open questions the TODO body flagged for planning are resolved as
follows (confirmed with the user):
- **Write-back mechanism**: a new dedicated MCP tool, tested via
  `bin/test`, not ad-hoc `emacsclient` calls.
- **Synthetic identifier**: derived from the orchestrating session's own
  real session id with a per-agent suffix — `<session-id>-bg<N>` (e.g.
  `abc123-bg1`, `abc123-bg2`) for the Nth agent in a batch. Never the bare
  real session id (satisfies the TODO's "never this orchestrating
  session's own real session_id" rule), but still traceable back to which
  session ran the batch and which agent within it, rather than an opaque
  fixed sentinel like `"hand-edit"`.
- **Batch size**: capped at 3, matching this project's existing
  Plan-Mode-workflow convention ("launch up to 3 Explore agents in
  parallel").

## Design

### 1. New elisp in `modules/tools/claude-code-ide-org/config.el`

**`claude-code-ide-org--insert-plan-link (plan-file)`** — helper, point
already at the heading (called from inside an `--at-id` callback, same
pattern as every other wrapper). Idempotent: if the heading body already
contains a `[[file:...][Plan]]` link, do nothing; otherwise insert
`[[file:PLAN-FILE][Plan]]` on its own line, right after the property
drawer (and after `:SESSIONS:`/`:LOGBOOK:` drawers if present — use
`org-end-of-meta-data` the way `--append-to-drawer` already locates the
insertion point, then skip past any drawers). No existing function does
this (confirmed by exploration — grepping `.el` files for `Plan]]`/
`plans/` returns zero matches); this is new ground, but small and
mechanical.

**`claude-code-ide-org-log-background-plan (id plan-file session-id)`** —
the exported wrapper, mirroring the shape of every existing tool function:
```elisp
(defun claude-code-ide-org-log-background-plan (id plan-file session-id)
  (claude-code-ide-org--at-id
   id
   (lambda ()
     (claude-code-ide-org--insert-plan-link plan-file)
     (let ((claude-code-ide-org--log-session-id session-id))
       (claude-code-ide-org--log-session-event "Background-planned"))
     (save-buffer)
     (format "Logged background plan for \"%s\"." (org-get-heading t t t t)))))
```
Reuses `claude-code-ide-org--at-id` (fresh `:ID:` resolution, per-call,
matching the documented "other sessions touch this file constantly" hazard)
and `claude-code-ide-org--log-session-event` (correct `:SESSIONS:`
drawer-append semantics, forward-compatible with the pending
ordering-flip TODO) exactly as the TODO body specifies. Deliberately
**does not** touch `org-todo`, `org-clock-in`/`-out`, or either owner
defvar — no TODO transition, no `:LOGBOOK:` entry, by design (the single-
clock model can't represent true parallelism honestly, so the tool
structurally can't produce one).

### 2. New MCP tool registration (same file, `claude-code-ide-make-tool` block)

```elisp
(claude-code-ide-make-tool
 :function #'claude-code-ide-org-log-background-plan
 :name "org_log_background_plan"
 :description "Record a completed background-planning pass on a heading: insert a Plan-file link (idempotent) and append a synthetic :SESSIONS: entry. Never transitions TODO state or touches the clock."
 :args '((:name "id" :type string :description "Target heading's :ID:")
         (:name "plan_file" :type string :description "Absolute path to the plan markdown file")
         (:name "session_id" :type string :description "Synthetic id for this write, e.g. <orchestrating-session-id>-bg1")))
```

### 3. Tests in `config-test.el`

Add to the existing `claude-code-ide-org-test--with-heading` fixture
pattern:
- `log-background-plan-inserts-link-and-sessions-entry` — call once,
  assert the Plan link and a `:SESSIONS:` line tagged with the synthetic
  id both land on disk (`claude-code-ide-org-test--disk-contents`).
- `log-background-plan-is-idempotent` — call twice with the same
  `plan-file`; assert the link appears exactly once.
- `log-background-plan-does-not-touch-todo-or-clock` — assert TODO
  keyword unchanged, `org-clocking-p` unchanged, `:LOGBOOK:` absent/
  unchanged, and neither owner defvar is set by this call.
- `log-background-plan-resolves-fresh-by-id` — mirror the existing
  `set-todo-reports-success-when-hook-cascade-moves-point` pattern:
  mutate the buffer between two calls and confirm the second still lands
  on the right heading.

### 4. Skill documentation — new section in `.claude/skills/org/SKILL.md`

Add a subsection (e.g. "Background-planning a batch of NEXT/TODO
headings") documenting the orchestration workflow for the *main* Claude
Code session driving this:

1. Use `org_query` to list open `NEXT`/`TODO` candidates.
2. Pick up to 3 headings per batch.
3. Launch one background agent per heading (`Agent` tool, read-only
   research + `Write`-ing its own `~/.claude/plans/<slug>.md`). Each
   agent's brief must state explicitly: never call `org_set_todo`,
   `org_clock_in`, or any other state/clock-mutating tool — research and
   plan-file writing only.
4. As each agent reports, call `org_log_background_plan` for its heading
   with `session_id` = `<this session's real session id>-bg<N>` — one
   call at a time, only after that agent's plan file is finalized
   (serialized write-back, per the TODO's explicit rule).
5. Leave TODO state as-is (still `NEXT`/`TODO`) — a human (or a later,
   separate interactive session) reviews each plan and decides whether/
   when to promote it to `PLANNING`/`DOING`.
6. Don't auto-commit the resulting `TODO.org` diff; leave it for explicit
   review (per the TODO body and the still-open commit-safety questions
   in the two cross-referenced TODO headings).

### 5. `CLAUDE.md` MCP tools table

Add `org_log_background_plan` as a new row (wraps: custom, not a single
`org-*` primitive — insert-link + `--log-session-event`), same table
format as the other nine tools.

## Verification

- `bin/test` — new ERT tests above must pass alongside the existing 79.
- `org-dev` skill's live-reload step (`emacsclient -e '(load-file
  "modules/tools/claude-code-ide-org/config.el")'`) to pick up the new
  tool registration in a running Doom session, then a manual smoke test:
  call `org_log_background_plan` via the MCP tools server against a
  scratch heading and confirm the Plan link + `:SESSIONS:` entry appear
  correctly, and that no `:LOGBOOK:` entry or TODO-state change occurs.
- Skill-content verification is inherently manual/fuzzy per CLAUDE.md's
  testing rule (trigger-matching and workflow-following aren't
  mechanically testable) — do one real dry run: query the backlog, launch
  a real batch of up to 3 background planning agents against genuine open
  headings, and confirm the write-back lands correctly end to end.

## After approval

Per CLAUDE.md's Plan-link rule, add
`[[file:~/.claude/plans/warm-marinating-puddle.md][Plan]]` to TODO.org
heading `d8444673-b047-4755-b62c-d03df738f16a`'s body as soon as this
plan is finalized — a separate step, not gated on a `DOING` transition,
and requiring its own explicit approval per the "new org heading"/
"Plan-approval isn't heading-wording approval" rules before any further
edits proceed.
