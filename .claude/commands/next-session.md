---
description: The sequenced slice of work queued for the next session, with its blockers and rationale
---

# Next session

Rewritten 2026-08-21 (evening), revised 2026-08-22 to add `8bcd56f4`. Items
1–3 of the previous slice shipped; what follows is what it left, plus what the
sessions since have designed.

Read the heading bodies before starting any item — each carries measurements
this prompt only summarises.

**Before anything else:** confirm `emacs-tools` is reachable by calling
`org_pending_updates`. Items may have moved if a review pass ran since this
was written.

**Format note, under trial.** Every item carries a **Decision:** line saying
whether it holds an unresolved decision and whose it is. That is `c10bfb15`'s
first assertion, and this file is its trial — the previous prompt left item
1's "Possible shapes, none chosen" buried in a heading body, and the executing
session picked one with no checkpoint. Worth noticing that **nothing in this
slice is now blocked on a decision**: the discussion that produced items 2–4
settled every one of them. That is the marker doing its job rather than
finding nothing to do.

---

## What is already true, so it is not re-derived

- The meta-work mechanism **works by hand today**: `* Review and planning`
  with `:DATE_TREE:`, a weekly archive repeater, a daily ritual repeater, and
  a live day node carrying an `:ID:`.
- `bin/lint-org` understands datetree scaffolding. 0 errors throughout.
- `--trigger-auto-promote-sole-todo` no longer promotes containers and no
  longer fires mid-batch; it settles once after apply.
- The NEXT-nomination rule is in CLAUDE.md.
- **The `:PLAN:` lifecycle is designed and filed** (`8bcd56f4`), the drawer
  name is settled, and `cc0c17a7` is a worked example of the end state.
- **A queue is pending.** Roughly 15 items including six `DONE`s. `cd1e974e`
  is `:BLOCKER:`-ed on `e30d52d7` and the queue already holds them in that
  order. TODO.org is left read-only; `C-x C-q` before applying.

---

## 1. `9575e65b` — build the resolver

**Decision: none outstanding.** Option (c), chosen by the user: the resolver
runs at **apply time** and dates the node from **the event's own timestamp**,
never from "today".

Smaller than the heading's length suggests — the recorded steps are unchanged
except for the date argument passed to `org-datetree-find-date-create`. The
body still contains a superseded "`org_clock_in` … *creates* if absent"
paragraph *above* the decision; append-only, flagged in place. Read to the
bottom.

Independent of items 2–4, so it can go first or last.

## 2. `3063c3e5` — build the body-revision tools

**Decision: none outstanding.** The drawer is `:PLAN:`, chosen by the user.

**Build wrapping first; it is not the same job as revision.** Measured on
`cc0c17a7`: `org_amend` *already* appends below a `:PLAN:` drawer sitting at
the top of a body, so the debrief needs no new tool. The only new operation
the completion transition needs is **wrapping** — insert the drawer at the
end-of-drawers boundary, close it after the last body line. Two insertions at
computable positions.

General in-place revision is the harder tool and is needed for the
*continuous paring* half, not for completion. Splitting them means items 3
and 4 unblock after the cheap half.

**Do not hand-roll either.** Two corruptions are on record, each a different
range bug — an `emacsclient` edit that "corrupted a sibling heading", and a
`startswith("*")` next-heading test that matched a *bold prose line* and
orphaned 117 lines. Both times `bin/lint-org` reported **0 errors**, because
the damage is prose-level under a well-formed heading. Git was the only safety
net; commit before revising is a precondition, not ceremony.

## 3. `8bcd56f4` — adopt the `:PLAN:` lifecycle

**Decision: none outstanding.** The design is settled; this is writing it
down and switching the conventions over. **Blocked on item 2** — and the
blocker is verified live, not assumed.

The deferred edits, all held back deliberately so that no rule describes
something a session cannot yet perform:

- CLAUDE.md's plan-link wording — "not removed at `DONE`" becomes *relocated
  into `:PLAN:`, not deleted*.
