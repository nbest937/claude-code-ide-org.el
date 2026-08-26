# Adopt `:CATEGORY:` and retire the level-1 heading tier

Plan for TODO.org `:ID:` 29439196, *Adopt org-native mechanisms for the heading tiers*.
Approved 2026-08-26 after the decision sat parked since 2026-08-19.

## Context

TODO.org's level-1 headings are a hand-built category tier. Org has a native
mechanism for exactly this — `:CATEGORY:` — and the project uses none of it.
The heading was parked because its own body is all cost analysis with no
statement of what the change buys.

Three things unblocked it, all measured 2026-08-26:

- **The objection was never evidence-backed.** 29439196's body records
  `:CATEGORY:` inheritance as a *verified benefit*. The "`:EPIC:` means one
  thing" counter-argument exists only as a clause in CLAUDE.md.
- **The clocktable cost was overstated** (by me, in conversation, and
  corrected). Flattening does not destroy per-category clock roll-ups:
  `:match "CATEGORY=\"X\""` reproduces them on a flat file, and
  `:properties ("CATEGORY")` adds a category column. `82df2a6c` said
  "rebuilt rather than inherited," which was accurate.
- **The archive-routing objection inverts.** `38b92521` closed flattening
  against because routing depends on level-1 `:ARCHIVE:`. Flattened there is
  one target instead of nine, which is simpler — and it is what the user's
  recency-ordered DONE.org wants anyway.

**The argument that actually decides it**, and which nobody made while it was
parked: flattening converts a grouping **inferred from level position** into
one **declared on the task**. That is the thesis of the slice this heading
belongs to (`979e02b6`), and CLAUDE.md already names the level-1 tier as the
standing example of the inference error.

**Scope note from the user:** "flattening" means *only* the level-1 category
tier. Stories keep their children; nesting below level 1 is untouched.

## Decisions already taken

| decision | by | note |
|---|---|---|
| `:CATEGORY:` over `:EPIC:` | user | three agenda affordances vs. semantic tidiness |
| Flatten the level-1 tier | user | |
| Two-step transition | user | mechanical migration first, taxonomy second |
| Capture target: top of file, `:CATEGORY:` optional | user | matches the recency ordering |
| Category values: single words, capitalised | user | `Queue`, `Clock`, … |
| `Bigger swings` is a throw-away | user | splits 3 → Skill, 3 → Tools |
| Sequence `8183fc7c` + `478d6ec9` **first** | user | see Prerequisites |

| `NEXT` is reserved to containers; promotion is advisory | user | see Step 0 |

## Step 0 — `NEXT` belongs to containers, and promotion stops writing

**This is its own heading and lands first.** It is not a consequence of
flattening; flattening only *exposed* it. It improves today's file unchanged.

### What flattening exposed

`--map-siblings` uses `org-get-next-sibling`, which for a top-level heading
spans the whole file. Flattened, 9 sibling groups become 1. My first instinct
was to teach it about `:CATEGORY:` so the old behaviour survived. The user
asked the better question — *when have we ever referred to tier-2 tasks as
siblings?* — and the evidence says the old behaviour was never right.

### The evidence

- **Top-level auto-promotions have a poor record.** Of roughly eight that
  fired at level 2, three are now `MAYBE`: `Worktree-based session
  partitioning`, `Org skill: commit a newly-captured TODO`, `Evaluate choice
  of shell`. The trigger declared something next; a human later parked it.
- **A category is a drawer, not a project.** GTD's invariant is that a live
  *project* has a next action. "The sole remaining TODO in Tooling" asserts
  nothing about what to do next.
- **The test fixture has no category tier at all.** `--with-heading` builds a
  level-1 task with level-2 children, so every trigger test already models the
  flat world, and "top-level sibling" in `42808717`'s verification meant
  *task*, never *category*.
- **This is `42808717` one tier up.** That heading taught the trigger to
  refuse a *container*, because promoting one "declares a project to be an
  action, inverting the one thing `NEXT` means." It fixed the case where the
  promoted heading was the wrong kind of thing; this fixes the case where the
  *sibling group* is.

