---
description: The sequenced slice of work queued for the next session, with its blockers and rationale
---

# Next session

Rewritten 2026-08-21 (evening) after the previous slice was consumed. Items 1–3
of that slice shipped; what follows is what it left, plus what the session
itself uncovered.

Read the heading bodies before starting any item — each carries measurements
this prompt only summarises.

**Before anything else:** confirm `emacs-tools` is reachable by calling
`org_pending_updates`. Items may have moved if a review pass ran since this
was written.

**Format note, new and under trial.** Every item below carries a **Decision:**
line saying whether it holds an unresolved decision and whose it is. That rule
is `c10bfb15`'s first assertion, and this file is its first application — the
previous prompt left item 1's "Possible shapes, none chosen" buried in a
heading body, and the executing session picked one with no checkpoint. If the
marker turns out to be noise, say so on `c10bfb15` rather than dropping it
silently.

---

## What is already true, so it is not re-derived

- The meta-work mechanism **works by hand today**. `* Review and planning`
  exists with `:DATE_TREE:`, a weekly archive repeater, a daily ritual
  repeater, and a live day node carrying an `:ID:`.
- `bin/lint-org` understands datetree scaffolding. 0 errors throughout.
- `--trigger-auto-promote-sole-todo` no longer promotes containers, and no
  longer fires mid-batch — it settles once after apply instead.
- The NEXT-nomination rule is in CLAUDE.md.
- **A queue is pending.** Roughly 15 items including six `DONE`s. `cd1e974e`
  is `:BLOCKER:`-ed on `e30d52d7` and the queue already holds them in that
  order. TODO.org is left read-only; `C-x C-q` before applying.

---

## 1. `9575e65b` — build the resolver

**Decision: none outstanding.** Option (c) was chosen by the user 2026-08-21
and is recorded on the heading: the resolver runs at **apply time** and dates
the node from **the event's own timestamp**, never from "today".

Smaller than the heading's length suggests. The recorded steps are unchanged
except for the date argument passed to `org-datetree-find-date-create`. Note
the body still contains a superseded "`org_clock_in` … *creates* if absent"
paragraph *above* the decision — append-only, flagged in place. Read to the
bottom.

The `SessionStart` half is unchanged and still correct: resolve read-only,
never create.

## 2. `3063c3e5` — build revise-in-place properly

**Decision: one, and it is the user's** — ratify or replace the drawer name
`:ORIGINAL:`, which the 2026-08-21 trial invented and did not establish. If it
stands it belongs in `.claude/rules/org-conventions.md`.

A working prototype exists: `f0cdc90` took `cc0c17a7` from 138 lines to 34 by
hand. So the operation is proven and the policy is settled; what is missing is
a tool that owns the range logic.

**Do not hand-roll it again.** Two corruptions are now on record from doing so,
each a different range bug — an `emacsclient` edit that "corrupted a sibling
heading", and a `startswith("*")` next-heading test that matched a *bold prose
line* and orphaned 117 lines. Both times `bin/lint-org` reported **0 errors**,
because the damage is prose-level under a well-formed heading. Git was the only
safety net. Commit before revising is therefore a precondition, not ceremony.

## 3. `cbe282ec` — clear the archive backlog

**Decision: none outstanding**, but it is gated by item 2 in practice.

30 finished headings sit in TODO.org; the newest `:ARCHIVE_TIME:` is
2026-08-17. Archiving stalls because CLAUDE.md requires an outcome summary
before a `DONE` heading is archived — so a pass over 30 is 30 judgements, and
producing those summaries *is* item 2's operation applied 30 times. The weekly
repeater is for the steady state; the first pass is a backlog and should not
wait for it.

**Out of scope here:** *where* archived work lands. Per-category `:ARCHIVE:`
versus a `datetree/` location is item 4's question, and switching would break
`e30d52d7`'s lint rule until that is settled.

## 4. `82df2a6c` — look through Org's own lenses before moving anything

**Decision: none yet, and that is the point** — this item exists to produce the
evidence a decision would need. Do not treat it as a mandate to refactor.

`29439196` was promoted MAYBE → TODO on 2026-08-21, by a trigger written that
morning and met that afternoon. The cheap path is not the refactor: agenda
views, sparse trees and column view **all run against the current structure**,
so evaluate them first on the corpus as it stands. If they show nothing worth
having, `29439196` resolves against and the whole line closes.

Related and not duplicates: `8ca6541d` (stories as checkbox lists of id links,
which needs `--container-heading-p` taught about them or it reintroduces
`42808717`), and `9651d4c8` (which a declared story answers by construction).

**Cut line:** stop after item 3. Items 1–3 finish the meta-work mechanism and
stop the live file growing; item 4 is research whose value does not decay.

---

## Deliberately off the critical path

- `6ae83993` (`org-clock-default-task`) — a human keystroke convenience. Under
  option (c) it degrades gracefully: unset until the first apply.
- `25ec37b0` — **may be half dead scope.** Settle before building; do not
  assume it survives.
- `a279216c` (whole-span gap line) — real but cosmetic.
- `c10bfb15` — the format rule this file is trialling. Write it up only once
  the marker has survived a session or two of use.

---

## Standing rules, with what actually happened on 2026-08-21

- **Clock in at the drift, not at the ask.** Violated *twice* that day: 24
  minutes in the morning, and an hour of meta-work in the afternoon that was
  clocked only at 14:54 after starting around 13:52. A session that opens as a
  question drifts into tracked work without feeling like "starting a task."
- **Read structure through org, not through text.** An `awk` parent-inference
  returned each heading's *own* title instead of its parent and put a wrong
  structural claim into conversation. `org_outline` answers parentage,
  keywords, titles and tags in one call and cannot be misread that way.
- **Run a proposed mechanism before recommending it.** Held up well: the
  archive path was read *and* executed before anything was built on it, which
  is how `CLOSED`-based filing was found.
- **Never pass `--no-verify`.**
- **A `:BLOCKER:` written in the same session that captured its target is
  inert** until a human applies the queue.
