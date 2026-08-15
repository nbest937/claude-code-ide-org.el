# Promote 02aaae22 to an epic, and the roadmap for its children

TODO.org `:ID:` 02aaae22-0958-4c0f-b5bb-2cbea32416ae

## Context

This heading was written as one task and is not one. Bringing CLAUDE.md in line
with the shipped architecture is at least three passes — a correctness pass, a
deduplication pass against the two skills, and a decision about lazy loading that
cannot honestly be made until the first two have changed the file's size and shape.
Each earns its own plan, and a single heading cannot carry three plan links.

It is also the last non-`MAYBE` child of the queue epic (`:ID:` b5f7c5c7¹). That
epic has 34 children: 31 `DONE`/`CANCELLED`, two `MAYBE`, and this one. Promoting
this heading out leaves only the two `MAYBE`s, so the epic can close — which is what
unblocks the archive pass (`:ID:` 38b92521²), which carries `:BLOCKER: ids(b5f7c5c7)`.

That is the same move already made three times with this epic, on reasoning the
epic's own body records: *"An epic that absorbs every defect found in the code it
produced can never close."* `:ID:` f4e628ce³ and `:ID:` 5ff5a4b8⁴ were promoted out
on exactly this basis and now sit at `**` level.

## The restructure

Promote `02aaae22` from `***` (under the epic) to `**`, under the same `*
Clock lifecycle & visibility` category at TODO.org:1560 — matching where its
promoted siblings already live. It becomes an epic by acquiring children with TODO
keywords, which is emergent rather than declared (`--container-heading-p`).

Its `:BLOCKER: ids(7771fc63 e51d6ba1 c084553c)` is satisfied — all three are `DONE`
— and stays as history.

## The children

**1. Correct CLAUDE.md's account of the queue architecture.** The factual pass. Its
plan is essentially written already — see the evidence table below.

**2. Remove CLAUDE.md content the org and org-dev skills already own.** Both skills
already document what CLAUDE.md restates. Anything removed that the target skill
does *not* already say gets added there first, so nothing is deleted without a home.
Separate from (1) because it changes *where* instructions live rather than whether
they are true, and it is the pass most likely to be judged wrong later.

**3. Decide whether CLAUDE.md needs a path-scoped `.claude/rules/` split.**
`:BLOCKER:` on (1) and (2) — the decision takes the resulting size as input, and
the user's standing instruction is to raise the question again after the content
changes. May close as won't-do; if it doesn't, it gets its own plan.

Ordering is 1 → 2 → 3. Only (3) is blocked; (1) and (2) touch overlapping paragraphs
so serialising them avoids editing the same lines twice.

**Amended 2026-08-14, after the restructure landed: child 1 proceeds without a plan
of its own.** The Context above says each pass earns its own plan; that holds for
(2) and (3) and does not for (1). Its spec is the evidence table below — ten defects,
each already located against its source of truth — and a separate plan would restate
that table in a second file. The rule that earns a plan is *design not yet settled*,
and for the correctness pass nothing is: every row is a known-wrong claim with a
known-right replacement. (2) and (3) genuinely have open design, and keep theirs.

## Evidence: what is wrong with CLAUDE.md today (feeds child 1)

Verified against source, not inferred.

| Claim in CLAUDE.md | Reality |
|---|---|
| "Direction (**not yet implemented**)" (L21–68) | Shipped. `org_pending_updates` and `org_review_apply` are registered tools |
| `org_set_todo` → "Saves buffer after state change" | `config.el:1156` — *"Changes no TODO keyword"* |
| Transition table → "Open a CLOCK (call `org_clock_in`)" | `config.el:410` — *"Opens no clock"*. The *call* is still right; the *effect* is deferred to apply |
| MCP table lists 12 tools | 15 registered. Missing: `org_amend`, `org_outline`, `org_review_apply` |
| "`session-pause` is a thin alias for `org_clock_out`" | It is `exec queue-append pause` |
| Session tracking section | No mention of `PermissionRequest`/`PermissionDenied`, `block_start`/`block_end`, or the `.block-open` sentinel (shipped today, `c8c33a1`) |
| L518–524 recovery paragraph | Garbled by a botched edit — a fragment mashed into a parenthetical |
| Repository layout | Omits 7 of 10 `bin/` scripts and all 7 `bin/hooks/` scripts |
| `#+TODO:` file-header template (L~240) | Omits `REVIEW` and every logging cookie. Real line: `TODO(t!) NEXT(n!) PLANNING(p!) DOING(d!) REVIEW(r!) WAIT(w@/!) MAYBE(m!) \| DONE(D!) CANCELLED(c@)` |
| Keyword semantics table | No `REVIEW` row — the string does not appear in CLAUDE.md at all (0 occurrences), though `org_set_todo` accepts it |

The first row is the one that matters: a session reading CLAUDE.md today is told
that calling `org_set_todo` changes state. It doesn't. That is a false behavioural
instruction, not a stale detail.

