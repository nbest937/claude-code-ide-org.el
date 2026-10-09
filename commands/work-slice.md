---
description: Work the slice in hand -- the DOING slice not yet integrated, else the NEXT slice -- from its :PLAN: drawer, member by member.
---

# Work the slice

**This file names no slice, and it is not rewritten between slices.** The
plan lives in the slice's own `:PLAN:` drawer; this file says how to find
that slice and what every session does first. Start it in a **fresh
session**: planning a slice is `/plan-slice`'s job, in a session of its
own, and each deserves an empty context (TODO.org :ID: dc21f724).

**This project's own rules come from `.claude/slice-rules.md`**, if it
exists. Read it now, before anything below. It holds what is this
project's practice rather than the tracker's machinery: how work is
branched, reviewed and merged, which testbed skill to load, and the lore
its slices earned. Where it and this file disagree on a point of
practice, it wins; where it would break the machinery below, say so and
ask. With no such file, there is nothing to add.

## Which slice

Find the open slices, *after* Step 0's first item (the queue applied), so
keywords are current:

```
org_query "property:KIND,slice !todo:DONE !todo:CANCELLED"
```

1. A `DOING` slice whose integration is **not yet open** is the one in
   hand. Continue it. How integration is checked -- an open pull request,
   say -- is the project file's business; without one, ask.
2. Otherwise, the `NEXT` slice. There is at most one, because a category
   holds at most one top-level `NEXT`.
3. **Neither, or more than one: stop and ask.** Do not choose by reading
   titles.

## The plan

`org_body` on that slice with `drawer=PLAN`. Read the `org_outline` of the
slice for its checklist, since **the slice is the list** and the drawer is
the plan, not the membership.

- **Where the drawer and a member's own heading disagree, the heading
  wins.** Plans get premises wrong from the slice's altitude.
- **At each step, read that member's own `:PLAN:` before starting.** The
  slice's drawer gives the order; the member's drawer gives the design,
  with every decision already made written into it. An open question
  found there that is not decided goes to the user *before* the step,
  never partway through it.
- **No slice drawer, one too thin to act on, or members it reaches with
  no plan: stop, and point the user at `/plan-slice`** in a fresh
  session. Do not compose a plan silently from titles.

---

## Step 0 -- preliminaries

> **Nothing below is specific to a slice or to a project.** These are the
> steps the tracker's machinery needs. Amend this section and *Standing
> rules* only when a session earns a new entry, and only by addition; a
> project's own steps go in `.claude/slice-rules.md`.

1. **Apply the queue before composing anything.** Until it is applied,
   `TODO.org` shows the old keyword on headings whose work shipped, and a
   slice's checkboxes disagree with their referents. **That disagreement is
   staleness, not a defect — do not fix it by hand.** `org_pending_updates`
   says what is waiting; it is also step 2.
2. **Confirm `emacs-tools` is reachable** by calling `org_pending_updates`.
   Read-only, and a reply proves the server is up in a way that seeing the
   tools listed does not.
3. **Clock in before the first thing that writes**, naming the heading, or
   "Review and planning" for cross-cutting meta-work. The drift from question
   to tracked work is invisible from inside the session doing it. Where
   time tracking is off, the clock tools do nothing; name the heading
   anyway, since the work still has to belong to one.
4. **Queue the slice itself → `DOING` the moment its work starts.** The
   member-level rule ("set `DOING` before starting a task") got applied
   to every member of `ff7ccb2d` while the slice sat at `NEXT` for four
   days of its own execution — on a grouping, `DOING` means "at least
   one member is in the mail", which was true from this file's first
   step. It opens no clock (grouping exemption) and costs one queued
   event; without it the slice's LOGBOOK shows a `NEXT`→`DONE` teleport
   and every report that keys on `DOING` is blind to the work in flight
   (the `4133772c` defect, one tier up).

Then the project file's own Step 0 items, if any.

## Per member

Set the member `DOING` with `org_set_todo` before starting it, read its
`:PLAN:`, and work it. At its end, the two-call close the org conventions
describe -- the resolution onto the body, then `drawer=DEBRIEF` -- and
inside a grouping, the nomination of the next action. Those are the
conventions' rules ("Closing a member nominates the next", "The
`:DEBRIEF:` drawer"); follow them there rather than from memory.

## Integration and close

A slice carrying code closes when its integration point lands, not when
its last member goes terminal; it sits in `REVIEW` between the two (the
org conventions, "Closing a slice"). **How** it integrates -- a branch,
a pull request, a review, a merge -- is the project file's business.

---

## Standing rules, with what actually happened

> **Add to this list; never refresh it.** The dates are not staleness --
> they are the evidence that turns a platitude into a rule. A rule whose
> incident is forgotten is a rule nobody follows. Rules about one
> project's code, tests or workflow go in its `.claude/slice-rules.md`.

- **Never type a UUID from memory.** Write the 8-character prefix and let the
  tool expand it; where a full id is unavoidable, `grep` the `:ID:` line. On
  2026-09-04 a slice's twenty member lines were *generated from `TODO.org`*
  and the result diffed against what landed — one full id was not what recall
  offered. Generate, then diff; do not proofread. Two other full ids were
  typed from memory the same day and both were refused by the tool, which is
  the guard working and not a reason to lean on it.
- **Prefer the heading over the slice.** The 2026-09-18 plan for `8bbae3aa`
  got three premises wrong and one member mis-sequenced, and *all four came
  from the plan while none came from the headings*: each wrong claim was
  written while looking at the slice, and each heading that contradicted it
  was written while looking at the thing. Since 2026-09-19 the plan is
  composed from the members' `:PLAN:` drawers for exactly this reason; where
  a step and a drawer disagree, the drawer wins.
- **A full drawer masks an empty body.** On 2026-09-19 eight headings lost
  their captured bodies to a silently dropped argument and looked composed
  for five hours, because each had a `:PLAN:` drawer written by a later
  call. When a tool reports success and the location, check the primary
  artifact for the *content* — the reply says where it wrote, never what.
