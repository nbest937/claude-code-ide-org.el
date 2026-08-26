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
#+TODO: TODO(t!) NEXT(n!) PLANNING(p!) DOING(d!) REVIEW(r!) WAITING(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)
#+TAGS: code comms research review
#+ARCHIVE: DONE.org::* Done
```

The per-keyword cookies matter: `!` records a timestamp on entry, `@`
*prompts for a note*. See CLAUDE.md's transition rules for why that
asymmetry is load-bearing.

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

## Top-level headings

Top-level (`*`) headings in `TODO.org` are epics — pure
structure, grouping related tasks — not tasks in their own right. They carry
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
An **epic** is the separate thing: the grouping a task belongs to, today
a level-1 heading and proposed as an `:EPIC:` label (`:ID:` 29439196).

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

Slices live under the level-1 `* Slices` category and are level-2
headings. Each carries an `:ID:`, a `:CREATED:`, and a
`:COOKIE_DATA: checkbox recursive` property so its statistics cookie
counts nested members as well as top-level ones.

**Members are `[[id:...]]` links in a checkbox list**, not child
headings. The list may mirror the tree — a story's children indented
under it — but it need not contain every child of a story it refers to.
Write the link so it displays the 8-character prefix, and put the
referent's keyword and title *outside* the brackets:

```
- [X] [[id:49557477-e50c-496f-85df-82c65109832b][49557477]] DONE Expand an 8-character prefix ...
```

The link target is the only part that cannot go stale; keeping the
keyword and title as plain text alongside it makes the copy visible
*as* a copy.

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

**A slice carries a `:BLOCKER:` naming exactly its cookie-carrying
members**, so it cannot reach `DONE` before they do. Derived, never
authored — `M-x claude-code-ide-org-refresh-slice-blocker` writes it from
the checklist, and `bin/lint-org` reports an **error** if the two
disagree in either direction. The checkbox list is the human half and the
blocker the machine-readable one; redundancy without a check is just two
things that can disagree.

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
| `DOING` `REVIEW` `PLANNING` `WAITING` | `[-]` |
| `TODO` `NEXT`        | `[ ]`       |
| `CANCELLED` `MAYBE`  | *no cookie* |

**A cancelled or deferred member has its checkbox cookie deleted
entirely**, leaving a plain `- ` list item, so it neither counts against
the numerator nor inflates the denominator. The line stays, because the
record of having considered and dropped something is what a bare list
loses.

Because every field is derived, **the only things a slice declares are
membership and order** — which headings belong and in what sequence. If
a checkbox looks wrong, either the slice needs regenerating or the
*referent's keyword* is under-reporting; the fix is never to set the box
by hand. Regenerating is `:ID:` 0acc1df2, and belongs immediately after
apply.

**A slice carries state but never a clock.** Its `:LOGBOOK:` records
state transitions only; every referent already carries its own clock, so
clocking the slice would add a second quantity inside the one that
already exists and could not be told apart from the sum. Note this is
not yet enforced — `--container-heading-p` does not recognise a slice,
so hand-setting `DOING` on one *does* open a clock today (`:ID:`
95c27fca).

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

## The `:PLAN:` drawer

A finished heading's body has two halves, and they live in different places.

- **`:PLAN:`** holds the *prospective* half — motivation, observations,
  speculation, and the `[[file:~/.claude/plans/...][Plan]]` link if there is
  one. It sits beside `:PROPERTIES:` and `:LOGBOOK:`, above the prose.
- **The body** is the *debrief* alone: problem restated, what the solution
  turned out to be, how it was verified, what was falsified.

So a folded heading shows the debrief and nothing else.

Create it with `org_wrap_plan`, never by hand — it takes an optional seam
marker naming the first line that stays in the body, which is what a heading
written before this convention needs, since such a body usually already holds
both halves. `org_amend` appends *below* a `:PLAN:` drawer, so the debrief
needs no special handling.

**An empty `:PLAN:` drawer is a real answer, not an accident.** A heading
written outcome-first has no prospective half at all, and that is the
convention working rather than a heading missing a step. Pass the debrief's
first line as the seam and `org_wrap_plan` writes an empty drawer, recording
that the question was asked and answered; the whole body stays visible.

The point is that **whether a body has a prospective half is a judgement,
not something derivable from its prose** — bodies of both kinds open with a
bold lead, so nothing in the text distinguishes them. So it is *declared*,
by running the wrap, exactly as a slice is declared rather than inferred.

This is also what makes the lint's question answerable. `bin/lint-org` warns
when a finished heading has a substantial body and no `:PLAN:` drawer; before
the empty drawer existed, the only way to satisfy that warning on a
debrief-only heading was to wrap the debrief into a drawer readers are told
to skip — the exact inversion the lifecycle exists to prevent. See `:ID:`
f421c5c3.

**Readers skip it.** Treat `:PLAN:` as absent unless the question you are
answering is retrospective — "how did we get here", "why was it done this
way". The debrief and the source code describe present reality; the plan
describes an intention that may not have survived contact, and reading it
for current fact is how superseded design claims get repeated as though
they still held.

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
