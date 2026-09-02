---
paths:
  - "**/*.org"
---

# Org-file conventions for this project

Loaded only when working with `.org` files. Anything that must hold whether
or not an `.org` file is open — the state transition rules, when to create a
heading at all, the queue architecture — stays in CLAUDE.md deliberately: a
path-scoped rule that does not load is a rule that does not apply, and the
failure is silent.

## File header

Every `.org` file in this project should start with:

```org
#+TODO: TODO(t!) NEXT(n!) DOING(d!) REVIEW(r!) WAITING(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)
#+TAGS: code comms research review
#+ARCHIVE: DONE.org::
#+STARTUP: logdrawer logdone content
```

The per-keyword cookies matter: `!` records a timestamp on entry, `@`
*prompts for a note*. See CLAUDE.md's transition rules for why that
asymmetry is load-bearing.

**`#+STARTUP: logdrawer` is the fourth line and it is doing real work.**
`org-log-into-drawer` defaults to nil, so org's *native* state-change
logging writes notes bare, just after the property drawer, while this
project's apply path lands them in `:LOGBOOK:` — it binds the variable
locally and deliberately, so a user's own interactive `org-todo` keeps
their configured behaviour. Without the header line the two paths
disagree, and the result is visible in the wild: `:ID:` b5f94b88 has a
`DOING` note sitting *above* its drawer while older entries sit inside
it.

**Why a header line rather than a `setq`.** Verified 2026-08-12 that
`#+STARTUP: logdrawer` sets the variable *buffer-locally* — effective
value `"LOGBOOK"` inside the file, global still nil — which claims
exactly the scope this project owns and changes nothing for a user's
other org files. A global `setq` would reconfigure org for everyone who
installs the module.

**Its verification precondition, which is not the obvious one.**
`#+STARTUP:` is read when org *initialises a buffer*, so a file already
open in Emacs keeps the old value until it is reverted. Saving is not
enough, and neither is `global-auto-revert-mode` noticing the change if
the buffer is unmodified — the mode has to re-run. A check made against
an already-open buffer measures the old value while every signal says
success.

`org-todo-keywords` in the Doom config does **not** include `REVIEW`, so it
resolves only in files carrying their own `#+TODO:` header. TODO.org does;
a new file will not unless you give it one.

## Keywords

Per-keyword meanings are in the **org skill**. Project policy on top of it:

- `REVIEW` is **experimental** (TODO.org `:ID:` c954f650): finished and
  handed back for human judgement, as distinct from `WAITING`, which means
  blocked on someone else. Its fate is not settled.
- Priority is expressed through keyword choice, not `[#A]`/`[#B]`/`[#C]`
  cookies. **Do not add priority cookies.**

## Tags

The four standard tags (`:code:` `:comms:` `:research:` `:review:`), their
meanings, and the archiving convention are in the **org skill** — including
the per-heading `:ARCHIVE:` override. Tags are free-form beyond those four;
declare additional ones in `#+TAGS:`.

Don't write the same tag twice on one headline. `org-get-tags` does not
deduplicate, so `:code:code:` survives untouched and org-lint says nothing;
`bin/lint-org` reports it as an error. It happens when a tag is appended to
a headline by hand without checking what is already there.

## Top-level headings, and the category they used to be

**Since 2026-08-27 (`:ID:` 29439196) a top-level heading is a *task*.** The
level-1 category tier is gone: a task's grouping is declared on the task
itself, as `:CATEGORY:`, rather than inferred from its position in the tree.
Level 1 is therefore where `:ID:`, `:CREATED:`, a TODO keyword and tags all
belong — the exact inverse of the rule that stood here before, which is
quoted below because a reader of older commits will meet it.

One exception, and it is structural rather than a carve-out: **`* Review and
planning` remains a level-1 container**, because org-datetree's
year/month/day scaffolding is an irreducible tree. Real tasks that used to
sit beside that scaffolding were moved out to level 1; level 2 beneath the
anchor now holds nothing but org's own nodes.

### The ten values

Settled 2026-08-28 (`:ID:` 29439196, step 2). Single words, capitalised, so a
value is distinguishable at a glance from a TODO keyword and from a tag:

| value | what belongs here |
|---|---|
| `Queue` | the event queue itself — events, guideposts, spans, attribution |
| `Apply` | the review buffer and the apply pass over that queue |
| `Clock` | clock correctness proper — intervals, CLOCK lines, org-clock state |
| `Skill` | what an agent must follow: CLAUDE.md, the skills, these conventions, keyword semantics |
| `Tools` | the `org_*` MCP surface and its behaviour |
| `Dev` | the repo's own machinery: `bin/`, lint, tests, hooks, packaging, the Doom and shell environment |
| `Meta` | the meta-work datetree and the daily ceremony — the day node, archiving |
| `Slices` | slice machinery: composition, refresh, the blocker and the cookie |
| `Docs` | prose written for a human reader — README, procedures |
| `Upstream` | defects belonging to `claude-code-ide.el`, not to this repo |

