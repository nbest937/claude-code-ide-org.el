# State transition rules

> Ships with the **claude-code-ide-org** plugin. `claude-org-setup` promotes
> this file into a consuming repo's `.claude/rules/` so it is always
> loaded there; until that runs it is on-demand reading, like any skill
> reference. The consuming project's own rules take priority over it.

**A state change has no side effect of its own.** `org_set_todo` queues
an event and edits nothing; a human applies it later. These are the
transitions this project uses:

| Transition                |
|---------------------------|
| `TODO`     → `NEXT`       |
| `TODO`     → `DOING`      |
| `NEXT`     → `DOING`      |
| `DOING`    → `DONE`       |
| `DOING`    → `WAITING`    |
| `DOING`    → `REVIEW`     |
| `DOING`    → `CANCELLED`  |
| `WAITING`  → `DOING`      |
| `REVIEW`   → `DOING`      |
| `REVIEW`   → `DONE`       |
| Any        → `MAYBE`      |

**Where time tracking is on, several of these rows also open or close a
clock.** That column and its rules are in `org-time-tracking.md`, which
`claude-org-setup` promotes only where it was told the feature is on — if
that file is not loaded, none of it applies, and `org_clock_in` /
`org_clock_out` queue events nothing consumes.

## What the keywords mean

**`DOING` means started and owed a return — not executing right now.**
*In the mail*: we have begun and need to circle back. It is durable and
**plural**; several headings may be `DOING` at once, because the keyword
records what is *owed*, never what is executing. GTD's one-thing-at-a-time
is deliberately not followed: it is calibrated to human working memory,
and keeping several started items visible is what stops an agent silently
dropping them. So a keyword may also be set *retroactively* — recording
that something was started earlier is an ordinary queued transition
(`:ID:` 4f6a6bb1).

- **A heading that was worked and set down stays `DOING`.** Demoting it
  to `NEXT` or `TODO` loses the fact that it is owed.
- **A leaf held for *the user's* judgement is `WAITING`, not `DOING`** —
  nothing is owed by us.

**`REVIEW` is experimental** (`:ID:` c954f650): finished work handed back
for human judgement. It behaves exactly like `WAITING`. **`REVIEW` →
`DONE` is the expected exit; `REVIEW` → `DOING` is rework**, because the
review found something missing or broken. Setting it asserts the work is
finished and only judgement remains — a heading parked there to mean "not
sure yet" is `WAITING`, or still `DOING`.

**On a grouping — a story or a slice — the words read one level up.**
`DOING` means at least one member is in the mail. `REVIEW` means every
member is terminal and the work has not yet integrated: for a slice
carrying code, the window between the final commit and the pull request
merging. The window needs a name because review findings arrive *after*
every member is terminal, by construction — `:ID:` c19fbbf5 closed on
"all members done" and its review's findings had nowhere to go. The
close condition is in the org conventions, "Closing a slice".

**Do not clock a grouping on purpose.** The groupings that carry CLOCK
lines were clocked honestly as leaves and became groupings later; they
are history, not debt. `claude-code-ide-org--grouping-heading-p` is the
union of the two ways to be one — a container is *emergent* (it acquired
keyworded children), a slice is *declared* (`:KIND: slice`, `:ID:`
95c27fca).

## Using the tools

**Rule**: always use the MCP tools for state changes and clocking — never
hand-edit CLOCK entries or TODO keywords. If the `emacs-tools` MCP server
is *not* connected, stop and say so. The `emacsclient` fallback is blocked
by a hook: a direct `org-todo` applies immediately and writes **nothing**
to the queue, so the review pass and `org_pending_updates` never see it.
It also hangs: `org-add-log-note` pops `*Org Note*` before checking
whether a note is wanted, so *any* keyword with a logging cookie in
`#+TODO:` breaks a non-interactive transition (`:ID:` 3d576d29) — here,
all eight. That is a fact about this `#+TODO:` line, not about org; a
consuming repo's cookies are its own. It is why state changes are queued:
apply runs inside a genuinely interactive command, where the deferred
note can complete.

**Rule**: confirm the server is reachable *before* the first state or
clock call of a session, by calling `org_pending_updates` — read-only, and
a reply proves the server is up in a way a tool list does not. The
failure is silent, which is why this is a standing rule.

**Rule**: before a session's first act that changes anything — a repo
edit, a capture, an amend, any immediate org tool — know which heading
the work belongs to, and capture one first (with an `initial_state`) if
none exists. Where time tracking is on this also requires an
`org_clock_in` naming it (`org-time-tracking.md`). A purely read-only
session owes nothing.

