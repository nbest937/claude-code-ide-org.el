# Next session

Rewritten 2026-08-24, replacing the slice of 2026-08-21/22 — which is
finished. Every item on it shipped except `82df2a6c`, which was never
started.

Read the heading bodies before starting any item. Each carries measurements
this prompt only summarises.

**Before anything else:** confirm `emacs-tools` is reachable by calling
`org_pending_updates`. Items may have moved if a review pass ran since this
was written.

**Decision markers, continued from the last slice.** Every item says whether
it holds an unresolved decision and whose it is. *Nothing here is blocked on
one.* Two items carried a user decision when this was first drafted and both
were made the same afternoon — the repeater cap and the `CLOSED:` archaeology
— which is the marker doing its job rather than the format finding nothing.
What remains is one deliberately-open sub-question (item 4's datetree) and
one item whose entire purpose is to produce evidence a decision would need
(item 6).

---

## What is already true, so it is not re-derived

- **Explicit clock brackets are authoritative.** `eaeeb4ee` shipped: a
  main-lane `clock_in`/`clock_out` pair produces a review item, subdivided
  into runs, with permission blocks excised. A sub-minute run is rounded up
  to a minute rather than dropped (`31c6ac39`).
- **The meta-work day node resolves on demand** (`9575e65b`), dated from the
  event rather than from today, and `Review and planning` is offered first
  when assigning a span.
- **The `:PLAN:` lifecycle is adopted** (`8bcd56f4`): `org_wrap_plan` exists,
  the conventions are written down, and `bin/lint-org` asserts it for
  headings closed on or after 2026-08-24.
- **The archive backlog is swept**: 34 of 43 closed headings carry a `:PLAN:`
  drawer. The nine that do not are correct — their bodies are entirely
  debrief.
- **Both org files are normalised**: 58 backfilled `CLOSED:` markers, every
  heading separated by two blank lines, `#+STARTUP:` lines identical.
- **The suite is 369 tests, plus `bin/footnote-check-test`.** Lint: 0 errors.
- **A repeater's body is capped** (`ff92700e`, decided and shipped): nothing
  else ever prunes one, since every pruning event in the `:PLAN:` lifecycle
  is tied to reaching `DONE`. Fires on nothing today; would have caught
  `cbe282ec` at 47 lines.
- **The promotion trigger no longer re-enters itself** (`7148cddc`). One
  apply made 1201 mutations across 114 headings before the guard existed;
  the file was restored from `HEAD` and the queue rolled back by hand.
- **Apply failures now name their item and keep a backtrace.** Five
  identical "Before first headline" messages cost an afternoon and three
  withdrawn hypotheses.
- **`e` honours the bracket style you type**: `<...>` records an interval
  as *your* attention, `[...]` stays agent activity. Inactive is still the
  default.
- **`b7b46a26` is cancelled.** Nothing mechanical consumes `CLOSED:` on the
  39 headings that lack one, and nothing ever will — the `:PLAN:` lint
  exempts them permanently by design. Don't re-derive this.

---

## 1. `edd47f32` — make the daily ceremony cheap enough to run

**Decision: none outstanding.** The sequence is settled and written down in
`.claude/rules/org-conventions.md`: apply, consolidate, re-separate, archive.

**First, because everything else this slice does makes more of the mess it
cleans up.** The ceremony has four steps, two have a tool, and nothing
composes them. Measured: 13 of 25 drawers archived since consolidate-on-apply
shipped are still out of order, and the separation normaliser had to be
re-run three times in one session — once after every apply.

Three children, and the order matters: `7ae6562d` (the consolidation sweep,
not built) is the missing tool; `e1284bdb` (separation) is built and only
needs wiring into the same command; `aa1ba915` (the prompt) is what makes
any of it happen without being remembered.

`aa1ba915` carries a measured constraint worth reading before designing
around it: neither available scheduler can do this. `CronCreate` is
session-only and expires in seven days; the `schedule` skill runs cloud
agents with no route to a local Emacs. The `SessionStart` hook is the
mechanism, and it already does the shape — fires at first opportunity,
self-limits to once a day, asks rather than proposes.

**Not a child, deliberately:** `cbe282ec`, the ritual itself. It carries a
repeater and `bin/lint-org` refuses a repeater under a completable ancestor.

## 2. `3063c3e5` — the revision half of body editing

**Decision: none outstanding.**

The wrapping half shipped as `org_wrap_plan`. The heading's actual title —
`org_amend` can only append — is untouched, and it is what *continuous
paring* needs. Every correction still lands furthest from the reader.

Now cheaper to judge than before: the sweep exercised wrapping across 34
real headings, so the shape of a body-editing operation that must not
corrupt is well understood. Two corruptions are on record, both range bugs,
and `org_wrap_plan`'s guards (`outline-next-heading` for boundaries, a bare
`:END:` refusal, a text-preservation check in the reply) are the pattern to
reuse rather than reinvent.

## 3. `f421c5c3` — the `:PLAN:` lint over-demands

**Decision: none outstanding.** Small, and it protects a rule that is
currently silent.

A debrief-only heading has no prospective half to wrap, and six exist. Only
a ten-prose-line threshold keeps the lint from demanding a drawer for one of
them — and satisfying that warning would mean wrapping a debrief into a
drawer readers are told to skip, which is the inversion the lifecycle exists
to prevent, arrived at by obeying the lint.

