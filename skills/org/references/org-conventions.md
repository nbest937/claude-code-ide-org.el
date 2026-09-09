---
paths:
  - "**/*.org"
---

# Org-file conventions

Loaded only when working with `.org` files. Rules that must hold whether
or not an `.org` file is open — the state transition rules, when to
create a heading at all, the queue architecture — live in the
always-loaded machinery rules instead (`org-state-transitions.md`,
`org-event-queue.md`, promoted alongside this file by
`claude-org-setup`): a path-scoped rule that does not load is a rule
that does not apply, and the failure is silent.

## File header

Every `.org` file in this project should start with:

```org
#+TODO: TODO(t!) NEXT(n!) DOING(d!) REVIEW(r!) WAITING(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)
#+TAGS: code comms research review
#+ARCHIVE: DONE.org::
#+STARTUP: logdrawer logdone content
```

The per-keyword cookies matter: `!` records a timestamp on entry, `@`
*prompts for a note*. See the state-transitions rules for why that
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

### Category values

The values are per-project — a repo declares its own taxonomy (this
plugin's home repo keeps its ten in
`.claude/rules/org-conventions-local.md`). What transfers is the shape:
single words, capitalised, so a value is distinguishable at a glance
from a TODO keyword and from a tag — and never a word that is *also* a
TODO keyword, which would render an agenda line as `Review  REVIEW  Some
task` and defeat the reason the values are capitalised.

### One top-level NEXT per category

Settled 2026-09-03 (`:ID:` 758a8b78). **At most one level-1 heading per
`:CATEGORY:` value carries `NEXT`**, the Slices category included — so
within Slices, mechanism work and actually starting a slice compete for
the one nomination. That competition is a deliberate forcing function,
not a side effect: picking one up is a decision, never a drift. Measured
at adoption, the five live NEXTs sat in five distinct categories, so the
rule landed with zero demotions.

Two exemptions, one per grouping kind. A story's **internal** `NEXT` —
at most one, kept by `--trigger-demote-conflicting-next` — does not
count against the budget: it is a memoization of where it has been
determined best to start upon entering the story, weighing its members
against each other. And a slice's member list may show **several**
`NEXT`s: members are references, so those are other groups' nominations
showing through — a useful signal when formulating the slice's plan, not
a violation. Two members of the *same* story still cannot both be
`NEXT`; the story's internal limit wins.

Nothing enforces the budget yet, deliberately — the rule is days old,
and the project's precedent is observation before machinery.
`bin/lint-org` is the natural home when it earns a check.

### Closing a member nominates the next

**Every transition to `DONE` inside a grouping nominates the next
action**: set `NEXT` on whichever remaining member should be picked up
next, or say in a sentence that no clear candidate exists. Leaving the
group silently un-nominated is the thing to avoid — GTD's actual
invariant is that a live project always has a next action, and a project
without one is the canonical defect a weekly review exists to catch.
Closing a *top-level* task nominates nothing: it has no group, and
several top-level `NEXT`s at once are expected and correct — at most one
per `:CATEGORY:` (above).

**And the same moment files the residue.** Any work the closing debrief
names as *not done* becomes a filed heading before the `DONE` is queued —
or the debrief says explicitly that it is not worth filing. **A sentence
pointing at another heading is not a filing action**, and neither is
"belongs to X". Residue named in a closed heading's body sits in a
document readers treat as history, and a later `:PLAN:` sweep can bury it
in a drawer readers skip — it is on a path to invisibility from the
moment it is written. Both halves happened in one session, hours apart
(`e1284bdb` was closed correctly after its unfinished half was filed as
`601c885c`; `aa1ba915` was closed with its gap described only in prose,
caught by the user a day later), and nothing distinguished them at the
time.

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

**`bin/lint-org` reports a slice without it as an error, and checks the
*value* rather than mere presence** (`:ID:` b6da3480). Both words are
load-bearing: `checkbox` because a slice's members are list items rather
than TODO children, of which it has none by definition, and `recursive`
because a member that is a story carries indented child lines that org
otherwise excludes from the count. `:COOKIE_DATA: todo` is well formed
and would give a cookie that can only ever read `[0/0]`.

*Added while the corpus was clean, after it had already bitten once.*
The property is required by convention, defaulted by nothing and
consulted only by org, so its absence is invisible until a slice nests a
member — at which point the headline silently recomputes to exclude every
indented line. On 2026-09-04 `:ID:` ff7ccb2d recomputed to `[0/9]`
against twelve checkboxes; the hand-written `[0/12]` had been right and
org's own recount made it wrong, which is the worst direction for a
defect to arrive from. Two of seven slices lacked it, one bitten and one
latent.

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