**`Tools` versus `Dev` is one test: `Tools` is what Claude calls, `Dev` is
what a developer runs.** They split 26/26 without being forced, which is why
the seam is trusted. Note `Dev` names an *audience* where the others name
subjects — read alone it would swallow the file, and the bound comes entirely
from its sibling.

**Not `Review`, deliberately.** `REVIEW` is also a TODO keyword, so
`:CATEGORY: Review` would render an agenda line as `Review  REVIEW  Some
task` — the one value that defeats the reason these are capitalised. It also
read to its daily reader as naming the ceremony rather than the apply
subsystem. `apply` is the project's own word for it by a wide margin.

### Where the nine old labels went

None mapped one-to-one but `Slices` and `Upstream`; the point of the exercise
was that the big labels were compound.

| was | became |
|---|---|
| Clock lifecycle & visibility (76) | Apply 30, Clock 24, Queue 15, Skill 2, Meta 2, Docs 1, Tools 1, Dev 1 |
| Skill logic (50) | Skill 23, Tools 21, Queue 2, Slices 2, Clock 1, Docs 1 |
| Tooling (32) | Dev 23, Skill 4, Slices 2, Tools 2, Meta 1 |
| Observability (15) | Queue 6, Skill 2, Apply 2, Meta 2, Slices 1, Clock 1, Tools 1 |
| Review and planning (6) | Meta 5, Apply 1 |
| Bigger swings (6) | Skill 3, Dev 2, Tools 1 |
| Slices (2) | Slices 2 |
| Documentation (2) | Slices 2 |
| Upstream (claude-code-ide.el) (1) | Upstream 1 |

Two findings worth keeping, because they generalise past this file. The
compound label really was three subsystems — 76 splits close to evenly across
`Apply`, `Clock` and `Queue`. And **`Skill logic` was exactly as compound
while containing no conjunction to give it away**, splitting 23/21 between
`Skill` and `Tools`: the "only two names contain an `&`" heuristic points true
where it fires but is silent on a label that hides two subjects behind one
word.

`* Review and planning` carries `:CATEGORY: Meta` on the anchor itself, since
org-datetree's day nodes have no drawer of their own and would otherwise
inherit the file name.

### What each old category meant

A `:CATEGORY:` value is a bare string, so the prose that used to live in a
category heading's body had nowhere to go in the file. Preserved here
verbatim; it was the input to the taxonomy work above:

- **Clock lifecycle & visibility** — "Everything here is specifically about
  the clock subsystem's correctness and observability, as opposed to the
  general TODO-state machine above — three different angles on 'make sure the
  clock is never silently wrong.'"
- **Observability** — "Broader than clocking — visibility into what every
  tool call actually did, both after the fact and at the start of a session."
- **Bigger swings** — "Significant directions this project has not committed
  to. Think hard before building any of them."
- **Upstream (claude-code-ide.el)** — "Issues found against the third-party
  `claude-code-ide.el` (manzaltu/claude-code-ide.el) package itself, not this
  repo's own code — worth reporting upstream but not this repo's work to fix."

`Slices`, `Documentation`, `Skill logic` and `Tooling` carried no body prose
and lost nothing.

### The rule that stood until 2026-08-27

Top-level (`*`) headings in `TODO.org` were epics — pure
structure, grouping related tasks — not tasks in their own right. They carried
no `TODO` keyword, no tags, and **no task metadata**: no `:ID:` and no
`:CREATED:`, overriding the general "every heading creation" rule for this
one case.

**"No task metadata", not "no properties drawer"** — narrowed 2026-08-17.
The rule's purpose is that a category must not look like work, and its
concrete targets are `:ID:` and `:CREATED:`. A *structural* property, which
says something about the grouping rather than about work, is permitted.
`bin/lint-org` has always read it this way: it checks `:ID:`, `:CREATED:`,
the TODO keyword and tags, and nothing else.

The case that forced the wording is `:ARCHIVE:`. Each category carries
`:ARCHIVE: DONE.org::* <its own title>`, which is how archived work lands
under a matching category in DONE.org instead of one flat `* Done` pile.
The property is inherited, so one line per category routes every task
beneath it.

Two consequences worth knowing:

