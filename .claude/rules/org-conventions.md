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

Top-level (`*`) headings in `TODO.org` are categories/epics — pure
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

An epic is not declared, it is emergent: a heading that has acquired
children carrying TODO keywords. Detectable via
`claude-code-ide-org--container-heading-p`. Don't classify a heading as one
when writing it.

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