### The decision

`NEXT` is meaningful only **within a container** — a story or a slice, i.e.
`claude-code-ide-org--grouping-heading-p`. Top-level headings have no sibling
group. **Promotion becomes advisory: the trigger nominates a candidate in
discussion rather than flipping a keyword silently.** Setting `NEXT` is
strictly intentional. Any tension this implies is accepted.

### What it retires, and why that is the point

| retired | lines | existed only because… |
|---|---:|---|
| `--trigger-auto-promote-sole-todo` | 93 | …becomes a small advisory report |
| `--review-settle-auto-promote` | 42 | …suppression skipped it mid-batch |
| `--auto-promote-active` | 17 | …re-entrancy; added after 1201 mutations across 114 headings in nine seconds |
| `--review-applying` | 15 | …apply lands one event at a time |

Verified: `--review-applying` and `--auto-promote-active` each have **exactly
one reader** — the promote trigger itself (`config.el:3577`). Every guard in
the chain exists solely because the function writes autonomously; each was
added after an incident caused by the previous one's absence. Advisory
promotion leaves nothing to guard.

**Survives unchanged:** `--map-siblings` (still needed inside containers),
`--trigger-demote-conflicting-next` (scoped to containers — demotion is a
consequence of an intentional act, not an autonomous one), and the other
settle steps (slice refresh, separation normalisation) which are independent.

**Where the advisory goes:** the same channel the ceremony and stale-interval
reports already use — `SessionStart` `additionalContext`, which states facts
and asks rather than acting. Do not invent a second mechanism.

## Prerequisites, and why they come first

Today the tree is how a reader navigates. Flattened, that job passes to
`org_outline` and to id-prefix resolution — and both are currently broken for
exactly the declared groupings that would carry the load:

- **`8183fc7c`** — `org_outline` scoped to a slice returns a single line. The
  user's own proposal on it (carry blocker *ids* in the general schema rather
  than a bare `[blocked]` flag) was measured at +2.2% on the outline.
- **`478d6ec9`** — 8-character prefixes resolve only against TODO.org. Hit
  live twice on 2026-08-26: `org_amend`'s link checker refused `b8e6007a`
  because it lives in DONE.org. Cross-file references become common once the
  tree stops grouping.

The slice orders these *last*. That ordering is wrong for this work and should
be inverted.

## Step 1 — mechanical migration (verbatim names)

Purely structural, reversible, changes no meaning. **Nine names carried across
unchanged.** This lands and is verified before any taxonomy work begins.

1. **Stamp `:CATEGORY:`** on every level-2 heading with its current parent's
   title, in **both files** — 273 headings, not 121. DONE.org's archived
   entries need it or the archive loses the grouping its mirrors provide.
2. **Promote** every level-2 heading to level 1 and each descendant by one
   level, in both files. **Except** `* Review and planning`, which stays a
   level-1 container because its datetree is an irreducible 4-level tree.
3. **Delete** the now-empty category headings (8 of 9; the datetree anchor
   survives).
4. **Archive routing** → a single `#+ARCHIVE: DONE.org::` target; remove the
   per-category `:ARCHIVE:` properties. Set `org-archive-reversed-order` to
   `t` for the user's newest-first DONE.org.

### Code that reads level, and what each becomes

| site | today | after |
|---|---|---|
| `--map-siblings` (config.el ~3422) | same level, same parent | **unchanged** — Step 0 removed the need to touch it |
| `--capture-level-1-headings` / `--capture-target-spec` (~2038) | title of a level-1 heading | target is an `:ID:` or nil; nil prepends at top of file; `:CATEGORY:` optional |
| `--categories-with-archive` (~8605) | level-1 headings carrying `:ARCHIVE:` | retire; routing is file-level |
| lint: level-4 rule (~8729) | "the file has three levels" | two, plus the datetree island |
| lint: level-1 rule (~8744) | a category: no `:ID:`, no `:CREATED:`, no keyword, no tags | **inverts** — level 1 is where tasks live and *must* carry all four |
| lint: cookie rule (~8778) | unchanged | unchanged |
| `--datetree-node-role` (~8598) | depth relative to the `:DATE_TREE:` anchor | **unchanged** — already relative |
| `org_outline` (~2539) | indents by level; a category is a real heading | group output *by* `:CATEGORY:` with a synthetic header per group — see below |