- **Renaming a category means updating its `:ARCHIVE:` and the matching
  DONE.org heading in the same edit.** The target is matched as a literal
  string, and a mismatch does not error — org silently appends a second,
  near-identical category heading at the end of the file.
- **Don't archive a child directly unless you are promoting it to a sibling
  in the same move, explicitly.** Archiving a level-3 heading lands it at
  level 2 under the category — a sibling of its former parent — with only
  `:ARCHIVE_OLPATH:` recording where it came from. That promotion is a real
  decision and sometimes the right one, so it isn't forbidden; what's
  forbidden is arriving at it by accident. Archiving the level-2 parent
  takes the child along and keeps the nesting, which is the default.

Actual tracked work lives as their level-2+ children, each with its own
`:ID:`. Don't put a `TODO`/`NEXT`/etc. keyword on a top-level heading — if
one needs to represent actionable work rather than group children, demote
it: give it an `:ID:` and treat it like any other task, or nest it a level
deeper under a category heading.

A **story** is not declared, it is emergent: a task that has acquired
children carrying TODO keywords. Detectable via
`claude-code-ide-org--container-heading-p` — "container" is the code's
older word for a story. Don't classify a heading as one when writing it.
An **epic** is the separate thing: the grouping a task belongs to,
carried on the task as a `:CATEGORY:` value since 2026-08-28 (`:ID:`
29439196). It is declared, where a story is emergent — which is why one
is written down and the other must never be.

**A heading with TODO-carrying children carries a statistics cookie.** Add
`[/]` to the headline and let org fill it in
(`org-update-statistics-cookies`, `C-c #`); `[%]` works too. The point is
that a container's progress is readable without unfolding it — with
`#+STARTUP: content` folding every body by default, the cookie is often the
only thing distinguishing a container that is nearly finished from one that
has not started.

Add it when the *first* child appears, since that is the moment the heading
becomes a container. `bin/lint-org` reports a missing cookie as an **error**,
so a commit will refuse: unlike `:CREATED:`, the count is derived from
structure and can be retrofitted honestly, so there is no reason to let it
slide. The check tests only that a cookie is *present* — org owns the
arithmetic.

## Slices

A **slice** is a declared grouping: a sequenced set of tasks asserted to
belong together for a reason the tree does not encode. Unlike a story,
which is emergent and detected from its keyworded children, a slice
cannot be derived — so it is written down as an explicit list, and being
written down, it can go stale.

Slices carry `:CATEGORY: Slices`. They used to live under a level-1
`* Slices` heading; the flattening retired that tier (`:ID:` 29439196),
so a slice is an ordinary top-level heading whose category says what it
is. Each carries an `:ID:`, a `:CREATED:`, and a
`:COOKIE_DATA: checkbox recursive` property so its statistics cookie
counts nested members as well as top-level ones.

**The statistics cookie itself is not yours to remember.** A slice's
headline carries `[n/m]` over its checkbox list, and
`M-x claude-code-ide-org-refresh-slice` now *inserts* the `[/]` when it
is missing rather than only recomputing an existing one. `bin/lint-org`
reports a cookie-less slice as an **error** as a backstop.

**It goes immediately after the TODO keyword** — `* DOING [6/11] Close
the gap …`, not at the end of the title. Measured across both files:
**13 of 14 cookies sit there**, and the single trailing one had been
written by `--ensure-statistics-cookie-at-point`, which is now fixed to
match.

Two reasons, and the second is why it is not merely cosmetic. A trailing
cookie is the part a narrow agenda window or a folded outline truncates
away — which defeats the one thing the cookie is for, that progress is
readable *without* unfolding. The user reported the current slice as
"missing its cookie" on exactly that basis; it was present, at the end
of a line they could not see the end of.

*Recorded because the way this was got wrong generalises.* An earlier
version of this paragraph said the opposite, having read the convention
off the inserter's source rather than off the corpus — inferring a
declared thing from the one mechanism that happened to implement it,
which is the error `:ID:` 979e02b6 exists to close. The corpus was 13:1
against the code, and nobody had asked it.

Both halves were added 2026-08-26 (`:ID:` 28415ca8) because relying on
the creator to type `[/]` failed on the second slice ever written.
`org-update-statistics-cookies` updates a cookie and never inserts one,
and the container cookie rule asks "has TODO-carrying children", which a
slice never does — so three separate mechanisms declined to mention it
and `:ID:` 979e02b6 ran most of its life uncookied. The lint rule is a
*second* clause rather than a widened predicate, since the two rules
count different things: children, versus checkbox members.

**Members are `[[id:...]]` links in a checkbox list**, not child
headings.

