# Plan — org-clock-out-remove-zero-time-clocks silently erases short CLOCK intervals

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