**The planned checklist is introduced by a `Planned:` lead line** —
column zero, on a line of its own, directly above the first member —
symmetric with the machine-written `Incidental:` lead below (adopted
2026-09-09 from `:ID:` c5e58ea1, the surviving half of the
section-subheadings proposal; made load-bearing the same day,
`:ID:` a43cfaa0). Both leads are parsed: `Incidental:` bounds the
section the refresh rewrites, and `Planned:` anchors the *start* of
the planned member region — which is what dissolves the old
prose-bullet trap: a `- [[id:...]]` bullet in the theme prose above
the lead is ordinary prose, not a member with a deleted cookie. The
lead is maintained, not remembered: the refresh inserts a missing one
above an existing checklist (reported in its summary), and
`org_slice_add_member` writes it when a checklist is born. Where no
lead exists the member scan falls back to the body start — closed
slices predate the lead and are never refreshed, so the fallback is
permanent, and the prose-bullet caution still applies to them. Both
leads are also navigation anchors (grep, occur, isearch; imenu via an
`imenu-generic-expression` entry). Actual subheadings were measured
and declined (`c5e58ea1`): a headline checkbox cookie cannot count
boxes past a child heading — org's "recursive" means nested lists,
verified at source — and every member derivation stops at the first
child, so sections would zero the cookie and blind the refresh.

**A heading joins a checklist only once it exists on disk with its
keyword** (`:ID:` 2d2211d5, choosing the candidate `798bb7a1` closed
without picking). Both lint rules are right and both fire at once on a
keyword-less referent: naming it in the `:BLOCKER:` is an error because
`org-depend` acts only on an unfinished keyword, and omitting an
unfinished member from the `:BLOCKER:` is also an error — so
`.githooks/pre-commit` refuses, and it did twice, once costing a full
revert. In practice this costs nothing: `org_capture` with an
`initial_state` writes the keyword through immediately when the file is
free, and its reply says which happened — after "Captured:" the heading
may be added to a slice at once, after "Queued capture:" the queue is
applied first. A capture deliberately left keyword-less is a note, and
a note is not a member.

**And a slice never has keyworded children** (`:ID:` dca940c1). A
heading carrying both the `:KIND: slice` declaration and keyworded
children satisfies the slice and container predicates at once, and every
mechanism then takes the slice branch: the nomination report goes blind
to the children, and the derived `:BLOCKER:` names members only, so the
heading can close over a live child. `bin/lint-org` reports the
combination as an **error** — added while latent, zero instances
existing. Keyword-less children (notes) are legal; the container
predicate tests keywords. The same rule read backwards: a heading that
already has keyworded children is a story, and is never declared
`:KIND: slice`.

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

**When the slice does not undertake all of an open story's open
children, the parent line carries no checkbox** (`:ID:` 758a8b78): write
it as an `[[id:...]]` reference with keyword and title but no cookie,
its member children indented beneath. A checkboxed parent over partial
coverage could never check while the story stays open, which would wedge
the slice short of `DONE` for work it never claimed. This is a fourth
reading of a cookie-less line beyond the three the dropping section
names, and the disambiguator is structural: **a cookie-less line with
indented member lines beneath it is a grouping label, never a drop**
(`:ID:` 1b727475 tracks the ambiguity this rides). A story the slice
undertakes whole may stay a checkboxed member as before.
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

**Add the member's id to the slice's `:DROPPED:` property; the refresh
renders the drop.** Its line loses the checkbox cookie (delete it by
hand or let the next refresh do it), so it neither counts against the
numerator nor inflates the denominator — and `--slice-blocker-ids`
excludes such a line deliberately: a deferred member is *unfinished*,
so blocking on it would hold the slice open forever for work it
explicitly decided not to do.

*The property replaced the bare cookie deletion on 2026-09-08*
(`:ID:` 1b727475). Deleting the cookie *was* the whole mechanism, and
it made two different facts render identically — a hand drop, and a
member that is cookie-less merely because its keyword is `MAYBE` or
`CANCELLED` — with nothing anywhere recording which was which. Worse,
the refresh read the absence as the declaration and kept it, so the
drop was sticky: a `MAYBE` member promoted to `TODO` never regained
its box. Now the checkbox is *fully* derived — from the referent's
keyword, minus `:DROPPED:` ids, minus grouping-label lines — so a
promoted member's box returns by itself, and a drop is a visible,
reversible, one-line declaration that survives the line being
regenerated wholesale.

**Keeping the line is the point.** The slice declared that member; deleting
the line would make the slice read as though it never had, which is the
same falsification `:ID:` 30a340fd refused for closed slices. A cookie-less
line still parses as a member, so it is not re-listed as incidental
either — it says *this was planned here and is no longer counted*, which
is exactly the fact.

**It covers three cases and does not distinguish them**: cancelled,
deferred, and moved. The line's absence of a cookie says only that the
slice no longer counts it. (A cookie-less *parent* line with indented
member lines beneath it is the distinct fourth reading — a grouping
label, not a drop; see the nesting rule above.)

**The ambiguity this used to carry is resolved** (`:ID:` 1b727475,
2026-09-08). A cookie-less line now has exactly three readings, each
declared somewhere the regeneration cannot destroy: the id is in the
slice's `:DROPPED:` (a drop), the referent's keyword is `MAYBE` or
`CANCELLED` (derived — an unchecked box would inflate the denominator
forever), or the line is a grouping label with indented member lines
beneath (structural). A `MAYBE` member promoted to `TODO` regains its
box on the next refresh; a dropped one does not, until someone removes
its id from `:DROPPED:`.

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