**When a member is a story, its relevant children get indented member
lines beneath it** — added 2026-08-28. Not *every* child: the ones that
belong to this slice, and *especially* any child that blocks another
member, since a cross-member dependency is invisible from either side
otherwise. Which children belong is a judgement, so it is **declared**
like any other membership; only the rendering is derived, and
`refresh-slice` already regenerates indented lines exactly as it does
top-level ones. A story whose children are all irrelevant to the slice
appears as a single line, which is correct rather than incomplete.

Two consequences. The nested lines count toward the cookie, because
`:COOKIE_DATA: checkbox recursive` is what that property is for. And an
unfinished child enters the `:BLOCKER:` on its own account, which is the
point: a slice that names a story is not finished when the story's
*relevant* parts are outstanding.

Prefer nesting a child over listing it at top level or leaving it as
*incidental*. A child promoted to a top-level member loses the fact that
it belongs to something; one left incidental claims it was unrelated to
the plan when it was the plan's own subject. `478d6ec9`'s children were
five incidentals and four absentees before this rule; they are now nine
indented lines under their parent.
Write the link so it displays the 8-character prefix, and put the
referent's keyword and title *outside* the brackets:

```
- [X] [[id:49557477-e50c-496f-85df-82c65109832b][49557477]] DONE Expand an 8-character prefix ...
```

The link target is the only part that cannot go stale; keeping the
keyword and title as plain text alongside it makes the copy visible
*as* a copy.

**Two things about where a slice's list may live**, both found by
breaking them 2026-08-28 while composing `:ID:` b36e6369.

*The member list must sit in the slice's own body, above any subheading.*
`--slice-members` scans the heading's own body and stops at the first
subheading, so putting the list under a `** Members` section takes the
whole thing out of reach. It fails **silently and in the worst
direction**: the refresh finds zero members, writes an empty `:BLOCKER:`,
and the slice reports `[0/0]` as though it were empty rather than broken.

*Do not write `- [[id:...]]` bullets as prose inside a slice body.* A
cookie-less list item carrying an id link is exactly the shape reserved
for a cancelled or deferred member, so prose bullets naming ids are read
as members with their cookies deleted. Name ids as `=c74f8663=` in prose
instead. `orgit-rev:` links are safe, which is why the plan-revision
list at the end of a slice body works.

**A slice declares itself with a `:KIND: slice` property**, not by where
it sits or what its body looks like. "Has a checkbox list of id links" is
not a structural fact — an ordinary body may hold one for reference — so
unlike an epic, which is *derived*, a slice must be *declared*. Read
without inheritance, so a subheading of a slice is not one.

**Not `:CATEGORY:`**, which is the obvious org-native candidate: `:ID:`
29439196 already assigns it to *epic assignment* — "a label, carried by
headings, not a place they live". Sharing one property would make
`:CATEGORY: X` undecidable, since nothing would say whether `X` names an
epic or a kind. They also answer different questions: a category says
what a heading is *about*, a kind says what it *is*, and a slice belongs
to no epic by design while certainly being a slice.

A tag was tried first and lasted an hour. When the tags on the first
slice were deleted as inadvertent, the lint assertion built on them went
**silently inert** — zero errors because nothing was a slice any more,
which reads exactly like nothing being wrong. A declaration whose removal
is invisible is the wrong declaration. `:KIND:` was not coined for this:
`:ID:` 8ca6541d had already named it as the missing property while
listing four heading classes each detected by a different bespoke
mechanism.

**A slice carries a `:BLOCKER:` naming exactly its members that are
cookie-carrying and not yet done**, so it cannot reach `DONE` before they
do. Derived, never authored — `M-x claude-code-ide-org-refresh-slice-blocker`
writes it from the checklist, and `bin/lint-org` reports an **error** if
the two disagree in either direction. The checkbox list is the human half
and the blocker the machine-readable one; redundancy without a check is
just two things that can disagree.

**So the property shrinks as the slice progresses**, and is gone entirely
once every member has landed. Narrowed 2026-08-28 (`:ID:` 0086614a) from
"every cookie-carrying member". That was harmless while a slice held only
its planned members, but a slice also lists the *incidental* work that
closed during its life, and every one of those is done on arrival — they
would enter the blocker at birth and never leave, making a
machine-readable property long enough to stop being readable while
changing nothing, since `org-depend` does not block on finished work.
Nothing is lost: membership is recorded by the checkbox list, and the
blocker only ever answered "what still has to finish".

A member whose cookie was **deleted** is deliberately *not* in the
blocker set. Cancelled is harmless either way, but a **deferred** member
is unfinished, so blocking on it would hold the slice open forever for
work it explicitly decided not to do. Cookie and blocker are the same set
by construction.

