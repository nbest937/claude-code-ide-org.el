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
#+TODO: TODO(t!) NEXT(n!) PLANNING(p!) DOING(d!) REVIEW(r!) WAIT(w@/!) MAYBE(m!) | DONE(D!) CANCELLED(c@)
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
  handed back for human judgement, as distinct from `WAIT`, which means
  blocked on someone else. Its fate is not settled.
- Priority is expressed through keyword choice, not `[#A]`/`[#B]`/`[#C]`
  cookies. **Do not add priority cookies.**

## Tags

The four standard tags (`:code:` `:comms:` `:research:` `:review:`), their
meanings, and the archiving convention are in the **org skill** — including
the per-heading `:ARCHIVE:` override. Tags are free-form beyond those four;
declare additional ones in `#+TAGS:`.

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
- **Archive at level 2 only.** Archiving a level-3 heading directly lands it
  at level 2 under the category, severed from its parent, with only
  `:ARCHIVE_OLPATH:` recording where it came from. Archiving its level-2
  parent takes it along and keeps the nesting.

Actual tracked work lives as their level-2+ children, each with its own
`:ID:`. Don't put a `TODO`/`NEXT`/etc. keyword on a top-level heading — if
one needs to represent actionable work rather than group children, demote
it: give it an `:ID:` and treat it like any other task, or nest it a level
deeper under a category heading.

An epic is not declared, it is emergent: a heading that has acquired
children carrying TODO keywords. Detectable via
`claude-code-ide-org--container-heading-p`. Don't classify a heading as one
when writing it.

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
