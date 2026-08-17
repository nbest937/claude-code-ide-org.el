# Plan — Direct file writes to a live org buffer can desync org-clock-marker

`:ID: 53b0047d-c55c-486c-8eed-ba4994d97a1a`

## Context

Two distinct, live-caught incidents, both filed under one heading because
they share a root theme ("a file this project treats as Emacs's exclusive
domain gets mutated by something else while Emacs is still running against
it"), not because they share a fix:

**Incident 1 (2026-08-04).** `TODO.org` was rewritten directly via `git
hash-object`/`update-index` (bypassing Emacs), and `global-auto-revert-mode`
picked up the change. Emacs's in-memory `org-clock-marker` — an Emacs
marker, which tracks a raw buffer *position*, not buffer *content* — kept
its old numeric offset. A whole-buffer revert (`erase-buffer` +
`insert-file-contents`, functionally what auto-revert does) preserves that
offset relative to the *new* text, not the old, so the marker silently
ended up sitting on an unrelated `:SESSIONS:` line. `org_clock_out` then
failed outright with `"Clock start time is gone"`, and the statusline (which
reads live `org-clocking-p`/`org-clock-marker` state, not file text — see
`claude-code-ide-org--statusline-task-string`, config.el:768) kept showing
"clocked in" even after a text-level recovery via
`claude-code-ide-org-close-open-interval` had already closed the `CLOCK:`
line on disk. Worked around by hand: reset
`org-clock-marker`/`org-clock-hd-marker`/`org-clock-start-time` via
`emacsclient`, then called `claude-code-ide-org--clock-status-hook-out` by
hand since normal `org-clock-out` never got far enough to fire it.

**Incident 2 (2026-08-05), distinct.** On a sibling heading, after a
cross-session clock resume followed by a proper `org_clock_out`, the
`:LOGBOOK:` briefly contained a genuinely malformed line — bare `CLOCK:`
with no timestamp at all — sitting between two valid entries, before
`claude-code-ide-org-consolidate-history` rebuilt the drawer and it
disappeared. TODO.org's own later note (the "parallelize background
planning" design, written the same day) pins this to a *specific*,
already-observed mechanism, not left purely speculative: "this session's
own ordinary `UserPromptSubmit` resume hook reopened an unrelated heading's
clock *twice*" — i.e. two near-simultaneous, separately-invoked
`org-clock-in`/`-out` sequences (each its own `emacsclient -e` round trip,
each internally multi-step — insert `org-clock-string`, then
`org-insert-timestamp`, per `org-clock-in`'s implementation, see
`org-clock.el:1514,1532` in the installed straight checkout) landing close
enough in wall-clock time to corrupt the drawer between them. This is the
existing session-ownership bug cluster (`582cc7f4-...`
"session-resume blindly inherits any session's last-clocked heading",
`d150c02e-...` "org_clock_in doesn't record clock ownership"), not a new
root cause — working hypothesis, not proven, and explicitly out of scope
to chase further here (see Scope below).

The existing "Stale interval recovery" design (CLAUDE.md) only repairs the
*text* side of a stale interval — the crash/shutdown case, where Emacs's
own in-memory state is simply gone after a restart, detected by scanning
file text for an unclosed `CLOCK:`/`Resumed` line. It has no equivalent for
incident 1's case: Emacs is still running and still *thinks* it's clocking,
but its live marker state has gone stale relative to a file it didn't
itself edit.

**Why "never write live org files outside Emacs" (discipline alone) is not
a sufficient answer.** CLAUDE.md's own engineering practices *mandate*
feature branches for new work. That means `git checkout <branch>`, `git
stash`, `git rebase`, and merge-driven working-tree rewrites of `TODO.org`
are a normal, expected, recurring part of this project's workflow — not a
rare mistake to train away. Any of those can rewrite `TODO.org` on disk
while Emacs has it open and (if a clock happens to be running when it
lands) desynced from underneath. Discipline can eliminate the *ad hoc git
hash-object* case that triggered incident 1, but not routine branch
switches — so a code-level guard is warranted, not just a "don't do that"
note.

## Confirmed from org-clock.el source (installed straight checkout,
`~/.config/emacs/.local/straight/repos/org/lisp/org-clock.el`)

