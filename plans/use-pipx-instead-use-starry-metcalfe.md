# Two independent plans: concurrent-session clock identity, and zero-time-clock erasure

This file replaces the prior (unrelated, already-completed) Warp-proxy plan
that used to live at this path. It contains **two fully independent plans**,
one per `NEXT` item in `TODO.org`'s "Clock lifecycle & visibility" section.
Each can be implemented, tested, and shipped without the other.

**Immediately on approval, before any code changes:** split this file into
two standalone plan files (`~/.claude/plans/concurrent-session-clock-identity.md`
and `~/.claude/plans/zero-time-clock-erasure.md`, content unchanged, just
separated), then add a `[[file:~/.claude/plans/<name>.md][Plan]]` link to
each corresponding TODO.org heading's body (337f7fb2-... and
293ac49e-...) — per this repo's own CLAUDE.md convention that Plan-Mode
work gets a permanent link on the heading the moment it exists, added
without touching the heading's TODO state. Both headings stay at `NEXT`;
this is documentation only, not a transition to `DOING`.

---

# Plan A — Concurrent Claude Code sessions share one global org-clock with no session identity

`:ID: 337f7fb2-b9e9-4c02-82dd-d88e60df364b`

## Context

`bin/hooks/session-pause` (Stop) and `bin/hooks/session-resume`
(UserPromptSubmit) call `claude-code-ide-org-session-pause`/`-resume` with
zero arguments, which operate on Emacs's single global `org-clock-marker`/
`org-clock-history` — there is no notion of *which* Claude Code session
triggered the pause/resume. If two sessions are open against the same org
files, one session's turn boundary can pause, resume, or steal another
session's actively-running clock. Not yet hit in practice, but nothing
prevents it.

Investigated live: both hook scripts already read stdin (`cat >/dev/null`)
but discard it — Claude Code's Stop/UserPromptSubmit hook payload includes
a `session_id` field, unused today. Two *other* hook scripts in this repo
(`bin/hooks/pretooluse-transition-guard`, `bin/clock-notify`) already parse
this same stdin JSON via `jq`, so the idiom exists, just isn't applied
here. Neither the `:SESSIONS:` drawer nor `clock-status.json` currently
record any session-identifying data — both are timestamp/heading-keyed
only.

## Approach