- `.claude/rules/org-conventions.md` gains `:PLAN:` beside the other drawer
  conventions.
- The org skill's "Body prose and the task lifecycle" section is **superseded
  wholesale**, not amended. It already says of itself *"Until that is fixed
  (TODO.org `:ID:` 3063c3e5)"*. Add the rule that agentic readers ignore the
  `:PLAN:` drawer until a retrospective question is actually asked.
- `bin/lint-org` can then assert that a `DONE` heading with a substantial body
  carries a `:PLAN:` drawer.

## 4. `cbe282ec` — clear the archive backlog

**Decision: none outstanding.** Migration is **sweep the old bodies into
`:PLAN:` unedited**, chosen by the user.

30 finished headings sit in TODO.org; the newest `:ARCHIVE_TIME:` is
2026-08-17. Under the sweep decision this splits into a mechanical step
(wrapping — item 2's cheap half, zero judgement) and a cheap one (the debrief,
still per-heading, but the expensive judgement was deciding what to *discard*
and sweeping discards nothing). Old drawers will be raw transcripts where new
ones are pared plans; the ignore-the-drawer rule makes that invisible.

The weekly repeater is for the steady state; this first pass is a backlog and
should not wait for it.

**Out of scope:** *where* archived work lands. Per-category `:ARCHIVE:` versus
a `datetree/` location is item 5's question, and switching would break
`e30d52d7`'s lint rule until that is settled.

## 5. `82df2a6c` — look through Org's own lenses before moving anything

**Decision: none yet, and that is the point** — this item exists to produce
the evidence a decision would need. It is not a mandate to refactor.

`29439196` was promoted MAYBE → TODO on 2026-08-21 by a trigger written that
morning and met that afternoon. The cheap path is not the refactor: agenda
views, sparse trees and column view **all run against the current structure**,
so evaluate them on the corpus as it stands. If they show nothing worth
having, `29439196` resolves against and the line closes.

Related, not duplicates: `8ca6541d` (stories as checkbox lists of id links —
needs `--container-heading-p` taught about them, or it reintroduces
`42808717`), and `9651d4c8` (which a declared story answers by construction).

**Cut line:** stop after item 4. Items 2–4 are one arc — build the tool, adopt
the convention, apply it to the backlog — and stopping mid-arc leaves a tool
built and unused. If the session is short, do **1 and 2 only**: item 2's cheap
half makes the lifecycle performable by hand, which is the same "works by
hand" standard the previous slice cut on.

---

## Deliberately off the critical path

- `6ae83993` (`org-clock-default-task`) — a human keystroke convenience. Under
  option (c) it degrades gracefully: unset until the first apply.
- `25ec37b0` — **may be half dead scope.** Settle before building.
- `a279216c` (whole-span gap line) — real but cosmetic.
- `43201e64` — every orgit link a body adds costs a permanent lint warning.
  Small, and worth doing before the convention is used much more.
- `c10bfb15` — the format rule this file is trialling. Write it up only once
  the marker has survived a session or two of use.

---

## Standing rules, with what actually happened

- **Clock in at the drift, not at the ask.** Violated *twice* on 2026-08-21:
  24 minutes in the morning, and an hour of afternoon meta-work clocked only
  at 14:54 after starting around 13:52.
- **Read structure through org, not through text.** An `awk` parent-inference
  returned each heading's *own* title instead of its parent and put a wrong
  structural claim into conversation. `org_outline` answers parentage,
  keywords, titles and tags in one call and cannot be misread that way.
- **Grep before coining a name.** `:ORIGINAL:` was invented on the spot for a
  concept the project already had a word for. The correct name, `:PLAN:`, was
  free and obvious in hindsight.
- **Run a proposed mechanism before recommending it.** Held up well: the
  archive path was read *and* executed before anything was built on it, which
  is how `CLOSED`-based filing was found.
- **Never pass `--no-verify`.**
- **A `:BLOCKER:` written in the same session that captured its target is
  inert** until a human applies the queue.
