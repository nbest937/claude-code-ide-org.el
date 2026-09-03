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

## This file is a starting point; the artifact is the authority

**Read this before the claims below, because it qualifies all of them.**
This file is loaded into every session by default while the things it
describes are not. So a stale claim here *outranks the truth* until
someone deliberately checks, and the sections describing mechanisms that
have been cut over are the highest-risk kind — the prose outlives the
code that justified it.

Which artifact wins depends on the question:

| question | authority |
|---|---|
| what the system does | the code and its tests |
| how Emacs is configured | the live `~/.config/doom/config.el` |
| what is planned, blocked, or next | `TODO.org`, via `org_outline`/`org_query` |
| what a number means | the `defcustom`'s own docstring |

**This is about *state*, not about *rationale*.** Why a decision went the
way it did lives only in a heading body or in this file, and cannot be
recovered from the code — which is why the load-bearing reasons are
quoted here rather than left to a lookup. Distrust the file's account of
what *is*; do not distrust its account of *why*.

**And accuracy does not retire the risk — it disguises it.** An accurate
CLAUDE.md makes answering from it more often correct, which makes the
habit of answering from it instead of from the artifact harder to notice:
the same behaviour with better odds. The evidence is that most wrong
claims never came from this file. On 2026-08-11, of roughly a dozen wrong
claims, only four traced here; the rest came from unchecked inference,
from a session's own earlier summaries, and three times from reading a
silently-failing command's empty output as a result.

`bin/check-conventions` mechanises the part of this that can be
mechanised — that cited `:ID:`s resolve and the keyword set agrees
everywhere. It cannot check a claim that is merely out of date, which is
most of them.

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

*A caveat that stood here until 2026-08-28, wrong in its detail and now
fixed outright (`:ID:` 98908aff).* It said `active_only` *drops* live
children of a finished parent. It did not drop them — it emitted them at
their unchanged absolute indent with the parent gone, so a reader
re-parented a live child onto whatever line above happened to have a
smaller indent. Wrong structure rather than a visible gap, which is worse,
and the difference matters because a missing line is noticed and a
misparented one is not.

`--outline-map` now keeps a filtered-out heading when it is an *ancestor*
of something that survived, so the path stays intact. Two related things
also stopped being true: the old note's reassurance rested on level-1
headings being keywordless categories, which the flattening removed, and
the corpus still has zero instances — so this was fixed while it was
still latent rather than after it bit.

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
feature-vs-story classification either. **A task that has acquired
children carrying TODO keywords is a story** — emergent, reversible, and
machine-detectable via `claude-code-ide-org--container-heading-p`, whose
"container" is simply the code's older word for it. No heading needs to
be classified as one when it is written; see TODO.org `:ID:` b5f94b88,
which says so about itself.

**Three words, and they do not overlap.** An **epic** is the grouping a
task belongs to — since 2026-08-28 a `:CATEGORY:` value carried by the
task itself (`:ID:` 29439196). A **story** is a task that grew keyworded
children. A **slice** names members by reference and sequences them.
Earlier drafts of this file called a story an "epic", which is why
`:ID:` 2e660571 exists.

**A fourth word, and it names a failure rather than a thing: a
_twin_.** Two headings that describe the same defect, or the same class
of work, closely enough that fixing one and not the other is arbitrary.
**The _twin asymmetry_ is scheduling one and forgetting the other**, and
it has happened twice in composition: `:ID:` c31b6c76 and `:ID:`
5a5e87c9 are both time-of-day test flakes and only one reached a slice;
`:ID:` 5f1068f9 and `:ID:` 33864a0f are "make the file read newest-first
after archiving" differing only in key, and again only one did — after
the first case had already been caught and fixed.

**Both were caught by a reader, never by the composer**, which is the
part worth acting on: a twin asymmetry is invisible from inside the act
that creates it. So it is a *review* question — "does anything in this
list have a twin that is not in it?" — rather than a rule composition
can follow. Note the second escape happened in prose that had *just
named* the first, so knowing about it is not protection (`:ID:`
d5490814).

**The axis under both of those, and the one worth carrying:** a grouping
is either **emergent** or **declared**, and which it is determines the
mechanism it needs.

A **story** is emergent. A task becomes one by acquiring keyworded
children — however they arrived, whether grown or refiled — so it can be
*detected*, nothing is written down, and therefore nothing can go stale.
That is the whole reason the paragraph above says not to classify one: a
declaration of something already derivable is a second copy that can
disagree with the first.