The cookie omission is the one with teeth. `@` means *prompt for a note*, so `WAIT`
and `CANCELLED` prompt while every other transition only timestamps. A transition
driven non-interactively through `emacsclient -e` therefore hangs for those two
keywords and not for the others — the exact hazard the queue architecture exists to
route around, currently undocumented. Child 1 should state it, and should record
that `REVIEW` is experimental (`:ID:` c954f650) rather than presenting it as settled.

## The lazy-loading finding (feeds child 3)

`@path` imports are the obvious move and do not work for this. From the Claude Code
memory docs: *"Splitting into `@path` imports helps organization but doesn't reduce
context, since imported files load at launch."* Imports organise; they do not defer.

What actually loads lazily:

- **`.claude/rules/*.md` with `paths:` frontmatter** — loads only when Claude reads
  a matching file. The real mechanism, and the natural home for org conventions
  (`paths: ["**/*.org"]`).
- **Skills** — load on demand. Already used here; child 2 exploits this.

Unused in this repo today, and a rule that silently fails to load is
indistinguishable from one that loaded and was ignored — so adopting it needs a
fresh session to verify, which is part of why it is child 3 rather than child 1.

Documented target is **under 200 lines**. CLAUDE.md is **640**.

## Files

- `TODO.org` — the restructure itself; add the Plan link to `02aaae22` first, per
  the standing rule that the link is written as soon as a plan file exists
- Later children touch `CLAUDE.md`, `.claude/skills/org/SKILL.md`,
  `.claude/skills/org-dev/SKILL.md`

Source of truth to re-read rather than recall, for child 1:
`modules/tools/claude-code-ide-org/config.el` (docstrings at `:1156`, `:410`,
`:444`), `bin/hooks/*`, `.claude/settings.json`.

## Verification

For this restructure specifically:

1. **`bin/lint-org`** on TODO.org after the edit — catches the misplaced-heading
   class of error that a promotion can introduce.
2. **Level check**: `02aaae22` is at `**`, the three children at `***`, and the
   epic `b5f7c5c7` has no remaining `***` child that is neither `DONE`,
   `CANCELLED`, nor `MAYBE`.
3. **`:BLOCKER:` on child 3** names both child 1 and child 2 by `:ID:`, looked up
   after they are written rather than typed from memory.
4. `bin/test` — untouched by an org-file edit, run to confirm exactly that.

Closing `b5f7c5c7` is *not* part of this plan. It becomes possible, and is a
separate judgement about its two `MAYBE` children.

## Immediate next step after approval

Write the promoted heading and its three children — titles, tags, `:ID:`,
`:CREATED:`, `:BLOCKER:`, intro bodies — and **stop**, per the standing rule that
approving a plan is not approving a heading's wording. No child moves to `DOING`,
and no CLAUDE.md edit begins, until the structure is reviewed.

Note the `ExitPlanMode` promotion hook will not fire for `02aaae22`: this session
set `PLANNING` directly through `emacsclient` (the `emacs-tools` MCP server did not
connect), so nothing was queued for the hook to find. Its `PLANNING` → `DOING`
transition has to be made explicitly.

---

# Child 2 design: dedupe CLAUDE.md against the skills

`:ID:` c556a9ed-8e37-4fc3-ab4b-63292837236d. Kept in this file rather than a
separate one: this is the epic's plan document, and the harness reuses one plan
path per session. Both headings link it.

## Context

Child 1 left CLAUDE.md at **736 lines, up from 640** — a correctness pass can only
add, because queued-vs-immediate is a distinction the old text never had to draw.
The documented target is 200. Meanwhile both skills already own material CLAUDE.md
restates, so the cheapest real reduction is deletion, not relocation.

## Precondition: the org skill is stale, and must be fixed first

`org/SKILL.md:42-49` declares the keyword set as
`TODO NEXT DOING WAIT MAYBE | DONE CANCELLED` — no `PLANNING`, no `REVIEW` — and
then says "The five states to the left are all active" when there are seven. The
file mentions `PLANNING` four times elsewhere, so it is internally inconsistent
too.

**Correct it before deleting anything**, or the pass replaces correct text in
CLAUDE.md with wrong text in a skill. This is the same class of defect child 1
just cleared, in the other file.

## The moves

| Content | Disposition | Rationale |
|---|---|---|
| org skill keyword set, `SKILL.md:42-49` | **Correct** | Precondition above |
| CLAUDE.md Tags table | **Delete**, point to skill | Skill has it verbatim under "Standard tags for this user's files" |
| CLAUDE.md Archiving convention | **Delete**, point to skill | Skill covers it *more* fully — includes the per-heading `:ARCHIVE:` override CLAUDE.md omits |
| CLAUDE.md keyword semantics table | **Delete**, point to skill | Redundant once the skill is corrected |
| CLAUDE.md `:BLOCKER:` subsection | **Trim to one sentence** | Skill covers `:BLOCKER:`, multi-ID, the inverse `:TRIGGER:`, and the enforcement caveat. Only "this project's blocker hook blocks on a running clock, not on `:BLOCKER:`" is project-specific |
| CLAUDE.md "Emacs integration" (60 lines) | **Move** to org-dev as a new §7 | org-dev already discusses `after!` ordering, the Warp-wiring block, and the restart rule for those exact files |
| CLAUDE.md Design notes, `org-clock-load` entry | **Delete** | org-dev §2 already owns it, with the better explanation (*why* it only appears on a fresh boot) — **and back-references CLAUDE.md for it**, so that pointer must be fixed in the same edit or it dangles |