**The checkbox is derived from the referent's keyword, not chosen.**
There is no judgement in it, and a slice that disagrees with its
referent is simply stale:

| referent keyword     | checkbox    |
|----------------------|-------------|
| `DONE`               | `[X]`       |
| `DOING` `REVIEW` `WAITING` | `[-]` |
| `TODO` `NEXT`        | `[ ]`       |
| `CANCELLED` `MAYBE`  | *no cookie* |

**A cancelled or deferred member has its checkbox cookie deleted
entirely**, leaving a plain `- ` list item, so it neither counts against
the numerator nor inflates the denominator. The line stays, because the
record of having considered and dropped something is what a bare list
loses.

**A closed slice stops being derived, and is left alone.**
`claude-code-ide-org-refresh-slice` skips a slice whose own keyword is
terminal. Member lines are copies of referents' keywords, and referents
keep changing after a slice is done — so refreshing a closed one lets
unrelated later work rewrite finished history. Observed on `:ID:`
c44c2119: a member that was `CANCELLED` when the slice closed was
reopened two days later, its cookie and its `:BLOCKER:` entry both came
back, and a `DONE` slice silently became `[27/28]` and blocked again
(`:ID:` 30a340fd).

So a cookie-less line in a *closed* slice does not mean "this was
cancelled" — it means the slice is **done with** this member. Anything
you want to know about what the member is doing now is in its own
`:LOGBOOK:`, which is where that question belongs.

Because every field is derived, **the only things a slice declares are
membership and order** — which headings belong and in what sequence. If
a checkbox looks wrong, either the slice needs regenerating or the
*referent's keyword* is under-reporting; the fix is never to set the box
by hand. Regenerating is `:ID:` 0acc1df2, and belongs immediately after
apply.

**A slice carries state but never a clock.** Its `:LOGBOOK:` records
state transitions only; every referent already carries its own clock, so
clocking the slice would add a second quantity inside the one that
already exists and could not be told apart from the sum. **Enforced
since 2026-08-26** (`:ID:` 95c27fca): both triggers now consult
`claude-code-ide-org--grouping-heading-p`, which recognises a slice by
its `:KIND:` declaration as well as a container by its children, so
hand-setting `DOING` on a slice opens nothing.

Note this is stricter than the rule for a *story*, and deliberately.
A story may be clocked deliberately, because a parent's own coordination
time is real (`:ID:` 3964c575, decided 2026-08-26). A slice may not,
because it is a sequencing declaration rather than a place work happens
— there is no coordination to record that is not already one of its
members'.

**The plan that drove the slice is linked at the end of the body, as one
`orgit-rev:` link per revision of it.** `.claude/commands/next-session.md`
is rewritten in place, so a single reference names whatever it says today
rather than what it said when the slice opened. Each commit that revised
the prompt gets a link, oldest first, with its date and what the revision
did:

```org
- [[orgit-rev:claude-code-ide-org::97e1ef2][97e1ef2]] [2026-08-24 Mon 15:39] defined the slice
```

This is deliberately *not* the `plans/` pattern. A copied snapshot was
built first and removed the same day (`:ID:` 637ee73d): `plans/` exists
because `~/.claude/plans` is outside the repo and would otherwise have no
history, whereas this file is committed and only lacks a stable identity
— which is exactly what an `orgit-rev:` link is, at no cost in sync
scripts or drift checks.

**Several links, not one, is what lets a slice outlive a session.** A CLI
restart or a cleared context is a *revision of the prompt*, not a new
slice, so unfinished members stay put instead of being deferred into a
successor slice that has not earned them. Deferral proliferates mentions
of tasks that were planned and never reached the top of the stack; a
slice that can span sessions mostly removes the need for it.

Note the links cost nothing in `bin/lint-org` as of 2026-08-25 (`:ID:`
43201e64) — before that each one added a permanent unresolvable-location
warning, which would have made this convention degrade the report a
little more with every slice.

### Dropping a member from a slice

**Delete the checkbox cookie; keep the line.** `- [X] [[id:…]] …` becomes
`- [[id:…]] …`. That is the whole mechanism, and it was already in the
code before it was written down here — `--slice-member-regexp` makes the
cookie optional and names group 1 *"absent for a cancelled or deferred
member"*, and `--slice-blocker-ids` excludes such a line deliberately: a
deferred member is *unfinished*, so blocking on it would hold the slice
open forever for work it explicitly decided not to do.

**Keeping the line is the point.** The slice declared that member; deleting
the line would make the slice read as though it never had, which is the
same falsification `:ID:` 30a340fd refused for closed slices. A cookie-less
line still parses as a member, so it is not re-listed as incidental
either — it says *this was planned here and is no longer counted*, which
is exactly the fact.