**Rule**: when asked to start work on a task tracked as a heading with an
`:ID:`, transition it to `DOING` via `org_set_todo` *before* beginning,
unless it already is. This is a standing instruction rather than a hook
because "this conversation is now doing that task" is a judgement about
intent. Hooks enforce only the mechanics once a transition is triggered:
on `org-blocker-hook`, `org-depend-block-todo` (refuses `DONE` while a
`:BLOCKER:` names unfinished work) and
`claude-code-ide-org--blocker-clock-running-p`; on `org-trigger-hook`,
`--trigger-demote-conflicting-next` inside a container, plus
`--trigger-auto-clock-in` where time tracking is on.

`PLANNING` was retired 2026-08-28 (`:ID:` c954f650) and nothing replaced
it, deliberately (`:ID:` 7771fc63): a heading is `DOING` while it is being
planned and implemented, so Plan Mode needs no state change of its own.

## `NEXT` and nomination

**`NEXT` belongs to a container's *members*, and nothing sets it by
itself** (`:ID:` 62b65ad0). It is meaningful *within* a story, and **a
story must never carry it** — promoting one declares a project to be an
action (`:ID:` 42808717).

**A slice is the exception** (`:ID:` abce1850). A story is *emergent*; its
next action is one of its children. A slice is *declared and sequenced*,
and several are open at once with nothing else saying which to pick up.
So **a slice may carry `NEXT`, meaning "this is the slice to pick up
next"** — a portfolio-level nomination, not an action:

- **At most one top-level `NEXT` per `:CATEGORY:`, slices included**
  (`:ID:` 758a8b78). A story's *internal* `NEXT` is exempt — it memoizes
  where to start on entering the story — and a slice's *members* may show
  several, since they are references reflecting other groups'
  nominations.
- **It does not substitute for a member's `NEXT`.** A slice marked `NEXT`
  whose members are all `TODO` is still un-nominated.
- **Nothing sets it automatically.** An auto-promotion trigger stood here
  and is gone: three of roughly eight top-level promotions ended up parked
  as `MAYBE`, and at top level its "sibling group" was a whole category.
  Do not rebuild it. `--trigger-demote-conflicting-next` survives inside a
  container, and `--nomination-candidates-context` reports every grouping
  with no `NEXT` at `SessionStart` — it *asks* rather than acting.

**Rule**: every transition *to* `DONE` **inside a grouping** nominates
the next action — set `NEXT` on whichever remaining member should be
picked up next, or say in a sentence that no clear candidate exists.
Closing a *top-level* task nominates nothing. A live project always has a
next action; one without is the defect a weekly review exists to catch.

**Rule, same moment**: any work the closing debrief names as *not done*
becomes a filed heading before the `DONE` is queued — or the debrief says
explicitly that it is not worth filing. **A sentence pointing at another
heading is not a filing action**, and neither is "belongs to X": `:ID:`
aa1ba915 was closed with its gap described as belonging to `:ID:`
edd47f32, which was never told, while `:ID:` e1284bdb was closed the same
day *after* its unfinished half was split out as `:ID:` 601c885c. Prose
is not enough for a structural reason: residue named in a closed body
sits in a document readers treat as history, on its way into a drawer
they are told to skip.

**Rule**: when nominating, call out blockers that live in a *different*
subtree — name the heading and where it is; a `:BLOCKER:` property is the
machine-checkable form. A `:BLOCKER:` naming a heading captured
*keywordless* in the same session is inert until the queue is applied,
since `org-depend` blocks only on an unfinished keyword; pass
`initial_state` to `org_capture` and it bites at once (`:ID:` c74f8663).

## Creating headings

**Rule**: any time a new task is described in conversation, create an org
heading for it (with an `:ID:`) and set its initial TODO state, rather
than tracking it in conversation memory. What counts as "a task" is a
judgement, so this is a standing instruction.

Every new heading carries `:CREATED:` beside its `:ID:`. The MCP creation
paths stamp both and `bin/lint-org` checks it, so only a hand-written
heading can miss it (`:ID:` d5345abb).

**Rule**: when a new heading is created as the direct result of an
approved Plan Mode plan, write only that heading — title, tags,
properties, intro body — and stop: show it and get explicit approval
before transitioning it to `DOING` or touching anything else the plan
describes. Approving a plan is not approval of the heading's wording. The
general form — `ExitPlanMode` approval and "start implementing" are two
checkpoints — is in the org skill, "Plan Mode checkpoint".
