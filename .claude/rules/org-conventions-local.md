---
paths:
  - "**/*.org"
---

# Org-file conventions: this repo's local additions

The portable conventions are promoted into
`.claude/rules/org-conventions.md` by `bin/claude-org-setup` from
`skills/org/references/org-conventions.md`, where they ship with the
plugin. This file carries what is this repo's alone and is history: how the
old category labels were split, and the level-1 category tier that
preceded `:CATEGORY:`. The live taxonomy itself is in
`.claude/rules/org-categories.md`, always loaded.

## The ten values

**Moved to `.claude/rules/org-categories.md` on 2026-09-15** (`:ID:`
b0d55552), which carries no `paths:` scope and so loads in every
session. They were here, behind this file's `**/*.org` scope, from
commit `42a3221` (2026-09-09) — and a capture is done with no `.org`
file open, so the sessions doing the capturing never saw them: ten
level-1 headings arrived uncategorised in the next two days. The
conventions' own opening paragraph predicted it — "a path-scoped rule
that does not load is a rule that does not apply, and the failure is
silent." What follows is the history those values replaced.

## Where the nine old labels went

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

## What each old category meant

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

## The rule that stood until 2026-08-27

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
