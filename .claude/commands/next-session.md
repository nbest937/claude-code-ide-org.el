---
description: The sequenced slice of work queued for the next session, with its blockers and rationale
---

# Next session

Rewritten 2026-08-21 (evening); revised 2026-08-22 to add `8bcd56f4`, then
again to put `eaeeb4ee` first.

Read the heading bodies before starting any item — each carries measurements
this prompt only summarises.

**Before anything else:** confirm `emacs-tools` is reachable by calling
`org_pending_updates`. Items may have moved if a review pass ran since this
was written.

**Format note, under trial.** Every item carries a **Decision:** line saying
whether it holds an unresolved decision and whose it is (`c10bfb15`'s first
assertion). Nothing in this slice is blocked on a decision — the discussions
that produced these items settled all of them. That is the marker working, not
the marker finding nothing.

---

## What is already true, so it is not re-derived

- The meta-work mechanism **works by hand**: `* Review and planning` with
  `:DATE_TREE:`, a weekly archive repeater, a daily ritual repeater, and a
  live day node carrying an `:ID:`.
- `bin/lint-org` understands datetree scaffolding. 0 errors throughout.
- `--trigger-auto-promote-sole-todo` no longer promotes containers and no
  longer fires mid-batch; it settles once after apply. Verified in production.
- The NEXT-nomination rule is in CLAUDE.md.
- The `:PLAN:` lifecycle is designed and filed (`8bcd56f4`), the drawer name
  is settled, and `cc0c17a7` is a worked example of the end state.
- **The queue holds precise per-heading attribution that the review pass does
  not use.** Twelve `clock_in`/`clock_out` pairs from 2026-08-21, each naming
  a heading and carrying a note, all `applied: false`. That is item 1.

---

## 1. `eaeeb4ee` — make explicit clock pairs authoritative

**Decision: none outstanding.** This is a bug hunt, not a design.

**First, because it corrupts the record now and compounds** — the same test
that put the auto-promote guards first in the previous slice. Every review
pass mis-allocates, and each pass adds more. Measured: an hour of
implementation work across five headings landed on `a279216c`, a cosmetic
item nobody had opened, while the queue held the correct answer for all of it.

**The capability is not missing — find why it doesn't fire.** `config.el`
already pairs `clock_in` with `clock_out` into items, and already resolves
"the enclosing `clock_in`'s note" when labelling a span. The 2026-08-21 day
node proves the path works end to end. Four headings clocked in the same
session, by the same session, produced no CLOCK line at all. **That asymmetry
is the whole task.**

**Do not read this as a discipline problem.** `62c6b1be` diagnosed the same
failure on 2026-08-20 as calling `org_clock_in` too seldom. On 2026-08-21 it
was called twelve times, correctly, with notes — identical outcome. The
discipline half is done; the consumption half is missing. That is a
falsification, not an opinion.

Once consumed: a work-run inside a `clock_in`/`clock_out` interval is
attributed with **certainty** and needs no human; a span is **partitioned** by
the pairs it contains rather than assigned whole; only the residue reaches a
person. Follow-ons that get much cheaper afterwards — `2d100d0d` (a span and
an explicit interval can both apply, double-counting nine minutes on the
measured day) and `5a6d2c75` (evidence, plus a coverage line and a meta-work
cue), which then only has to serve the residue it was written for.

## 2. `9575e65b` — build the resolver

**Decision: none outstanding.** Option (c), chosen by the user: the resolver
runs at **apply time** and dates the node from **the event's own timestamp**,
never from "today".

Smaller than the heading's length suggests — the recorded steps are unchanged
except for the date argument to `org-datetree-find-date-create`. The body
still holds a superseded "`org_clock_in` … *creates* if absent" paragraph
*above* the decision; append-only, flagged in place. Read to the bottom.

Independent of items 3–5. Pairs naturally with item 1: item 1 makes clocks
land, this makes there be somewhere to land meta-work.

## 3. `3063c3e5` — build the body-revision tools

**Decision: none outstanding.** The drawer is `:PLAN:`, chosen by the user.

**Build wrapping first; it is not the same job as revision.** Measured on
`cc0c17a7`: `org_amend` *already* appends below a `:PLAN:` drawer at the top
of a body, so the debrief needs no new tool. The only new operation the
completion transition needs is **wrapping** — insert the drawer at the
end-of-drawers boundary, close it after the last body line. Two insertions at
computable positions. General in-place revision is the harder tool and is
needed for *continuous paring*, not for completion; splitting them unblocks
items 4 and 5 after the cheap half.

