# Plan — org_clock_in doesn't record clock ownership, unlike session-resume

`:ID: d150c02e-06fe-4514-bf69-e2cc5d8df4c7`

## Context

`claude-code-ide-org--clock-owner-session-id` (`config.el:302-315`) records
which Claude Code session's turn boundary owns the currently-running clock,
and is consulted by `claude-code-ide-org-session-pause`/`-resume` to avoid
pausing or stealing another session's actively-running clock (TODO.org :ID:
`337f7fb2-b9e9-4c02-82dd-d88e60df364b`). Today it is set from exactly one
place: `claude-code-ide-org-session-resume` (`config.el:461-514`).

But `(org-clock-in)` — the primitive that actually opens a clock — is
invoked from three distinct call paths, confirmed by grepping every call
site in `config.el`:

1. `org-clock-in-last` inside `claude-code-ide-org-session-resume` — the
   **only** path that records an owner today.
2. `claude-code-ide-org-clock-in` (`config.el:346-370`, wraps `org_clock_in`
   MCP tool) — a direct, explicit clock-in call. Records no owner.
3. `claude-code-ide-org--trigger-auto-clock-in` (`config.el:1574-1596`, an
   `org-trigger-hook` function firing on **any** transition to `DOING` or
   `PLANNING` — via `org_set_todo`, a hand-edit, or any other path). Records
   no owner.

Path 3 fires on every ordinary `NEXT → DOING` or `NEXT → PLANNING`
transition — the single most common way a clock starts in practice. So
today's owner-recording covers only the least common case (resume-after-
pause) and misses the most common one. Live-verified 2026-08-05: a
genuinely clocked `PLANNING` heading (set via `org_set_todo`, the "proper"
path) had `claude-code-ide-org--clock-owner-session-id` `nil` while the
sibling `claude-code-ide-org--planning-owner-session-id` correctly held the
owning session's ID — same heading, same instant, one guard engaged, the
other completely absent, confirming this is a real live gap, not a
theoretical one. Checked the `337f7fb2` DONE writeup (TODO.org line ~751):
it only ever describes threading `session_id` through
`session-pause`/`-resume`, never claims trigger-hook coverage, so this is
an honest original scope gap, not a regression.

**Existing precedent to mirror**: `claude-code-ide-org--maybe-record-
planning-owner` (`config.el:1598-1618`) already solves the identical shape
of problem for `claude-code-ide-org--planning-owner-session-id` — a
`PostToolUse` hook matched on `org_set_todo`
(`bin/hooks/posttooluse-record-planning-owner`) reads `session_id` straight
from its own hook payload (a field present on **every** `PostToolUse`
payload regardless of what parameters the underlying MCP tool itself
declares — confirmed by reading `bin/hooks/exitplanmode-promote-planning`,
which reads top-level `session_id` from an `ExitPlanMode` payload even
though `ExitPlanMode` is a built-in tool with no `session_id` arg of its
own) and records ownership with no changes needed to the MCP tool schema,
`org_set_todo` itself, or the trigger hook. This plan reuses that same
mechanism for two call sites: `org_set_todo` (DOING/PLANNING) and, as a
separate, smaller addition, bare `org_clock_in` calls.

**Relationship to `582cc7f4-41a2-4666-ad3f-1b76b459147e`'s plan**
(`~/.claude/plans/session-resume-continuity-guard.md`, already written):
that plan's own research reached the same conclusion this plan's brief
anticipated — `d150c02e` is **not** a hard prerequisite for `582cc7f4`.
Confirmed by re-reading that plan in full:

- `582cc7f4`'s fix is entirely on the *close* side: a new variable
  `claude-code-ide-org--clock-last-paused-by` (cons of session-id and
  heading-id), written only by `claude-code-ide-org-session-pause` and read
  only by `claude-code-ide-org-session-resume`'s new idle-resume gate. It
  does not read or depend on `claude-code-ide-org--clock-owner-session-id`
  at all for its core mechanism.