- `org-clock-in` sets `org-clock-marker` to point at the just-inserted
  `CLOCK: [start]` line itself (not the heading) —
  `(move-marker org-clock-marker (point) (buffer-base-buffer))` at
  `org-clock.el:1535`, executed immediately after inserting the `CLOCK:
  [timestamp]` text and indenting.
- `org-clock-out` (`org-clock.el:1836-1841`) validates the marker only by
  *shape*, not by *value*: `(goto-char org-clock-marker) (forward-line 0)`,
  then `(looking-at (concat "[ \t]*" org-keyword-time-regexp))` checked
  against `org-clock-string` ("CLOCK:"). If that fails, it signals exactly
  `"Clock start time is gone"` — the error incident 1 hit. Critically, the
  duration is then computed from whatever timestamp text sits at that
  line (`match-string 2`), **not** cross-checked against the in-memory
  `org-clock-start-time` value at all. A marker that has drifted onto a
  *different* still-shape-valid open `CLOCK:` line (e.g. another heading's,
  or a stale one) would pass this check silently and produce a wrong
  duration/heading — worse than the loud error incident 1 happened to get,
  because a `:SESSIONS:` line doesn't shape-match but another heading's
  open `CLOCK:` line would.
- This means a shape-only detector ("does the marker's line look like an
  open `CLOCK:` line") is not enough. The one value that survives a
  whole-buffer revert intact — because it is a plain Lisp time value, not a
  marker — is `org-clock-start-time`. The detector below anchors on it.

## Design

### 1. Shared detector: `claude-code-ide-org--clock-marker-desynced-p`

New function, `config.el`, placed near the other clock-status internals
(after `claude-code-ide-org--clock-status-active-data`, before the hooks
that will use it):

```elisp
(defun claude-code-ide-org--clock-marker-desynced-p ()
  "Non-nil if `org-clocking-p' but `org-clock-marker' no longer points
at the actual open CLOCK line it opened — the signature left when a
live-tracked org file is rewritten outside Emacs (e.g. a git checkout/
rebase/stash on a feature branch, or raw git-plumbing writes) while
`global-auto-revert-mode' silently reloads the buffer. Emacs markers
track a raw buffer *position*, not content; a whole-buffer revert
preserves the numeric offset but not what text sits there.

Anchored on `org-clock-start-time', a plain Lisp time value (not a
marker) that survives a revert intact — a shape check alone
(\"does the marker's line look like an open CLOCK: line\") is not
enough, since a marker that drifted onto a *different* open CLOCK:
line would pass a shape check and org-clock-out's own validation
(org-clock.el:1838-1840) while still computing the wrong duration.
Never signals; a marker pointing at a dead/killed buffer or nil
counts as desynced."
  (and (org-clocking-p)
       (or (not (markerp org-clock-marker))
           (not (marker-buffer org-clock-marker))
           (not (buffer-live-p (marker-buffer org-clock-marker)))
           (not (org-with-point-at org-clock-marker
                  (save-excursion
                    (forward-line 0)
                    (when (looking-at "^[ \t]*CLOCK: \\(\\[[^]]+\\]\\)[ \t]*$")
                      (time-equal-p (claude-code-ide-org--parse-org-timestamp
                                     (match-string 1))
                                    org-clock-start-time))))))))
