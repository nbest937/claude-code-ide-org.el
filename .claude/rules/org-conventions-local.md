---
paths:
  - "**/*.org"
---

# Org-file conventions: this repo's local additions

The portable conventions are promoted into
`.claude/rules/org-conventions.md` by `bin/claude-org-setup` from
`skills/org/references/org-conventions.md`, where they ship with the
plugin. This file carries what is this repo's alone: its `:CATEGORY:`
taxonomy and the history of the level-1 category tier that preceded it.

## The ten values

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
