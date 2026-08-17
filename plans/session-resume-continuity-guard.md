# Plan — session-resume blindly inherits any session's last-clocked heading

`:ID: 582cc7f4-41a2-4666-ad3f-1b76b459147e`

## Context

`claude-code-ide-org-session-resume` (`modules/tools/claude-code-ide-org/config.el:461-514`)
is the `UserPromptSubmit` hook's elisp entry point. When no clock is
currently running, its final `cond` clause calls `org-clock-in-last`
unconditionally — resuming whichever heading sits at the head of the
single, global `org-clock-history`, regardless of which Claude Code
session paused it there or whether anyone is actually working on it.

The existing session-identity mechanism from `337f7fb2-b9e9-4c02-82dd-d88e60df364b`
(`claude-code-ide-org--clock-owner-session-id`, set only by
`session-resume`, cleared by `session-pause`) only guards a clock that is
*actively running* from being paused or stolen by a different session
mid-flight (the first `cond` clause in `session-resume`, and the guard in
`session-pause`). It says nothing about whether an *idle* clock — one
already paused, sitting in `org-clock-history` — should be silently
reopened by whoever's turn boundary happens to fire next. That's exactly
the gap this heading reports, confirmed live: a deliberate, explicit
clock-out (not the DOING task actually being worked on that turn) was
immediately followed by `session-resume` silently reopening an unrelated
heading (`b95b9fba-f78e-48fe-8546-988709cce309`, "PLANNING TODO state"),
whose own `:SESSIONS:` history showed a *different* concurrent session's
`session-pause`/`session-resume` calls as the true most recent activity.

Read fresh from TODO.org (`grep -n '582cc7f4\|337f7fb2\|d150c02e' TODO.org`)
— the heading's own text has already sharpened the fix direction beyond
the original capture: make `session-resume` conditional on session
continuity — only call `org-clock-in-last` if the clock's most recent
close belongs to *this same session's* ID; otherwise leave it clocked
out and require an explicit `org_clock_in`.

