---
description: The sequenced slice of work queued for the next session, with its blockers and rationale
---

# Next session

Revised 2026-08-21 after the user asked for the meta-work mechanism ASAP and
named the real worry: *"all of the other issues that have piled up and I have
lost sight of."*

Read the heading bodies before starting any item — each carries measurements
this prompt only summarises.

**Before anything else:** confirm `emacs-tools` is reachable by calling
`org_pending_updates`. Items may have moved if a review pass ran since this
was written.

---

## The measurement that shapes this list

TODO.org, 2026-08-21: **72 active headings — 51 TODO, 16 MAYBE, 3 DOING, and
2 NEXT.** 21 of the 72 were created in the last two days.

The backlog is not un-reviewed. It is **un-nominated**. With 2 nominations
against 51 candidates, "what should I do next" has to be re-derived from
scratch every time it is asked, which is exactly what losing sight of it
feels like. That is a diagnosis, not a mood, and item 3 addresses it
directly.

Also: 18 non-MAYBE headings are 8+ days old, the oldest 22 days.

---

## 1. Fix both `--trigger-auto-promote-sole-todo` guards together

`c8a6c5d2` and `42808717`. **First**, not because anything blocks on them
but because they corrupt the record *now*: every batch apply mis-marks a
`NEXT`, and each review pass adds another. With only 2 NEXTs in the file,
a wrong one is a large fraction of the total nomination signal.

Two guards on one function sharing one test scaffold — splitting them pays
for it twice.

- `42808717` — promotes a **container**, declaring a project to be an action.
  `claude-code-ide-org--container-heading-p` is the guard, already used by
  `--trigger-auto-clock-in`.
- `c8a6c5d2` — fires on **apply order**. The review pass lands one event at a
  time, so the first child's keyword makes it momentarily the sole TODO of
  its group. The resulting `NEXT` records queue order, nothing more.

`62c6b1be` shipped the identical container guard for
`--review-suggest-heading` on 2026-08-21 — read it first and copy its
mutation-test pattern, **including its assertion that a leaf is still
promoted**, which is what catches an over-applied guard.

## 2. Stand up the meta-work mechanism — `e30d52d7`, then `cd1e974e`

These two are the whole critical path to clocking meta-work. **They are
smaller than the five children of `a1d63f52` make it look.**

- `e30d52d7` — **bigger than its title suggests; re-scoped 2026-08-21 by
  linting the proposed structure.** It is not a warning flood, it is three
  *errors* the pre-commit hook refuses:

  ```
  error: heading has no :ID:: 2026
  error: heading has no :ID:: 2026-08 August
  error: level-4 heading; the file has three levels: 2026-08-21 Friday
  ```

  Year and month fail on `:ID:` — an error — before reaching the `:CREATED:`
  warning. And **the level-4 rule rejects the day node itself**, the one
  heading that does carry `:ID:`/`:CREATED:` and that should stay linted, so
  exempting scaffolding does not reach it.

  The level rule is a documented assertion, not an implementation detail:
  `3bd3402b`, restated in `bin/lint-org`'s header as "the file has three
  levels (category, task, epic-child)". A datetree makes that false. **Read
  `3bd3402b` before touching the rule** — this is revising a structural claim
  about TODO.org, not tweaking a linter.
- `cd1e974e` — write the category, its `:DATE_TREE:` and `:ARCHIVE:`
  properties, the ritual repeater, and the matching `* Review and planning`
  in DONE.org *in the same edit* (the archive target is matched as a literal
  string and a mismatch silently appends a second category).

Doing item 2 in the previously-scoped order would exempt two warnings, then
hit three errors partway through `cd1e974e` with the category half-written.

**After `cd1e974e` you can clock meta-work the same day**, by hand-creating
the first day node with an `:ID:` and `:CREATED:`. That is the ASAP answer —
the resolver below automates a step you can otherwise do in ten seconds each
morning.

## 3. `dd2399c0` — write the NEXT-nomination rule

Added to this slice because it is the direct answer to the stated worry, and
it is cheap: it is writing a rule, not building a mechanism.