### `org_outline` needs the most care of any tool

CLAUDE.md makes it the first thing a session reads, and today **the grouping
is the tree**: `--outline-line` indents by `(* 2 (1- level))`, so a category
renders as a bare unindented line — no keyword, no `:ID:`, no tags — with its
tasks indented beneath. Flattened, every task is level 1 and the output
becomes a flat wall of ~121 lines with no grouping at all. Categories do not
move; they stop existing as renderable objects.

**Group by `:CATEGORY:`, emitting a synthetic header line per group.** The
rendered shape stays identical to today's, so no session, skill or habit needs
to relearn anything — only the *source* changes, from tree structure to
declared property. That is this slice's thesis applied to the tool itself, and
it is cheaper than the alternative: nine synthetic headers versus a category
prefix on every one of ~185 lines.

Two details that will bite:

- **`max_depth` shifts by one.** Today `max_depth 2` means categories + tasks;
  flattened it means tasks + story children. Not documented in CLAUDE.md, the
  rules or the skills (checked), so churn is limited to the tool schema
  description. Synthetic headers must **not** count toward depth, or
  `max_depth 1` returns headers only.
- **File order and outline order diverge.** The file becomes recency-sorted;
  the outline stays category-grouped. The outline therefore stops answering
  "where will a new capture land." Acceptable — an index is not a mirror — but
  say so rather than let someone infer it.

### …and its consumers

Enumerated, because one fails *silently* rather than loudly:

| consumer | today | after |
|---|---|---|
| `org_capture` schema (config.el 9814) | "run `org_outline` to see what categories exist" | **breaks** — must describe `:CATEGORY:` values, not headings |
| `org_capture` `target` param (9829) | "the exact title of a top-level category" | **breaks** — mechanism retired by the capture decision |
| capture error message (2219) | "level 1 … is reserved for categories" | **inverts** — level 1 is where tasks live |
| CLAUDE.md:707 tool table | "level, keyword, title, `:ID:`, tags" | level stops implying grouping; mention `:CATEGORY:` |
| CLAUDE.md:70 orientation | "start with `org_outline`" | survives **iff** grouped rendering lands |
| `.claude/commands/next-session.md` | "use `org_outline` with `scope`" | a plan doc, expected to be rewritten; not maintained |
| `.claude/settings.local.json` | permission entry | no change |

The capture schema is the dangerous one: it is how a model learns the legal
targets, so a stale description means the model runs the tool, sees no
categories, and guesses. Its three sites are already in scope from the capture
decision — but the error message at 2219 is a fourth site not implied by it.

**This is the strongest argument for grouped rendering over per-line
prefixes:** it keeps the two CLAUDE.md rows true without editing them, holding
the churn to the four capture sites.

**A collision that dissolves.** `.claude/rules/org-conventions.md` records that
a real task sits at the same depth as the year node, "the whole reason
`--datetree-node-role` gates on org's literal title shapes rather than on
depth." Flattened, level 2 under the anchor is scaffolding only. Keep the
title-shape gate anyway — stricter and free — but the hazard is gone.

### Also in step 1

- **Widen `org-agenda-prefix-format`.** `%-12:c` is a default the Doom config
  never set. Twelve columns of every agenda line currently carry the *file
  name* — two distinct values across 274 headings. Widen it so the taxonomy is
  chosen on what reads as a subject, not on a character budget. The manual's
  10-character guidance is aesthetic advice, not a constraint; nothing in org
  validates a `:CATEGORY:` value's length.
- **Sort** TODO.org by descending `:CREATED:` — flattened, this is one
  operation over the whole file rather than nine.