Org itself only ever supports one *running* clock — this plan does not
attempt true multi-session concurrent clocking (a much bigger lift: a
custom clock multiplexer outside org's native mechanism). Instead it
narrows the actual failure mode described in the bug (silent
pause/resume/steal across sessions) down to the same "low-cost stray
interval" category the design already tolerates for the *existing*,
accepted "wrong but still active task" case (see CLAUDE.md's documented
self-correction note).

1. **Thread `session_id` through the hooks.** In `bin/hooks/session-pause`
   and `bin/hooks/session-resume`, parse stdin with `jq -r
   '.session_id // empty'` (matching the existing idiom), then pass it to
   `emacsclient -e`. Build the elisp string argument via `jq`'s own
   JSON-string encoding (e.g. `printf '%s' "$session_id" | jq -R -s .`)
   rather than naive shell interpolation — JSON string-escaping is a safe
   superset for elisp string literals given session IDs are plain ASCII
   UUIDs, and this avoids any injection risk from interpolating untrusted
   data into an `-e` expression. (Passing via an env var doesn't work
   here: `emacsclient -e` evaluates inside the *already-running* Emacs
   server process, which does not see env vars set on the short-lived
   `emacsclient` client process.)

2. **Add an optional `session-id` argument** to
   `claude-code-ide-org-session-pause`/`-resume` in `config.el`, defaulting
   to `nil`. This keeps all 5 existing tests (which call both functions
   with zero arguments) passing unchanged, and makes `nil`/absent
   session-id fall back to today's fully unconditional legacy behavior —
   no behavior change for manual/test invocations or a genuinely
   single-session workflow.

3. **Track which session owns the current clock.** A new defvar,
   `claude-code-ide-org--clock-owner-session-id`, records which session's
   turn boundary most recently opened the currently-running clock.

4. **`session-pause` guard:** if a session-id is given and it doesn't match
   the recorded owner (and an owner is recorded), no-op — leave the other
   session's running clock alone. Clear the owner var on a successful
   clock-out.

5. **`session-resume` guard:** if a session-id is given and a clock is
   already running that's owned by a *different* session, no-op instead of
   stealing it. Otherwise proceed exactly as today (resume from
   `org-clock-history`) and record the resuming session as the new owner.

6. **Small enhancement, same scope:** extend
   `claude-code-ide-org--log-session-event` to optionally append the
   session-id to `:SESSIONS:` drawer entries (e.g. `"- Paused [timestamp]
   (session abc123)"`) when one is supplied — gives direct, visible
   evidence of which session did what, both for verifying this fix and as
   a step that doesn't make the separate "Coarsen `:SESSIONS:`" `MAYBE`
   item any harder to build later.

**Explicitly out of scope:** `clock-status.json` is a single global file
with the same latent gap (two sessions' writes could clobber each other).
Not fixed here — flagged as its own follow-up note in TODO.org rather than
silently expanding this task.

## Files

- `bin/hooks/session-pause`, `bin/hooks/session-resume` — parse stdin JSON,
  extract `.session_id`, pass through to `emacsclient -e` safely.
- `modules/tools/claude-code-ide-org/config.el` —
  `claude-code-ide-org-session-pause`/`-resume` (new optional arg + guard
  logic), new `claude-code-ide-org--clock-owner-session-id` defvar,
  `claude-code-ide-org--log-session-event` (optional session-id suffix).
- `modules/tools/claude-code-ide-org/config-test.el` — new regression
  tests simulating two sessions (session "A" clocks in and pauses; session
  "B" attempts to resume/pause session A's clock and is correctly
  blocked; session A then resumes correctly).

## Verification

- `bin/test`: new ERT tests exercising the guard logic directly (pure
  elisp) — cross-session pause/resume attempts must no-op while
  same-session ones succeed; omitting session-id must reproduce exactly
  today's behavior. All 5 existing session-pause/-resume tests must keep
  passing unchanged.
- Manual pass (the bash-level `jq` parsing + `emacsclient` wiring isn't
  exercised by `bin/test`, same as today's session-pause/-resume, which
  are only tested via their elisp entry points): fabricate two
  Stop/UserPromptSubmit-shaped JSON payloads with distinct `session_id`
  values, pipe each directly into the updated hook scripts, and confirm
  via `emacsclient` that the clock-owner state and `:SESSIONS:` entries
  reflect the expected session-scoped behavior.

---

# Plan B — org-clock-out-remove-zero-time-clocks silently erases short CLOCK intervals

`:ID: 293ac49e-3324-421c-8495-de1a46fc04ac`

## Context

Doom's `lang/org` module sets `org-clock-out-remove-zero-time-clocks t`
globally (not something this project configured). Org-native
`org-clock-out` deletes a just-closed `CLOCK:` line outright whenever its
**raw, unrounded** duration floors to `0h0m` (i.e. under 60 seconds) —
*before* `claude-code-ide-org-consolidate-history` (this project's own
logic, which rounds to the nearest 5 minutes, merges adjacent intervals,
and *then* correctly drops genuinely-zero results) ever gets a chance to
run. Confirmed live: a heading with real completed work ended up with a
fully empty `:LOGBOOK:`, because Claude's fast per-turn Stop boundaries
kept producing sub-minute raw intervals that org deleted one at a time,
each one forfeiting any chance of being merged into a larger, meaningful
interval.

This project already wants — and already correctly implements — zero-time
dropping (see the existing, still-relevant test
`claude-code-ide-org-test-consolidate-history-rounds-merges-and-drops-zero`).
The bug is a pure ordering/authority conflict: org's cruder raw-duration
version pre-empts this project's own rounding-aware one, not a
"want vs. don't want" disagreement.

## Approach

Fix precisely at the conflict point, and *only* on the call path this
project actually cares about:

- In `claude-code-ide-org-clock-out` (`config.el`), let-bind
  `org-clock-out-remove-zero-time-clocks` to `nil` around the existing
  `(org-clock-out)` call. This stops org-native's premature deletion from
  firing on this path; `claude-code-ide-org-consolidate-history`, called
  immediately after, becomes the sole authority on whether/how to drop or
  merge the interval — exactly the logic it was already built for.
- Deliberately **not** a global Doom-config change. A human's own
  manual/interactive `org-clock-out` (e.g. accidentally clocking in and
  right back out) should keep org's normal, sensible zero-time-dropping
  behavior — this project's rounding/merge logic exists specifically for
  the turn-boundary-driven many-short-intervals scenario, not general
  interactive use, so it shouldn't change behavior globally.
- The Doom-config `kill-emacs-hook`/`suspend-hook` path
  (`claude-code-ide-org--clock-out-if-clocking`, which calls bare
  `org-clock-out` directly, bypassing this wrapper) is intentionally left
  untouched — it fires once at session end for the real accumulated
  session length, not per-turn, so it isn't the failure mode this bug
  describes.

## Files

- `modules/tools/claude-code-ide-org/config.el` —
  `claude-code-ide-org-clock-out`: wrap the existing `(org-clock-out)`
  call in a local `(let ((org-clock-out-remove-zero-time-clocks nil)) ...)`.
- `modules/tools/claude-code-ide-org/config-test.el` — new regression
  test.

## Verification

- `bin/test`: new ERT regression test. Since `bin/test` runs under
  `emacs --batch -Q` (Doom's config, and its `t` override, is never
  loaded there), explicitly let-bind `org-clock-out-remove-zero-time-clocks`
  to `t` around the test body to simulate Doom's real-world default —
  matching the pattern the two existing (currently inert under `-Q`)
  let-bindings at `config-test.el:173` and `:379` already establish.
  Reproduce the actual bug shape: two consecutive fast clock-in/clock-out
  cycles (each individually under a minute, simulating rapid turn
  boundaries), and assert the resulting `:LOGBOOK:` shows a
  merged/rounded interval rather than being empty — proving the
  intervals survived long enough to reach `consolidate-history`'s own
  logic instead of being deleted by org-native first.
- Confirm `claude-code-ide-org-test-consolidate-history-rounds-merges-and-drops-zero`
  (this project's own, correct, by-design zero-duration dropping) still
  passes unchanged — this fix must not touch that separate, already-correct
  behavior.
- Live/manual: reload `config.el` in the running Doom Emacs (per the
  org-dev skill) and confirm via `emacsclient` that a fast clock-in/out no
  longer strips the `:LOGBOOK:` outright.