**But "however they arrived" describes detection, not permission**, and
reading it as permission is a live trap — it was walked into on
2026-08-31 (`:ID:` 9e627dc0). The test is what the heading *already
owns*: **a task that has done work of its own — a clock, a `:LOGBOOK:`,
a body recording what it did — must not simply be given children.**
Doing so traps that record in a container, and a container with live
children can never close, so a heading whose own work is finished is
held open by its group indefinitely. Divide it instead; see "Where a
story comes from" below. Only a heading with nothing of its own to
strand may grow children in place.

An **epic** and a **slice** are both declared, and they are not the same
thing. Each asserts that particular tasks belong together for a reason
the tree does not encode; they differ in what they do about it.

An **epic** is a *label* on the task — `:CATEGORY:`, shipped 2026-08-28.
Note what that buys now that level-1 groupings are gone: a story spans
epics for free, because its children simply carry different `:CATEGORY:`
values. No refiling, and no arrangement of parents to work around.

**It was very nearly `:EPIC:` instead**, on the argument that a
purpose-built property means exactly one thing. `:CATEGORY:` won on
three affordances org gives it and gives nothing else: it populates the
agenda prefix column, it inherits with no configuration, and
`org-agenda-filter-by-category` exists. The "means one thing" worry was
answered from the other side — `:KIND:` took the what-is-this job, so
`:CATEGORY:` only ever answers what-is-this-about. See
`.claude/rules/org-conventions.md` for the ten values.

A **slice** names its members *by reference* — a checkbox list of
`[[id:...]]` links — and **sequences** them. Nothing moves, so a slice
can pick a whole story or one task inside one, and the same task can
appear in one slice and not the next. `:ID:` c44c2119 is the working
prototype and carries the composition rules inline; the convention
extracted from it is in `.claude/rules/org-conventions.md`.

What a slice declares is **membership and order, and nothing else**.
Every other field on one of its lines — keyword, title, checkbox — is
*derived* from the referent and gets regenerated, never hand-set. A
checkbox that disagrees with its referent means the slice is stale or
the referent's keyword is under-reporting; it never means someone
formed a second opinion worth recording.

**Where a story comes from.** A task that outgrows itself **divides**
rather than being promoted: a new parent appears, the original leaf
moves under it *carrying its `:ID:`, clock and `:LOGBOOK:`*, and the
undone parts of its swollen body become new sibling leaves. `:ID:`
a0813ae3, **built 2026-08-28** as `org_divide`.

**Note the direction, because getting it backwards is the whole trap:
after dividing, the original heading is the _child_.** The new parent
carries a new `:ID:` that did not exist before. If the heading you
started from is still the parent afterwards, you did not divide — you
added children, and the paragraph above says when that is wrong.
**Order matters too:** divide *first*, then file the new leaves as
siblings. Dividing afterwards carries any children you already added
down with it, since `org-demote-subtree` moves the whole subtree, and
they arrive as grandchildren needing a refile.

Two halves, split on whether judgement is involved. The tool does the
*structural* move and nothing else — new parent, demote, carry
everything — because that part is mechanical and this repo has two body
corruptions on record from hand-rolled region edits. Splitting the
child's engorged body into further leaves stays manual: a tool that
guessed at it would be inventing headings. So `org_divide` guarantees
the record survives; it does not guarantee the division was a good
one.

The payoff is that **a story is precipitated, never authored.** The new
parent *is* a story the instant it has keyworded children, so there is
no moment where anyone decides "this is now a story" and writes it down
— which is the decision that was always going to be got wrong, and the
one the emergent definition exists to avoid.

And it is **born empty**, which settles three open things *by
construction rather than by rule*:

- **No clock, and this bullet is narrower than it was.** A story born by
  division has never been worked, so it starts with no clock. That is a
  statement about its *birth*, not a rule that groupings stay clockless
  — `:ID:` 3964c575 asked for the latter and was **declined** 2026-08-26
  (see the clock rules below). Mitosis never needed that argument: its
  case is that the record stays with the task that earned it, which is
  the next bullet.
- **No history.** The `:ID:`, `:LOGBOOK:` and state transitions travel
  with the elder child, which is the task that actually did the work.
- **No body of actions.** The engorged body is *consumed* producing the
  new leaves. What is left is the reason the group exists — which is the
  one thing a story's body should hold, and why "a story has no body" is
  a consequence here rather than an instruction to remember.

Two consequences that are easy to get backwards. Declaring an emergent
grouping is the error the epic paragraph guards against. Trying to
*infer* a declared one — reading a story out of the tree's shape — is
the same error mirrored, and it is what the top-level category tier did
silently until it was retired (`:ID:` 29439196). And note that a declared grouping
is made of ids, which is why `:ID:` 478d6ec9 is load-bearing here rather
than a convenience.