Its own body has the argument: this repo already enforces **at most** one
NEXT per level mechanically, via `--trigger-auto-promote-sole-todo`. The
nomination rule supplies **at least** one, for the case no trigger can
decide. Together they give exactly one — "a live project always has a next
action, and a project without one is the canonical defect a weekly review
exists to catch."

**Its one open question is now answered.** Placement was deferred pending
`befaed0a`, which closed 2026-08-21: path-scoped rules hold org-*file*
conventions, CLAUDE.md holds ways of working. `dd2399c0` says of itself that
it is "a way of working rather than an org-file convention" — so it goes in
CLAUDE.md.

Both halves must be written: nominate a NEXT on every transition to DONE
when clear candidates exist, and call out blockers that live in a *different*
subtree. Verify with
`grep -n -i nominat .claude/skills/org/SKILL.md CLAUDE.md`.

## 4. `3063c3e5` — the revise-in-place gap

Raised to the slice 2026-08-21. It **blocks `b07df584`**, which is the
user's standing concern: *"I am questioning the long-term utility of
capturing this quantity of minutiae"* (2026-08-18), repeated 2026-08-21 with
the added point that accumulated prose costs *working context*, not just
readability. Machinery gates the policy — what to stop capturing is hard to
settle while nothing can revise what was already captured.

Measured: TODO.org is ~118,000 tokens; across 72 active headings the median
body is **50 lines**, the longest 404, and **44 bodies of 40+ lines carry 86%
of all active body text**.

**The main objection is weaker than the heading's neighbourhood assumed.**
CLAUDE.md calls deletion "the one irreversible half", but justifies that by
`plans/`'s history being *bounded*. `.org` files are version-controlled in
full, so superseded prose stays recoverable from git. Revision is reversible
here; only prose written and deleted inside one uncommitted window is at
risk.

An interim convention shipped 2026-08-21 in `.claude/skills/org/SKILL.md`
("Body prose and the task lifecycle") and does **not** close this — it stops
the body contradicting the keyword, but cannot put the outcome first.

## 5. `9575e65b` — the resolver

Automates the hand-made day node from item 2. Find the `:DATE_TREE:`
heading, `org-datetree-find-date-create` for today, stamp `:ID:`/`:CREATED:`
if new, set `org-clock-default-task`, return the id. Two callers:
`org_clock_in` creates; the `SessionStart` hook refreshes only and **never**
creates.

**Cut line:** if the session is running long, stop after item 3. The
mechanism already works by hand at that point, and item 4 is a steady-state
cost rather than an accelerating one.

## Free, and starting immediately: write shorter bodies

Needs no tool and no decision, and it is already standing user guidance —
*economise on body prose, never on heading count.* 2026-08-21's own output
did not follow it: 13 headings filed, several with 40+ line bodies. Two
bounded headings beat one long body. This is the largest available
improvement per unit of effort on the list and it costs nothing.

---

## Deliberately off the critical path

- `6ae83993` (`org-clock-default-task`) — a human keystroke convenience.
  Claude cannot use it at all. Nothing depends on it.
- `25ec37b0` — **may be half dead scope.** Its *addressable day node* half
  belongs to `9575e65b`. Its *teach `org_capture` to target a datetree* half
  exists to support capturing entries **under** a day node, which the
  2026-08-21 decision ruled out when the day node became the thing clocked
  against. Settle this before building it; do not assume it survives.
- `a279216c` (whole-span gap line) — real but cosmetic; it was item 3 before
  `dd2399c0` displaced it.

---

## Standing rules that were violated on 2026-08-21

- **Clock in before starting, not after.** A session that opens as a question
  drifts into tracked work without ever feeling like "starting a task." 24
  minutes landed on the wrong heading that way. Call `org_set_todo` DOING +
  `org_clock_in` at the first substantive action, even mid-turn.
- **Run a proposed mechanism before recommending it.** A heading body's
  design claims are the perishable half. `9202b39d`'s depth counter was
  relayed as fact and falsified on measurement — it loses 9.18 h and latches.
  Its *measurement* reproduced exactly.
- **Never pass `--no-verify`.** The pre-commit hook caught a silent no-op
  `:BLOCKER:` on 2026-08-21 and was right to.
- **A `:BLOCKER:` written in the same session that captured its target is
  inert** until a human applies the queue, because `org-depend` blocks only
  on an unfinished TODO keyword.