**It covers three cases and does not distinguish them**: cancelled,
deferred, and moved. The line's absence of a cookie says only that the
slice no longer counts it.

**When the work moves to another slice, it is copied there with its cookie
intact** — the receiving slice counts it, the origin does not. Do not
leave a cookie in both: a member counted twice makes two slices' cookies
disagree about the same work, and measured 2026-09-02 that also let a
*shared* member's clock open an unstarted slice's incidental window,
which took two fixes to close.

**Say why, in the slice's body.** The mechanism records that a member was
dropped; only prose records why, and a slice that silently stops counting
something reads as having forgotten it — which is the failure `:ID:`
c60a1c53 exists to detect.

### Proposing a slice

**A proposal is a slice with the declaration withheld.** It has the
checklist, the theme and the ordering — everything a slice has — but no
`:KIND: slice`. Withholding is not bookkeeping: *declaring is the act of
committing*, so a heading without the declaration is precisely a
proposal. It also keeps the checklist outside `bin/lint-org`'s slice
rules until someone means it, which matters because the absent
`:BLOCKER:` would otherwise be an error against a list nobody agreed to.

**It carries no prompt link**, for the same reason — there is no
`next-session.md` revision driving a proposal, and there will not be
until it is picked up.

**It lives exactly where a slice lives**, with `:CATEGORY: Slices`. The
question of a separate location was open while slices sat under a level-1
`* Slices` heading; the flattening dissolved it, and a distinct location
would be a *second* copy of the fact the missing `:KIND:` already
carries — the duplication this project rejects everywhere else.

**Its keyword is `MAYBE`.** The original argument for this was that
`MAYBE` would stop the sole-TODO promotion trigger nominating a proposal
as a next action; **that argument has expired**, since the trigger was
retired (`:ID:` 62b65ad0). The surviving one is better: `MAYBE` *means*
not committed, which is exactly what a withheld declaration says, and it
keeps the proposal out of the un-nominated-container report. Its
`:BLOCKER:` being dormant on a `MAYBE` heading is correct here rather
than a defect — the checklist is not agreed yet.

**Accepting one is three mechanical steps**: add `:KIND: slice`, run
`claude-code-ide-org-refresh-slice` so the blocker and cookie appear, and
link the prompt revision that picks it up. Worth a single command if
proposals become routine; three calls until then.

**Rejecting one is `CANCELLED`, and the body stays.** The argument for a
slice nobody ran is usually the part worth keeping.

## The `:PLAN:` drawer

**Write the plan into the drawer from the start.** A heading's prospective
prose — motivation, options, the reasoning behind an approach, and the
`[[file:~/.claude/plans/...][Plan]]` link if there is one — goes into `:PLAN:`
at the moment it is composed, not at `DONE`. The body carries a brief
statement of the problem and the proposed solution, two to five sentences. At
`DONE` the debrief is appended to the body.

So the two halves are never mixed and **no seam is ever created**, which is
the entire point. The seam is a fact about *when* a sentence was written;
nothing in the prose records it, and it is not recoverable afterwards.
Measured on `:ID:` f099379b: a lexical marker finds the prospective half as
often as the retrospective one, and 88 of 93 finished headings carried a
debrief that a blind wrap would have buried.

Compose it in three calls — `org_amend` the prospective prose, `org_wrap_plan`
with no seam marker to move it whole into the drawer, then `org_amend` the
short body. `org_amend` appends *below* a `:PLAN:` drawer, so the debrief
later needs no special handling.

The two-to-five-sentence limit governs the body **before** the debrief, not
forever. A finished heading's body is that statement plus the debrief. Read as
an absolute cap it would push the debrief into the drawer, which is the
inversion this convention exists to prevent.

**Which way to read the drawer depends on the keyword, and this reverses
earlier advice.** On a **finished** heading, treat `:PLAN:` as absent unless
the question is retrospective — "how did we get here", "why this way". The
debrief and the source describe present reality; the plan describes an
intention that may not have survived contact, and reading it for current fact
is how superseded design claims get repeated as though they still held.

On a **live** heading the drawer holds the *current* plan, and skipping it
means skipping the only full statement of what the task intends. **Read it.**
The drawer's status follows the heading's keyword rather than being a property
of the drawer, which is why nothing has to move when the heading closes.

**An empty `:PLAN:` drawer is a real answer, not an accident.** A heading
written outcome-first has no prospective half at all, and that is the
convention working rather than a heading missing a step. Pass the debrief's
first line as the seam and `org_wrap_plan` writes an empty drawer, recording
that the question was asked and answered; the whole body stays visible.