```

### 2. Repair: `claude-code-ide-org-repair-clock-marker`

Not an MCP tool — same precedent as `claude-code-ide-org-close-open-interval`
(CLAUDE.md's "Recovery" section): a manual, `emacsclient`-invoked repair
function, not part of the normal workflow surface. Reuses the existing
scanner rather than writing a new one: `claude-code-ide-org--tracked-files`
+ `org-map-entries` with `"ID={.}"` (the exact pattern
`claude-code-ide-org-find-stale-open-intervals`, config.el:580, already
uses) and `claude-code-ide-org--entry-open-interval` (config.el:561, which
finds an open `CLOCK:` line by text search — ID-based, not
marker-dependent) to find every heading, across every tracked file, whose
open `CLOCK:` timestamp equals `org-clock-start-time`.

```elisp
(defun claude-code-ide-org-repair-clock-marker ()
  "Repair a desynced `org-clock-marker'/`org-clock-hd-marker' (see
`claude-code-ide-org--clock-marker-desynced-p') by re-locating the
real open CLOCK line: scan every tracked file
(`claude-code-ide-org--tracked-files') for a heading whose open
CLOCK: timestamp equals the in-memory `org-clock-start-time' — the
one value that survives a revert intact — and move both markers
there. Deliberately does not touch `org-clock-start-time' itself:
by construction, a match's timestamp already equals it. Never
edits buffer text or saves; this is a pure in-memory marker fix,
unlike the text-level `claude-code-ide-org-close-open-interval'.
Refuses (returns an error string) if zero or more than one heading
match — an ambiguous or missing match needs a human to look, same
philosophy as the existing stale-interval-recovery report requiring
user confirmation rather than guessing."
  (if (not (org-clocking-p))
      "No clock is currently running; nothing to repair."
    (let (candidates)
      (dolist (file (claude-code-ide-org--tracked-files))
        (when (file-exists-p file)
          (with-current-buffer (find-file-noselect file)
            (org-map-entries
             (lambda ()
               (let* ((interval (claude-code-ide-org--entry-open-interval))
                      (open (plist-get interval :logbook-open)))
                 (when (and open (time-equal-p open org-clock-start-time))
                   (push (list :id (org-entry-get nil "ID")
                                :heading-marker (point-marker))
                         candidates))))
             "ID={.}" 'file))))
      (cond
       ((null candidates)
        (format "Error: no open CLOCK line in any tracked file matches the in-memory clock start time (%s). Clock state may be genuinely gone -- consider a manual clock-out or claude-code-ide-org-close-open-interval instead."
                (format-time-string "[%Y-%m-%d %a %H:%M]" org-clock-start-time)))
       ((> (length candidates) 1)
        (format "Error: %d headings have an open CLOCK line matching the in-memory clock start time -- ambiguous, refusing to guess. :ID:s: %s"
                (length candidates)
                (mapconcat (lambda (c) (plist-get c :id)) candidates ", ")))
       (t
        (let* ((c (car candidates))
               (heading-marker (plist-get c :heading-marker)))
          (with-current-buffer (marker-buffer heading-marker)
            (save-excursion
              (goto-char heading-marker)
              (move-marker org-clock-hd-marker (point) (current-buffer))
              (re-search-forward "^[ \t]*CLOCK: \\[[^]]+\\][ \t]*$")
              (forward-line 0)
              (move-marker org-clock-marker (point) (current-buffer))))
          (if (claude-code-ide-org--clock-marker-desynced-p)
              "Error: repair attempted but the marker is still desynced -- something else is wrong, do not trust the clock state."
            (format "Repaired: org-clock-marker now points at \"%s\" (:ID: %s)."
                    (org-with-point-at org-clock-marker (org-get-heading t t t t))
                    (plist-get c :id))))))))))
```

(Self-check at the end — re-running the same predicate before declaring
success — is deliberate: it's cheap and catches a bug in the repair logic
itself rather than reporting false confidence.)

### 3. Per-call-site policy — deliberately different at each of the four
read sites, not a single blanket rule:

| Site | Current behavior | New behavior when desynced | Why |
|---|---|---|---|
| `claude-code-ide-org-clock-out` (config.el:372) | Calls `org-clock-out` directly | Return `"Error: clock state is stale ... run claude-code-ide-org-repair-clock-marker via emacsclient, then retry."` *without* calling `org-clock-out` | This is the site that hit the incident. Org's own validation there is shape-only (see source excerpt above) and can silently close the *wrong* line if the marker drifted onto another valid-looking open CLOCK line rather than erroring — worse than incident 1's loud failure. Refuse outright rather than risk it. |
| `claude-code-ide-org--statusline-task-string` (config.el:768) | Reads name/id/total straight off `org-clock-marker` | Never error (existing hard contract — the docstring says a status line must never error or hang). When desynced: fall back to `(car org-clock-history)` (last known-good heading) for name/id/total, but set `status-label` to `"clock state stale"` instead of `"clocked in"` | Confidently showing the wrong heading as "clocked in" is worse than an honest degraded label. The user glancing at their terminal sees the discrepancy directly, which *is* the "detect and warn loudly" behavior, just delivered through the statusline instead of an error. |
| `claude-code-ide-org--blocker-clock-running-p` (config.el:1549) | Blocks a DONE transition only if target heading's `:ID:` matches the ID at `org-clock-marker` | When desynced and target is `DONE`: block conservatively (`org-block-entry-blocking` set to a stale-state message), regardless of whether target matches | Can't trust the marker-based identity check while desynced, and this hook's whole purpose is "don't let a clocked heading get marked DONE out from under a running clock." Blocking is the fail-safe direction — worst case is an extra required repair step before completing a heading; the alternative (permitting) risks silently DONE-ing a heading whose clock never actually got closed. |
| `claude-code-ide-org--trigger-auto-clock-in` (config.el:1574) | Compares target `:ID:` against ID at `org-clock-marker` to decide whether to skip `org-clock-in` | When desynced: skip the `already-clocked-here` comparison entirely and skip calling `org-clock-in`, emitting `(display-warning 'claude-code-ide-org ...)` instead | `org-clock-in`, when something is already clocking, auto-closes the old clock first — i.e. it would call the exact same fragile `org-clock-out` path this whole guard exists to protect, compounding the corruption instead of fixing it. Skipping leaves the heading DOING/PLANNING with no fresh clock — a visible, self-correcting gap: the next explicit `org_clock_in` or the next `org_clock_out`'s new fail-loud message surfaces it, rather than a silent doubled/corrupted clock attempt. |

All four reuse the one predicate — no duplicated detection logic.

### 4. Incident 2 (malformed bare `CLOCK:` line) — scope decision

**Not chasing the root cause further here.** TODO.org's own later note
already pins a concrete, plausible mechanism (two near-simultaneous
`org-clock-in`/`-out` invocations from the session-resume bug,
`582cc7f4-...`/`d150c02e-...`) — fixing *that* is those headings' job, not
this one's. Re-opening it here would duplicate planning already staked out
elsewhere in TODO.org ("three distinct root causes in the same subsystem,
worth planning together, not assumed to be one fix").

**What this plan does do:** lock in, with an explicit regression test, the
resilience that already accidentally saved incident 2 from data loss.
`claude-code-ide-org--parse-clock-lines` (config.el:950) only recognizes
two line shapes — a closed `CLOCK: [s]--[e]` and an open `CLOCK: [s]` — and
silently drops anything else, including a bare `CLOCK:` with no timestamp.
That's *why* `claude-code-ide-org-consolidate-history` was able to rebuild
the drawer cleanly and drop the malformed line without complaint or data
loss. This behavior is currently accidental (a side effect of a
permissive-by-omission parser, never asserted by a test); a regression
test makes it a deliberately-relied-upon contract instead.

## Files

- `modules/tools/claude-code-ide-org/config.el`:
  - New `claude-code-ide-org--clock-marker-desynced-p` (shared detector).
  - New `claude-code-ide-org-repair-clock-marker` (manual repair,
    `emacsclient`-only, not an MCP tool).
  - `claude-code-ide-org-clock-out` — early desync check, error string,
    no `org-clock-out` call when desynced.
  - `claude-code-ide-org--statusline-task-string` — fallback-to-history +
    `"clock state stale"` label when desynced.
  - `claude-code-ide-org--blocker-clock-running-p` — block-conservatively
    branch when desynced.
  - `claude-code-ide-org--trigger-auto-clock-in` — skip-and-warn branch
    when desynced.
- `modules/tools/claude-code-ide-org/config-test.el` — new tests (below).

## Verification

`bin/test` (ERT), all new tests grouped near the existing clock-status
tests:

1. **Predicate, healthy state.** Clock in via `claude-code-ide-org-clock-in`;
   assert `claude-code-ide-org--clock-marker-desynced-p` is nil.
2. **Predicate, simulated desync.** This is inherently hard to reproduce
   mechanically end-to-end — it requires an out-of-Emacs file write racing
   `global-auto-revert-mode` mid-session, which isn't something `bin/test`
   (a one-shot `emacs --batch` run) can trigger for real. Two levels of
   simulation, in order of preference:
   - **Closest feasible repro:** clock in via the existing
     `--with-heading` fixture (which uses a real scratch file, not just a
     buffer), then rewrite `file` on disk *outside* the visiting buffer
     (`write-region` to the same path from a `with-temp-buffer`, bypassing
     the visiting buffer entirely — mirrors the real `git hash-object`
     mechanism) with content that shifts the CLOCK line to a different
     offset, then call `(revert-buffer t t t)` on the visiting buffer to
     mirror what `global-auto-revert-mode` does. Assert the predicate
     flips to non-nil. If `revert-buffer`'s diffing turns out to preserve
     marker positions well enough that this doesn't reproduce the drift
     (plausible — Emacs's revert can do a minimal-diff replace rather than
     a blind erase+insert) fall through to the deterministic case below
     and note in the test comment that the end-to-end repro didn't
     trigger it, so the direct case is the one actually load-bearing.
   - **Deterministic fallback:** directly `(move-marker org-clock-marker
     <wrong-position>)` after clocking in (e.g. onto the `:SESSIONS:`
     line, or onto a second heading's own open CLOCK line with a
     different start time) and assert the predicate flips to non-nil.
     This is the one guaranteed to work regardless of `revert-buffer`
     internals, and directly exercises the exact "marker still points
     into a live buffer but at wrong/different-shaped text" condition the
     detector is built for.
   - Test cleanup note: once a test deliberately desyncs the marker, the
     `--with-heading` fixture's own `unwind-protect` cleanup
     (`(when (org-clocking-p) (org-clock-out))`) would itself hit the same
     "Clock start time is gone" error since it calls *raw* `org-clock-out`,
     not the wrapper. Each such test must restore a valid marker (or call
     the new `claude-code-ide-org-repair-clock-marker`) before returning,
     so cleanup doesn't poison later tests in the same `bin/test` run.
3. **`claude-code-ide-org-clock-out`, desynced.** Using the deterministic
   desync from (2), call the wrapper; assert it returns the new stale-state
   error string (not the org-native "Clock start time is gone" or a
   silently-wrong close), and that `org-clocking-p` is still `t` afterward
   (nothing was touched).
4. **`claude-code-ide-org-repair-clock-marker`, success case.** Desync the
   marker deterministically, call the repair function, assert it returns a
   "Repaired: ..." string naming the correct heading, that the predicate
   is now nil, and that `claude-code-ide-org-clock-out` afterward succeeds
   normally (closes the real CLOCK line, produces the expected disk text).
5. **`claude-code-ide-org-repair-clock-marker`, no-match case.** Set
   `org-clock-start-time` (via `move-marker`/direct `setq` after clocking
   in) to a timestamp that matches no CLOCK line in the fixture; assert an
   "Error: no open CLOCK line ... matches" string.
6. **`claude-code-ide-org-repair-clock-marker`, ambiguous case.** Fixture
   with two headings whose open CLOCK lines share an identical start
   timestamp; assert the "Error: N headings ... ambiguous" string, naming
   both `:ID:`s.
7. **Statusline, desynced.** Desync the marker deterministically; assert
   `claude-code-ide-org--statusline-task-string` still returns (never
   errors) and its label reads `"clock state stale"` rather than
   `"clocked in"`, with name/id/total falling back to
   `(car org-clock-history)`.
8. **Blocker hook, desynced.** Desync the marker on a `DOING` heading,
   attempt `claude-code-ide-org-set-todo` to `DONE` on that same heading;
   assert it is blocked (state unchanged) with the new stale-state
   message, distinguishing this from the existing
   `--blocker-clock-running-p` regression test (which covers the
   already-correct, non-desynced identity-match case and must keep
   passing unchanged).
9. **Trigger hook, desynced.** Desync the marker, then transition a
   *different* heading to `DOING` via `claude-code-ide-org-set-todo`;
   assert no new `CLOCK:` line appears in that heading's `:LOGBOOK:` (the
   auto-clock-in was skipped, not attempted-and-corrupted), and — via
   `cl-letf` stubbing `display-warning` to record its call — that a
   warning was actually raised rather than silently doing nothing.
10. **Incident 2 regression (already-accidental resilience, now
    asserted).** Build a `:LOGBOOK:` body containing a bare `CLOCK:` line
    (no timestamp) sitting between two valid closed CLOCK lines; run
    `claude-code-ide-org-consolidate-history`; assert the malformed line
    is gone from the result and the surviving entries' summed duration
    matches the two valid lines only (nothing silently double-counted or
    lost from the *valid* lines either).

All existing tests — the 5 `--statusline-task-string` regressions, the
`--blocker-clock-running-p` and `--trigger-auto-clock-in` regressions, and
every `clock-in`/`clock-out` test — must keep passing unchanged; the
desynced branch is additive and only activates when the new predicate is
true, which it never is in any existing (non-desyncing) test.

**Not mechanically testable, flagged rather than skipped:** whether
`global-auto-revert-mode`'s *actual* idle-timer-driven revert (as opposed
to an explicit `revert-buffer` call in a test) reproduces the exact drift
incident 1 hit is not something `bin/test`'s batch/`-Q` environment can
exercise — auto-revert's timer and `noninteractive` batch mode don't mix
cleanly. The deterministic `move-marker` simulation is the load-bearing
test; the `revert-buffer` attempt in (2) is a best-effort corroboration,
not the primary evidence, and the plan says so explicitly rather than
implying full end-to-end coverage exists.