**And a third case, which looks like the second and is not: the thing
belongs to another system.** Org's datetree nodes are identified by
matching org's own title shapes, and that is *correct* — not an
inference standing in for a declaration we failed to make. We could not
have made it: `org-datetree-find-date-create` builds year, month and day
inside org, with no hook, and the DONE.org archive datetree would be
built by `org-archive-subtree` outside this project entirely. A property
we cannot write at creation is absent on arrival, and fails open and
silently, where reading the owner's published shape does not. So the
emergent/declared axis governs *our own* conventions; where another
system owns the thing, read the contract it actually publishes
(`:ID:` 2e660571, which proposed the opposite and measured its way out).

**Rule**: work planned via Claude Code's own Plan Mode gets a single
permanent link — `[[file:~/.claude/plans/<slug>.md][Plan]]` — written
into the heading's **`:PLAN:` drawer**, added as soon as the first round
of planning finishes (right after `ExitPlanMode` is called and the plan
file is finalized), not gated on the heading later transitioning to
`DOING`. This matters because approval and the `DOING` transition don't
always happen in the same beat as planning — e.g. the user may
deliberately stop right after a plan is written, before deciding whether
to implement it — and the link should exist the moment a real plan file
does, independent of what happens next. A plan link *is* planning
content, so it belongs with the rest of the prospective prose (`:ID:`
b75d553a): planning before composition simply includes the link in the
normal three-call composition. When the drawer already exists before a
Plan Mode session, nothing writes into it yet — `org_amend` appends
*below* a drawer, and `:ID:` 501a8422 is the nominated fix — so until
that lands, put the link in the body and move it into the drawer at the
next revision that can. Revisions (re-entering Plan Mode on the same
task) edit that same plan file in place — Claude Code reuses the
existing plan file path for a continuation of the same task — so the
link is written once and never needs updating to point at a new file. No
transcription of the plan into org, ever; the link is the record.

Nothing moves at `DONE`: the link has lived in `:PLAN:` since
composition (2026-09-02, `:ID:` b75d553a), which is what keeps a
forward-looking pointer out of the retrospective readout a finished body
becomes. (Two earlier forms of this rule — "not removed at `DONE`", then
"relocated into `:PLAN:` at `DONE`, when `org_wrap_plan` wraps it" —
described the wrap-at-`DONE` flow that convention retired; a
pre-convention heading's link still travels into the drawer whenever its
body is retroactively wrapped.) A task with no separate Plan Mode
session simply carries no link — that's expected, not a gap to fill in.

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

**Since 2026-09-02 the plan goes into `:PLAN:` when it is *composed*, not
at `DONE`** (`:ID:` b75d553a). The body carries a two-to-five-sentence
statement of the problem and proposed solution; the debrief is appended
at `DONE`. So the two halves are never mixed and no seam is ever
created — which matters because the seam is a fact about *when* a
sentence was written, is recorded nowhere in the prose, and is not
recoverable later (`:ID:` f099379b). `org_wrap_plan`'s seam marker is now
a retroactive tool. **And how to read the drawer depends on the
keyword**: skip it on a finished heading, *read* it on a live one, where
it holds the current plan rather than superseded design.

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

*The backlog rule was "wrap unedited" and is retired* (`:ID:` f099379b).
`cbe282ec` chose it to keep 30 purely prospective bodies cheap. Measured
2026-09-02, 88 of 93 unwrapped headings carry a debrief, so a blind wrap
would bury it in a drawer readers are told to skip — and no lexical
marker finds the seam, since the first match sits in the *prospective*
half as often as not. The backlog pass is `:ID:` 35d25265, which reads
each body; it costs the per-heading judgement `cbe282ec` was trying to
avoid, and there is no cheaper honest option.

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
| `DOING`    → `DONE`       | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `WAITING`       | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `REVIEW`     | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `CANCELLED`  | Close the CLOCK (call `org_clock_out`) |
| `WAITING`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `REVIEW`   → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `REVIEW`   → `DONE`       | None                                |
| Any        → `MAYBE`      | None                                |

**The table describes setting a keyword because the work is happening
now.** Under `DOING`'s looser sense — started and owed, not executing —
a keyword can also be set *retroactively*, and then none of the clock
column applies. See the rules below.

`REVIEW` is **experimental** (TODO.org `:ID:` c954f650) — finished work
handed back for human judgement. Clock-wise it behaves exactly like
`WAITING`: entering it closes the clock, leaving it for `DOING` opens one,
and `REVIEW` → `DONE` touches nothing because no clock is running. These
rows were added 2026-08-21; until then the keyword was in live use with
its clock semantics written down nowhere.

