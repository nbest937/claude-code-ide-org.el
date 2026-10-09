---
description: Plan the NEXT slice -- brainstorm each member without a plan, then write the slice's own :PLAN: -- and stop before any work starts.
---

# Plan the slice

**This file names no slice.** It finds the slice to plan, brings every
member it reaches to a written design, and writes the slice's own plan.
It does no implementation: working the slice is `/work-slice`, in a
**fresh session** of its own, because each deserves an empty context
(the plugin's own tracker, :ID: dc21f724).

**This project's own rules come from `.claude/slice-rules.md`**, if it
exists. Read it now; most of it governs working rather than planning,
but it may name what a plan here must cover.

## Which slice

The `NEXT` slice, or the one the user names. Find it after the queue is
applied, so keywords are current:

```
org_query "todo:NEXT property:KIND,slice"
```

**No `NEXT` slice, or more than one: stop and ask.** Do not choose by
reading titles.

## Preliminaries

1. **The queue applied first.** Applying is the user's, never yours; ask
   for it if `org_pending_updates` shows work waiting. Until it is
   applied, keywords and checkboxes show the old state.
2. **Confirm `emacs-tools` is reachable** with that same
   `org_pending_updates` call.
3. **Clock where the work is.** While a member is brainstormed, the clock
   is on that member -- planning a `TODO` heading clocks in on it and
   changes no keyword. Composing the slice's own drawer clocks in on
   "Review and planning", because a slice is never clocked. Where time
   tracking is off, the clock tools do nothing.

## The pass, member by member

`org_outline` on the slice gives its members in order. For each:

- **Skip** a member that is finished, dropped, or `MAYBE`.
- **Skip** a member whose `:PLAN:` already holds a design with no open
  question. Read it to judge; a drawer that only gathers evidence for a
  later brainstorm is not a design.
- **Brainstorm** every other member with the brainstorming skill, its
  gates included: classify it, settle it with the user one question at a
  time, record the approved design in the member's own `:PLAN:`, and
  never implement. A member whose design turns out too large divides as
  that skill describes.
- **Raise** a `WAITING` member as the question it waits on, rather than
  planning around it.

## The slice's own plan

Write or revise the slice's `:PLAN:`: the order, with one line per member
saying why it falls there. It holds the order and its reasons, nothing a
member's drawer should hold, and **where it and a member's drawer
disagree, the member wins** (the org conventions, "A slice's plan, and
its members'").

## End state

- The slice **stays `NEXT`**. Planning is `TODO`-phase work; `DOING`
  begins with implementation, in `/work-slice`.
- No branch, no code.
- A short readiness report: which members are planned, which questions
  remain open, and anything that should be decided before work starts.
- A pointer to `/work-slice` in a fresh session.

**Resumable by construction.** A long slice will not plan in one sitting.
Planned members are skipped, so running this again in a new session
picks up where the last one stopped, with no record of progress to keep.
