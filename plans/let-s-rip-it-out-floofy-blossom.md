# Discard the Plan-checklist convention; migrate skills to plain-text format

## Context

Two things converged in this planning session, both landing in the same
change:

**1. The Plan-checklist convention.** CLAUDE.md currently requires every
`**** Plan [n/m]` org checklist to be reconciled — checkboxes verified,
deviations noted, open questions resolved — before its heading is archived,
and org.skill separately documents the mechanics of maintaining one (check
off as you go, verify before checking, recompute the cookie) plus a
formatting rule mandating it be a sub-heading. This was added after a batch
of parallel-subagent work left checkboxes stale despite real implementation;
a follow-up session (tracked as TODO.org's still-open DOING heading
`6a448345-016c-495f-b26b-ee81b30cd95c`, "Revisit: does org.skill's checkbox
discipline apply to TODO.org itself?") pushed back on the rule's reasoning
and deferred a final call.

**Final decision:** the whole mechanism was a bad idea — transcribing a plan
into org and then keeping two copies in sync as work happens. Claude Code's
own Plan Mode already externalizes the plan to a Markdown file (confirmed
empirically: `~/.claude/plans/*.md` files are never cleaned up — two from
2026-07-28/29 are still present untouched), so the org side only needs a
durable link to it, not a transcription. Discard the concept **entirely,
with no evidence left in HEAD**: stripped from org.skill's guidance and from
every existing heading currently carrying a `Plan [n/m]`/`Plan [/]` block —
both DONE.org's 14 already-completed ones and TODO.org's 4 still-speculative
MAYBE roadmap items (checked: neither of the two files in `~/.claude/plans/`
backs any of those 4, so they have nothing to link to — their checklists are
just removed; each heading's own intro/trailing prose already stands alone).
The one thing that *does* persist past `DONE`: the plan-file link itself
stays in the heading permanently, even after archiving.

**2. Skill file format.** While scoping the org.skill edit, checked with
Claude Code's own documentation (via the claude-code-guide agent, sourced
from code.claude.com/docs/en/skills.md) whether `.skill` zip archives are
an actual supported format. They are not — **the only documented format is
a plain directory containing `SKILL.md`**, e.g. `.claude/skills/<name>/
SKILL.md`, tracked as ordinary text. The zip-archive `.skill` convention
this repo uses (`org.skill`, `org-dev.skill`, each a zip with one internal
entry) is non-standard, invented for this project, and exactly the "binary
artifact, can't diff or text-edit directly" pain org-dev.skill's own
section 7 documents workarounds for. Since this session is already editing
both skill files' content, migrate them to the native format first.

**Per the user's explicit instruction:** commit the plain-text migration
(verbatim content, format only) *before* making the actual content edits,
so the format change and the substantive edit are separate, reviewable
commits.

## Sequencing gate (per user instruction)

Once this plan itself is approved, the *very first action* is to write only
the new TODO.org heading below (nothing else — no CLAUDE.md/skill/DONE.org
edits, no `DOING` transition, no clock) and stop to show it for a separate,
explicit approval before proceeding to anything in "Approach" below:

```org
*** TODO Discard the Plan-checklist convention; migrate skills to plain-text format :code:
:PROPERTIES:
:ID:       <generated via (org-id-new) at write time>
:CREATED:  [<actual current timestamp at write time>]
:END:
Plan: [[file:~/.claude/plans/let-s-rip-it-out-floofy-blossom.md][let-s-rip-it-out-floofy-blossom]]

CLAUDE.md's Plan-checklist reconciliation rule (and org.skill's matching
checklist-discipline guidance) is being discarded entirely as unnecessary
overhead — a plan tracked twice (org checklist + Claude Code's own Plan
Mode file) that then needs keeping in sync. Replacing with: a permanent
link to the Plan Mode file, kept through DONE, plus a concise prose outcome
summary at completion instead of checkbox reconciliation. Also migrating
org.skill/org-dev.skill off their non-standard zip-archive packaging to
Claude Code's actual native format (.claude/skills/<name>/SKILL.md, plain
text) since both files are being edited anyway. See the linked plan for
full scope.
```

Only after that heading is explicitly approved does work proceed: transition
it to `DOING` (`org_clock_in`), then execute the two commits below.

## Approach — two commits

### Commit 1: migrate `.skill` zips to plain-text `.claude/skills/`

- Extract current content verbatim: `org.skill` → `.claude/skills/org/
  SKILL.md`; `org-dev.skill` → `.claude/skills/org-dev/SKILL.md`. No content
  changes in this commit — pure format conversion.
- `git rm org.skill org-dev.skill`; `git add` the two new paths.
- Update CLAUDE.md's "Repository layout" listing (currently lines ~19-20)
  to reference the new paths instead of the root-level zip files.
- Update `bin/check-org-dev-skill`'s `check_skill_zip` function (and its
  two call sites) — it currently asserts each `.skill` file is a zip with
  exactly one entry at a specific internal path. Replace with a check that
  the new `SKILL.md` files exist at their expected locations and are plain
  text (not zip-magic-byte-prefixed). Run the script after editing to
  confirm it passes.
- Remove/rewrite org-dev/SKILL.md's section "7. Editing the `.skill` files
  themselves" — the unzip/edit/rezip procedure it documents no longer
  applies once the files are plain text. Delete the section (no renumbering
  needed elsewhere in the file).