**`REVIEW` → `DONE` is the expected exit; `REVIEW` → `DOING` is the
exception** (the user, 2026-08-26). Going back to `DOING` means the review
found something *missing or broken* — it is rework, not the normal close.
Read the two rows above in that light: the clock reopens only because
work resumed, and most `REVIEW` headings should never reach that row at
all.

Which makes the keyword a claim worth being careful with. Setting
`REVIEW` asserts the work is finished and only judgement remains, so a
heading parked there to mean "not sure yet" is misusing it — that is
`WAITING`, or it is still `DOING`.

**`DOING` means started and owed a return — not executing right now.**
The useful metaphor is *in the mail*: we have begun and need to circle
back as soon as possible. It is durable and **plural**; several headings
may be `DOING` at once. What records actual execution is the *clock*,
not the keyword, and at most one heading carries a running clock because
org runs one.

On a **grouping** — a story or a slice — the same word reads one level
up: at least one member is in the mail. That sense opens *no automatic*
clock, and takes no `NEXT` either, since both belong to a member.

**A grouping may still be clocked deliberately, and that is not a
defect.** `:ID:` 3964c575 proposed that groupings carry no clock at all;
declined 2026-08-26. A parent's own coordination and planning time is
real work, and a blanket "only leaves may be clocked" rule discards it —
which is what `--container-heading-p`'s docstring has said all along. So
the exemption is deliberately narrow: it suppresses the *automatic*
clock a state change would open, never a deliberate `C-c C-x C-i`.

Two consequences worth stating, since both have been read backwards. The
nine groupings carrying their own CLOCK lines today are **history, not
debt** — each was clocked honestly while it was still a leaf, and became
a grouping later by acquiring children or by a refile. Nothing is to be
migrated. **That is amnesty for what already happened, not a licence to
make more**: each of those arose by accident, and choosing the shape
deliberately today is the error the story paragraph above now names. And the resulting ambiguity is a **reporting** problem, not a
data one: measured 2026-08-26, a clocktable row for a parent shows own
plus subtree as one number and its own share appears nowhere, recoverable
only by subtracting every child (`:ID:` 64d34a64). Both triggers
now ask `claude-code-ide-org--grouping-heading-p`, which is the union of
the two ways a heading can be one: a container is *emergent* (it acquired
keyworded children) and a slice is *declared* (`:KIND: slice`). Until
2026-08-26 they asked the container predicate alone, so a slice was
clocked and auto-promoted like an action, its members being links rather
than children (`:ID:` 95c27fca).

Note which predicate goes where. `--grouping-heading-p` is right wherever
the question is about *meaning* — whose clock, whose next action. Where
the question really is "does this have TODO children", as in
`bin/lint-org`'s statistics-cookie rule, the narrow container predicate
stays.

GTD's one-thing-at-a-time is not being followed here, deliberately. That
rule is calibrated to human working memory; an agent re-reading a
checklist each turn has different limits, and keeping several started
items visible is what stops them being silently dropped.

Consequences, each of which has been got wrong in practice:

- **A leaf held for *the user's* judgement is `WAITING`, not `DOING`** —
  nothing is owed by us, so nothing is in the mail.
- **A heading that was worked and set down stays `DOING`.** Demoting it
  to `NEXT` or `TODO` loses the fact that it is owed. This reverses an
  earlier draft of this section, which claimed the keyword tracks
  attention rather than progress and that no "started but resting" state
  should exist; that is exactly the state `DOING` is for.
- **Setting `DOING` retroactively is safe through the queue, and only
  through the queue.** `org_set_todo` opens no clock by itself, and apply
  binds `--trigger-auto-clock-in` off for every item it lands — measured
  2026-08-26, and pinned by
  `claude-code-ide-org-test-review-suppresses-the-auto-clock-in-trigger`.
  A hand `C-c C-t` to `DOING` in Emacs *does* clock in at once, so
  recording that something *was* started is a queue action rather than a
  keystroke. See `:ID:` 4f6a6bb1.

**Rule**: a transition *to* `DOING` opens a clock **when you are starting
work now** — the ordinary case, and what the table above describes. One
exception: a **retroactive** `DOING` — recording that a heading was started earlier — opens nothing,
because the work did not happen now. **The queue honours that exception,
so such a transition may be queued freely.** This said the opposite until
2026-08-26 and was wrong the whole time (`:ID:` 4f6a6bb1): `org_set_todo`
and `org_clock_in` are separate calls precisely so state and clock are
decided separately, and apply suppresses the trigger outright. The one
path that does *not* honour it is a hand `C-c C-t` in Emacs — where a
human is present to know which act they are performing.