Live/manual (documented pass, not automated — this project's own
convention for anything a batch Emacs can't safely exercise): reload
`config.el` in the running Doom Emacs (org-dev skill), clock in on a
scratch heading, manually `(move-marker org-clock-marker (point-min))` via
`emacsclient`, confirm `org_clock_out` now returns the new stale error
instead of the old cryptic one or a silent wrong-close, then confirm
`claude-code-ide-org-repair-clock-marker` (via `emacsclient`) restores it
and a normal `org_clock_out` succeeds afterward.

## Explicitly out of scope

- Incident 2's actual root cause (why a bare `CLOCK:` line got written) —
  owned by `582cc7f4-...`/`d150c02e-...`, not re-litigated here.
- `4cda6bf7-...`'s own statusline TODO-keyword fix (swapping
  `org-get-todo-state` in for `status-label`) — that heading's note already
  flags it inherits this same desync mode; this plan's detector and
  fallback-to-history pattern in `--statusline-task-string` is exactly what
  that fix should build on, but implementing it is that heading's job.
- True automatic self-healing wired transparently into every call site
  with no visible signal (e.g. silently repairing inside
  `--trigger-auto-clock-in` before proceeding) — considered and rejected:
  this is a rare failure mode, the repair's correctness depends on exactly
  one heading matching `org-clock-start-time` (the ambiguous/zero-match
  cases above are real, not hypothetical, once two headings' clocks
  happen to share a start minute), and silently "fixing" state the model
  can't see fixed risks exactly the kind of confident-but-wrong behavior
  this whole plan exists to avoid. Detect-and-refuse (clock-out),
  detect-and-degrade (statusline), detect-and-block (blocker hook), and
  detect-and-skip-with-a-warning (trigger hook) were judged the more
  honest defaults; a human- or model-invoked
  `claude-code-ide-org-repair-clock-marker` is the deliberate, visible
  escape hatch.

## After approval

Per CLAUDE.md: add
`[[file:~/.claude/plans/clock-marker-desync-guard.md][Plan]]` to this
heading's body once a real implementation session picks this up (this is
background/unattended planning research — no heading edit, no TODO-state
change, and no clock touched by this planning pass itself).