## Step 2 — the taxonomy (separate, after step 1 is verified)

**Why separate:** re-categorising requires per-heading judgement across half
the corpus. Splitting it lets the structural change land and be verified
without also betting on a taxonomy neither party has fully derived.

### The evidence

Counting every descendant in both files — 273 headings:

| category | total | share |
|---|---:|---:|
| Clock lifecycle & visibility | 138 | **51%** |
| Skill logic | 54 | 20% |
| Tooling | 34 | 12% |
| Review and planning | 20 | 7% |
| Observability | 15 | 5% |
| Bigger swings | 6 | 2% |
| Slices / Upstream / Documentation | 2 each | <1% each |

One label covers half the corpus; four cover twelve headings between them.
Four have **never had a single item archived**.

**A reliable tell, the user's:** only two category names contain a conjunction
— `Clock lifecycle & visibility` and `Review and planning` — and both are the
ones the survey independently flagged as compound.

### Proposed values

Single words, **capitalised** — the user's call, for stylistic distinctiveness
against keywords and tags.

| value | drawn from |
|---|---|
| `Queue` | event queue, guideposts, spans, attribution |
| `Review` | the review buffer and the apply cycle |
| `Clock` | clock correctness proper |
| `Skill` | CLAUDE.md, the skills, org conventions, declared-vs-inferred |
| `Tools` | MCP surface, lint, scripts, tests, packaging |
| `Docs` | prose for humans — README, procedures. A growth area, not the two-heading vestige it is today |
| `Slices` | slices |
| `Meta` | the datetree anchor and its rituals |
| `Upstream` | claude-code-ide.el |

`Observability` and `Bigger swings` dissolve. The 138 split into
`Queue`/`Review`/`Clock`, which is this project's own three architectural
layers rather than one drawer.

**The one seam needing judgement:** `Skill` vs `Docs`. CLAUDE.md is both the
agent's discipline and human prose. Suggested cut — `Skill` is what an agent
must follow, `Docs` is what a person reads to understand the project.

## Verification

- `bin/test` — full suite green; add fixtures for the rewritten level rules
  and for `--map-siblings` grouping by `:CATEGORY:`.
- `bin/lint-org` — **0 errors** on both files after migration. This is the
  main safety net: it asserts `:ID:`/`:CREATED:` presence, link resolution,
  and level bounds, so a botched promotion shows up here.
- **Prove the lint rules discriminate** — break each rewritten rule on a copy
  and confirm it fires. A rewritten assertion that has never failed proves
  nothing.
- `bin/check-org-dev-skill` — 6 ok.
- **Count invariance**: heading count, `:ID:` count and CLOCK-line count must
  be identical before and after promotion. Promotion must move no content.
- **Agenda**: `org-todo-list` renders with a populated prefix column and 9
  distinct values, not 2.
- **Clock roll-up**: reproduce the per-category totals via
  `:match "CATEGORY=\"X\""` and check they equal today's `:maxlevel 2` table.
- **Archive**: archive one finished heading and confirm it lands at the top of
  DONE.org with `org-archive-reversed-order` set.
- **git**: commit step 1 as its own commit, separate from any taxonomy change,
  so the mechanical pass can be reverted independently.

## Order of work

1. **Step 0** — `NEXT` to containers, promotion advisory. Own heading, own
   commit. Independent of everything below.
2. **Prerequisites** — `8183fc7c`, then `478d6ec9`.
3. **Step 1** — mechanical migration, verbatim names. Own commit.
4. **Step 2** — the taxonomy. Own commit, or several.

## Open

- Whether `Slices` earns a category at all, given `:KIND: slice` already
  declares what a slice is.
- Whether ambition (`Bigger swings`) is preserved on some other axis or simply
  dropped. Dropping loses a real signal about which items are speculative.
- The `Skill` / `Docs` seam. The user notes documentation is real work ahead
  for this project, so `Docs` should be a live category rather than the
  two-heading vestige it is today.
