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

**Moved into the plugin, 2026-09-09** (`:ID:` b0e478f7): the full text
ships as `skills/org/references/org-event-queue.md` and is promoted by
`bin/claude-org-setup` into `.claude/rules/org-event-queue.md`, which is
the copy every session here loads. The one line that must survive even a
broken promotion: **state and clock changes are queued, not applied** —
`org_set_todo`, `org_clock_in` and `org_clock_out` append events for
human review and change nothing when called; `org_pending_updates` shows
what waits.

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

(`--outline-map` keeps a filtered-out heading that is an *ancestor* of a
surviving one, so `active_only` never re-parents a live child; `:ID:`
98908aff has the history.)

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
wired in `.claude/settings.json` — what each hook appends is in the
session-tracking rules (`.claude/rules/org-session-tracking.md`), not
repeated here.

Five things you would not guess:

- **`.claude-plugin/`, `hooks/` and `skills/` are the plugin surface**
  (2026-09-09, `:ID:` b0e478f7): the manifest, the shipped hook wiring
  (mirroring `.claude/settings.json` — a repo enables one or the other,
  never both), and the org skill whose `references/` carry the machinery
  prose and conventions. `bin/claude-org-setup` promotes those references
  into a consuming repo's `.claude/rules/` — this repo runs it on itself,
  so the machinery files under `.claude/rules/` are **generated**, marked
  by their header; edit the reference and re-run setup, never the copy.

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

The org skill's canonical home is `skills/org/` — the plugin's unit of
travel — with `.claude/skills/org` a symlink into it, so this repo's
sessions discover it exactly as before. `org-dev` stays a real directory
under `.claude/skills/`, testbed-only and unshipped.

## Scripting conventions

**The boundary is Emacs, not audience** (decided 2026-09-04, `:ID:`
84b7d8b3, which retired fish from the repo):

- **A script that needs the running Emacs keeps its logic in elisp**,
  behind a thin POSIX `sh` stub whose only job is moving bytes — write
  stdin to a temp file, call `emacsclient`, cat the reply.
  `bin/statusline.sh` and `bin/check-org-dev-skill` (core in
  `bin/lib/check-org-dev-skill.el`) are the shape.
- **A script that must survive an Emacs outage stays plain shell.** The
  queue-append hook family exists precisely so a stopped Emacs costs
  nothing; routing it through `emacsclient` would reintroduce the
  dependency the queue escapes. `jq` is fine there — logic beyond field
  mapping is not.
- **Test harnesses and dev tooling are bash**, unremarkably.
- **No fish.** It reached the commit gate (`bin/check-conventions`)
  undeclared, which is what turned a style question into this decision.
- **Python was considered and declined** for JSON handling: Emacs is
  already the harder, always-present dependency — every such script
  ends in `emacsclient` anyway — so elisp avoids adding a runtime
  rather than trading one.

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

**Rule**: work that wants its own **integration point** lands on a
`feature/short-name` branch and merges. What earns one is not a taxonomy:
several commits that should arrive together, work you might abandon, or
something you want to review as a unit — and a slice always is one.

**Maintenance between such chunks may land on `main` directly.** Applying
the review queue, debriefing and closing work that already merged, filing
headings, correcting a stale cross-reference: none of these wants an
integration point.

*This clause was added 2026-09-04 because its absence produced three
branches in one afternoon*, two existing solely to carry a single
bookkeeping commit and one renamed mid-flight when it turned out to be
doing real work after all. The rule before it opened "work does not land
directly on `main`" and then explained that a branch is *earned* by
wanting an integration point — two sentences that disagree, since work
that has not earned one then has nowhere to go. The contradiction
resolved toward the absolute clause every time. The cost is not the
branch; it is that a merge is a decision, and manufacturing decisions
devalues the ones that matter.

**The test, when unsure: would you want to review this as a unit, or
abandon it as a unit?** If neither, it is maintenance. Anything carrying
code or tests answers yes almost by definition, so this exemption is
narrower than it reads.

