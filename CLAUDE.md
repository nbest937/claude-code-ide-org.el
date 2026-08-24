# claude-code-ide-org

Doom Emacs module exposing org-mode operations to Claude Code as MCP tools,
plus org-mode skills for Claude Code sessions.

The goal is natural-language manipulation of `.org` files from within Emacs,
via `claude-code-ide`, without needing to internalise Emacs chord sequences.

A second, co-equal goal — never spelled out until now, though a large share
of this project's actual work has gone toward it — is trustworthy tracking
of where attention/time actually went on tracked tasks. What "trustworthy"
requires in practice (interval granularity, how much manual confirmation is
acceptable, what reports actually need to come out the other end) is
deliberately left open here, not pinned to whatever CLOCK-drawer mechanics
happen to exist at a given point: it should be driven by concrete reporting
needs, most of which haven't been fully articulated yet. See "Direction"
below for the current best guess at how these two goals combine.

---

## Architecture: the event queue

**State and clock changes are queued, not applied.** This is the single
most important thing to know before calling any tool below, because the
tool names suggest otherwise. `org_set_todo` changes no TODO keyword.
`org_clock_in` opens no clock. `org_clock_out` closes none. Each appends
an event to a per-session file and returns; a human later reviews the
accumulated events and applies the approved ones.

A read that still shows the old keyword after you called `org_set_todo`
is therefore **expected, not a failure**. Use `org_pending_updates` to
see what is queued but not yet applied — that is how you tell "waiting
for a human" apart from "the call didn't work."

**The problem it responds to**: driving live org state (TODO keyword,
clock, `:LOGBOOK:` logging) directly and synchronously from Claude Code
sessions — including concurrent and background ones — produced a
sustained run of desync, ownership, and logging bugs. The pattern traced
to one mismatch: org's clock/logging model assumes one human at one
buffer; this project's actual workload is the opposite.

**The shape**: sessions do not touch the live buffer for state/clock
changes. They append events to a plain, per-session file — durable,
cheap, no Emacs required to write. A human, at a moment of their own
choosing, reviews the accumulated events (`M-x
claude-code-ide-org-review`) and applies the approved ones through org's
own native `org-todo`/`org-clock-in`/`org-clock-out`, run inside a
genuinely interactive command — so org's native state-change logging
works instead of needing to be suppressed.

**Load-bearing constraint**: apply is *always* human-triggered, never
invoked by Claude programmatically. Not a style preference — org's native
logging only completes correctly inside a real interactive session; a
non-interactive `emacsclient -e` call hits the exact hang this design
exists to route around. Practical consequence: clock/TODO-state accuracy
is only ever as fresh as the last time a human ran the review pass, not
live. That is an accepted, deliberate trade of "Claude does it all in
real time" for "the record, once confirmed, is actually correct" — not an
oversight to fix later.

**What is still immediate**: read-only queries, tagging, capture, refile,
archive, and sort remain as immediate and Emacs-chord-free as the opening
goal promises. Queuing is scoped narrowly to state transitions and clock
start/stop — the two categories that caused every incident.

---

## Reading the tracker