**A second exception: a _grouping_.** A story or a slice entering
`DOING` opens no automatic clock, because on a grouping the keyword
means "at least one member is in the mail" rather than "work is
happening here". `--trigger-auto-clock-in` declines when
`--grouping-heading-p` is true.

**Note where that exemption actually bites, because it is narrower than
it reads.** The trigger tests `--auto-clock-in-active` *before* it tests
for a grouping, and apply binds that variable around the whole pass — so
on the apply path the trigger short-circuits for **every** heading,
grouping or leaf, and the grouping test is never reached. The exemption
therefore does its work in exactly one place: a TODO state changed *by
hand* in Emacs (`C-c C-t`, `S-right`). And it suppresses only the
*automatic* clock, never a deliberate `C-c C-x C-i` — a grouping's own
coordination time is real work and may be clocked on purpose.

**Rule**: a transition *from* `DOING` closes the clock **if this
heading's clock is the one running**. Because `DOING` is plural, a
heading can be `DOING` with no clock — another heading holds it — and
there is then nothing to close.
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
**`PLANNING` was retired 2026-08-28** (`:ID:` c954f650), and with it the
`ExitPlanMode` promotion hook, the cross-session owner guard, and four
rows of the table above. Measured across the project's whole history
before removing it: 7 `PLANNING` transitions in 432 state changes, on 6
of the 24 days the keyword existed and absent from the three busiest;
43 headings carried a plan link and 7 of them ever wore it; and the
premise it was built on — long spans of agent work in Plan Mode — held
for one of the seven, four having clocked nothing at all inside the
window. All seven exited to `DOING`, so it never distinguished an
outcome.

Nothing replaced it, deliberately. A "plan approved" event was
considered and declined: nothing would consume it, and this project's
precedent (`:ID:` 7771fc63) is to delete a mechanism whose premise
failed rather than reimplement it more cheaply. **Plan Mode now needs no
state change of its own** — a heading is `DOING` while it is being
planned and implemented, which is what `DOING` already meant.

**Rule**: before a session's first act that changes anything — a repo
edit, a capture, an amend, any immediate org tool — name the heading the
work belongs to and call `org_clock_in` on it, or on "Review and
planning" (that exact title) for cross-cutting meta-work: review,
planning, deciding what to do rather than doing it. No heading yet means
capture one first, with an `initial_state`. The trigger is the *first
write, not the ask*: a session that opens as a question drifts into
tracked work, and the drift is invisible from inside the session doing
it — on 2026-09-03 three sessions worked through the immediate tools
alone and every span reached review UNASSIGNED (`:ID:` ccfd89ce). A
purely read-only session owes nothing. `bin/hooks/clock-target-check`
backstops this at turn end, once per session: write activity in the
transcript with no `clock_in` in the queue blocks the stop with a
reminder. It reports; it cannot name the heading — that judgement is
this rule's alone.

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
`--trigger-auto-clock-in` (opens the clock the moment DOING is
set by hand — gated by `claude-code-ide-org-auto-clock-in-on-doing`,
default `t`), plus `--trigger-demote-conflicting-next`, live and
ungated **inside a container**.

**`NEXT` belongs to a container's *members*, and nothing sets it by
itself** (`:ID:` 62b65ad0, 2026-08-26). Read that carefully: `NEXT` is
meaningful *within* a story, and **a story must never carry it** —
promoting one declares a project to be an action, which is `:ID:`
42808717. "Belongs to containers" was the original phrasing here and read
as the opposite of what it meant.

**A slice is the exception, and the rule was split on 2026-09-02 to say
so** (`:ID:` abce1850). It previously read "within a story *or a slice*",
which neither source heading argued: `:ID:` 42808717 was written six days
before slices existed and never mentions them, and `:ID:` 62b65ad0
mentions them once in 5,418 characters. The generalisation was
editorial.

And it does not hold, because the two groupings differ in the way that
matters. A story is *emergent*; its next action is one of its children,
so naming the parent names no action. A slice is *declared and
sequenced*, and **several are open at once** — three on the day this was
written — with nothing in the vocabulary saying which to pick up.
`DOING` on a slice means at least one member is in the mail, which is
state rather than priority.

So **a slice may carry `NEXT`, and it means "this is the slice to pick up
next"** — a portfolio-level nomination, not an action. Three constraints
keep it from re-creating the confusion `:ID:` 42808717 named one tier
down:

- **At most one top-level `NEXT` per `:CATEGORY:`, slices included**
  (`:ID:` 758a8b78, 2026-09-03 — generalising the original "at most one
  slice carries it"). Within the Slices category, mechanism work and
  starting a slice compete for the same nomination, which is a
  deliberate forcing function. A story's *internal* `NEXT` is exempt —
  it is a memoization of where to start upon entering the story, not a
  portfolio nomination — and a slice's *members* may show several
  `NEXT`s, since they are references reflecting other groups'
  nominations.
- **It does not substitute for a member's `NEXT`.** The two answer
  different questions — which slice, and which action inside it — and a
  slice marked `NEXT` whose members are all `TODO` is still
  un-nominated.
- **Nothing sets it automatically**, exactly as before. Sequencing
  slices is a judgement, and the retired promotion trigger is the
  standing evidence for what happens when that judgement is mechanised.

A `--trigger-auto-promote-sole-todo`
stood here and set `NEXT` on a container's sole remaining `TODO`
autonomously. It is gone, along with its three guards — a re-entrancy
flag, a mid-batch suppression flag, and the settle pass that re-ran what
the suppression skipped. 163 lines, every one of which existed *because*
the trigger wrote to the file on its own.

Two things went wrong with it, and only the second is obvious in
hindsight. It nominated badly: three of roughly eight top-level
promotions ended up parked as `MAYBE`. And its sibling group was a
*category* — `--map-siblings` walks with `org-get-next-sibling`, which at
top level stops only at the file's boundary — so "the sole remaining
`TODO` in Tooling" was a claim about a filing drawer, not a project. That
is `:ID:` 42808717 one tier up: it taught the trigger to refuse a
container because promoting one declares a project to be an action; this
retires the case where the *group* is the wrong kind of thing.

`--trigger-demote-conflicting-next` survives, scoped the same way: it
declines at top level, where there is no sibling group worth the name.
Having a parent is the test, since a keyworded heading with a parent
makes that parent a container by definition.

**What replaced the promotion is a report, not a rule.**
`--nomination-candidates-context` names every grouping whose live
members include no `NEXT`, at `SessionStart`, alongside the
stale-interval and ceremony reports — and it *asks* rather than acting,
which is the contract those reports already keep. It names a sole
candidate and merely counts several, because that is the case no rule
can decide. Measured on this corpus the day it shipped: five groupings,
each a real un-nominated project.

**Rule**: every transition *to* `DONE` **inside a grouping** nominates
the next action — set `NEXT` on whichever remaining member should be
picked up next, or say in a sentence that no clear candidate exists.
Leaving the group silently un-nominated is the thing to avoid. Closing a
*top-level* task nominates nothing, because it has no group; several
top-level `NEXT`s at once are expected and correct — at most one per
`:CATEGORY:` (`:ID:` 758a8b78), which is what a workstream now means.

Since 2026-08-26 this is the *whole* invariant rather than half of it.
`--trigger-demote-conflicting-next` still gives at most one `NEXT` per
container, but nothing gives you one automatically any more — setting
`NEXT` is strictly intentional, and the report only points. GTD's actual invariant is that a live project
always has a next action; a project without one is the canonical defect a
weekly review exists to catch.

**Rule, same moment**: any work the closing debrief names as *not done*
becomes a filed heading before the `DONE` is queued — or the debrief says
explicitly that it is not worth filing. **A sentence pointing at another
heading is not a filing action**, and neither is "belongs to X".

This exists because both halves happened in one session, hours apart, and
nothing distinguished them at the time. `:ID:` e1284bdb was closed *after*
its unfinished half was split out as `:ID:` 601c885c. `:ID:` aa1ba915 was
closed with its gap described in prose as belonging to `:ID:` edd47f32 —
which was never told, and whose four children did not include it. The user
caught it a day later by asking whether the heading was really done.

The reason prose is not enough is structural rather than a matter of
diligence: residue named in a *closed* heading's body sits in a document
readers are told to treat as history, and `org_wrap_plan` will eventually
sweep it into a `:PLAN:` drawer readers are told to skip. It is on a path
to becoming invisible from the moment it is written.

Note this is a strictly stronger claim than the nomination rule above.
Nominating answers "what next in this group"; this answers "what did
closing this leave behind", which may belong to no group yet.

**Rule**: when nominating, call out blockers that live in a *different*
subtree. Name the blocking heading and where it is; a `:BLOCKER:` property
is the machine-checkable form. A dependency inside the same sibling group
needs no announcement — anyone reading that group can already see it — but
a cross-subtree one is invisible from either side. Note that a `:BLOCKER:` naming a
heading captured in the same session is **inert** until a human applies
the queue *if that capture was keywordless* — `org-depend` blocks only on
an unfinished TODO keyword. Since 2026-08-31 `org_capture` takes an
`initial_state`, so pass one and the blocker bites immediately (`:ID:`
c74f8663). Omitting it is still right for a note rather than a task, and
then the old caveat applies unchanged.
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
wording. (This used to note that the `ExitPlanMode` auto-promotion hook
could not affect the rule; the hook was deleted with `PLANNING` on
2026-08-28, so nothing promotes anything automatically now.) The
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
| `org_divide`        | custom (`org-demote-subtree`) | Task mitosis: insert a new parent above a heading and demote it under. The id, clock and history stay with the **child** |
| `org_wrap_plan`     | custom (two insertions)  | Wrap the prospective part of a body in a `:PLAN:` drawer. No `until` wraps the whole body (the composition-time case); `until` marks where the debrief begins (the retroactive case). Lossless — nothing deleted or reflowed — and it refuses rather than guesses: an existing `:PLAN:` drawer, an empty body, or a missing/duplicated `until` are errors. The composition procedure lives in its schema docstring |
| `org_set_property`  | `org-entry-put`          | Set a property by `:ID:`. `:BLOCKER:` is validated — ids resolved, prefixes expanded, unresolvable refused — and `append` unions rather than replaces. Refuses `:ID:`/`:CREATED:` |
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
| `org_outline`       | Compact structural index: level, keyword, title, `:ID:`, tags. Marks `[blocked: id …]`. **Scoped to one heading it leads with that heading's front matter** — `:CREATED:`, `:CATEGORY:`, `:KIND:`, the `:BLOCKER:` *value* with each id's keyword, the plan file — so "what is this, what blocks it, what is under it" is one call and no body read. Accepts an 8-character prefix as scope. Use before creating a heading |
| `org_body`          | Returns one heading whole — heading line, drawers and body — by `:ID:` or 8-character prefix. Filters **nothing**, `:PLAN:` included; the caller extracts, and how to read that drawer depends on the heading's keyword (skip when finished, read when live). This heading's own body by default, `include_children` for the subtree. Replaces grep-plus-awk-plus-`Read`; still reach for `org_outline` first |
| `org_pending_updates` | Summary of queued-but-unapplied updates, grouped by heading. Counts *proposals*, not queue lines. This is how you check a queued call landed |

There is **no MCP tool that applies the queue**, by design. Apply is `M-x
claude-code-ide-org-review`, run by a human. If you find yourself looking
for `org_review_apply`, it is a log-source label in `config.el`, not a
tool.

Text editing (via the org skill) is used for adding or changing tags,
generating new headings, and time reporting. `org_query` now covers
structured cross-file reads (e.g. "what's blocked," "everything :research:
and not DONE") that used to mean Claude reading whole files by hand.

**Read-only buffers: nothing to do.** The file-touching tools bind
`inhibit-read-only` themselves, so a buffer the user has toggled
read-only (`C-x C-q`) is written normally and the flag is still set
afterwards. **The clear-and-restore convention that stood here until
2026-08-31 is retired** (`:ID:` c8a97d9d) — do not clear
`buffer-read-only` by hand, and do not report having done so.

It is a *binding*, never a `setq`, and that is the whole safety
property: the flag comes back when the scope exits, including on a
non-local exit, so a tool erroring part-way through cannot leave the
buffer writable. The old convention could, and the failure window was
not theoretical — restoring the flag *correctly* after an `org_amend`
is what broke a human's own apply pass on 2026-08-25.

Two things this deliberately does not cover. **Interactive commands
still ask**: `M-x claude-code-ide-org-review` prompts before apply
(`--review-ensure-writable`), because clearing a human's guard is the
human's call when a human is present to make it. And a **hand-written
`emacsclient` call** is not a tool and binds nothing — if you find
yourself reaching for one against a read-only buffer, that is a signal
the tool surface is missing something, not a licence to clear the flag.

If the user ever wants a specific buffer left alone, they'll say so
explicitly; that overrides this for that instance only.

---

## Session tracking (`.claude/settings.json`, `bin/hooks/`)

Two separate timekeeping mechanisms, deliberately kept apart:

- **`:LOGBOOK:` CLOCK entries** (org's own, native mechanism) hold
  *confirmed intervals* — work time a human accepted at a review pass.
  **No hook writes one.** Since the 2026-08-11 cutover the `Stop` and
  `UserPromptSubmit` hooks append **turn-boundary guideposts**: bare
  timestamps, naming no heading and touching no clock. The review pass
  clusters those into spans, and a human confirms or corrects each one
  before it becomes a CLOCK line. So the *emission* is still per-turn;
  the *record* is not, and intervals are per-decision rather than per-turn.

  Two consequences that read as bugs and are not. A `DOING` heading
  normally has **no running clock** — live CLOCK lines are only ever
  written by the review pass, so every `DOING` heading sits clockless
  between passes. And CLOCK lines arrive in **bursts when someone
  applies**, not continuously as work happens, so their timestamps
  describe when the work was, never when the line was written.

  **Churn relocates; it does not disappear.** Guideposts still accumulate
  every turn, into the queue file — cheap, disposable, no Emacs required.
  What ended is churn in the *org record*.
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

### The three numbers that shape a recorded interval

All three are `defcustom`s, all three run at their defaults, and none was
written down here until 2026-09-02. They apply in order:

| variable | default | decides |
|---|---|---|
| `claude-code-ide-org-guidepost-gap-threshold` | 1200 s | how guideposts group into spans for review |
| `claude-code-ide-org-span-idle-floor` | 120 s | how much idle *inside* a span is absorbed rather than split on |
| `claude-code-ide-org-span-minimum-interval` | 0 s | below which a run is dropped rather than written |

**The threshold no longer defends any duration, and reading it as though
it still does is the mistake this section exists to prevent.** A span
used to be written as one CLOCK line end to end, so where the threshold
fell decided how much idle became work — which is what made its
derivation load-bearing. Since 2026-08-18 apply writes one line per run
of `resume` → `pause` *inside* the span, so the threshold now governs
**grouping and display only**: how many items a human is shown and how
wide each reads. Moving it moves lines around the review buffer without
moving a single recorded minute.

Its value is still well founded, for what it now does. 1200 s sits inside
a band containing *no observations at all* — measured over 422 events,
the longest short gap was 1061 s and the shortest long gap 2070 s — and
span count is flat across 1200–1800 s, so every value in the band yields
an identical reconstruction. It was 900 s until 2026-08-13, just below
the band, splitting five spans nothing justified splitting.

**The idle floor is the consequential one — it is what decides how much
idle the record claims as work.** Two runs separated by less than 120 s
merge into one line. Strictly less, so a gap of exactly 120 s splits.
The trade is deliberate and measured: splitting at every idle gap turns
one span into 54 CLOCK lines against 39 at two minutes, while raising
the floor to 300 s would write 30.89 h where 120 s writes 23.05 h —
re-absorbing nearly eight hours of the idle the floor exists to keep
out. Legibility is all a larger floor buys; accuracy is the point.

**The minimum interval is a named no-op, deliberately.** Zero means
exactly today's behaviour: what keeps sub-minute intervals out of the
drawer is two *rendering* conditions, which are consequences of the clock
format rather than a policy anyone chose. Naming it makes the policy
settable without changing it — a knob that cannot be turned is not a
knob — and the value it should take is a reporting decision, not an
implementation one.

**Do not infer any of these from a drawer.** They are the reason two
CLOCK lines on the same heading can describe adjacent work and still be
separate lines, and the reason a turn you remember taking thirty seconds
may appear nowhere at all.

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

**That hook now carries a second, independent report: the daily ceremony
prompt** (TODO.org `:ID:` aa1ba915). One hook and one payload, because
`additionalContext` is a single string and a second SessionStart hook
would double the Emacs round-trip to say the same thing. Either half may
be absent; the payload is `{}` only when both are, and the script's
`[[ -s ]]` guard drops it.

The ceremony half names what is waiting — pending queue items, drawers
out of order, finished headings not yet archived — and then **asks**,
following the same rule as the stale-interval report above. It is
explicit that apply is the human's alone, so a session must not offer to
run the pass. Its "already done today" test is a stamp file,
`ceremony-last-run` in the queue directory, whose *mtime* carries the
date; `M-x claude-code-ide-org-mark-ceremony-done` writes it. A day node
or a falling pending count were both rejected for conflating "the
ceremony was performed" with "something happened".

The two commands the ceremony runs after apply are
`claude-code-ide-org-consolidate-all-drawers` (`:ID:` 7ae6562d — reaches
every drawer, not only ones an apply pass happened to touch) and
`claude-code-ide-org-normalize-heading-separation` (`:ID:` e1284bdb).
Both are idempotent and both default to a dry run interactively; **from
Lisp both default to writing**, which is the one thing to know before
calling either from code.

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