A one-helper fix committed straight onto the branch you are already on
still does not need its own — and note that assumed you *were* on one,
which is exactly what stops being true the moment a slice merges.

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
`.claude/rules/org-conventions-local.md` for the ten values.

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
normal two-call composition below. When the drawer already exists before
a Plan Mode session, `org_amend` with `drawer=PLAN` appends the link
inside it directly (`:ID:` 501a8422, shipped 2026-09-08; this paragraph
described a workaround for its absence until then). Revisions
(re-entering Plan Mode on the same
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
at `DONE`** (`:ID:` b75d553a). **The composition is two calls**
(`:ID:` 16d7d39a, written here because a CLAUDE.md directive moves usage
where a schema docstring does not — `:ID:` 420816ec measured it):
`org_amend` with `drawer=PLAN` writes the prospective prose — motivation,
options, reasoning, the plan link — creating the drawer when absent;
then a plain `org_amend` writes the two-to-five-sentence
problem-and-proposed-solution statement as the body. (This replaced the
three-call form that routed through `org_wrap_plan`, retired when
`:ID:` 501a8422 shipped the drawer argument.) At `DONE` the close is
two calls again: the authored resolution onto the body, the debrief via
`drawer=DEBRIEF` (`:ID:` d5eb32a3). So the two halves are never mixed
and no seam is ever created — which matters because the seam is a fact
about *when* a sentence was written, is recorded nowhere in the prose,
and is not recoverable later (`:ID:` f099379b). `org_wrap_plan`'s seam
marker is now a retroactive tool. **And how to read the drawer depends on the
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

**Rule**: closing a heading records the outcome twice, at two grains
(`:ID:` d5eb32a3, 2026-09-08): a one-to-two-sentence **resolution**
appended to the body, and the full **debrief** — what shipped, how it was
verified, what was falsified, what differed from the plan — into a
`:DEBRIEF:` drawer via `org_amend` with `drawer=DEBRIEF` (created when
absent). Together with the `:PLAN:`-at-composition rule above, the body
stays a fixed-size scannable summary: problem, proposal, resolution. Read
`:DEBRIEF:` on a finished heading — unlike `:PLAN:`, which is superseded
design there, the debrief is the part worth reading. This absorbs the
older pre-archive outcome-summary rule, whose "next to that link" location
stopped existing when the link moved into `:PLAN:`; a heading closed this
way owes archiving nothing further. Applies to delegated-subagent work
too: ask for a one-paragraph outcome summary in the subagent's final
report, not per-checkbox status — there are no checkboxes to report on.

---

## Org-mode conventions

Moved to the plugin's **`skills/org/references/org-conventions.md`**,
promoted by `bin/claude-org-setup` into
`.claude/rules/org-conventions.md` — path-scoped to `**/*.org`, so it
loads only when an org file is actually in play. This repo's own
additions — the ten `:CATEGORY:` values and the history of the level-1
tier — stay hand-maintained in `.claude/rules/org-conventions-local.md`.

The test that used to govern what stayed in this file — a rule that must
hold when no `.org` file is open cannot live in a path-scoped rule — is
now met by the promoted machinery rules instead, which carry no path
scope and load in every session: the queue architecture, the state
transitions, the tool tables and session tracking all live there, and
their sections below are pointer stubs.

---

## State transition rules

**Moved into the plugin, 2026-09-09**: the transition table, every clock
rule, and the `NEXT`/nomination invariants ship as
`skills/org/references/org-state-transitions.md` and load here as
`.claude/rules/org-state-transitions.md`. They are unchanged by the
move — follow that file exactly as this section was followed.

---

## MCP tools (`modules/tools/claude-code-ide-org/config.el`)

**Moved into the plugin, 2026-09-09**: the tool tables — queued,
immediate, conditional, read-only — ship as
`skills/org/references/org-mcp-tools.md` and load here as
`.claude/rules/org-mcp-tools.md`. The headline that must not be lost:
the three queued tools change nothing when called, and there is no MCP
tool that applies the queue — apply is `M-x claude-code-ide-org-review`,
human-run.

---

## Session tracking (`.claude/settings.json`, `bin/hooks/`)

**Moved into the plugin, 2026-09-09**: the hooks table, the three
numbers that shape a recorded interval, permission blocks and
stale-interval recovery ship as
`skills/org/references/org-session-tracking.md` and load here as
`.claude/rules/org-session-tracking.md`. The wiring exists twice on
purpose — this repo through `.claude/settings.json`, consumers through
the plugin's `hooks/hooks.json` — and a repo must enable only one of
the two, or every guidepost is appended twice.

---

## Emacs integration

**A reachable Emacs server is a hard prerequisite** — every MCP tool
goes through `emacsclient`; if tools fail, check that first. The
install and wiring guidance — Doom module, the org 9.7 floor, the
pinned port, per-repo setup — ships as
`skills/org/references/org-emacs-setup.md` (deliberately not promoted
into rules: it is read at install time, not needed every session).

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