`org_wrap_plan`'s seam marker is now a **retroactive** tool. A heading written
under this convention never needs one, because its body was never mixed. It is
for bodies written before the convention existed, which usually hold both
halves — see `:ID:` 35d25265 for the pass over those, and note that pass's
one-off exception (wrap the whole body, leave a pointer note) is explicitly
**not** available to new headings.

This is also what makes the lint's question answerable. `bin/lint-org` warns
when a finished heading has a substantial body and no `:PLAN:` drawer, and
`org_set_todo` says the same thing at the moment `DONE` is queued — which is
the last moment anyone knows where the seam is. Before the empty drawer
existed, the only way to satisfy the warning on a debrief-only heading was to
wrap the debrief into a drawer readers are told to skip. See `:ID:` f421c5c3.

## Citing code from a body

**Cite the symbol, never a line number.** `file.el:NNN` is deprecated in
org bodies (`:ID:` 5fc7b934), extending the rule the skills already
follow — `bin/check-org-dev-skill` exists partly because the org-dev
skill describes the tool-registration block *structurally*, "specifically
so a `config.el` edit that shifts line counts can't put the doc out of
date."

**The form rots upward, which is what makes it worse than a broken
link.** The file grows, the cited line still exists, and it now holds
something else plausible. It resolves, and it resolves to the wrong
thing — a dangling reference at least announces itself.

**The measurement that settled it:** every one of the eight live anchors
in the corpus already named its symbol in the same sentence, so the line
number was carrying nothing the symbol did not. Deleting it lost
information in exactly zero cases.

`bin/lint-org` reports one as an **error** on a live heading, because the
correct form is mechanical. A *closed* heading's anchor is left alone: it
is a historical statement — "this was true at `config.el:2792` on
2026-08-21" — and rewriting it would falsify the record rather than
repair it. 38 stand in the corpus and are not to be touched. A live
heading that closes carries its anchor into `:PLAN:` with the rest of the
prospective half, which is how the citation stops being a live pointer
without anyone editing prose.

## The meta-work datetree

`* Review and planning` carries `:DATE_TREE: t`, which is what makes org nest
the year/month/day tree *inside* the category instead of writing a second
`* 2026` at level 1.

**A real task sits beside the tree, at the same depth as the year node:**

```
* Review and planning          :DATE_TREE:
** TODO Open today's node      <- a real task, level 2
** 2026                        <- org's scaffolding, also level 2
*** 2026-08 August
**** 2026-08-24 Monday         <- carries :ID:, and is what time is clocked against
```

That collision is the whole reason `claude-code-ide-org--datetree-node-role`
gates on org's literal title shapes rather than on depth. A depth-only test
would read every ritual heading as scaffolding and waive `:ID:`/`:CREATED:`
for it — and the day node is the one heading here that most needs them,
since every tool addresses headings by `:ID:` and time is clocked against
that node.

Year and month nodes carry neither `:ID:` nor `:CREATED:`; the day node
carries both. `bin/lint-org` knows the difference.

## Heading separation

**Every heading is preceded by exactly two blank lines**, at every level and
whatever its TODO state; the last heading in a file is the only exception.
The *why* — that `org-cycle-separator-lines` defaults to 2, so two lines in
the file buy one visible line of air in a folded outline and one line buys
none — is in the **org skill**, along with the corpus measurement that
retired the older same-level-only version of the rule.

What is project-specific is that **it is maintained by a normaliser, not by
hand**: `M-x claude-code-ide-org-normalize-heading-separation`, which takes
an optional file and a dry-run flag. The count is
`claude-code-ide-org-heading-separator-lines`, default `2` — set it below
`org-cycle-separator-lines` and the convention still changes the file but
stops being visible anywhere, which is the one way to get it wrong.

**It is a normaliser, not a migration, and that distinction is the reason it
has to be re-run.** Applying queued events inserts lines without the
convention, so the files drift out of it as a matter of course rather than
by mistake. It has been re-run twice since it first shipped for exactly that
reason. Run it in the same sitting as the drawer consolidation sweep and
before the archive step below — the order in "Archiving" is where it belongs,
not as its own ritual.

**The safety property is worth knowing before running it on a dirty tree.**
It touches only the run of blank lines immediately preceding a heading,
found by walking back from the next heading and stopping at the first
non-blank line, so the edit cannot reach text. Verified on its first run
over both files: 224 insertions, 37 deletions, and zero changed lines
carrying any character.