**Start with `org_outline`, not a file read.** It is roughly 40x smaller
than the file and answers most orientation questions on its own. TODO.org is
~118,000 tokens and the median active heading body is 50 lines, so reading
around to find something costs more than the answer is usually worth. Drop
to `org_query` for a predicate ("what's blocked", "everything `:research:`
and not DONE") and to a targeted read only once you have an `:ID:` and a
reason.

**Pass `active_only`, and ignore DONE by reflex.** What a finished heading
records is *history*; the current state of the implementation is in the
code, the tests and the config, which are authoritative in a way a body
written weeks ago is not. TODO.org exists to inform planning, orchestration
and coordination of *future* work — read it for what to do next, not for
what the system currently is.

*One caveat, latent rather than theoretical:* `active_only` also drops live
children of a finished parent (`:ID:` 98908aff). Measured 2026-08-21 — zero
headings are hidden that way today, so the reflex is safe now and will fail
**silently** the first time a parent is closed with unfinished children
under it.

**DONE.org is reference, never orientation.** Do not survey it to start a
session; it will not tell you what to work on. Open it when something live
names an ID in it — a `:BLOCKER:`, a body cross-reference, a docstring, or
this file. That is worth doing: on 2026-08-21 a review-buffer line was about
to be filed as a defect until DONE.org showed it was `:ID:` 5ff5a4b8's
deliberate design, along with the open question it had deferred.

The exception to "the code is authoritative" is *why* a decision went the
way it did, which lives only in a body — which is why the load-bearing ones
(the `.warp/.mcp.json` investigation, the retired guess heuristic) are
quoted directly in this file rather than left to a lookup.

---

## Repository layout

`ls` answers most of this; only the non-obvious parts are written down.
The elisp lives in `modules/tools/claude-code-ide-org/` (`config.el` plus
its ERT suite). `bin/` holds the test suites and `bin/hooks/` every hook
wired in `.claude/settings.json` — what each hook appends is in "Session
tracking" below, not repeated here.

Four things you would not guess:

- **`plans/` is the archive, not the working copy.** Claude Code owns
  `~/.claude/plans` and Plan Mode writes there, so that is the file org
  headings link and a revision edits. A plan is copied here *iff* some
  heading in TODO.org or DONE.org links it, which is what makes an
  unlinked plan history-less. `bin/sync-plans --check` reports drift;
  `.githooks/pre-push` refuses a push while the archive is stale.
- **`.claude/hooks/session-context.sh` is the one hook not under
  `bin/hooks/`**, for no recorded reason. It produces the "what was I last
  doing" context injected at `SessionStart`. Whether the two directories
  should be consolidated is open.
- **`.claude/commands/` is new as of 2026-08-21** and holds prompt files
  Claude Code exposes as slash commands — `next-session.md` is `/next-session`,
  the sequenced slice of work queued for the next session. It is a *plan*, not
  a convention: expect it to be rewritten or deleted once consumed, unlike
  everything else under `.claude/`, which is standing configuration.
- **`bin/check-org-dev-skill`** checks the org-dev skill's own claims still
  hold — run it after editing that skill.
- **`.warp/.mcp.json`** — see below; do not delete it.

**`.warp/.mcp.json` is deliberate, not duplication — do not "clean it
up."** It is currently byte-for-byte identical to the root `.mcp.json`,
and Warp can read the root file directly, so a cleanup pass will reliably
propose deleting it. Both are kept on purpose: the separate file is
evidence this project has actually been verified working under Warp's own
agent, and it is a seam for the two clients to diverge later if the
`claude` CLI and Warp ever need different settings against the same tools
server. The investigation behind it is archived in DONE.org
(`:ID: 6a6d5b4e-0327-4578-a44a-356576870ceb`) — worth reading before
touching either file, because the proxy the files were originally meant to
support turned out to be unnecessary: the real bug was this project's HTTP
server answering `200` where the MCP spec requires `202 Accepted`.

**One-time setup, required for `.githooks/` to do anything:**

```sh
git config core.hooksPath .githooks
```

That setting lives in `.git/config`, which is not version controlled, so a
fresh clone silently has no hooks until it is run. The hooks themselves are
tracked precisely so they are reviewable and shared — putting them in
`.git/hooks/` instead would make them invisible local state, which is the
same problem the `plans/` archive exists to fix. Note that `core.hooksPath`
redirects *every* hook: check `.git/hooks/` holds nothing but `.sample`
files before setting it (it did here, 2026-08-11).

Run the tests with `bin/test`. They exercise the four wrapper functions
against scratch org files in a temp directory — no Doom, no real Emacs
config, no touching real org-id/clock state.

The module is symlinked into `~/.config/doom/modules/tools/claude-code-ide-org/`
and enabled in `~/.config/doom/init.el` under `:tools claude-code-ide-org`.

Both skills live under `.claude/skills/` and are auto-discovered by Claude
Code from there — no separate install step.

---

## Engineering practices

**Rule**: any new feature should be tested to the extent possible and
reasonably feasible before being considered done. Automated where the
feature has a mechanical surface to test against (elisp via `bin/test`/
`config-test.el`, shell scripts via direct invocation); a documented
manual verification pass otherwise. "Reasonably feasible" is doing real
work here — some things (e.g. a skill's *trigger-matching* against its
own description, as opposed to the accuracy of its documented content)
are inherently fuzzy and not worth forcing into a deterministic test;
say so explicitly rather than skipping verification silently.

**Rule**: work does not land directly on `main` — it lands on a
`feature/short-name` branch and merges. What earns a branch is wanting a
separate **integration point**, not a taxonomy: several commits that
should arrive together, work you might abandon, or something you want to
review as a unit. A one-helper fix committed straight onto the branch
you are already on does not need its own.

This is deliberately not "one branch per task." The repo's own history
is the evidence: `feature/capture-amend-queue` earned one because it had
phases and its own plan, and was branched off `feature/event-queue-format`
and merged back into it; `feature/fix-tracked-files-resolution` earned
one despite being a bug fix, which a feature-vs-bugfix reading would have
exempted. The old wording said `feature/short-name-of-task` and so read
as demanding a decision per heading — a decision that has never actually
predicted the practice, and that costs momentum on every heading to
answer.

**Related, since it is the same instinct**: don't reach for a
feature-vs-epic classification either. An epic is simply a heading that
has acquired children carrying TODO keywords — emergent, reversible, and
machine-detectable via `claude-code-ide-org--container-heading-p`. No
heading needs to be classified as one when it is written; see TODO.org
`:ID:` b5f94b88, which says so about itself.

**Rule**: work planned via Claude Code's own Plan Mode gets a single
permanent link in its heading body — `[[file:~/.claude/plans/<slug>.md][Plan]]`
— added as soon as the first round of planning finishes (right after
`ExitPlanMode` is called and the plan file is finalized), not gated on the
heading later transitioning to `DOING`. This matters because approval and
the `DOING` transition don't always happen in the same beat as planning —
e.g. the user may deliberately stop right after a plan is written, before
deciding whether to implement it — and the link should exist the moment a
real plan file does, independent of what happens next. Revisions (re-
entering Plan Mode on the same task) edit that same plan file in place —
Claude Code reuses the existing plan file path for a continuation of the
same task — so the link is written once and never needs updating to point
at a new file. No transcription of the plan into org, ever; the link is the
record.

At `DONE` the link is **relocated into the `:PLAN:` drawer, not deleted** —
it travels with the rest of the prospective body when `org_wrap_plan` wraps
it, because a plan link *is* planning content, and a forward-looking pointer
sitting in a retrospective readout invites a reader to treat the plan as
current. (Reworded 2026-08-24; this said "not removed at `DONE`", which was
a rule against losing the link and got read as a rule against moving it.)
A task with no separate Plan Mode session simply carries no link — that's
expected, not a gap to fill in.

The link is also what makes the plan durable, which is why it is not
gated on anything: `bin/sync-plans` copies only those plans some heading
links, so an *unlinked* plan is never archived and has no history at all.
Verified 2026-08-14 — the sync refused a freshly written plan until its
heading linked it.

**Rule**: where a plan is linked, the heading body is a **journal, not a
design doc** — the plan is the design doc. The body carries what
happened: what shipped, how it was verified, what was measured, what was
falsified, and why a decision went the way it did. It does not restate
design the linked plan already holds.

*Revision is expected, not forbidden* (reversed 2026-08-24; this rule
previously read "Prospective only — bodies written before 2026-08-14 are
not to be trimmed"). A finished heading's body may be split: the
prospective half wrapped into a `:PLAN:` drawer via `org_wrap_plan`, the
debrief left as the body. Relocation is lossless and needs no
permission. *Condensing* the prospective half is wanted where the seam
is confident — a body that contradicts itself pollutes the context of
every later session that consults it for background, which is a cost
paid repeatedly rather than once.

Three things stay untouched. **Open questions**: a body that asks
something nobody answered keeps its question verbatim — do not settle it
now by inference, which is the only thing "relitigating" ever meant.
**The debrief**: what happened, how it was verified, what was falsified.
**Anything whose seam you are unsure of** — wrap it whole and condense
nothing; uncertainty is a reason to relocate rather than to stop.

*Condense in a separate commit from the wrap, never the same one.* A bad
pare inside `:PLAN:` is invisible by design, since readers are told to
skip the drawer — it is the one edit here that no later reader will
catch, which is a sharper hazard than the reversibility question the old
rule turned on. (That question is settled and no longer load-bearing:
body prose in the version-controlled `.org` files is recoverable from
any commit, and only *plans* have bounded history, since
`.githooks/pre-push` merely bounds how stale the archive can be.)

*The backlog is not this rule.* `cbe282ec` chose "sweep old bodies in
unedited" to keep 30 headings cheap, and that stands: **backlog = wrap
unedited; opportunistic = split when you are already reading the heading
anyway.** Letting the backlog pass acquire per-heading judgement is
exactly the cost that decision was made to avoid.

*The evidence for the split, from a single day's drift:* three headings
carried confident design claims that were later found wrong —
`:ID:` d1cf852a asserted "nothing ever unsets it" of a mechanism that
already existed, `:ID:` 4cda6bf7 specified reading a keyword at the clock
marker after the cutover had superseded that path, and `:ID:` 7771fc63
declared a crash scenario unreachable while a hand-edit still reached it.
Not one journal claim needed correcting in the same period. Design is the
perishable half and belongs where it can be revised; the record of what
happened accumulates and belongs here.

*Note this does not empty the body of a planned heading.* `:ID:` b5f94b88
has both a plan and a substantial body, and the body is where the "epic
wearing a child's clothes" reasoning and the plan-file-overwrite incident
live. Neither is design, and neither belongs in a design doc.

**Rule**: before a `DONE` heading is archived, add a concise prose outcome
summary next to that link — what shipped, how it was verified, anything
that differed from the plan. `DONE.org`'s existing `*Verified, not just
implemented:*`/`*Implementation notes:*` style is the model to match.
Applies to delegated-subagent work too: ask for a one-paragraph outcome
summary in the subagent's final report, not per-checkbox status — there
are no checkboxes to report on.

---

## Org-mode conventions

Moved to **`.claude/rules/org-conventions.md`**, which is path-scoped to
`**/*.org` and so loads only when an org file is actually in play: the file
header template, tags, the top-level-headings-are-categories rule, and
`:BLOCKER:` usage.

What stayed in this file did so on one test: **a rule that must hold when no
`.org` file is open cannot live in a path-scoped rule**, because a rule that
doesn't load is a rule that doesn't apply, and the failure is silent. So
"create a heading for any newly described task", the state transitions, and
the queue architecture are all still here.

---

## State transition rules

**"Side effect" below means the call you must make, not something that
happens to the file.** Every entry queues an event; the CLOCK line appears
when a human applies it. The rules are unchanged by that — you still make
exactly these calls, in exactly these places — but nothing in this table
edits an org file at the moment you act.

| Transition                | Side effect                         |
|---------------------------|-------------------------------------|
| `TODO`     → `NEXT`       | None                                |
| `TODO`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `NEXT`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `NEXT`     → `PLANNING`   | Open a CLOCK (call `org_clock_in`)  |
| `PLANNING` → `DOING`      | None — same clock interval continues, no close/reopen |
| `PLANNING` → `DONE`       | Close the CLOCK (call `org_clock_out`) |
| `PLANNING` → `WAITING`       | Close the CLOCK (call `org_clock_out`) |
| `PLANNING` → `CANCELLED`  | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `DONE`       | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `WAITING`       | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `REVIEW`     | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `CANCELLED`  | Close the CLOCK (call `org_clock_out`) |
| `WAITING`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `REVIEW`   → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `REVIEW`   → `DONE`       | None                                |
| Any        → `MAYBE`      | None                                |

`REVIEW` is **experimental** (TODO.org `:ID:` c954f650) — finished work
handed back for human judgement. Clock-wise it behaves exactly like
`WAITING`: entering it closes the clock, leaving it for `DOING` opens one,
and `REVIEW` → `DONE` touches nothing because no clock is running. These
rows were added 2026-08-21; until then the keyword was in live use with
its clock semantics written down nowhere.

**Rule**: any transition *to* `DOING` or `PLANNING` must open a clock, with
one documented exception: `PLANNING` → `DOING` reuses the already-running
clock interval rather than closing and reopening it.
**Rule**: any transition *from* `DOING` or `PLANNING` must close the clock
first, except the `PLANNING` → `DOING` handoff above.
**Rule**: always use the MCP tools for state changes and clocking — do not
edit CLOCK entries or TODO keywords by hand when the tools are available.
If the `emacs-tools` MCP server is *not* connected, prefer stopping and
saying so over reaching for `emacsclient`: a direct `org-todo` call applies
immediately and writes **nothing** to the queue, so the change is invisible
to the review pass and to `org_pending_updates`. That is a real divergence
between the file and the record, not a harmless shortcut.

**Rule**: confirm the `emacs-tools` server is actually reachable *before*
the first state or clock call of a session, rather than discovering it
when a call fails. Check by calling `org_pending_updates` — it is
read-only, and a reply proves the server is up in a way that the tools
merely appearing in a list does not. If it is unreachable, say so before
doing anything that would otherwise have been queued.

This is a standing rule because the failure is silent and the fallback is
tempting: on 2026-08-15 the server did not connect at session start,
nothing announced it, and three state changes went through `emacsclient`
and never reached the queue. Nothing in the transcript looked wrong at the
time. The user should not have to ask for this check.

**And it can hang.** The `#+TODO:` line carries per-keyword logging
cookies: `!` records a timestamp on entry, `@` *prompts for a note*. In
this project `WAITING(w@/!)` and `CANCELLED(c@)` carry `@` and nothing else
does — so a transition driven non-interactively through `emacsclient -e`
blocks on a prompt for **those two keywords and only those two**. That
asymmetry is one of the reasons state changes go through the queue rather
than being applied live: apply runs inside a genuinely interactive command,
where the prompt is answerable.
**Rule**: entering `PLANNING` is a model judgment call made *before* calling
`EnterPlanMode`, never during — Plan Mode itself forbids non-readonly tool
calls, so `org_set_todo` cannot run once inside it. Leaving `PLANNING` is
*not* a model decision: a `PostToolUse` hook matched on `ExitPlanMode`
(`bin/hooks/exitplanmode-promote-planning`) promotes `PLANNING` → `DOING`
automatically the instant a plan is approved and execution begins. A "plan
and implement" prompt must still produce both transitions at their correct,
separate times, never a premature jump to `DOING`. When the user enters
Plan Mode directly (shift-tab, not a model-initiated `EnterPlanMode` call),
there is no window to set `PLANNING` first — the hook's "clocked heading
isn't PLANNING → no-op" branch is the **common** case then, not a bug.
**Known gap, accepted**: the `ExitPlanMode` hook fires whether the plan was
approved or rejected, with no reliable signal to distinguish the two (see
TODO.org :ID: b95b9fba-f78e-48fe-8546-988709cce309). A stray promotion after
a rejected plan is low-cost and self-corrects the next time the heading's
real state is set explicitly — not fixed.
**Cross-session guard**: the `ExitPlanMode` promotion only fires for the
session that set `PLANNING`. It no longer needs a variable to do that.
`claude-code-ide-org--planning-owner-session-id` and
`claude-code-ide-org--clock-owner-session-id` were deleted at the
2026-08-11 cutover (TODO.org `:ID:` feba67eb, reconciled by `:ID:`
e51d6ba1): the promotion moved into
`bin/hooks/exitplanmode-promote-planning`, which reads *the session's own
queue file* for the heading it most recently queued `PLANNING` on. The
guard comes free from the file being per-session — another session's
`PLANNING` is simply not in it to be found — which is why there is
nothing left to track. Note this also means the guard no longer depends
on a clock running, since none does.
**Rule**: when asked to start work on a task tracked as an org heading with
a `:ID:`, transition it to `DOING` via `org_set_todo` *before* beginning,
unless it's already `DOING`. This has to be a standing instruction, not a
hook — deciding "this conversation is now doing that task" is a judgment
call about intent, which only the model can make. Hooks can only enforce
the mechanics of a transition once it's triggered — and that safety net
**is live** (corrected 2026-08-21; this file said "not built yet" long
after it was). On `org-blocker-hook`: `org-depend-block-todo` (refuses
DONE while a `:BLOCKER:` names unfinished work) and
`claude-code-ide-org--blocker-clock-running-p` (refuses DONE while the
heading's own clock is running). On `org-trigger-hook`:
`--trigger-auto-clock-in` (opens the clock the moment DOING/PLANNING is
set by hand — gated by `claude-code-ide-org-auto-clock-in-on-doing`,
default `t`), plus `--trigger-demote-conflicting-next` and
`--trigger-auto-promote-sole-todo`, both live and ungated.

`--trigger-auto-promote-sole-todo` carries two guards, both added
2026-08-21 (TODO.org `:ID:` 42808717 and `:ID:` c8a6c5d2, which this file
listed as open defects until they shipped). It refuses to promote a
*container*, since that would declare a project to be an action; and it
declines entirely while a review pass is mid-batch, because apply lands
one event at a time and the first of several captured children is
transiently the only keyworded sibling of its group. The promotion is not
lost, only deferred — `--review-settle-auto-promote` runs it once after
the batch, against the finished state.

**Rule**: every transition *to* `DONE` nominates the next action — set
`NEXT` on whichever remaining sibling should be picked up next, or say in
a sentence that no clear candidate exists. Leaving the group silently
un-nominated is the thing to avoid. This completes an invariant the
triggers only half-enforce: `--trigger-demote-conflicting-next` gives *at
most* one `NEXT` per sibling group, and `--trigger-auto-promote-sole-todo`
gives *at least* one only in the sole-survivor case. Everything between —
several live candidates needing judgement — is what no trigger can decide,
and it is the common case. GTD's actual invariant is that a live project
always has a next action; a project without one is the canonical defect a
weekly review exists to catch.

**Rule**: when nominating, call out blockers that live in a *different*
subtree. Name the blocking heading and where it is; a `:BLOCKER:` property
is the machine-checkable form. A dependency inside the same sibling group
needs no announcement — anyone reading that group can already see it — but
a cross-subtree one is invisible from either side. Note that a `:BLOCKER:`
naming a heading captured in the same session is **inert** until a human
applies the queue, since `org-depend` blocks only on an unfinished TODO
keyword and a fresh capture is keywordless on disk.
**Rule**: any time a new task is described in conversation, create an org
heading for it (with a `:ID:`) and set its initial TODO state, rather than
only tracking it in conversation memory. Same reasoning as above — this is
a judgment call about what counts as "a task," so it has to be a standing
instruction, not something a hook could infer.
**Rule**: any newly created org heading gets a `:CREATED:` property in its
property drawer, stamped with an inactive timestamp (`[YYYY-MM-DD Dow
HH:MM]`) at creation time, alongside its `:ID:`. Applies to every heading
creation, not just the "new task described in conversation" case above.
**Rule**: when a new org heading is created as the direct result of an
approved Plan Mode plan, write only that heading (title, tags, properties,
any Plan-file link, intro body) and stop — show it and get explicit
approval before transitioning it to `DOING` or touching anything else the
plan describes. Approving a Plan is not approval of the heading's exact
wording. The `ExitPlanMode` auto-promotion hook does not affect this rule:
it only ever promotes an *already-clocked, already-`PLANNING`* heading, and
never touches a newly created heading the plan describes creating. The
more general form of this rule — `ExitPlanMode` approval and "start
implementing" are always two separate checkpoints, not just for newly
created headings — lives in the org skill (`.claude/skills/org/SKILL.md`,
"Plan Mode checkpoint") rather than here, since it's a way-of-working for
Claude Code's Plan Mode generally, not an org-file convention specific to
this repo.

---

## MCP tools (`modules/tools/claude-code-ide-org/config.el`)

Most tools locate a single heading by its `:ID:` property.  Every heading
Claude is expected to act on must have one (`M-x org-id-get-create`).
`org_query` is the exception — it searches across files by query, not by ID.

**Queued (change nothing when called)** — the three that caused every
incident, and the reason the queue exists:

| Tool                | Notes                                  |
|---------------------|-----------------------------------------|
| `org_set_todo`      | Records a keyword change. **Changes no TODO keyword.** Call when entering/leaving any state |
| `org_clock_in`      | Records the start of work. **Opens no clock.** Always call when entering DOING |
| `org_clock_out`     | Records the end of work. **Closes no clock.** Always call when leaving DOING |

**Immediate (act on the file when called)**:

| Tool                | Wraps                    | Notes                                  |
|---------------------|--------------------------|-----------------------------------------|
| `org_clock_report`  | `org-clock-report`       | Clocktable summary; :ID:-scoped or all |
| `org_archive`       | `org-archive-subtree`    | Respects `#+ARCHIVE:` directive        |
| `org_query`         | `org-ql-select`          | Cross-file search; not :ID:-scoped     |
| `org_capture`       | `org-capture`            | Quick-add a new TODO heading           |
| `org_refile`        | `org-refile`             | Move a subtree under a different parent |
| `org_move_sibling`  | `org-move-subtree-up/down` | Move a heading up/down among siblings |
| `org_sort_children` | `org-sort-entries`       | Sort a heading's direct children       |
| `org_log_background_plan` | custom (insert-plan-link) | Write-back for background-planned headings: inserts the Plan link. Still accepts `session_id`, but no longer records it — that went with `:SESSIONS:`; never touches TODO state or the clock |

**Conditional** — writes through Emacs when it can, queues when it can't:

| Tool                | Notes                                  |
|---------------------|-----------------------------------------|
| `org_amend`         | Appends prose to a heading's body. Writes through Emacs when the file is free, and **queues the text for review when the human has unsaved changes in that buffer** — so an interjection never collides and is never lost. Prefer it over the Edit tool for body text on a tracked heading, which writes behind Emacs's back |

**Read-only**:

| Tool                | Notes                                  |
|---------------------|-----------------------------------------|
| `org_outline`       | Compact structural index: level, keyword, title, `:ID:`, tags. Marks `[blocked]` when a `:BLOCKER:` names an unfinished heading. Use before creating a heading, to see what already exists |
| `org_pending_updates` | Summary of queued-but-unapplied updates, grouped by heading. Counts *proposals*, not queue lines. This is how you check a queued call landed |

There is **no MCP tool that applies the queue**, by design. Apply is `M-x
claude-code-ide-org-review`, run by a human. If you find yourself looking
for `org_review_apply`, it is a log-source label in `config.el`, not a
tool.

Text editing (via the org skill) is used for adding or changing tags,
generating new headings, and time reporting. `org_query` now covers
structured cross-file reads (e.g. "what's blocked," "everything :research:
and not DONE") that used to mean Claude reading whole files by hand.

**Read-only buffers:** none of the file-touching tools bind `inhibit-read-only`,
so if the user has toggled a buffer read-only (`C-x C-q`) it fails
outright with a `buffer-read-only` error. The user only does this to
guard against their own stray keystrokes while viewing the file, not to
block Claude — clear it (`(setq buffer-read-only nil)` via
`emacsclient`) and proceed, no need to ask first. **Restore it when the
work is done, and say so** — clearing is permitted, leaving it cleared
is not: each unrestored clear silently switches the user's guard off
until they happen to notice (their request, 2026-08-10; the proper fix —
tools binding `inhibit-read-only` themselves — is TODO.org `:ID:`
c8a97d9d). If they ever want a specific buffer left alone, they'll say
so explicitly; that overrides this default for that instance only.

---

## Session tracking (`.claude/settings.json`, `bin/hooks/`)

Two separate timekeeping mechanisms, deliberately kept apart:

- **`:LOGBOOK:` CLOCK entries** (org's own, native mechanism) track *active
  Claude work time only*. A running clock is paused the moment Claude Code
  stops and is waiting on the user, and resumed the moment the user sends
  the next prompt. A DOING task can therefore accumulate many short CLOCK
  intervals instead of one long one spanning idle waiting time.
- **The `:SESSIONS:` drawer is retired** (2026-08-11, TODO.org
  `:ID: 9d2fcdad-9bf7-47b6-8018-223b13ec4577`). It used to hold the
  bracketing history — a timestamped log of every pause and resume, so
  the full wall-clock arc including the gaps stayed visible. All 49
  existing drawers were deleted and nothing writes one now. The
  per-session event queue holds the same pause/resume stream
  undecimated, survives without a running Emacs, and carries
  `session_id`/`agent_id`/`agent_type`/`source`, none of which the
  drawer recorded. Historical drawers are recoverable from git if that
  judgement turns out to be wrong.

Driven by Claude Code hooks, configured in `.claude/settings.json`. None
of them reaches Emacs any more — each appends a line to the session's
queue file and exits:

| Hook                | Script                        | Appends       |
|---------------------|-------------------------------|---------------|
| `Stop`              | `bin/hooks/session-pause`     | `pause`       |
| `UserPromptSubmit`  | `bin/hooks/session-resume`    | `resume`      |
| `PermissionRequest` | `bin/hooks/block-start`       | `block_start` |
| `PostToolUse` (unscoped) | `bin/hooks/block-end`    | `block_end`, if a block is open |
| `PermissionDenied`  | `bin/hooks/block-end`         | `block_end`, if a block is open |
| `ExitPlanMode`      | `bin/hooks/exitplanmode-promote-planning` | `todo` DOING, if this session queued PLANNING |

`session-pause` and `session-resume` are one line each — `exec
queue-append pause` / `resume`. They are *guideposts*: timestamps marking
when the agent was running, which the review pass clusters into spans.
They no longer call `org-clock-out`/`org-clock-in-last`, so a stopped
Emacs costs nothing.

**Permission blocks** (TODO.org `:ID:` f4e628ce). `Stop` fires when a
*turn* ends, and a turn stalled waiting on a permission prompt has not
ended — so the run of guideposts used to continue straight across the
wait, crediting the human's decision latency as agent work. `block-start`
and `block-end` bracket that wait, and the review pass removes the
bracketed interval so the span splits around it.

The pair is coordinated by a **sentinel**: an empty file at
`~/.claude/org-updates/<session_id>.block-open`, whose existence is the
whole message. `block-end` runs on every tool call in the session, so its
common path must be one `stat` and an exit rather than a queue read.

Two measured facts worth not rediscovering:

- **`PermissionRequest` carries no `tool_use_id`.** `PostToolUse` does.
  So the pair cannot be keyed by tool call, and is not — the sentinel is
  one unkeyed slot per session.
- **Prompts serialise.** Two tool calls dispatched in one parallel block
  still produce the second `PermissionRequest` only after the first is
  approved, so at most one block is open at a time and there is nothing
  to tell apart.

**Known edge case:** if the user's next prompt is about a different task
than the one that got paused, `session-resume` still resumes the wrong
(last-paused) one. This self-corrects the moment Claude actually starts
the new task and calls `org_clock_in` on it — `org-clock-in` always closes
whatever clock is currently running first — so the cost is a short, stray
CLOCK interval on the wrong heading, not lost time or a stuck state.

**Resolved by the retirement above:** `:SESSIONS:` and `:LOGBOOK:` used
to end up in an unstable relative order, since whichever drawer already
existed was appended to in place while a fresh one landed right after the
property drawer. With only `:LOGBOOK:` left there is nothing to order.

### Stale interval recovery

A crash or system shutdown can kill Emacs (or the whole machine) before
the `Stop` hook gets a chance to pause a running interval, leaving a
CLOCK line open indefinitely. Because
`org-clock-persist` is set to `history` (not `t`/`clock`) in the Doom
config, a restart does *not* auto-resume that in-memory clock state — so
detection works by scanning the actual *text* of tracked org files for an
unclosed `CLOCK:` line or an unclosed `Resumed` entry, never by checking
`org-clocking-p`.

Checked via a third hook, `SessionStart` → `bin/hooks/session-start-recovery-check`
→ `claude-code-ide-org-write-session-start-report`. Self-limiting to
"first thing each day": it only reports intervals whose open timestamp
predates today, so once closed (or if nothing was ever left open) it
stays quiet regardless of how many sessions start that day. The report is
injected as `additionalContext`, which Claude is expected to relay to the
user as a question — the hook itself has no way to literally prompt.

**The report asks; it never proposes.** It states the timestamp the
interval opened at — a fact it has — and asks what time work actually
stopped, explicitly instructing the relaying session not to invent one.
`claude-code-ide-org-working-hours` and the educated guess it fed were
retired 2026-08-14 (TODO.org `:ID:` 7771fc63): the premise that absence
is predictable from the clock was measured and failed, with 11 of 19
long gaps beginning *inside* working hours. A wrong guess is worse than
none, because a plausible suggestion is harder to reject than no
suggestion at all.

**Configuration** (`defcustom`s; neither is set in
`~/.config/doom/config.el` today, so both run at their defaults):
- `claude-code-ide-org-session-recovery-enabled` (default `t`) — set nil
  to disable the whole check.
- `claude-code-ide-org-query-files` (default nil, falls back to
  `org-agenda-files`) — which files to scan. Shared with the still-MAYBE
  `org_query` tool in TODO.org for when it's eventually built.

**Recovery**: once the user confirms or corrects a stop time, call
`claude-code-ide-org-close-open-interval` (via `emacsclient`, not an MCP
tool — this is a text-level fix for a stale interval, unrelated to
whatever may currently be clocking) with the heading's `:ID:` and an org
timestamp string. It closes the open CLOCK line, computes the duration,
and saves the buffer. It does not touch the live clock, and it no longer
writes a `:SESSIONS:` entry or triggers a history consolidation — both
were dropped in the 2026-08-11 retirement.

**Won't do** (closed out 2026-08-14 with the guess heuristic itself,
TODO.org `:ID:` 7771fc63): using the system sleep/wake/shutdown log
(`pmset -g log` on macOS) as a more precise guess signal than working
hours. It was recorded as "not yet attempted" while a better guess still
seemed worth having; the decision that the report should not guess at
all removes the thing it was meant to improve. The original objection
stands anyway — the log is dominated by per-app power assertions rather
than clean sleep/wake transitions. Note this is *not* the same as
`:ID:` 1a5a5254, which proposes power assertions as a **review-time
attribution** signal; that one is about assigning a span to a heading,
not about guessing when a stale clock stopped, and is unaffected.

---

## Emacs integration

**A reachable Emacs server is a hard prerequisite, not a convenience** —
every MCP tool in this project goes through `emacsclient`. The Doom config
starts one automatically; if tools fail, check that first.

The rest of the Doom config — the org settings, the clock-out hooks, the
`claude-code-ide` block, vterm's build quirk, and which guards are live on
`org-blocker-hook` — is documented in the **org-dev skill, §7**, which
triggers precisely when you are changing those files. Read the live
`~/.config/doom/config.el` rather than any summary of it; the copy that
used to live here had drifted.

---

## Design notes

- **Why MCP tools over text editing for clock/state/archive?**
  Native org functions handle LOGBOOK formatting, timestamp arithmetic, and
  internal state (the running clock timer) correctly and atomically. Text
  editing risks malformed CLOCK entries or stale timer state.

- **Why text editing for everything else?**
  Tag changes, new headings, and time report summaries don't require
  org-mode's internal state — they're straightforward text operations the
  org skill handles well. Keeping the MCP tool surface small reduces
  per-request token overhead. Cross-file reads used to fall in this bucket
  too, but were slow enough in practice (whole-file reads to answer
  one-line questions) to justify `org_query` as a dedicated tool instead.

- **Why IDs rather than heading titles?**
  Titles are not unique and can change. `:ID:` properties are stable
  references that survive renames and refiling.

- **Why short snake_case tool names rather than upstream's convention?**
  Upstream `claude-code-ide` registers each MCP tool's name as the verbatim
  elisp function name (e.g. `claude-code-ide-mcp-xref-find-references`).
  This module deliberately diverges: elisp identifiers follow elisp
  convention (full `claude-code-ide-org-` package prefix), while
  model-facing tool names follow MCP convention — short snake_case with an
  `org_` namespace prefix (e.g. `org_clock_in`). snake_case is the
  prevailing style for MCP tools, the `org_` prefix names the domain the
  model actually cares about, and shorter names reduce per-request schema
  overhead.

(The `org-clock-persist-load` trap — why calling it inside `(after! org
...)` breaks org-mode outright, and why the breakage only shows on a fresh
boot — lives in the **org-dev skill, §2**, which triggers when the Doom
config is being changed. It used to be duplicated here.)

