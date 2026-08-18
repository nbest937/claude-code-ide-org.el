# Archive sweep: mirror TODO.org's categories into DONE.org

## Context

Nothing has been archived since before the queue cutover. TODO.org is 12,927
lines and **64% of it is completed work** — 41 level-2 `DONE`/`CANCELLED`
subtrees, ~8,300 lines. This is TODO.org `:ID:` 38b92521, whose `:BLOCKER:`
(b5f7c5c7) is now satisfied.

Two things make this more than a bulk move:

1. **DONE.org's shape is being changed at the same time.** Its flat `* Done`
   came from `#+ARCHIVE: DONE.org::* Done` and was never wanted. We mirror
   TODO.org's 7 categories instead, using inherited `:ARCHIVE:` properties —
   verified end-to-end on 2026-08-12 and recorded in 38b92521.
2. **Ordering is a requirement, not a side effect.** Each DONE.org category
   section must read newest-completion-first.

Outcome: TODO.org holds only live work; DONE.org holds the rest, organised by
category and ordered by completion.

## Decisions already made

- Mirror categories now (not flat `* Done`, not "decide later").
- Within each category: **descending completion time**, newest at top.
- Sequence: 39 childless subtrees → `23a75720` (3 children) → `b5f7c5c7`
  (31 children, 4,386 lines) as its own step.
- Outcome summaries: write one for `9e80a32d` (the only empty body),
  spot-check a handful of others, don't audit all 23.
- DONE.org's existing 22 entries get redistributed into the categories.

## The two mechanics everything rests on

**`org-archive-reversed-order`.** Default `nil` (appends). Bound to `t`, org
pastes each subtree as the *first* child of the target
(`org-archive.el:369-373`). So **archive in ascending completion order** and
the result is descending. Bind it in a `let` around the whole driver — never
`setq` it, or every later `C-c C-x C-a` in that Emacs changes behaviour.

**`claude-code-ide-org-archive` returns an error *string*, it does not
signal** (`config.el:63-75`). A naive loop sails past a failure and produces a
*silently wrong order* for everything after it. The driver must check the
return value and abort:

```elisp
(let ((org-archive-reversed-order t)
      (claude-code-ide-org--log-source "org_archive_sweep"))
  (dolist (id ids)
    (let ((r (claude-code-ide-org-archive id)))
      (unless (string-prefix-p "Archived: " r)
        (error "Sweep aborted at %s: %s" id r)))))
```

This must run as **one elisp form via emacsclient**, not 41 `org_archive` MCP
calls — there is nowhere to put the `let` around a tool call.

## Resolving a conflict between two of the decisions

"Epic last" and "descending completion order" cannot both hold literally.
`b5f7c5c7` completed `[2026-08-15 Sat 19:02]`, but **11 headings completed on
08-17** and belong above it. Archiving it last puts it at slot 1 of *Clock
lifecycle & visibility* when it belongs at slot 10.

Reconciliation: keep the phasing, then **reposition** with 9 ×
`claude-code-ide-org-move-sibling` (`config.el:1926`, already an MCP tool).
This preserves "separate deliberate step" and the ordering. The alternative —
archiving it mid-sequence — dissolves the deliberate step and is not chosen.

## Completion timestamps: a tier ladder

Only **28 of 41** carry a `- State "DONE"/"CANCELLED" … [ts]` log line. There
are **zero** `CLOSED:` lines (`org-log-done` is nil — the root cause of this
whole exercise; worth its own heading later).

- **T1** — the state-change log line (28).
- **T2** — `git log --reverse -S'<exact heading line>' -- TODO.org`, first
  commit's author date (13). Verified working.
- **T3/T4** — last CLOCK end, then `:CREATED:`. Expected to be unused; declared
  so a future sweep has the ladder.

Cross-check every T2 against `:CREATED:` and last clock-out; record anomalies
rather than overriding them silently.

**Tie-break:** sort ascending by `(timestamp, TODO.org line number DESC)`, so
ties preserve TODO.org's own top-to-bottom order in DONE.org.

Record the 41-row manifest (`id | category | timestamp | tier`) in
**38b92521's outcome summary**, so the ordering stays auditable and travels
with the heading when it is itself archived.

## Steps

Each step is one commit.

1. **Test archiving a subtree with children.** No existing test covers it
   (`config-test.el:281-297, 395-407` are all childless), and it is exactly
   what steps 6–7 do. Land it *before* anything moves.
2. **Narrow the level-1 prose rule.** `.claude/rules/org-conventions.md:51-55`
   says level-1 headings carry "no `:PROPERTIES:` drawer". The lint
   (`config.el:5720-5729`) only forbids `:ID:`, `:CREATED:`, TODO keyword and
   tags — so `:ARCHIVE:` already passes. Narrow the prose to "no *task*
   metadata", the change 38b92521 argues for. Also fix
   `.claude/skills/org/SKILL.md:93-114`, which documents `* Done` as the
   target.