- Leave DONE.org's historical prose mentioning the zip-packaging decision
  untouched (e.g. the "org-dev skill" and "Make check-org-dev-skill line-
  number checks robust" archived headings) — that's a legitimate historical
  record of a since-superseded decision, a different concern from the
  Plan-checklist reconciliation burden this change is actually about.

### Commit 2: discard the Plan-checklist convention

**CLAUDE.md** — under "State transition rules", add a new standing rule next
to the existing "any newly described task gets an org heading"/`:CREATED:`
rules: when a new org heading is created as the direct result of an approved
Plan-Mode plan, write only that heading (title, tags, properties, any
Plan-file link, intro body) and stop — show it and get explicit approval
before transitioning to `DOING` or touching anything else the plan
describes. Plan-Mode approval covers the implementation approach; it is not
approval of the heading's exact wording. (This rule is what this very task
is following right now — TODO.org's new heading was written and shown
separately before any other edit began.)

Under "Engineering practices", delete the two-paragraph
`Plan [/]` reconciliation rule (`**Rule**: when a task's...` through `...just
needs to not be skipped.)`). Replace with:
- Work planned via Claude Code's own Plan Mode gets a single permanent link
  in its heading body — `[[file:~/.claude/plans/<slug>.md][Plan]]` — added
  when the heading goes `DOING`. No transcription into org, ever; the link
  is the record, and it is **not removed at `DONE`**. A task with no
  separate Plan Mode session simply carries no link.
- Before a `DONE` heading is archived, add a concise prose outcome summary
  next to that link — what shipped, how it was verified, anything that
  differed from the plan. `DONE.org`'s existing `*Verified, not just
  implemented:*`/`*Implementation notes:*` style is the model to match.
  Applies to delegated-subagent work too: ask for a one-paragraph summary in
  the final report, not per-checkbox status.

**`.claude/skills/org/SKILL.md`** — remove the three checklist-maintenance
bullets under "Editing & transforming" ("Check off completed subtasks as you
go," "Only check a box once the work is verified," "Recompute statistics
cookies whenever you check a box") and the "A 'Plan' checklist is a
sub-heading, not bold text" bullet under "Generating .org content." Leave
the generic "Checkboxes & progress cookies" syntax-reference section
untouched — that's general org syntax, independent of the discarded
convention.

**TODO.org:**
- Remove the `**** Plan [/]` block from the 4 MAYBE roadmap items (Idle-based
  auto clock-out, Coarsen `:SESSIONS:`, Remote MCP access, Package the Warp
  wiring) and from the still-open TODO heading `2e34162a-...` — no backing
  plan file for any of them, nothing to link, each heading's own prose
  already stands alone.
- Resolve the DOING meta-heading `6a448345-...`: replace its unresolved
  "Open questions" with the actual resolution reached here, `org_set_todo`
  to `DONE`, then `org_archive`. No clock action needed.
- Add this task's own heading under `** Developer tooling` (`:ID:` +
  `:CREATED:`, created by hand). Dogfoods the new convention: a
  `[[file:~/.claude/plans/let-s-rip-it-out-floofy-blossom.md][Plan]]` link
  in the body, `org_clock_in` on `DOING`. At completion: `org_clock_out`,
  `org_set_todo` to `DONE`, a concise outcome summary next to the retained
  link, then `org_archive`.

**DONE.org:** strip the `*** Plan [n/m]` block from all 14 archived
headings. Where a checklist has a real preamble sentence (e.g. org_capture's
"Verified empirically under `emacs --batch -Q`...", org_query's "Verified
against org-ql's actual source..."), fold it into the adjacent prose rather
than dropping it. Every one of the 14 already has its own separate prose
write-up capturing what actually happened, so no outcome information is
lost. Leave the "org-dev skill" heading's separate `*Follow-up:* [2/2]`
checklist alone — a retrospective record of verification steps actually
taken, not a forward-looking `Plan` transcription. No links get retroactively
added to any of the 14.

## Files

- `.claude/skills/org/SKILL.md`, `.claude/skills/org-dev/SKILL.md` (new)
- `org.skill`, `org-dev.skill` (removed)
- `/Users/neil.best/git/claude-code-ide-org/CLAUDE.md`
- `/Users/neil.best/git/claude-code-ide-org/bin/check-org-dev-skill`
- `/Users/neil.best/git/claude-code-ide-org/TODO.org`
- `/Users/neil.best/git/claude-code-ide-org/DONE.org`

## Verification

- `bin/check-org-dev-skill` passes after commit 1 (confirms the new
  plain-text layout and its own updated checks are consistent).
- `grep -n "Plan \[" TODO.org DONE.org` returns zero matches after commit 2.
- `grep -rn "org.skill\|org-dev.skill"` across the repo (excluding DONE.org's
  historical prose, left alone by design) shows only the new
  `.claude/skills/` paths.
- Re-read both edited SKILL.md files and CLAUDE.md for internal consistency.
- After archiving, `org_query` confirms TODO.org no longer shows either
  heading as active, and DONE.org's `* Done` section contains both with
  intact `:LOGBOOK:`/`:SESSIONS:` drawers; confirm the live Emacs buffer
  reflects on-disk state rather than assuming the tool calls alone sufficed.
