---
description: The sequenced slice of work queued for the next session, with its blockers and rationale
---

# Next session

Written 2026-08-21. Sequenced by hard blockers first, then by how fast the
defect is currently costing something. Read the heading bodies before
starting any item — each one carries measurements this prompt only
summarises.

**Before anything else:** confirm `emacs-tools` is reachable by calling
`org_pending_updates`, and note that some items below may already have
moved if a review pass ran since this was written.

---

## 1. Fix both `--trigger-auto-promote-sole-todo` guards together

`c8a6c5d2` and `42808717`. **Do these first**, not because anything blocks
on them but because they are corrupting the record *now*: every batch apply
mis-marks a `NEXT`, and every review pass adds another.

They are two guards on one function, so fixing them apart means writing the
same test scaffolding twice:

- `42808717` — it promotes a **container**, declaring a project to be an
  action. `claude-code-ide-org--container-heading-p` is the guard and is
  already used by `--trigger-auto-clock-in`.
- `c8a6c5d2` — it fires on **apply order**. The review pass lands one event
  at a time, so the first child's keyword makes it momentarily the sole TODO
  of a group and the trigger fires. The resulting `NEXT` records which
  capture was first in the queue, nothing more. Observed live on
  `a1d63f52`'s children.

`62c6b1be` shipped the identical container guard for
`--review-suggest-heading` on 2026-08-21 — read it first. The mutation-test
pattern there is the one to copy, including the assertion that a **leaf is
still promoted**, which is what catches an over-applied guard.

`c8a6c5d2` records three candidate fixes for the apply-order half and picks
none. The cheapest is likely *decline to promote when the group contains
keywordless siblings*, since that is precisely the signature of a
half-applied batch — but that is a judgement to make with the code open.

## 2. `e30d52d7` — exempt datetree scaffolding from `bin/lint-org`

Currently `NEXT`, and it **blocks `cd1e974e`** via a real `:BLOCKER:`. Small
and self-contained.

Its own instruction is to land *before* the tree exists: once several
hundred warnings are present the temptation becomes silencing the check
rather than exempting the class. Exempt **year and month nodes only** — the
day node carries `:ID:`/`:CREATED:` and should stay linted like any tracked
heading. Check whether the existing top-level-category exemption already has
a predicate to extend rather than adding a branch.

## 3. `a279216c` — collapse the whole-span gap line

Cheap, and it improves every review pass until it lands. When a gap covers
the entire span it reprints the two timestamps already in the item header.

Keep the empty case visible — that is `5ff5a4b8`'s deliberate design and
undoing it restores a worse defect. Change only the degenerate form. **Do
not** raise `claude-code-ide-org-span-evidence-gap` to suppress it; that
would hide the empty case silently and for short spans only.

---

## Stop here. What follows is the session after.

The datetree chain runs in strict dependency order and does not fit
alongside the above:

`e30d52d7` → `cd1e974e` (institute the category) → `9575e65b` (the
resolver, which needs `:DATE_TREE:` to exist) → `6ae83993` (default task,
which consumes the resolver).

**Resolve one scope question before building any of it:** `25ec37b0` may be
half dead. Its *addressable day node* half is essential and belongs to
`9575e65b`. Its *teach `org_capture` to target a datetree* half exists to
support capturing entries **under** a day node — which the 2026-08-21
decision ruled out, since the day node is the thing clocked against. Decide
whether that half survives before implementing it.

---

## Standing rules that were violated on 2026-08-21

- **Clock in before starting, not after.** A session that opens as a
  question drifts into tracked work without ever feeling like "starting a
  task." 24 minutes landed on the wrong heading that way. Call
  `org_set_todo` DOING + `org_clock_in` at the first substantive action on a
  heading, even mid-turn.
- **Run a proposed mechanism before recommending it.** A heading body's
  design claims are the perishable half. `9202b39d`'s depth counter was
  relayed as fact and falsified on measurement — it loses 9.18 h and
  latches. Its *measurement* reproduced exactly.
- **Never pass `--no-verify`.** The pre-commit hook caught a silent no-op
  `:BLOCKER:` on 2026-08-21 and was right to.
- **A `:BLOCKER:` written in the same session that captured its target is
  inert** until a human applies the queue, because `org-depend` blocks only
  on an unfinished TODO keyword.
