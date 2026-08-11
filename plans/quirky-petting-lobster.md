# Add a `PLANNING` TODO state, driven by the `ExitPlanMode` matcher

Tracked as `TODO.org` heading `b95b9fba-f78e-48fe-8546-988709cce309` (currently `DOING`).

## Context

Claude Code has no dedicated hook event for entering/leaving Plan Mode — only
`PreToolUse`/`PostToolUse` matched on the `ExitPlanMode` tool name exist, and
nothing fires on *entering* plan mode since that's not represented as a
matchable transition the way `ExitPlanMode` is. Today, planning work (time
spent in Plan Mode) is invisible to this project's TODO-state machine: a
heading sits in `NEXT` or jumps straight to `DOING`, with no way to see "this
was planned before it was implemented" or clock that planning time separately
from a manual glance at conversation history.

The fix: a new `PLANNING` keyword between `NEXT` and `DOING`. Entry is a
model-driven judgment call (same category as the existing "transition to
DOING before starting work" rule — not hook-inferable). Exit is automatic: a
`PostToolUse` hook on `ExitPlanMode` promotes `PLANNING` → `DOING` the instant
a plan is approved and execution begins, using the same continuous clock
interval (no close/reopen). A single "plan and implement" prompt must still
produce these two transitions at their correct, separate times, never a
premature jump to `DOING`.

## Design decisions

1. **Sequence**: `TODO → NEXT → PLANNING → DOING → WAIT → MAYBE | DONE → CANCELLED`.
2. **PLANNING opens a clock**, same as DOING — planning time is real tracked
   work; CLAUDE.md's dual-timekeeping note already treats many short CLOCK
   intervals per heading as intended granularity, so no LOGBOOK-level
   distinction between planning and implementation time is needed.
3. **PLANNING → DOING does not close/reopen the clock.** This falls out for
   free from `claude-code-ide-org--trigger-auto-clock-in`'s existing
   "already-clocked-here" guard — no new code needed for this specifically.
4. **Session-id correlation is needed after all — revised from the original
   plan-session draft.** The initial reasoning ("PLANNING is only ever set by
   the model on its own heading, so clock-marker identity alone is enough")
   covers *setting* PLANNING correctly but not *promoting* it correctly: the
   promote function fires on *any* session's `ExitPlanMode` call, and with no
   session check, a concurrent session B's unrelated `ExitPlanMode` would
   promote session A's still-in-progress `PLANNING` heading purely because
   it happens to own the single global clock — a real cross-session race,
   not just a low-cost timing gap. Fix: track *which session* set the
   current `PLANNING` state, and only promote for that session.
   - New defvar `claude-code-ide-org--planning-owner-session-id`, sibling to
     the existing `claude-code-ide-org--clock-owner-session-id` (same
     single-global-value shape — org only ever has one running clock, so
     "last session to set PLANNING" is all that's meaningful).
   - Recorded via a new `PostToolUse` hook matched on `org_set_todo`
     (`bin/hooks/posttooluse-record-planning-owner`) that captures the
     calling session's `session_id` whenever `tool_input.state` is
     `"PLANNING"`, regardless of whether the transition actually succeeded
     (a phantom owner recorded for a blocked/failed transition is harmless —
     the promote function's own state check never matches a heading that
     never actually became PLANNING).
   - **No `jq` needed for either this hook or the `ExitPlanMode` one** —
     revised from the original draft, which assumed `jq -R -s .`-style
     string encoding like `session-pause`/`-resume` use. Since neither hook
     needs to interpolate an untrusted *field value* into the `emacsclient
     -e` expression (only a `mktemp`-generated temp-file *path*, which is
     never attacker/session-controlled), the injection-safe-encoding problem
     `jq -R -s .` exists to solve doesn't arise here at all. Instead: the
     shell script writes stdin verbatim to a temp file and passes only that
     path to `emacsclient -e`; Elisp reads and parses the JSON itself via
     `json-read-file` (no external dependency) and extracts whatever fields
     it needs. This is the same "pure Emacs" pattern already established by
     `claude-code-ide-org--statusline-model-name` (reads the statusLine
     hook's JSON payload directly, no `jq`) — not a new idiom, reuse of one
     this project already chose once. Also directly answers TODO.org's own
     open "Evaluate choice of shell" heading's option 1 in the affirmative
     for this specific case.
   - The promote function takes the `ExitPlanMode` hook's own `session_id`
     as a parameter and only refuses when there's a **known, different**
     owner — a `nil` owner (no `org_set_todo`-driven PLANNING was ever
     recorded, e.g. a hand-edited state) stays permissive, mirroring
     `claude-code-ide-org--clock-owner-session-id`'s own established
     precedent for the ordinary single-session case. Owner is cleared after
     a successful promotion.
   **Important scoping fact discovered in planning, still holds**: Plan Mode
   itself forbids non-readonly tool calls, so `org_set_todo` can only be
   called *before* `EnterPlanMode`, never during. When the user enters plan
   mode directly (shift-tab, not a model-initiated `EnterPlanMode` call),
   there is no window to set `PLANNING` at all — so the hook's "clocked
   heading isn't PLANNING → no-op" branch is the **common** case, not an
   edge case, and gets documented as such rather than treated as a gap.
5. **`--blocker-clock-running-p` and `pretooluse-transition-guard` need no
   changes** — neither inspects the *current* state, only clock-marker
   identity, so both already work correctly for a clocked PLANNING heading
   exactly as they do for DOING. (Their comments get a wording touch-up for
   accuracy, not a logic change.)
6. **Plan-rejection gating: accepted gap, not gated.** `PostToolUse` fires
   whether the plan was approved or rejected, with no reliable
   approval/rejection signal to gate on — confirmed by direct experience
   during this planning session: attempting to instrument a temporary
   capture hook to inspect a live `ExitPlanMode` payload is itself a
   non-readonly action, which re-triggers Plan Mode re-entry before the
   capture can run, which then blocks the very instrumentation needed to
   capture it. Circular by construction — there's no way to observe this
   payload from inside a session without leaving Plan Mode first, at which
   point the event being captured has already passed. Documented as an
   accepted gap in the same register CLAUDE.md already uses for accepted
   "self-corrects" risk (the concurrent-session clock entry precedent): a
   stray promotion after a rejected plan is low-cost and self-corrects the
   next time the heading's real state is set explicitly. No approval-gating
   parameter is added to the function or hook. Unaffected by decision 4's
   session-ownership fix — that fix scopes promotion to the *correct*
   session and heading, but says nothing about approve-vs-reject *within*
   that session's own plan, so this gap remains exactly as described.

## Implementation

### `modules/tools/claude-code-ide-org/config.el`
- **MCP tool schema** (`org_set_todo`, ~line 1834-1845): add `PLANNING` to
  the `:description` string (currently "Valid states: TODO NEXT DOING WAIT
  MAYBE DONE CANCELLED", ~line 1837) and the `state` arg description. Add a
  clause noting PLANNING auto-promotes to DOING on `ExitPlanMode`.
- **`claude-code-ide-org-set-todo` docstring** (~line 1101-1102): same
  keyword-list addition.
- **`claude-code-ide-org--trigger-auto-clock-in`** (~line 1555): change the
  `:to` check from `(equal (plist-get change-plist :to) "DOING")` to
  `(member (plist-get change-plist :to) '("DOING" "PLANNING"))`. Update its
  docstring accordingly.
- **New defvar `claude-code-ide-org--planning-owner-session-id`** (near
  `claude-code-ide-org--clock-owner-session-id`, ~line 302): `nil` by
  default; holds the `session_id` of whichever session most recently set a
  heading to `PLANNING` via `org_set_todo`.
- **New function `claude-code-ide-org--maybe-record-planning-owner`** (plain
  `defun`, called via `emacsclient -e` by the new `org_set_todo`
  `PostToolUse` hook, not registered on any org hook). Takes a
  `payload-path` argument (a temp-file path), reads it with `json-read-file`,
  and if `tool_input.state` is `"PLANNING"`, sets
  `claude-code-ide-org--planning-owner-session-id` to the payload's
  `session_id`. No success/failure check on the underlying transition (see
  decision 4 — a phantom owner recorded for a blocked transition is
  harmless).
- **New function `claude-code-ide-org--promote-planning-to-doing`** (plain
  `defun`, not an MCP tool, not registered on any hook — called directly via
  `emacsclient -e`, exactly like `claude-code-ide-org-session-pause`/`-resume`
  already are). Placed near the other transition-enforcement functions
  (~after line 1577). Takes a `session-id` argument (read from the
  `ExitPlanMode` hook's payload the same way, via `json-read-file`).
  Behavior:
  - No clock running → no-op, return a descriptive string.
  - Clock running but clocked heading's state isn't exactly `"PLANNING"` →
    no-op, return a descriptive string.
  - Clock running on a `PLANNING` heading, but
    `claude-code-ide-org--planning-owner-session-id` is non-nil and doesn't
    match `session-id` → no-op, return a descriptive string ("belongs to a
    different session"). This is the new cross-session guard.
  - Clock running on a `PLANNING` heading, and owner is either `nil` or
    matches `session-id` → `(let ((org-inhibit-logging t)) (org-todo
    "DOING"))`, append a LOGBOOK note via the existing
    `claude-code-ide-org--format-log-state-line` +
    `claude-code-ide-org--append-to-drawer` helpers (both already exist,
    used by the sibling single-NEXT-per-level trigger functions), clear
    `claude-code-ide-org--planning-owner-session-id` back to `nil`, save the
    buffer, return a success string.
  - The `org-inhibit-logging` guard is required, not optional: this
    project's own live-confirmed finding (documented in
    `claude-code-ide-org-set-todo`'s docstring) is that even a bare `!`
    marker's log-note defers through `org-add-log-note`/`post-command-hook`
    and **blocks indefinitely** when triggered non-interactively via
    `emacsclient -e` — exactly this function's call path. Skipping this
    would hang the hook the first time it fires live.
  - No approval-gating parameter (see decision 6) — the function always
    promotes when it finds a clocked, session-owned (or unowned) PLANNING
    heading, regardless of whether the plan that triggered `ExitPlanMode`
    was approved or rejected.

### `modules/tools/claude-code-ide-org/config-test.el`
- **Fixture updates**: the `#+TODO:` line is hardcoded in **three** places
  (confirmed via grep — lines ~47, ~125, ~642, not just one), all reading
  `#+TODO: TODO NEXT(n!) DOING(d!) WAIT(w@/!) MAYBE(m!) | DONE(D!)
  CANCELLED(c@)`. All three need `PLANNING(p!)` inserted between `NEXT(n!)`
  and `DOING(d!)`.
- **New tests** (alongside the existing auto-clock-in tests, reusing the
  established `(let ((org-trigger-hook (list #'claude-code-ide-org--trigger-auto-clock-in))) ...)`
  isolation pattern):
  - auto-clock-in fires on a bare `org-todo "PLANNING"` (mirrors the
    existing DOING test)
  - auto-clock-in skips re-clocking when already clocked on that same
    PLANNING heading (mirrors the existing DOING test)
  - `--promote-planning-to-doing` promotes a clocked PLANNING heading to
    DOING when the owner session matches (or owner is nil), with exactly one
    CLOCK line on disk before and after (explicit duplicate-clock
    regression) and a LOGBOOK "Auto-promoted" note present
  - `--promote-planning-to-doing` no-ops (state unchanged) when the clocked
    heading is DOING, not PLANNING
  - `--promote-planning-to-doing` no-ops when nothing is clocked, no error
  - `--promote-planning-to-doing` no-ops when
    `claude-code-ide-org--planning-owner-session-id` is set to a
    **different** session-id than the one passed in — the cross-session
    regression this whole revision exists for; assert the heading stays
    PLANNING, the clock stays open, and the owner var is left unchanged
  - `--promote-planning-to-doing` promotes normally when the owner var is
    `nil` (never recorded — e.g. a hand-edited PLANNING) — confirms the
    permissive fallback for the ordinary single-session/manual case
  - `--maybe-record-planning-owner` sets the owner var from a `PLANNING`
    payload, and leaves it untouched for a payload requesting any other
    state
  - owner var is cleared to `nil` after a successful promotion (not just
    left stale for the next unrelated PLANNING episode)
  - no rejection-gating test — there is no gate (decision 6)
- Run the full suite to confirm all pre-existing tests still pass unmodified
  against the updated fixture (109 today; nothing else in the fixture
  depends on the exact old keyword list).

### New hook: `bin/hooks/posttooluse-record-planning-owner`
`PostToolUse`, matcher `mcp__emacs-tools__org_set_todo`. No `jq` — writes
stdin verbatim to a `mktemp` temp file, passes only that path to
`emacsclient -e`, lets Elisp parse the JSON itself:
```bash
#!/usr/bin/env bash
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT
cat > "$tmpfile"
emacsclient -e "(claude-code-ide-org--maybe-record-planning-owner \"$tmpfile\")" >/dev/null 2>&1
exit 0
```
Fails soft, always exit 0 — this must never block a `org_set_todo` call that
already went through (or was denied by) the transition guard.

### New hook: `bin/hooks/exitplanmode-promote-planning`
Same no-`jq`, temp-file shape as the hook above. Reads `session_id` out of
the `ExitPlanMode` `PostToolUse` payload the same way
(`claude-code-ide-org--promote-planning-to-doing` does the `json-read-file`
parsing on the Elisp side, mirroring `--maybe-record-planning-owner`). Fails
soft, always exit 0 — `PostToolUse` firing means `ExitPlanMode` already
completed, so this must never block Claude Code. Header comment documents
the accepted rejection-gating gap from decision 6 directly (no separate
live-capture step required first).

### `.claude/settings.json`
Two new `PostToolUse` array entries (separate from the existing
`org_clock_in|org_clock_out` entry — different matchers, not merged):
```json
{
  "matcher": "mcp__emacs-tools__org_set_todo",
  "hooks": [
    { "type": "command",
      "command": "${CLAUDE_PROJECT_DIR}/bin/hooks/posttooluse-record-planning-owner",
      "timeout": 10 }
  ]
},
{
  "matcher": "ExitPlanMode",
  "hooks": [
    { "type": "command",
      "command": "${CLAUDE_PROJECT_DIR}/bin/hooks/exitplanmode-promote-planning",
      "timeout": 10 }
  ]
}
```
Note: `ExitPlanMode` is a built-in Claude Code tool, not MCP-namespaced —
matcher is the bare name, no `mcp__...__` prefix. `org_set_todo`'s matcher
already exists once, on `PreToolUse` (`pretooluse-transition-guard`) — this
is a distinct, additional `PostToolUse` entry for the same tool name, not a
merge with that one.

### `TODO.org`
Line 1: insert `PLANNING(p!)` between `NEXT(n!)` and `DOING(d!)` in the
`#+TODO:` line. (Confirmed via grep: `DONE.org` carries no `#+TODO:` line of
its own — nothing to change there.)

### `~/.config/doom/config.el` (outside this repo)
Lines 65-66: insert `"PLANNING"` between `"NEXT"` and `"DOING"` in the
`org-todo-keywords` sequence. No `!`/`@` marker syntax here, matching this
file's existing convention (the marker/no-marker asymmetry between this file
and `TODO.org`'s file-local override already exists today and is out of
scope).

### `CLAUDE.md`
- File header example `#+TODO:` line: add `PLANNING` in position.
- TODO keyword semantics table: new row between `NEXT` and `DOING`.
- State transition rules table: add `NEXT → PLANNING` (opens clock),
  `PLANNING → DOING` (no clock action — explicitly called out as the one
  exception), `PLANNING → {DONE,WAIT,CANCELLED}` (closes clock, same as from
  DOING). Generalize the existing blanket rules ("any transition to DOING
  must open a clock" / "any transition from DOING must close the clock
  first") to also cover PLANNING, with the PLANNING→DOING handoff called out
  as the documented exception to the close-first rule.
- New standing-instruction paragraph (same style/location as the existing
  DOING-transition and new-task-heading rules): entering `PLANNING` is a
  model judgment call made *before* calling `EnterPlanMode` (not during —
  Plan Mode forbids non-readonly tool calls); leaving `PLANNING` is *not* a
  model decision, it's automatic via the `ExitPlanMode` hook; a "plan and
  implement" prompt must still produce both transitions at their correct
  separate times; and — explicitly, so it isn't mistaken for a bug — Plan
  Mode entered directly by the user (shift-tab) has no `PLANNING` transition
  to promote, so the hook silently no-ops in that case.
- One clarifying sentence added to the existing "approved Plan Mode plan"
  rule (~line 172): the auto-promotion hook only ever promotes an
  *already-clocked, already-PLANNING* heading — it never touches a newly
  created heading the plan describes creating, so that rule's "get explicit
  approval before DOING" for new headings is unaffected.
- State explicitly where the Plan-file link (`[[file:~/.claude/plans/<slug>.md][Plan]]`)
  gets added: still at the DOING transition (unchanged), whether that DOING
  is reached via the auto-promotion hook or set directly — the plan file
  doesn't exist yet when PLANNING is set, since it's Plan Mode's own output.
- Wording touch-up to `pretooluse-transition-guard`'s file-header comment
  ("DOING or PLANNING -> {DONE,WAIT,CANCELLED}") for accuracy — no logic
  change.
- Final grep pass across CLAUDE.md for any other place enumerating the full
  keyword list, to make sure none were missed.
- One sentence added noting the cross-session guard: the `ExitPlanMode`
  promotion only fires for the session that set `PLANNING`, tracked via
  `claude-code-ide-org--planning-owner-session-id` — the same pattern as
  `claude-code-ide-org--clock-owner-session-id`, applied to this new hook.

## Verification

1. **`bin/test`**: full suite green — 109 existing + ~10-11 new PLANNING
   tests (including the cross-session-guard and nil-permits cases from
   decision 4's revision). Specifically confirm the "no duplicate clock
   entry" test and the "different owner refuses" test both pass — the
   latter is the one that actually proves the race this revision exists to
   close is closed.
2. **Live manual pass** against the running Doom Emacs, via the `org-dev`
   skill's reload/verify workflow:
   - Reload `config.el`, confirm no load errors.
   - Pick a real `:ID:`-tagged heading, set it `NEXT`, then `PLANNING` via
     `org_set_todo` — confirm a clock opened, the state shows `PLANNING`,
     and `claude-code-ide-org--planning-owner-session-id` is now set
     (inspect via `emacsclient -e`).
   - Call `claude-code-ide-org--promote-planning-to-doing` directly via
     `emacsclient -e`, passing the same session-id — confirm `DOING`,
     exactly one CLOCK line, an "Auto-promoted" LOGBOOK note, and the owner
     var cleared back to `nil` afterward.
   - Repeat the PLANNING setup, then call `--promote-planning-to-doing` with
     a **different**, made-up session-id — confirm it refuses, the heading
     stays PLANNING, and the owner var is untouched. This is the direct live
     analog of the concurrent-session simulation the earlier
     `clock-owner-session-id` work did via fabricated hook payloads.
   - Repeat, this time driving it through the real hook path end to end
     (actual `EnterPlanMode`→approve→`ExitPlanMode` in a live session
     against this project) — this is the only step that validates both the
     `"ExitPlanMode"` matcher string and the `posttooluse-record-planning-owner`
     wiring are actually correct, which can't be confirmed by reading
     `.claude/settings.json` alone.
   - Confirm both original no-op branches live: nothing clocked, and a
     DOING (not PLANNING) heading clocked — verify no state corruption
     either way.
   - Confirm the accepted rejection-gating gap live too: reject a plan with
     a PLANNING heading clocked (owned by the same session), and observe
     (not fix) that it still gets promoted — this documents the known
     limitation with a real example rather than just asserting it.
3. Record in the outcome summary (per CLAUDE.md's DONE-archival convention)
   which of these ran live vs. only via `bin/test`, and the resolution of
   TODO.org's three original open questions plus the cross-session race
   found and fixed during planning itself (clock semantics, trigger-hook
   interaction, session→heading mapping — now solved via
   `claude-code-ide-org--planning-owner-session-id` — and the still-accepted
   rejection-gating gap, all as described in Design decisions above).

## Critical files
- `modules/tools/claude-code-ide-org/config.el`
- `modules/tools/claude-code-ide-org/config-test.el`
- `.claude/settings.json`
- `CLAUDE.md`
- `TODO.org`
- `~/.config/doom/config.el`
- `bin/hooks/session-pause` (pattern reference for hook shape, not payload
  handling)
- `bin/statusline.sh` / `claude-code-ide-org--statusline-model-name` (pattern
  reference for the no-`jq`, `json-read-file`-based payload parsing used by
  both new hooks)