The signal already exists: `--plan-seam`'s "first body line" condition *is*
the test for "no prospective half".

## 4. `961f15b6` — clock the human's review attention

**Decision: none outstanding on the mechanism.** Both open questions were
settled 2026-08-24: the clock starts on `claude-code-ide-org-review` itself
rather than on a spoken cue, ends on the user's word, and treats *burying*
the buffer as the backstop.

The review pass is the one activity this project never measures and the one
it most depends on — nothing reaches an org file without it.

**Three things are already reasoned out on the heading; do not re-derive
them.** It is not an exception to the union convention — human attention and
agent activity are different quantities that were never meant to be added.
It does not go through the queue: a human inside an interactive command has
none of the constraints the queue exists for, so it writes a native
`org-clock-in` with an *active* timestamp, which is exactly what
`--review-format-annotation` reserves for human-logged intervals.

**And `q` does not kill the buffer** — it is `special-mode`'s `quit-window`,
which buries. A naive `kill-buffer-hook` would clock all night. Verified
live; the fix is to treat burying as the end.

**Left open on purpose:** whether it gets its own datetree. Decide that
against a report someone actually wants, not in advance.

## 5. `2758f3a0` — confirm the footnote hook actually fires

**Decision: none outstanding.** It is in `REVIEW` for a reason no work can
remove: hook configuration is read once at session start, so the session that
wrote it could not test it.

If the first response of the next session citing an `:ID:` carries its
footnote, it works. If a turn hangs or loops, the sentinel guard is wrong and
the hook should come out of `.claude/settings.json` immediately — the docs
describe no `stop_hook_active` flag, which is why the guard exists.

## 6. `82df2a6c` — look through Org's own lenses

**Decision: none yet, and that is the point** — this produces the evidence a
decision would need. The only item carried over unstarted from the last
slice, and still the right one to do last: agenda views, sparse trees and
column view all run against the current structure, so evaluate them on the
corpus as it stands.

The corpus is now materially better suited to it than it was: `CLOSED:` is
populated, drawers are consistent, the datetree exists with a real day node.
Related: `29439196`, `8ca6541d`, `9651d4c8`.

## 7. `21c91613` — an apply cannot be rolled back

**Decision: yours, between three recorded options**, the cheapest of which
is nearly free.

Apply writes the org file and marks its events consumed as two independent
operations. Restore the file from git and the queue still believes the work
is done, so the events are never offered again. Found the hard way on
2026-08-24, when the recovery had to reconstruct the consumed set from a
`org_pending_updates` report captured minutes earlier — and where the
obvious heuristic would have rolled back 85 events instead of 54, because a
third apply had already landed and been committed.

Recording the *apply time* beside each consumed event is the option that
would have made that recovery one command.

**Cut line:** stop after item 4. Items 1–4 are all builds with settled
designs and leave the tooling coherent; 5 needs only a new session to observe
itself, and 6 is evaluation that keeps. **If the session is short, do 1
only** — it is the one that stops the record degrading between passes.

---

## Deliberately off the critical path

- `6cc71c36` — **the pattern behind the afternoon**: six defects, every one
  a place where the code computed the right answer and narrowed it on the
  way out. Proposes a review-buffer-wide audit of readouts, which is a
  dozen call sites rather than a redesign. Off the critical path only
  because nothing is currently broken by it.
- `b6e229c7` — auto-marking. Measure the staleness rate first; after two
  partial applies every state item was stale, so the check may be doing
  most of the work the proposal would automate.
- `c31b6c76` — a test that fails for the last hour of every day. Real,
  bounded, and green whenever anyone actually looks.
- `2d100d0d` — cross-item overlap. Much cheaper since `eaeeb4ee`: a span
  partitioned by its own brackets cannot overlap them.
- `5a6d2c75` — span evidence. Now serves only the residue it was written for.
- `7fbab3b3` — the backlog's wrapping phase is complete. What remains is the
  archive step itself, which belongs to item 1's ceremony.

---

## Standing rules, with what actually happened

- **Never `git stash` to compare before and after.** On a clean tree `stash`
  saves nothing and the paired `pop` takes an *older* stash. This swept a
  freshly applied review pass out of the working tree and into a stash on
  2026-08-24; it was recovered by luck. Copy the file aside instead.
- **Verify an ID before writing it.** Two invented UUIDs reached files this
  session — one placeholder link and one typed from memory — and both were
  caught by lint rather than by care.
- **A rule that has never been seen to fail proves nothing.** The `:PLAN:`
  lint reports nothing on the real files by design, so its positive case is a
  fixture. Same for the wrap guards: reintroducing the exact recorded bug
  fails exactly the tests written for it.
- **Measure the blast radius before writing a lint rule.** Unscoped, the
  `:PLAN:` rule fired on 124 headings; scoped by `CLOSED:` date it fires on
  zero and grows with new work.
- **Read structure through org, not through text.** A `:END:` inside a
  `#+BEGIN_EXAMPLE` block terminates a drawer — blocks do not protect their
  contents — which corrupted one heading before the guard existed.
- **Never pass `--no-verify`.**