- This plan (`d150c02e`) is entirely on the *open* side: making
  `claude-code-ide-org--clock-owner-session-id` actually get set on the two
  call paths that currently miss it.
- **Where they do interact, without depending on each other**: both plans
  touch the same functions' surrounding regions of `config.el`
  (`claude-code-ide-org-session-pause`/`-resume`, the owner-defvar block at
  ~lines 290-330) and `config-test.el` (the "Session identity" test block,
  and the `with-heading` fixture macro — `582cc7f4`'s plan adds
  `claude-code-ide-org--clock-last-paused-by` to that macro's bindings,
  this plan separately closes the *pre-existing* gap that macro never
  bound `claude-code-ide-org--clock-owner-session-id` at all, a gap
  `582cc7f4`'s own plan explicitly flagged as "out of scope there"). No
  logical conflict: they can land in either order, or as a combined
  changeset, without either needing to reference the other's new code.
  Landing this plan first means the accuracy improvement described in
  `582cc7f4`'s "first cond clause" (its unchanged, pre-existing steal-guard
  for an *actively running* clock, reused from `337f7fb2`) engages more
  often in practice — it currently frequently no-ops as permissive purely
  because owner is `nil` due to exactly this bug — but `582cc7f4`'s own new
  idle-resume gate is correct and self-contained either way, so this is a
  quality improvement to an existing guard, not a new dependency.

Related, same "single shared global clock" theme, distinct root cause,
not assumed to be one fix: `53b0047d-c55c-486c-8eed-ba4994d97a1a`
("Direct file writes to a live org buffer can desync org-clock-marker") —
untouched by this plan, no interaction.

## Design

### Part A — `org_set_todo` → DOING/PLANNING (the common path)

Extend and rename `claude-code-ide-org--maybe-record-planning-owner`
(`config.el:1598-1618`) → `claude-code-ide-org--maybe-record-transition-
owners`, since it now records two different pieces of ownership state
depending on the requested TODO state, not just one:

```elisp
(defun claude-code-ide-org--maybe-record-transition-owners (payload-path)
  "Read the `org_set_todo' `PostToolUse' hook payload JSON from
PAYLOAD-PATH (a temp-file path written by
bin/hooks/posttooluse-record-transition-owners) and record ownership
for whichever of the two owner variables the requested transition
opens:
- whenever tool_input.state is \"DOING\" or \"PLANNING\", record the
  payload's session_id in `claude-code-ide-org--clock-owner-session-id'
  -- both states open a clock via
  `claude-code-ide-org--trigger-auto-clock-in', so both need an owner
  recorded here, the same way `claude-code-ide-org-session-resume'
  already records one for the resume-after-pause path (TODO.org :ID:
  d150c02e-06fe-4514-bf69-e2cc5d8df4c7).
