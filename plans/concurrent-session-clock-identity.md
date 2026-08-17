# Plan — Concurrent Claude Code sessions share one global org-clock with no session identity

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