### Composing a slice

**A slice is composed declared — write `:KIND: slice` from the start.**
The proposal convention that stood here until 2026-09-08 (a slice with
the declaration withheld, parked at `MAYBE`, accepted by adding
`:KIND:` later) is retired (`:ID:` 7f0c9baa): its three arguments all
expired. The promotion-trigger argument died with the trigger
(`:ID:` 62b65ad0); the location question dissolved with the level-1
tier; and the lint-friction argument was measured false composing
`c19fbbf5` declared, which linted clean — what friction remained was
composition cost, and `org_set_property`'s `KIND=slice` branch now
completes the declaration itself (`:ID:` acf46449), so withholding no
longer buys anything. An open slice already *is* its own proposal until
work begins, and rejection is `CANCELLED` either way, with the body
kept — the argument for a slice nobody ran is usually the part worth
keeping.

**Nothing replaces the `MAYBE` signal, deliberately** (the user,
2026-09-08). An unstarted slice is visibly uncommitted without a
keyword saying so: it has no clocked members, nothing `DOING`, and no
prompt link — the `next-session.md` revision link arrives only when a
slice is actually picked up, since that is what a slice is *worked*
from, not what it is composed into.

**Review the composed list for twins before work begins.** A *twin* is
two headings describing the same defect, or the same class of work,
closely enough that scheduling one and forgetting the other is arbitrary
— and that asymmetry is invisible from inside the act of composing: it
has escaped twice (`c31b6c76`/`5a5e87c9`, then `5f1068f9`/`33864a0f` —
the second escape in prose that had just named the first), caught both
times by a reader and never by the composer. So it is a review question,
asked of the finished list: *does anything in this list have a twin that
is not in it?*

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

Compose it in two calls — `org_amend` with `drawer=PLAN` for the
prospective prose, which creates the drawer, then `org_amend` the short
body. (Three calls routed through `org_wrap_plan` until `:ID:` 501a8422
shipped the drawer argument, 2026-09-08; the wrap is retroactive-only
now.) At close, two calls again: the resolution onto the body, the
debrief via `drawer=DEBRIEF` — see "The `:DEBRIEF:` drawer" below.

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

## The `:DEBRIEF:` drawer

**At close, the debrief goes into a `:DEBRIEF:` drawer and the body gains a
one-to-two-sentence resolution** (`:ID:` d5eb32a3, 2026-09-08). Two calls:
`org_amend` the resolution onto the body, then `org_amend` with
`drawer=DEBRIEF` for the full debrief — what shipped, how it was verified,
what was falsified, what differed from the plan. The drawer is created when
absent, below the body.

This completes what `b75d553a` started: the plan out at composition, the
debrief out at close, so the body is a *fixed-size* artifact however much
reasoning a task accumulates. A folded heading then shows title,
problem-and-proposal, and resolution — a TL;DR with every drawer collapsed.

**The resolution line is authored, never derived.** It is the one part of
closing that costs judgement, and it is the part that makes orientation
cheap for every later reader. No lint requires it yet, deliberately —
observation before machinery, the project's standing precedent.

**Read `:DEBRIEF:` on a finished heading; it is exempt from the skip
advice.** The skip rule exists because `:PLAN:` on a finished heading is
*superseded* design. A debrief is the opposite — the record of what
actually happened, and the thing most worth reading when a finished
heading is consulted at all. Skip `:PLAN:`, read `:DEBRIEF:`.

**This also carries the pre-archive outcome summary.** The older rule said
to put the summary "next to the plan link" — a location that stopped
existing when the link moved into `:PLAN:` at composition. The outcome
summary *is* the debrief plus the resolution line; a heading closed under
this convention owes archiving nothing further. Delegated-subagent work
follows the same shape: ask the subagent for a one-paragraph outcome
summary, and it lands as the `:DEBRIEF:` content.

**The corpus written before this convention is a separate, judgement-heavy
pass** — every finished heading whose debrief still sits in its body needs
an authored resolution before the debrief can move, and that is a
per-heading act nobody should do by sweep. It has its own heading under
the `4c834fdb` story; new closes follow this convention now regardless.

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

`* Review and planning` carries `:CATEGORY: Meta` on the anchor itself, since
org-datetree's day nodes have no drawer of their own and would otherwise
inherit the file name.

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

## Moving a heading

**Moving a heading between files or levels is `org_refile` — never a
hand-rolled subtree move.** `org-cut-subtree`/`org-paste-subtree` through
`emacsclient` leaves `org-id` pointing at the old location, which is
exactly what stranded `8ddd7fa8`; the tool updates the locations index as
part of the move. This rule exists because the competitor had to be
named: `420816ec` measured that a good description does not move usage
and a standing rule does — but only for the situation it names, and the
reflex this one targets is the hand elisp, not a file read.

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