- whenever tool_input.state is exactly \"PLANNING\", additionally
  record it in `claude-code-ide-org--planning-owner-session-id'
  (unchanged from before this revision; TODO.org :ID:
  b95b9fba-f78e-48fe-8546-988709cce309).
Any other requested state, or any problem reading/parsing PAYLOAD-PATH,
is a no-op -- this must never error or block the hook it runs under. No
check on whether the underlying `org_set_todo' transition actually
succeeded: a phantom owner recorded for a blocked/failed transition is
harmless, since both consuming guards only ever match a heading whose
live state/clock-identity is actually what they're checking for."
  (condition-case nil
      (let* ((json-object-type 'alist)
             (payload (json-read-file payload-path))
             (tool-input (alist-get 'tool_input payload))
             (state (alist-get 'state tool-input))
             (session-id (alist-get 'session_id payload)))
        (when (member state '("DOING" "PLANNING"))
          (setq claude-code-ide-org--clock-owner-session-id session-id))
        (when (equal state "PLANNING")
          (setq claude-code-ide-org--planning-owner-session-id session-id)))
    (error nil)))
```

Note this is a pure addition to the existing `DOING`/`PLANNING` branch
logic — the pre-existing `PLANNING`-only branch for
`--planning-owner-session-id` is untouched in behavior, just re-expressed
as a second `when`.

**`PLANNING → DOING` auto-promotion needs no separate change.** That
transition happens via `claude-code-ide-org--promote-planning-to-doing`
(the `ExitPlanMode` hook), which reuses the same clock interval — no new
`org-clock-in` call, so no new ownership event to record. Since PLANNING's
clock-owner was already correctly set when `PLANNING` was set (by the fix
above), it remains correctly attributed straight through the promotion
with no additional code.

**Hand-edits remain unowned — accepted, not a gap.** A heading transitioned
directly in Emacs (`M-x org-todo`, no MCP call) never fires any
`PostToolUse` hook, so there is no `session_id` to record — same accepted
limitation the pre-existing `--planning-owner-session-id` mechanism already
lives with, not new to this plan.

### Part B — bare `org_clock_in` calls (the narrower, separate case)

`org_clock_in`'s own MCP argument schema (`config.el:1933-1942`) takes only
`id`, no `state` concept to gate on the way `org_set_todo` does — but its
`PostToolUse` payload still carries a top-level `session_id` field
regardless (same mechanism confirmed in Part A's Context section: this
field is populated on every hook payload independent of the tool's own
declared args). A call reaching this hook at all is sufficient signal that
this session just opened (or re-affirmed) a clock, so no state check is
needed.

**Wiring decision, revised during planning**: rather than adding a second,
independent `PostToolUse` array entry matched on
`mcp__emacs-tools__org_clock_in` alongside the existing combined
`mcp__emacs-tools__org_clock_in|mcp__emacs-tools__org_clock_out` →
`bin/clock-notify` entry (which would rest on an unverified assumption —
nothing in this repo demonstrates that two independent `PostToolUse` array
entries whose matchers *both* match the same `tool_name` both actually
fire; every existing case of two entries "coexisting" on one tool, e.g.
`org_set_todo`'s `PreToolUse` guard and its separate `PostToolUse`
planning-owner hook, involves different hook *events*, never the same
event matched twice), sidestep the assumption entirely: add the new hook
command as a **second entry in the existing combined matcher's own
`hooks` array** (unambiguously supported — multiple hooks under one
matcher is the documented, already-used shape, e.g. this same array
element could grow further without any new matcher). The new elisp
function reads `tool_name` from the payload itself and no-ops unless it
ends in `org_clock_in` — cheap (two extra lines, already parsing the
payload) and removes the assumption outright:

```elisp
(defun claude-code-ide-org--maybe-record-clock-in-owner (payload-path)
  "Read the `org_clock_in'/`org_clock_out' `PostToolUse' hook payload
JSON from PAYLOAD-PATH (a temp-file path written by
bin/hooks/posttooluse-record-clock-in-owner, which is wired to the same
combined matcher as bin/clock-notify) and, only when the payload's
tool_name ends in \"org_clock_in\" (not org_clock_out -- this function
is deliberately one-directional, since a clock-out has nothing to
record an opener for), record its session_id in
`claude-code-ide-org--clock-owner-session-id' unconditionally --
org_clock_in carries no separate \"state\" concept to gate on the way
org_set_todo does (TODO.org :ID: d150c02e-06fe-4514-bf69-e2cc5d8df4c7),
so a call reaching this branch at all is sufficient signal that this
session just opened a clock. Any other tool_name, or any problem
reading/parsing PAYLOAD-PATH, is a no-op -- this must never error or
block the hook it runs under. No check on whether the underlying
org_clock_in call actually succeeded (e.g. a bad :ID:): a phantom owner
recorded for a failed clock-in is harmless by the same reasoning
already established for
`claude-code-ide-org--maybe-record-transition-owners' -- the value is
only ever consulted while `org-clocking-p' is true, and any future
successful clock-open unconditionally overwrites it again."
  (condition-case nil
      (let* ((json-object-type 'alist)
             (payload (json-read-file payload-path))
             (tool-name (alist-get 'tool_name payload))
             (session-id (alist-get 'session_id payload)))
        (when (and tool-name (string-suffix-p "org_clock_in" tool-name))
          (setq claude-code-ide-org--clock-owner-session-id session-id)))
    (error nil)))
```

### `claude-code-ide-org--clock-owner-session-id` docstring update

(`config.el:302-315`) Currently says it is "Consulted by
`claude-code-ide-org-session-pause'/`-resume'" and describes only the
resume-set path. Update to note it is now also set by
`claude-code-ide-org--maybe-record-transition-owners` (org_set_todo
DOING/PLANNING) and `claude-code-ide-org--maybe-record-clock-in-owner`
(bare org_clock_in), cross-referencing this TODO.org `:ID:`.

### New hook script: `bin/hooks/posttooluse-record-clock-in-owner`

Same no-`jq`, temp-file shape as the existing planning-owner hook (neither
needs to interpolate an untrusted field value into the `emacsclient -e`
expression, only a `mktemp`-generated path). Wired to the **same**
`PostToolUse` matcher as `bin/clock-notify` (`mcp__emacs-tools__org_clock_in|
mcp__emacs-tools__org_clock_out`), as a second `hooks` array entry under
that one matcher — not a new, independent matcher entry (see the wiring
decision above):

```bash
#!/usr/bin/env bash
# PostToolUse hook, SAME matcher as bin/clock-notify
# (mcp__emacs-tools__org_clock_in|mcp__emacs-tools__org_clock_out) --
# wired as a second hooks-array entry under that one matcher, not a
# separate matcher entry, since two independent PostToolUse array
# entries both matching the same tool_name is not a confirmed-supported
# shape in this repo (see the design note in the plan this hook came
# from). Record which session's org_clock_in MCP call most recently
# opened the running clock -- the direct/bare clock-in path this
# project's session-resume-style ownership tracking never covered
# (TODO.org :ID: d150c02e-06fe-4514-bf69-e2cc5d8df4c7). The
# org_set_todo-driven DOING/PLANNING path is covered separately by
# bin/hooks/posttooluse-record-transition-owners. The elisp side reads
# tool_name from the payload itself and no-ops for org_clock_out (this
# matcher fires for both).
#
# Same no-jq, temp-file shape as the planning-owner hook -- see its
# header for why jq's injection-safe encoding isn't needed here either.
#
# Fails soft, always exit 0 -- this must never block an org_clock_in/
# org_clock_out call that already went through.
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT
cat > "$tmpfile"
emacsclient -e "(claude-code-ide-org--maybe-record-clock-in-owner \"$tmpfile\")" >/dev/null 2>&1
exit 0
```

### Rename: `bin/hooks/posttooluse-record-planning-owner` → `bin/hooks/posttooluse-record-transition-owners`

The old name is now inaccurate (it records clock ownership too, not just
planning ownership). Update its `emacsclient -e` call to invoke
`claude-code-ide-org--maybe-record-transition-owners`, and its header
comment to describe both responsibilities.

### `.claude/settings.json`

Two changes, both to existing `PostToolUse` array entries — **no new
matcher entries**:

1. Update the existing `mcp__emacs-tools__org_set_todo` entry's command
   path to the renamed script:
   ```json
   {
     "matcher": "mcp__emacs-tools__org_set_todo",
     "hooks": [
       { "type": "command",
         "command": "${CLAUDE_PROJECT_DIR}/bin/hooks/posttooluse-record-transition-owners",
         "timeout": 10 }
     ]
   }
   ```
2. Add a second `hooks` array element to the existing combined
   `mcp__emacs-tools__org_clock_in|mcp__emacs-tools__org_clock_out` entry
   (do not add a new matcher entry — see the Part B wiring decision above
   for why):
   ```json
   {
     "matcher": "mcp__emacs-tools__org_clock_in|mcp__emacs-tools__org_clock_out",
     "hooks": [
       { "type": "command",
         "command": "${CLAUDE_PROJECT_DIR}/bin/clock-notify",
         "timeout": 10 },
       { "type": "command",
         "command": "${CLAUDE_PROJECT_DIR}/bin/hooks/posttooluse-record-clock-in-owner",
         "timeout": 10 }
     ]
   }
   ```
   Order between the two `hooks` entries doesn't matter — independent
   concerns (a macOS notification vs. an in-memory owner variable), no
   shared state, no conflict running alongside each other.

### Files touched

- `modules/tools/claude-code-ide-org/config.el` — docstring update on
  `claude-code-ide-org--clock-owner-session-id` (~302-315); rename +
  extend `claude-code-ide-org--maybe-record-planning-owner` →
  `claude-code-ide-org--maybe-record-transition-owners` (~1598-1618); new
  function `claude-code-ide-org--maybe-record-clock-in-owner` (placed
  immediately after it); one-line addition to
  `claude-code-ide-org-clock-out` (~372-417) clearing
  `claude-code-ide-org--clock-owner-session-id` on every actual close (see
  design decision above).
- `modules/tools/claude-code-ide-org/config-test.el` — see below.
- `bin/hooks/posttooluse-record-planning-owner` → renamed to
  `bin/hooks/posttooluse-record-transition-owners`, function-name and
  comment updates.
- `bin/hooks/posttooluse-record-clock-in-owner` — new file.
- `.claude/settings.json` — one path update on the existing `org_set_todo`
  entry; one new `hooks` array element added to the existing combined
  `org_clock_in|org_clock_out` entry. No new matcher entries.
- **No changes needed to** `org_clock_in`'s or `org_set_todo`'s MCP `:args`
  schema — neither tool gains a new parameter; `session_id` is read
  entirely from the ambient `PostToolUse` hook payload, exactly like every
  other session-aware mechanism in this file.
- **No changes needed to** `claude-code-ide-org--trigger-auto-clock-in`,
  `claude-code-ide-org-clock-in`, or `claude-code-ide-org--promote-
  planning-to-doing` — none of them need to know about session identity
  themselves; ownership is recorded entirely from the hook-payload side,
  same architecture `337f7fb2` and `b95b9fba` already established.

### Design decision found during planning: clear the owner on `org_clock_out` too

Today `claude-code-ide-org--clock-owner-session-id` is set only by
`claude-code-ide-org-session-resume` and cleared only by
`claude-code-ide-org-session-pause` — a tight, matched pair, so in
practice it's essentially never stale. This plan adds **three** new
set-sites (Part A's two states, Part B) but, as drafted so far, **no**
new clear-sites. `claude-code-ide-org-clock-out` (`config.el:372-417`,
the function a direct `org_clock_out` MCP call runs) never touches the
variable — and CLAUDE.md's own transition-rule table *requires*
`org_clock_out` on every `DOING`/`PLANNING` → `DONE`/`WAIT`/`CANCELLED`
transition (enforced at the MCP layer by
`bin/hooks/pretooluse-transition-guard`). So after this fix, a stale
owner would survive *routinely* — every ordinary DOING→DONE close via a
direct `org_clock_out` call — rather than never.

Concrete consequence if left unaddressed: session A's clock closes via a
plain `org_clock_out` call (owner stays "session-A", stale); later,
session B hand-edits some *other* heading straight to `DOING` (a path
this fix cannot record an owner for — no MCP call, no hook payload); a
subsequent `session-pause("B")` would then wrongly refuse to pause B's
own, legitimately-owned clock, because the stale "session-A" value is
still sitting in the variable from the earlier, unrelated close. Narrow,
but a real regression this plan's own widened set-coverage introduces if
nothing clears the variable to match.

**Fix**: add `(setq claude-code-ide-org--clock-owner-session-id nil)` to
`claude-code-ide-org-clock-out` (`config.el:372-417`), clearing
unconditionally whenever a clock actually closes (mirroring exactly what
`claude-code-ide-org-session-pause` already does after its own call to
this same function — that call becomes redundant, not wrong, once this
change lands, since the callee now does it too).

Checked for conflicts, to be confirmed by `bin/test` rather than treated
as settled by inspection alone (the one assertion in this changeset
inspection can't fully rule out):
- `claude-code-ide-org-session-pause`'s existing ownership guard reads
  `claude-code-ide-org--clock-owner-session-id` *before* calling
  `clock-out`, so its own subsequent `(setq ... nil)` after the call is
  unaffected either way.
- `claude-code-ide-org--promote-planning-to-doing` (the `ExitPlanMode`
  auto-promotion path) never calls `clock-out` — reuses the same
  interval — so this change doesn't touch that path at all.
- `582cc7f4`'s plan (`session-resume-continuity-guard.md`) does not touch
  `claude-code-ide-org-clock-out` either — no merge conflict with that
  plan's own edits to `session-pause`/`-resume`.
- This plan's own new regression tests (6a/6b below) both refuse at the
  ownership guard in `session-pause` and return *before* `clock-out`
  runs, so this change doesn't affect their assertions.
- Existing `clock-out-*` tests (`config-test.el:152-241`) don't read or
  assert on `--clock-owner-session-id` at all, so they're unaffected in
  either direction.

## Test-isolation detail (not optional)

`claude-code-ide-org-test--with-heading` (`config-test.el:20-44`) binds
`claude-code-ide-org--planning-owner-session-id` to `nil` per test but,
per `582cc7f4`'s own plan (which explicitly flagged this as "an existing
gap in that macro, out of scope to fix here" for its purposes), does
**not** bind `claude-code-ide-org--clock-owner-session-id`. This plan's new
tests read and write that variable directly, so the gap is now in scope:
add `(claude-code-ide-org--clock-owner-session-id nil)` to the macro's
`let*` bindings. Without this, test order could leak a stale value between
tests and produce a flaky pass/fail depending on run order.

## Test changes (config-test.el, "PLANNING -> DOING promotion" block, ~840-933)

Two existing tests must change because the function they exercise now does
more:

1. `claude-code-ide-org-test-maybe-record-planning-owner-sets-owner-for-planning`
   → rename to
   `claude-code-ide-org-test-maybe-record-transition-owners-sets-both-owners-for-planning`;
   update the call site to `claude-code-ide-org--maybe-record-transition-owners`;
   add an assertion that `claude-code-ide-org--clock-owner-session-id` is
   now also `"session-A"` (new behavior).

2. `claude-code-ide-org-test-maybe-record-planning-owner-ignores-other-states`
   (currently uses `state = "DOING"` and asserts `--planning-owner-
   session-id` stays `nil`) — this is **not actually a true negative**
   under the new behavior: `DOING` now sets `--clock-owner-session-id`
   even though it correctly still leaves `--planning-owner-session-id`
   alone. Rename to
   `claude-code-ide-org-test-maybe-record-transition-owners-sets-clock-owner-only-for-doing`;
   keep the existing `--planning-owner-session-id` is-nil assertion; add a
   new assertion that `--clock-owner-session-id` is now `"session-A"`.

New tests, same block:

3. `claude-code-ide-org-test-maybe-record-transition-owners-ignores-non-clock-states`
   — payload `state = "NEXT"` (a real true-negative case, replacing the
   test-2 rename's old role): assert **both** owner variables stay `nil`.

4. `claude-code-ide-org-test-maybe-record-clock-in-owner-sets-owner` —
   write a payload `{session_id: "session-A", tool_name:
   "mcp__emacs-tools__org_clock_in", tool_input: {id: ID}}` (mirroring
   `org_clock_in`'s real schema — no `state` field, and the `tool_name`
   the new `string-suffix-p` check gates on), call
   `claude-code-ide-org--maybe-record-clock-in-owner`, assert
   `--clock-owner-session-id` is `"session-A"`.

5. `claude-code-ide-org-test-maybe-record-clock-in-owner-overwrites-stale-owner`
   — pre-set `--clock-owner-session-id` to `"session-B"`, call with a
   payload for `"session-A"` (same `tool_name` field as test 4), assert it
   is now `"session-A"` — proves unconditional overwrite, matching
   `session-resume`'s own existing semantics for the same variable.

5b. `claude-code-ide-org-test-maybe-record-clock-in-owner-ignores-clock-out`
   — payload with `tool_name: "mcp__emacs-tools__org_clock_out"` (same
   matcher this hook is now wired to, per the Part B wiring decision):
   assert `--clock-owner-session-id` is untouched (stays at whatever it
   was pre-set to, or `nil`) — proves the `string-suffix-p` gate actually
   excludes the sibling tool sharing its matcher, not just that it
   accepts the intended one.

6. **The two regression tests that most directly close the reported gap**,
   proving the fix end-to-end at the elisp level (same "closes the loop"
   style `337f7fb2`'s own tests used — clock-in, then attempt a
   cross-session pause, confirm it's refused):

   ```elisp
   (ert-deftest claude-code-ide-org-test-clock-in-owner-recorded-via-hook-protects-from-cross-session-pause ()
     (claude-code-ide-org-test--with-heading
       (claude-code-ide-org-clock-in id)
       (let ((payload (claude-code-ide-org-test--write-json
                       `((session_id . "session-A")
                         (tool_name . "mcp__emacs-tools__org_clock_in")
                         (tool_input . ((id . ,id)))))))
         (unwind-protect
             (claude-code-ide-org--maybe-record-clock-in-owner payload)
           (delete-file payload)))
       (should (equal "session-A" claude-code-ide-org--clock-owner-session-id))
       (should (string-match-p "different session"
                               (claude-code-ide-org-session-pause "session-B")))
       (should (org-clocking-p))))

   ;; Bare `org-todo' fires the auto-clock-in trigger under `bin/test'
   ;; with no hook isolation needed -- same pattern as the existing,
   ;; already-passing `claude-code-ide-org-test-trigger-hook-auto-clocks-
   ;; in-on-direct-org-todo' test (config-test.el:770-789), which asserts
   ;; `(org-clocking-p)' after a bare `(org-todo "DOING")' with no
   ;; special `org-trigger-hook' binding. Verified empirically during
   ;; planning by running this exact fixture shape (with-heading's own
   ;; setup, plus a bare `org-todo "DOING"') standalone against the real
   ;; `bin/test' load order (straight build-dir load-path included) —
   ;; the clock opens with no isolation required. The one `let
   ;; ((org-trigger-hook ...))` binding elsewhere in this file
   ;; (config-test.el:746) exists to exclude the *unrelated*
   ;; single-NEXT-per-level triggers for that specific test's own
   ;; reasons, not because org-trigger-hook is inactive by default.
   (ert-deftest claude-code-ide-org-test-set-todo-doing-owner-recorded-via-hook-protects-from-cross-session-pause ()
     (claude-code-ide-org-test--with-heading
       (org-with-point-at (org-id-find id 'marker) (org-todo "DOING"))
       (let ((payload (claude-code-ide-org-test--write-json
                       `((session_id . "session-A")
                         (tool_input . ((state . "DOING") (id . ,id)))))))
         (unwind-protect
             (claude-code-ide-org--maybe-record-transition-owners payload)
           (delete-file payload)))
       (should (equal "session-A" claude-code-ide-org--clock-owner-session-id))
       (should (string-match-p "different session"
                               (claude-code-ide-org-session-pause "session-B")))
       (should (org-clocking-p))))
   ```

   Before this fix, both of these would fail at the `string-match-p`
   assertion — `session-pause "session-B"` would succeed (wrongly stealing
   session A's clock) because `--clock-owner-session-id` was never set on
   either path. This is the literal live-verified scenario from the
   TODO.org heading's body, reproduced deterministically.

7. `claude-code-ide-org-test-clock-out-clears-owner` — new test for the
   "Design decision found during planning" fix above: clock in, set
   `--clock-owner-session-id` to `"session-A"` directly, call
   `claude-code-ide-org-clock-out` (the plain function, not
   `session-pause`), assert `--clock-owner-session-id` is now `nil`.
   Complements the pre-existing `session-pause`-clears-it coverage with
   direct coverage of the lower-level function itself.

8. All pre-existing tests in this block and the "Session identity" block
   (`config-test.el:284-390`) must keep passing unchanged — confirmed by
   inspection (none of them call the renamed function or otherwise depend
   on the old name) and re-confirmed by running `bin/test`.

## Verification

- **Baseline, confirmed during planning**: `bin/test` currently passes
  122/122 (run live during this research pass, read-only — scratch temp
  files only, no real Emacs/org-id/clock state touched, per this project's
  own `bin/test` isolation guarantee documented in CLAUDE.md).
- **After implementing**: `bin/test` should show 122 pre-existing tests
  (2 renamed, not removed) + 8 new tests = 130, all green. Explicitly
  confirm the "clears on clock-out" test (7) and the two "closes the
  loop" cross-session-pause tests (6a/6b) pass — those are the ones that
  actually prove both the fix and its accompanying regression-guard (the
  design decision found during planning) are correct, not just that
  nothing else broke.
- **End-to-end through the actual hook scripts**, same pattern `337f7fb2`
  used: fabricate `PostToolUse`-shaped JSON payloads with a `session_id`
  field — one shaped like an `org_set_todo` call (`tool_input.state =
  "DOING"` or `"PLANNING"`), one shaped like an `org_clock_in` call
  (`tool_name` ending in `org_clock_in`, no `state` field) — pipe each
  into `bin/hooks/posttooluse-record-transition-owners` /
  `bin/hooks/posttooluse-record-clock-in-owner` against a scratch
  heading, and confirm via `emacsclient -e
  "claude-code-ide-org--clock-owner-session-id"` that it now reflects the
  piped `session_id` afterward. Also pipe an `org_clock_out`-shaped
  payload into `posttooluse-record-clock-in-owner` (the script it now
  shares a matcher with) and confirm the owner variable is **not**
  spuriously touched by it.
- **Manually re-verify the literal reported scenario is now fixed, and
  that the rename didn't silently sever the pre-existing planning-owner
  wiring** (renames fail soft under this project's hook architecture — a
  stale path just stops firing with no visible error — so this is the one
  step inspection alone cannot settle): on a real scratch/test heading
  (not a real backlog item), transition it `NEXT → PLANNING` via the real
  `org_set_todo` MCP tool call (which fires the real, renamed
  `PostToolUse` hook, not a fabricated payload), then query **both**
  `claude-code-ide-org--clock-owner-session-id` and
  `claude-code-ide-org--planning-owner-session-id` via `emacsclient` and
  confirm **both** are now non-nil and match this session's real
  `session_id`. Both-set is the load-bearing signal here — either one
  alone would be ambiguous: `--planning-owner-session-id` alone set would
  mean the rename's wiring survived but the new DOING/PLANNING clause
  never fires; `--clock-owner-session-id` alone set would (implausibly,
  but not provably from that check alone) suggest the reverse. This is
  the same live-verification methodology the TODO.org body itself used to
  originally confirm the bug (which found `--clock-owner-session-id` nil
  in the equivalent check). Repeat once more via a direct `org_clock_in`
  MCP call on a different scratch heading to cover Part B independently.
- Record in the outcome summary (per CLAUDE.md's DONE-archival convention)
  which of these ran live vs. only via `bin/test`.

## After approval

Per this project's CLAUDE.md convention, the Plan link
(`[[file:~/.claude/plans/clock-in-ownership-recording.md][Plan]]`) gets
added to TODO.org heading `d150c02e-06fe-4514-bf69-e2cc5d8df4c7`'s body as
soon as this plan is finalized — not gated on the heading later moving to
`DOING`. Implementation itself (editing `config.el`/`config-test.el`,
renaming/adding hook scripts, editing `.claude/settings.json`, running
`bin/test`, the `DOING` transition and its clock-in) is a separate, later
checkpoint requiring its own explicit approval, per CLAUDE.md's "Plan Mode
approval and 'start implementing' are two separate checkpoints" rule —
doubly true here since this plan was produced by an unattended
background-planning agent, not an interactive Plan Mode session the user
just approved in the same beat.