**Do not hand-roll either.** Two corruptions are on record, each a different
range bug — an `emacsclient` edit that "corrupted a sibling heading", and a
`startswith("*")` next-heading test that matched a *bold prose line* and
orphaned 117 lines. Both times `bin/lint-org` reported **0 errors**, because
the damage is prose-level under a well-formed heading. Git was the only safety
net.

## 4. `8bcd56f4` — adopt the `:PLAN:` lifecycle

**Decision: none outstanding.** The design is settled; this writes it down and
switches the conventions over. **Blocked on item 3**, verified live.

Deferred edits, held back so no rule describes something a session cannot yet
perform: CLAUDE.md's plan-link wording ("not removed at `DONE`" → *relocated
into `:PLAN:`, not deleted*); `.claude/rules/org-conventions.md` gains
`:PLAN:`; the org skill's "Body prose and the task lifecycle" section is
**superseded wholesale**, plus the rule that agentic readers ignore the
`:PLAN:` drawer until a retrospective question is asked; and `bin/lint-org`
can then assert a `DONE` heading with a substantial body carries one.

## 5. `cbe282ec` — clear the archive backlog

**Decision: none outstanding.** Migration is **sweep the old bodies into
`:PLAN:` unedited**, chosen by the user.

30 finished headings sit in TODO.org; the newest `:ARCHIVE_TIME:` is
2026-08-17. Under the sweep decision this is one mechanical step (wrapping —
item 3's cheap half, zero judgement) and one cheap one (the debrief, still
per-heading, but the expensive judgement was deciding what to *discard* and
sweeping discards nothing). The weekly repeater is for the steady state; this
first pass is a backlog.

**Out of scope:** *where* archived work lands — item 6's question, and
switching would break `e30d52d7`'s lint rule until settled.

## 6. `82df2a6c` — look through Org's own lenses before moving anything

**Decision: none yet, and that is the point** — this produces the evidence a
decision would need. Not a mandate to refactor.

Agenda views, sparse trees and column view **all run against the current
structure**, so evaluate them on the corpus as it stands. If they show nothing
worth having, `29439196` resolves against and the line closes. Related:
`8ca6541d` (stories as checkbox lists — needs `--container-heading-p` taught
about them or it reintroduces `42808717`), `9651d4c8`.

**Cut line:** stop after item 5. Items 3–5 are one arc — build the tool, adopt
the convention, apply it to the backlog — and stopping mid-arc leaves a tool
built and unused. **If the session is short, do 1 and 2 only:** together they
make the time record trustworthy, which is the co-equal goal CLAUDE.md names.

---

## Deliberately off the critical path

- `6ae83993` (`org-clock-default-task`) — a human keystroke convenience. Under
  option (c) it degrades gracefully: unset until the first apply.
- `25ec37b0` — **may be half dead scope.** Settle before building.
- `a279216c` (whole-span gap line) — real but cosmetic.
- `43201e64` — every orgit link a body adds costs a permanent lint warning.
  Small; worth doing before the convention is used much more.
- `c10bfb15` — the format rule this file is trialling. Write it up once the
  marker has survived a session or two.

---

## Standing rules, with what actually happened

- **Verify the clock landed, not just the state change.** New, and it is the
  rule that would have caught item 1 a day earlier. The 2026-08-21 session
  confirmed its `DONE`s applied and never checked whether a single CLOCK line
  did — on the mechanism this project exists for.
- **Clock in at the drift, not at the ask.** Necessary but *not sufficient*:
  it was followed twelve times on 2026-08-21 and the record still came out
  wrong. Do it anyway; just don't mistake it for the fix.
- **Read structure through org, not through text.** An `awk` parent-inference
  returned each heading's *own* title instead of its parent and put a wrong
  structural claim into conversation. `org_outline` answers parentage,
  keywords, titles and tags in one call.
- **Grep before coining a name.** `:ORIGINAL:` was invented for a concept the
  project already had a word for; `:PLAN:` was free and obvious in hindsight.
- **Run a proposed mechanism before recommending it.** Held up well — the
  archive path was read *and* executed before anything was built on it, which
  is how `CLOSED`-based filing was found.
- **Never pass `--no-verify`.**
- **A `:BLOCKER:` written in the same session that captured its target is
  inert** until a human applies the queue.