3. **Mirror the categories, and reorganise DONE.org first.**
   - `:ARCHIVE: DONE.org::* <title>` on TODO.org's 7 level-1 headings
     (lines 6, 1753, 10182, 11059, 11383, 11421, 11519).
   - Create the 7 category headings in DONE.org **in TODO.org's order**, and
     redistribute the 22 legacy entries under them using
     `:ARCHIVE_OLPATH:` (18 map mechanically; 4 lack it and need a judgement
     call). Order them by `:ARCHIVE_TIME:` descending.
   - Delete `* Done`, so its reappearance is a loud alarm meaning a category
     is missing its `:ARCHIVE:`.

   **Doing this first is mechanical, not cosmetic:** it pre-creates every
   target so `org-archive-subtree` always takes the "heading found" branch and
   never the create-at-`point-max` branch — which would otherwise create
   categories in *archival* order.

   `org_refile` cannot do this (it targets by `:ID:`, which level-1 headings
   must not have). Hand edit, verified by a sorted-line diff.
4. **Outcome summary for `9e80a32d`** (`TODO.org:7139`, the one empty body),
   plus spot-check fixes.
5. **Archive the 39 childless subtrees**, ascending, one `let` form.
6. **Archive `23a75720`** (3 children) — the with-children canary at 206
   lines before the 4,386-line one. Lands at slot 1, which is correct.
7. **Archive `b5f7c5c7`** (31 children).
8. **Reposition `b5f7c5c7`** down 9 siblings to its completion-order slot.

## Verification

**Before (gate — abort on any failure):**
- `git status --porcelain TODO.org DONE.org` empty; no modified Emacs buffer
  for either (`claude-code-ide-org--tracked-file-modified-p`, `config.el:1454`).
- `org_pending_updates` reports nothing — 38b92521's stated precondition.
- `org-archive-subtree-save-file-p` is `t` or `'from-org`. **If nil, DONE.org
  accumulates 41 unsaved changes while TODO.org is saved after each cut — a
  crash loses the archive and leaves TODO.org already emptied.** Sharpest
  data-loss mode in the operation.
- All 41 `:ID:`s resolve (`org-id-find`) *before* archiving any.
- No open clock on any of the 41.
- Baselines recorded: `bin/lint-org` (0 errors, 28 warnings), `bin/test`,
  `bin/sync-plans --check`.
- No other Claude session active.

**After each phase:**
- **ID conservation** — `grep -h '^:ID:' TODO.org DONE.org | sort` byte-identical
  before and after. This is the check that catches a truncated paste, the one
  failure invisible in a 4,386-line move.
- `bin/lint-org` 0 errors and **28 warnings total** — 8 migrate from TODO.org
  to DONE.org with `b5f7c5c7`, so the total is the check, not the per-file count.
- Heading counts invariant; content diff shows only `:ARCHIVE_*:` additions.

**At the end:**
- Every one of the 41 resolves *into DONE.org*.
- For each, `:ARCHIVE_OLPATH:`'s first component equals its containing
  category — free self-verification, since `org-archive-save-context-info`
  writes olpath.
- **The deliverable assertion:** parse DONE.org, join to the manifest, confirm
  timestamps are non-increasing top-to-bottom within each category.
- `bin/sync-plans --check` unchanged (plan-neutral: `bin/sync-plans:47` reads
  both files); `bin/test` green.

**Reversibility:** every phase is one commit; `git checkout <sha> -- TODO.org
DONE.org` restores both. Git does *not* restore `org-id-locations` — a revert
needs `M-x org-id-update-id-locations`. Put that in the revert procedure.

## Risks worth knowing

- **Exact-match target regexp** (`org-archive.el:352-354`). A mismatch between
  an `:ARCHIVE:` value and its DONE.org heading does not error — it silently
  appends a *second, near-identical* category at end of file. After step 3,
  assert each of the 7 `:ARCHIVE:` values equals `"DONE.org::* " ++` its own
  title and that DONE.org has exactly one matching heading. Watch
  `Clock lifecycle & visibility` and `Upstream (claude-code-ide.el)`.
- **Two level-3 `DONE` headings under the still-`DOING` 02aaae22**
  (`TODO.org:8045`, `8090`) are **excluded**. Archiving a level-3 heading
  individually flattens it to level 2, severing it from an in-flight epic.
  After the mirror this hazard applies to *every* level-3 heading, so write
  the convention down: **archive at level 2 only.**
- **DONE.org is not in `--tracked-files`** (`config.el:501-507`), so after the
  sweep `org_query` and unscoped `org_clock_report` lose sight of ~8,300 lines.
  Not fixed here; it makes the open MAYBE `0465c1d5` materially more urgent.
- **Links and blockers survive** — `org-paste-subtree` → `org-id-paste-tracker`
  re-points every moved `:ID:`, and `bin/lint-org` covers both files. Proven
  this session (89bf8663 was cancelled over exactly this).
- **org-element cache** under 41 consecutive cut/pastes: re-visit both buffers
  between phases, or run with `org-element-use-cache` nil.
- **Concurrent sessions** can queue a transition mid-sweep onto a heading that
  has since moved — the untested behaviour 38b92521 exists to avoid.

## Not doing

- No bulk archive helper. It would be used once and needs a docstring, MCP
  registration, tests and permanent maintenance to replace a four-line `let`.
- No `org-archive-reversed-order` or inherited-`:ARCHIVE:` tests — they test
  org, not this repo, and 38b92521 already records an end-to-end verification.
- The "should TODO.org itself be flattened further?" half of 38b92521 is
  deliberately left for *after* the sweep, which is the whole reason it was
  written as "then judge".