## What stays in CLAUDE.md, and the rule that decides

**A standing rule must never move into an on-demand skill.** A skill that doesn't
trigger is a rule that doesn't apply, and the failure is silent. Only *reference*
material moves; anything phrased as "always" or "never" stays.

By that test these stay, despite looking movable:

- The `#+TODO:` line — project configuration, and it carries the `@`-cookie trap
  (`WAIT`/`CANCELLED` prompt, so a non-interactive `emacsclient` call hangs on
  exactly those two)
- `REVIEW` is experimental, and top-level headings are categories
- No priority cookies; every heading gets `:CREATED:`
- The Emacs server is a hard prerequisite — one line, kept because a session that
  learns this lazily has already failed
- Design notes 1–4 (why MCP tools for state, why IDs not titles, why snake_case).
  Rationale is what the docs explicitly say to *keep*; only the duplicated fifth
  entry goes

## Files

`CLAUDE.md`, `.claude/skills/org/SKILL.md`, `.claude/skills/org-dev/SKILL.md`.

## Verification

1. **`bin/check-org-dev-skill`** — the repo's own checker for org-dev's claims;
   this pass adds a section to that skill, so it must still pass.
2. **Nothing deleted without a home**: for each deleted block, grep the target
   skill and confirm the claim is present *and correct* there. A deletion whose
   target says something subtly different is the failure this pass risks.
3. **No dangling cross-references**: grep both skills for `CLAUDE.md` and confirm
   every pointer still names a section that exists. org-dev §2's pointer is known
   to break.
4. `bin/test` and `bin/lint-org` — untouched by a docs pass; run to confirm that.
5. `wc -l CLAUDE.md`, which is child 3's input.

## Out of scope

- **Repository layout (87 lines)** — the largest remaining block, and exactly what
  the docs say to cut as codebase-derivable. But it is not skills-duplication, so
  it is not this pass. Worth its own heading or folding into child 3.
- The `.claude/rules/` split (child 3).

---

# Child 3 decision: a limited split, and why 200 lines is unreachable

`:ID:` befaed0a-18ed-445e-b997-8b9c2965ad45. Decided 2026-08-15.

**The measurement that settled it.** Classifying every section by whether it must
hold when no particular file is open:

| | lines |
|---|---|
| always-on core (architecture, engineering practices, transitions, MCP tools, design notes) | **354** |
| path-scopable (org conventions 75, session tracking 133) | 208 |
| cuttable as codebase-derivable (repository layout) | 87 |

**The documented 200-line target is unreachable for this project** — the floor is
~354 even after moving everything movable, and getting under it would mean deleting
standing rules. That is not a failure to fix; it is what a CLAUDE.md that encodes a
*workflow* costs, as against one that records facts about a codebase. Record it so
the target is not re-litigated against this file every few months.

**Done:** repository layout trimmed to the four non-obvious facts (`ls` answers the
rest); org conventions moved to `.claude/rules/org-conventions.md` with
`paths: ["**/*.org"]`. 670 → 595.

**Not done, deliberately: session tracking (133 lines) stays.** It is the biggest
single block and the obvious next candidate, and path-scoping it to `bin/hooks/**`
would be wrong — its knowledge is wanted when reading a queue file or at review
time, not when editing a hook script. This session needed it repeatedly without
touching `bin/hooks/`. If it moves later it should become a skill, not a
path-scoped rule.

**The test that decided every case:** a rule that must hold when no `.org` file is
open cannot live in a path-scoped rule, because a rule that does not load is a rule
that does not apply and the failure is silent. Only reference material moved.

**Open, and it cannot be closed from the session that made the change:** whether the
rule file actually loads. Path-scoped rules load when Claude reads a matching file,
and this session predates the file's existence. Verifying it needs a *fresh* session
that opens an `.org` file and can be asked whether the conventions are in context —
`/context` lists loaded memory files, and the `InstructionsLoaded` hook logs which
instruction files load and why. Until then the split is written, not confirmed.

---

¹ `DOING` b5f7c5c7 — Refactor clock/TODO-state driving to an append-only event queue + interactive batch-apply review
² `TODO` 38b92521 — Archive the DONE backlog once the queue epic lands, then judge the structure question
³ `DONE` f4e628ce — pause/resume cannot see a turn blocked on a permission prompt
⁴ `DONE` 5ff5a4b8 — Show commits and heading creations inside an unassigned span's window