**Not asserted by `bin/lint-org`.** Nothing fails when the files drift, so
the convention holds only as long as the normaliser is actually run — and it
does drift: measured 2026-08-25 by the normaliser's own dry run, TODO.org
had 18 of 168 headings off the convention while DONE.org had 0 of 104.
(Those denominators exclude each file's last heading, which the convention
exempts.) The asymmetry is the mechanism
showing itself. DONE.org is written by archiving, which moves whole
subtrees; TODO.org is where applies and `org_amend` land, and both append
without the trailing lines.

## Archiving

**Both terminal keywords are archived, not just `DONE`.** `org-done-keywords`
is exactly `("DONE" "CANCELLED")`; the other seven are not-done. A sweep
filtering on `DONE` strands every abandoned heading permanently, because
nothing else ever removes one.

Read finishedness from `claude-code-ide-org--outline-finished-keywords`, not
from `org-done-keywords` — the latter is **buffer-local and nil outside a
visited org buffer**, so a filter using it from the wrong buffer silently
passes everything.

**Order: apply the queue, consolidate the drawers, then archive.** Never
archive first. Apply resolves a heading by `:ID:` through `org-id`, so a
pending event lands wherever the heading now lives; applied after a move it
executes inside DONE.org. And archiving is the *last* moment a heading is
ever touched, so a drawer out of order when it moves stays that way forever
— which is how 13 of the 25 drawers archived since consolidate-on-apply
shipped came to be disordered.

**A `CANCELLED` heading needs no outcome summary.** CLAUDE.md's rule names
`DONE` only, and that asymmetry is deliberate: `CANCELLED(c@)` carries an
`@` cookie, so org already prompts for the reason at the transition and
captures it where it happens.

**Where archived work lands is unsettled** — per-category `:ARCHIVE:`
routing today, versus a `datetree/` location. Don't switch unilaterally;
it would break `bin/lint-org`'s datetree rule until the question is
settled.

## Referring to a commit

A 7-hex SHA and an 8-hex `:ID:` prefix look identical in running text, and
this project cites both constantly. Distinguish them.

**In an org body, link it.** `orgit` is installed and its link types are
registered:

```org
[[orgit-rev:claude-code-ide-org::b146008][b146008]]
```

**Use the repo *name*, never a path.** `orgit--repository-directory` resolves
a name from `magit-repos-alist` before falling back to `expand-file-name`, so
the named form is machine-independent while a path form hard-codes one
machine. The Doom config sets `magit-repository-directories` to `("~/git/" . 1)`,
which names every repo there by its basename — verified 2026-08-21 to resolve
`claude-code-ide-org` to the right directory.

The link renders in org's link face — a stronger cue than verbatim — and
opens the commit in Magit. Use `orgit-log:` for a range.

**There is no implicit "the repo this file is in".** Nothing resolves that;
relative forms (`./…`) work but resolve against `default-directory`, and here
that is unreliable — `~/org/claude-code-ide-org/TODO.org` is a *symlink* to
the copy in the repo, so which directory a buffer reports depends on which
path opened it, and via the agenda path it is not a git repo at all.

**Prospective only.** The 25 existing `(=535c98c=)` references stay; there is
nothing wrong with them and rewriting them is churn.

## Dependencies between tasks

Use a `:BLOCKER:` property naming the blocking heading's `:ID:` rather than
a prose "depends on ..." sentence — a property is machine-checkable and a
sentence isn't. The org skill has the full syntax, including the inverse
`:TRIGGER:`.

**It is enforced.** `org-depend` is required in the Doom config, so
`org-depend-block-todo` is live on `org-blocker-hook` and will refuse a
`DONE` while any listed `:ID:` is unfinished. This project's own
`claude-code-ide-org--blocker-clock-running-p` sits on the same hook but
blocks on a *running clock* instead — two different guards, so don't assume
a refused transition came from the project's one.

**But a `:BLOCKER:` on a `MAYBE` heading is dormant**, because org
evaluates blocking against the *blocked* heading's own state: nothing
blocks a heading that is not trying to move. The property looks like a
live dependency and enforces nothing.

That is the worst shape a dependency can take. The whole point of
`:BLOCKER:` over a prose sentence is that it is machine-checkable, so one
that reads as enforcement and enforces nothing is *less* honest than the
sentence it replaced. `bin/lint-org` warns on it — three times in
TODO.org as of 2026-09-02 — but a warning with no rule behind it is
easy to dismiss.

**What to do:** keep it. A `:BLOCKER:` on a `MAYBE` is a record of a real
dependency that will wake by itself the moment the heading takes a live
keyword, and deleting it to silence the warning would lose that. Read the
lint line as "this is filed, not enforced" rather than as a defect to
clear — and if you are relying on the block to hold, the heading is not
`MAYBE`.