**Relationship to `d150c02e-06fe-4514-bf69-e2cc5d8df4c7`** (org_clock_in
doesn't record clock ownership): re-examined during research, and the
dependency is real but differently shaped than the heading's prose
suggests. `d150c02e` is entirely about the *open* side —
`claude-code-ide-org--clock-owner-session-id` is set only by
`session-resume`, never by `claude-code-ide-org-clock-in` or the
`org-trigger-hook` auto-clock-in path. This plan's new tracking variable
(below) is entirely about the *close* side, and is self-contained: it is
written only by `session-pause` and read only by `session-resume`, so it
does not depend on `d150c02e` landing first to be internally correct.

The real co-requisite is on the same close side, not `d150c02e` itself:
`org_clock_out` (the MCP tool, `claude-code-ide-org-clock-out` called
directly, e.g. a deliberate mid-conversation clock-out with no DOING task
in view — precisely the scenario that triggered this bug report) carries
no `session_id` at all in its MCP argument schema (confirmed:
`config.el:1945-1946`'s `org_clock_out` tool registration takes no
session-id parameter, only `bin/hooks/session-pause` threads one through
from its Stop-hook JSON payload). So a manual/explicit clock-out can
never populate this plan's new "who closed it" tracking, and any
`session-resume` call after one will correctly find "unknown" and
refuse — which is the *correct*, safe behavior per the heading's own
"otherwise leave it clocked out" directive, not a limitation to
apologize for. If a future fix threads `session_id` into `org_clock_out`
too (a natural sibling to `d150c02e`'s proposed `PostToolUse`-hook
approach, but for `org_clock_out` rather than `org_set_todo`), the
practical *frequency* of refusal drops, but this plan's correctness does
not depend on that happening — worth noting explicitly in TODO.org as a
"see also" rather than silently assumed.

## Design

### New tracking variable

Add, alongside the existing two owner defvars
(`config.el:302-329`):

```elisp
(defvar claude-code-ide-org--clock-last-paused-by nil
  "Cons (SESSION-ID . HEADING-ID) recording which Claude Code session's
`claude-code-ide-org-session-pause' call, and which heading, most
recently actually closed a running clock -- or nil if unknown (no
session-aware pause has happened, or the clock was closed some other
way, e.g. a direct `org_clock_out' MCP tool call, which carries no
session_id and so cannot update this variable). Consulted by
`claude-code-ide-org-session-resume' to decide whether an idle clock
may be auto-resumed via `org-clock-in-last', or must be left clocked
out pending an explicit `org_clock_in' (TODO.org :ID:
582cc7f4-41a2-4666-ad3f-1b76b459147e). Deliberately the *opposite*
default from `claude-code-ide-org--clock-owner-session-id' and
`claude-code-ide-org--planning-owner-session-id', which both treat an
*unknown* owner as permissive (preserving ordinary single-session
behavior for a clock/PLANNING-state that is already, correctly,
running/set). This variable instead guards whether an *idle* clock
should spontaneously reopen at all -- there unknown must mean refuse,
not permit, or this is not a fix. Cleared to nil the moment
`session-resume' actually performs a resume (successful or not is
irrelevant; what matters is that the 'paused' bookkeeping is now
stale) so that only a fresh, session-aware `session-pause' call can
re-arm auto-resume for the next idle period. Purely in-memory: resets
naturally on Emacs restart -- note that `org-clock-persist' being
`history' means `org-clock-history' itself *does* survive a restart,
so a post-restart resume attempt correctly finds this variable nil
and refuses, rather than resurfacing this exact bug across restarts.")
```

### `session-pause` — record who actually closed the clock

In `claude-code-ide-org-session-pause` (`config.el:419-447`), inside the
`prog1` branch (the one that actually calls `claude-code-ide-org-clock-out`,
as opposed to the early "owned by a different session" no-op return),
capture whether a clock was running *and which heading* before calling
`clock-out`, and record it:

```elisp
(defun claude-code-ide-org-session-pause (&optional session-id)
  ...
  (let ((claude-code-ide-org--log-source (or claude-code-ide-org--log-source "session-pause"))
        (claude-code-ide-org--log-session-id (or claude-code-ide-org--log-session-id session-id)))
    (if (and session-id
             claude-code-ide-org--clock-owner-session-id
             (not (equal session-id claude-code-ide-org--clock-owner-session-id)))
        "Clock is owned by a different session; not pausing."
      (let* ((was-clocking (org-clocking-p))
             (heading-id (and was-clocking
                               (org-with-point-at org-clock-marker
                                 (org-entry-get nil "ID")))))
        (prog1 (claude-code-ide-org-clock-out)
          (setq claude-code-ide-org--clock-owner-session-id nil)
          (when was-clocking
            (setq claude-code-ide-org--clock-last-paused-by
                  (cons session-id heading-id))))))))
```

Note this records `session-id` even when nil (a manual/legacy pause) —
that's correct: an explicit `session-resume` call *with* a session-id
should not treat a nil-session pause as "mine," and a nil-session
`session-resume` call bypasses this whole check anyway (see below), so
recording nil here is harmless and keeps the data honest. Only updates
when a clock was *actually* running before the call (`was-clocking`) —
a no-op pause on an already-idle clock must not spuriously claim credit
for "the last close."

### `session-resume` — gate the idle-resume on continuity

New helper, mirroring the existing `claude-code-ide-org--clock-history-head-done-p`
(`config.el:449-459`) in style and placement:

```elisp
(defun claude-code-ide-org--clock-last-pause-matches-p (session-id)
  "Non-nil if SESSION-ID matches the session recorded in
`claude-code-ide-org--clock-last-paused-by' *and* that record's
heading-id matches the heading at the head of `org-clock-history' --
i.e. SESSION-ID is confirmed to be the one whose
`claude-code-ide-org-session-pause' call most recently closed exactly
the clock `org-clock-in-last' is about to reopen. Callers must already
have established `org-clock-history' is non-nil."
  (and claude-code-ide-org--clock-last-paused-by
       (equal session-id (car claude-code-ide-org--clock-last-paused-by))
       (equal (cdr claude-code-ide-org--clock-last-paused-by)
              (org-with-point-at (car org-clock-history)
                (org-entry-get nil "ID")))))
```

The heading-id comparison (not just session-id) matters for a scenario
distinct from the one originally reported but just as real: session A
pauses heading H; session B (or this same session, via a direct
`org_clock_in`/`org_set_todo` call — see the `d150c02e` open-side gap)
clocks into and back out of a *different* heading K through some path
that doesn't update this variable; `org-clock-history`'s head is now K,
but a naive session-id-only check would still see "A" and let A's later
resume reopen K, the wrong heading. Comparing both fields closes that.

In `claude-code-ide-org-session-resume` (`config.el:461-514`), insert a
new `cond` clause between the existing "history head is DONE" clause and
the final unconditional `(t ...)` clause:

```elisp
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
 ((and session-id
       (not (claude-code-ide-org--clock-last-pause-matches-p session-id)))
  "Most recent pause wasn't this session's; not auto-resuming.")
 (t
  (org-clock-in-last)
  (if (not (org-clocking-p))
      "org-clock-in-last did not start a clock."
    (org-with-point-at org-clock-marker
      (claude-code-ide-org--log-session-event "Resumed"))
    (setq claude-code-ide-org--clock-owner-session-id session-id)
    (setq claude-code-ide-org--clock-last-paused-by nil)
    (let ((buffer (marker-buffer org-clock-marker)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (save-buffer))))
    (format "Resumed: \"%s\"" org-clock-heading))))
```

Two things to preserve exactly:

- **`session-id` nil reproduces the exact original unconditional
  behavior**, same idiom as every other guard in this file (the new
  clause's `(and session-id ...)` short-circuits to nil when the caller
  passed no session context, e.g. a manual/test call or an older Claude
  Code hook payload lacking `session_id` — falls straight through to the
  unconditional `t` branch, unchanged from today).
- **Clear `claude-code-ide-org--clock-last-paused-by` to nil on every
  successful resume**, not just when the new guard fired. Without this,
  the sequence that produced the actual reported bug still slips through:
  `session-pause("S1")` pauses H → `session-resume("S1")` resumes H
  (matches, proceeds) → this session deliberately calls `org_clock_out`
  directly (no session-id available, so `clock-last-paused-by` is *not*
  updated and still reads `("S1" . H)` from the earlier pause) → the next
  turn's `session-resume("S1")` would wrongly still match and reopen H.
  Clearing on every successful resume means only a *subsequent, fresh*
  `session-pause` call can re-arm auto-resume, so a manual clock-out
  correctly leaves the trail cold.

### Files touched

- `modules/tools/claude-code-ide-org/config.el` — new
  `claude-code-ide-org--clock-last-paused-by` defvar (near
  `--clock-owner-session-id`/`--planning-owner-session-id`, ~line 302-329);
  new `claude-code-ide-org--clock-last-pause-matches-p` helper (near
  `--clock-history-head-done-p`, ~line 449-459); edits to
  `claude-code-ide-org-session-pause` (~line 419-447) and
  `claude-code-ide-org-session-resume` (~line 461-514) as above.
- `modules/tools/claude-code-ide-org/config-test.el` — see below.
- **No changes needed to `bin/hooks/session-pause` or
  `bin/hooks/session-resume`.** Both already thread `session_id` from
  their Stop/UserPromptSubmit JSON payload through to the elisp entry
  points unconditionally (confirmed by reading both scripts in full);
  this plan only changes what the elisp side *does* with a session-id
  it already receives. This is a real finding worth stating plainly, not
  an oversight.
- No changes needed to `bin/hooks/exitplanmode-promote-planning` or
  `bin/hooks/posttooluse-record-planning-owner` — unrelated code paths
  (PLANNING-ownership, not clock-ownership).

## Test-isolation detail (not optional)

`claude-code-ide-org-test--with-heading` (`config-test.el:20-44`)
already `let`-binds `org-clock-history` and
`claude-code-ide-org--planning-owner-session-id` to nil per test, but
*not* `claude-code-ide-org--clock-owner-session-id` (an existing gap in
that macro, out of scope to fix here). For the new
`claude-code-ide-org--clock-last-paused-by` variable, follow the more
careful precedent (`--planning-owner-session-id`, added specifically
when that sibling feature was built) rather than the older gap: add
`(claude-code-ide-org--clock-last-paused-by nil)` to the macro's `let*`
bindings. Without this, test order could leak a stale cons between
tests and produce a flaky pass/fail depending on run order.

## New regression tests (config-test.el, alongside the existing
"Session identity" block at line ~327-390)

1. **`session-resume-noop-for-unmatched-last-pause`** — clock in, pause
   with `"session-A"`, then resume with `"session-B"`. Must return
   `"Most recent pause wasn't this session's; not auto-resuming."` and
   leave the clock **not running** (`(should (not (org-clocking-p)))`) —
   distinct from the existing `session-resume-noop-for-different-session-owner`
   test, which exercises the *running*-clock steal guard (clock left
   running, owned by A); this new test exercises the *idle*-clock guard
   (clock left stopped, nobody's).

2. **`session-resume-succeeds-when-last-pause-matches-session`** —
   clock in, pause with `"session-A"`, resume with `"session-A"`. Must
   succeed (`"Resumed: \"Test heading\""`), and a second pause/resume
   cycle with the same session-id must also still succeed (proves
   clearing `clock-last-paused-by` on resume doesn't break the ordinary
   repeated per-turn pause/resume flow — each `session-pause` re-arms it
   for the next `session-resume`).

3. **`session-resume-noop-after-manual-clock-out-different-session`** —
   the test that most directly reproduces the reported bug shape: clock
   in, pause with `"session-A"`, resume with `"session-A"` (succeeds,
   clears the tracking var per the design above), then call
   `claude-code-ide-org-clock-out` **directly** (simulating a deliberate
   `org_clock_out` MCP call with no session-id available), then attempt
   `claude-code-ide-org-session-resume "session-A"` again. Must refuse
   (`"Most recent pause wasn't this session's; not auto-resuming."`) even
   though it's the *same* session asking — because the manual close left
   no continuity record. This is the deliberately conservative behavior
   the design section above justifies, not a bug in the plan.

4. **`session-resume-with-no-session-id-still-unconditional`** — clock
   in, pause with `"session-A"` (or with no session-id — cover both),
   resume with **no session-id at all**. Must still succeed
   unconditionally, exactly as all 5 pre-existing session-pause/-resume
   tests already assert — proves the new guard never fires for a
   session-id-less caller.

5. All 5 pre-existing `session-resume`/`session-pause` tests
   (`config-test.el:284-390`) must keep passing **unchanged** — verified
   by inspection during design (each one either never reaches the new
   `cond` clause, because it fails an earlier clause or omits
   session-id, or matches by construction) and re-confirmed by actually
   running `bin/test`.

## Verification

- `bin/test`: all pre-existing tests pass unchanged (currently 90-ish
  total per the running count in TODO.org's recent DONE entries — get
  the exact baseline by running `bin/test` once before implementing),
  plus the 5 new tests above, matching `337f7fb2`'s own verification
  depth (it added 5 regression tests for the sibling running-clock
  guard; this is the idle-clock counterpart).
- End-to-end through the actual hook scripts, same pattern `337f7fb2`
  used and confirmed still applies here unchanged: fabricate
  Stop/UserPromptSubmit-shaped JSON payloads with distinct `session_id`
  values (e.g. `{"session_id": "session-A", ...}` and
  `{"session_id": "session-B", ...}`), pipe each into
  `bin/hooks/session-pause` / `bin/hooks/session-resume` in sequence
  against a scratch heading, and confirm via `emacsclient` queries of
  `claude-code-ide-org--clock-last-paused-by` and `(org-clocking-p)`
  that: A pauses, B's resume attempt correctly leaves the clock idle,
  A's own subsequent resume attempt succeeds.
- Manually re-verify the literal reported scenario is now blocked:
  against a scratch heading, clock in and pause via `session-pause` with
  a session-id, then call `claude-code-ide-org-clock-out` directly
  (simulating the "deliberate manual clock-out, no task in view"
  incident), then call `session-resume` with that same session-id and
  confirm it refuses instead of silently reopening the clock.

## After approval

Per this project's CLAUDE.md convention, the Plan link
(`[[file:~/.claude/plans/session-resume-continuity-guard.md][Plan]]`)
gets added to TODO.org heading `582cc7f4-41a2-4666-ad3f-1b76b459147e`'s
body as soon as this plan is finalized — not gated on the heading later
moving to `DOING`. Implementation itself (editing `config.el`/
`config-test.el`, running `bin/test`, the `DOING` transition and its
clock-in) is a separate, later checkpoint requiring its own explicit
approval, per CLAUDE.md's "Plan Mode approval and 'start implementing'
are two separate checkpoints" rule — doubly true here since this plan
was produced by an unattended background-planning agent, not an
interactive Plan Mode session the user just approved in the same beat.
