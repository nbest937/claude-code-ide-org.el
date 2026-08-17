# Org skill: auto-capture and dedupe modification requests against existing TODOs

Tracks TODO.org `:ID: 7eb7dd8d-2d9b-4a63-afbd-5878298e42a4`.

## Context

Captured 2026-08-04 at "capture the idea" depth. The heading was blocked on
`b95b9fba` (Add a `PLANNING` TODO state) via `:BLOCKER:`; that heading is
now `DONE` (implemented and live-verified 2026-08-05, see its own body and
`~/.claude/plans/quirky-petting-lobster.md`), so the prerequisite has
landed and this heading's `:BLOCKER:` is satisfied (left in place per the
project's own convention that a satisfied `:BLOCKER:` is harmless and
documents sequencing history).

The feature, as specified in the TODO body: whenever the user asks to
modify a feature this project tracks, first check whether the request
overlaps an existing TODO.org heading (including `DONE` ones) before
creating a new one:
- **Match found** → ask the user for clarification ("this looks like it
  overlaps with `<heading>` — same task, or something new?"), never
  silently assume either way.
- **No match** (or user says "something new") → capture a new heading via
  `org_capture`, set it to `PLANNING`, ask clarifying questions, then offer
  Plan Mode. If the user declines planning, revert to `TODO` rather than
  leaving the heading stuck in `PLANNING`.
- **Separately**, regardless of match outcome: check whether the change
  interacts with any *open* (non-`DONE`, non-`CANCELLED`) task via a
  depends-on relationship in either direction, and surface that to the
  user.

Three open questions were explicitly deferred to planning; this plan
resolves all three (see "Design" below):
1. How "matches an existing TODO" is determined.
2. Whether an existing `:BLOCKER:` link is sufficient, or whether informal
   prose cross-references also need checking.
3. Exactly when in the org skill's flow this check fires.

**Scope clarification** (not stated explicitly in the body, resolved here
from context): "the org skill's scope" means requests to modify *this
project's own tracked features* — `config.el`, hooks, the skills
themselves, org conventions — i.e. the domain `TODO.org`/`DONE.org`
actually track, not arbitrary edits to the user's unrelated personal org
files. This is consistent with the body's plain reading (it's about
deduping against *this backlog*) and with precedent: the skill's existing
"Background-planning a batch of NEXT/TODO headings" section is likewise
written as project-specific workflow guidance living directly in
`.claude/skills/org/SKILL.md`, since that skill file only auto-loads
within this project.

### Two real blockers found during research (not anticipated in the TODO body)

Both must be addressed for the designed workflow to actually work, not
just documented as aspirational prose:

1. **`org_capture`'s target file is not `TODO.org` today.**
   `claude-code-ide-org-capture-file` (the defcustom that controls where
   `org_capture` writes) is `nil` everywhere it was searched —
   `~/.config/doom/config.el` and the `doom+` sources both — so
   `claude-code-ide-org--capture-target-file` falls back to
   `org-default-notes-file`, which Doom's own org module sets to
   `(expand-file-name +org-capture-notes-file org-directory)` (confirmed
   in `~/.config/emacs/sources/doom+/modules/lang/org/config.el:354-355`)
   — i.e. `~/org/notes.org`, not this project's `TODO.org`. `TODO.org` is
   only reachable today via the symlink `~/org/claude-code-ide-org/TODO.org
   -> .../git/claude-code-ide-org/TODO.org`, which `org-agenda-files`
   picks up for *reading* (`org_query`, session-context, etc.) but which
   `org_capture` never targets by default. A capture done under this new
   workflow, unmodified, would silently land in the wrong file entirely.
2. **`org_capture`'s template never stamps `:CREATED:`.** CLAUDE.md's
   state-transition rules require "any newly created org heading gets a
   `:CREATED:` property... at creation time" — unconditional, not scoped
   to manually-written headings. The template in
   `claude-code-ide-org-capture` (`config.el` ~line 1309) is
   `"* TODO %%i\n:PROPERTIES:\n:ID:       %s\n:END:\n"` — no `:CREATED:`
   line. Every heading `org_capture` has ever produced violates this rule
   today; this new workflow would make that violation routine instead of
   incidental (right now `org_capture` is lightly used — DONE.org shows
   one prior dev task for the tool itself).

Both are addressed in Design below, since without them this feature would
either write to the wrong file or produce non-compliant headings on every
use.

## Design

### 1. Fix `org_capture` to stamp `:CREATED:` (config.el)

Change the template string in `claude-code-ide-org-capture`:

```elisp
(format "* TODO %%i\n:PROPERTIES:\n:ID:       %s\n:CREATED:  %s\n:END:\n"
        new-id (format-time-string "[%Y-%m-%d %a %H:%M]"))
```

Mechanical, small, and directly testable — add one new ERT test alongside
the existing capture tests in `config-test.el`
(`claude-code-ide-org-test-capture-stamps-created-property`, using the
existing `claude-code-ide-org-test--with-capture-file` fixture): capture a
heading, read it back via `claude-code-ide-org-test--disk-contents`, and
assert a `:CREATED:` line matching the inactive-timestamp format is
present. This closes a real, pre-existing gap between `org_capture` and
CLAUDE.md's own rule — in scope here because this plan's workflow is what
turns that gap from incidental to routine.

### 2. Point `org_capture` at `TODO.org` (Doom config, user-level, not this repo)

Set, in `~/.config/doom/config.el` (the same file that already documents
`claude-code-ide-org-session-recovery-enabled` etc. per CLAUDE.md's
"Emacs integration" section):

```elisp
(setq claude-code-ide-org-capture-file
      (expand-file-name "TODO.org" "~/git/claude-code-ide-org/"))
```

**Flag for explicit confirmation before making this change**: this is a
global default affecting *every* `org_capture` call, not just this new
workflow — worth a one-line check with the user before setting it,
since it changes where *all* quick-captures land, in every session, not
only ones exercising this new dedupe behavior. If the user wants
per-project capture targets instead of one global default, that's a
larger redesign out of scope here (today's `org_capture` has no per-call
file override — see its docstring/MCP arg list, which takes only `title`).

### 3. New SKILL.md section: "Auto-capture and dedupe modification requests"

Add a new `##` section in `.claude/skills/org/SKILL.md`, positioned
**before** the existing "Background-planning a batch of NEXT/TODO
headings" section (this workflow is upstream of it — it's what decides
whether a heading needs creating in the first place; background-planning
already assumes the heading exists). Content:

```markdown
## Auto-capture and dedupe modification requests

Whenever the user asks to modify one of this project's own tracked
features — anything in `config.el`, the hooks, the skills themselves, or
org conventions — before creating a new TODO.org heading for it (per
CLAUDE.md's standing "any time a new task is described in conversation,
create an org heading" rule), first check whether the request overlaps
something already tracked. This check is a mandatory step inserted
immediately before that heading-creation moment, scoped to this project's
own backlog — not a check run against the user's unrelated personal org
files.

### 1. Search for an existing match

"Matches" is a judgment call, not a mechanical decision — no semantic
search tool is available here, so combine a cheap mechanical narrowing
step with the model's own reading:

1. Pull 2-4 keywords from the request (the feature/tool/function/hook name
   involved).
2. Run `org_query` with a `heading:"<keyword>"` search (repeat for a couple
   of phrasings if the first doesn't obviously map to one term; combine
   candidates via `,` for OR). Deliberately issue this with **no `todo:`
   filter** — `org_query`'s default file scope
   (`claude-code-ide-org--tracked-files`, i.e. `org-agenda-files`) already
   includes `DONE.org` (confirmed: `org-agenda-files` is a recursive scan
   of `org-directory`, and `TODO.org`/`DONE.org` both live under it via the
   `~/org/claude-code-ide-org/` symlink), so an unfiltered query
   automatically surfaces `DONE` headings too — no special-casing needed
   for the "including DONE ones" requirement.
3. Also grep `TODO.org` and `DONE.org` body prose (not just heading text —
   `org_query`'s mini-language only matches headings/tags/todo/priority,
   never body text) for the same keywords. This is not optional: this
   project's own backlog already contains matches found only in prose,
   not heading titles (e.g. the "substantial overlap with [[id:...]]"
   cross-reference between `3cb3f955` and `782cda6c`, written before any
   `:BLOCKER:` existed between them) — informal cross-references predating
   the `:BLOCKER:` convention are the demonstrated norm here, not a
   hypothetical edge case.
4. Read each candidate's full heading + body and judge, as the model,
   whether it's a real overlap. Be honest that this step is fuzzy — a
   plausible-looking keyword hit is not proof of overlap, and a truly
   unrelated phrasing can still be the same task.

### 2a. If a plausible match is found

Ask the user directly — do not silently create a duplicate and do not
silently assume it's the same task:

> "This looks like it might overlap with `<heading title>` (`:ID:
> <id>`, currently `<state>`) — is this the same task, or something new?"

- **Same task**: treat the existing heading as the target for whatever
  the user asked (further conversation, replanning, etc.) instead of
  capturing anything new. If it's `DONE`/`CANCELLED` and the user wants it
  reopened, that's a separate explicit decision for the user to make, not
  an automatic reopen.
- **Something new**: proceed to step 2b.

### 2b. If no match (or the user confirms it's something new)

1. `org_capture(title)` — creates a new level-1 `* TODO` heading with a
   real `:ID:` (and, once the fix in this task lands, a `:CREATED:`
   stamp) in `claude-code-ide-org-capture-file`.
2. `org_refile(new_id, target_id)` — move it under the best-fit existing
   top-level category heading (`Skill logic`, `Clock lifecycle &
   visibility`, `Observability`, `Bigger swings`, `Upstream
   (claude-code-ide.el)`, `Documentation`, `Tooling`, or ask the user if
   none obviously fits). `org_capture` alone only ever produces a
   level-1 heading; this project's convention reserves level-1 for
   untagged category headers and requires actual tracked work to live as
   a level-2+ child (CLAUDE.md, "Top-level headings"), so a refile step is
   not optional here.
3. `org_set_todo(new_id, "PLANNING")` — the existing
   `claude-code-ide-org--trigger-auto-clock-in` trigger hook fires
   automatically on any transition *to* `PLANNING` (it checks the
   destination state only, not the origin), so this alone opens the clock
   — no separate `org_clock_in` call needed, even though the heading is
   moving `TODO → PLANNING` rather than the more common `NEXT →
   PLANNING`.
4. Ask the user any clarifying questions needed to scope the task.
5. Offer to plan it properly (enter Plan Mode / `EnterPlanMode`).
   - **Accepted**: proceed into Plan Mode as normal — the existing
     `PLANNING` → `DOING` auto-promotion on `ExitPlanMode` handles the
     rest.
   - **Declined**: `org_clock_out()` then `org_set_todo(new_id, "TODO")`
     — revert rather than leave the heading stuck in `PLANNING`. This
     mirrors CLAUDE.md's general "any transition *from* `PLANNING` must
     close the clock first" rule, extended here to a transition target
     (`TODO`) not previously listed in that table — see the CLAUDE.md
     update below.

Note: this is *not* the "new heading from an approved Plan Mode plan"
case CLAUDE.md's approval-gate rule covers (write only the heading, stop,
get approval before `DOING`/further edits) — that rule is specifically
about headings created as a *result* of an already-approved plan. This
workflow runs *before* any Plan Mode session exists for the task, so no
extra approval checkpoint is inserted between capture and `PLANNING`;
the natural checkpoint is `EnterPlanMode`/`ExitPlanMode` itself, which
already requires the user's approval to proceed past.

### 3. Depends-on / blocker check (always, regardless of match outcome)

Once a target heading is identified — the matched existing one, or the
freshly captured one — check both directions of the dependency graph.
`org_query`'s mini-language has no property-value predicate, so this is a
direct text search (Read/Grep) over the tracked files, not another
`org_query` call:

- **Forward** (does this change depend on unfinished work?): read the
  target heading's own `:BLOCKER:` property, if any. For each listed
  `:ID:`, grep `TODO.org`/`DONE.org` for that ID's property drawer and
  read the enclosing heading's TODO keyword. If it isn't `DONE`/
  `CANCELLED`, surface: "heads up — this depends on unfinished work:
  `<blocking heading>` (`<state>`)."
- **Backward** (does something else depend on the thing being changed?):
  grep `TODO.org`/`DONE.org` for `:BLOCKER:` properties naming the target
  heading's own `:ID:`. For each hit whose owning heading is itself open
  (not `DONE`/`CANCELLED`), surface: "heads up — `<dependent heading>`
  (`<state>`) is blocked on this."

Both are informational — surface findings to the user, don't block the
capture/dedupe flow on them.
```

### 4. CLAUDE.md — one new row in the state-transition table

Add `PLANNING → TODO` to the "State transition rules" table (the
existing table has `NEXT → PLANNING`, `PLANNING → DOING`, and `PLANNING →
{DONE,WAIT,CANCELLED}`, but never a revert-to-`TODO` path — this workflow
is the first thing in the project that needs one):

| Transition | Side effect |
|---|---|
| `PLANNING` → `TODO` | Close the CLOCK (call `org_clock_out`) — same as every other transition *from* `PLANNING` except the `DOING` handoff |

This is documentation only (the general "any transition *from* `PLANNING`
must close the clock first, except `PLANNING → DOING`" rule already
covers it in prose; this just enumerates the concrete pair like its
siblings). No code change needed — `org_set_todo` has no per-transition
special-casing to begin with; it's a plain `org-todo` call plus the
existing trigger hooks.

### 5. SKILL.md's own (separate, older) state-transition table

Found incidentally during research, **not fixed here** (out of scope —
flagging only): `.claude/skills/org/SKILL.md`'s "State transition
conventions" table (around line 232) predates `PLANNING` entirely — it
still shows the pre-`b95b9fba` five-state sequence
(`TODO`/`NEXT`/`DOING`/`WAIT`/`MAYBE`). This plan's new section doesn't
depend on that table being current, but it's a real, separate staleness
gap worth its own follow-up TODO heading rather than silently
patching it as a side effect of this task.

## Verification

- **Mechanical / automated** (the parts of this feature that have a real
  mechanical surface): the `:CREATED:` stamping fix gets one new
  `bin/test`-run ERT test, per CLAUDE.md's testing rule. No other code
  changes in this plan, so no other new automated tests.
- **Manual, explicitly not forced into a fake automated test** (per
  CLAUDE.md's "reasonably feasible" carve-out — trigger-matching and
  prose-workflow-following are inherently fuzzy): after implementation,
  do a real dry run —
  1. Describe a modification request that clearly overlaps an existing
     TODO.org heading by title; confirm Claude asks for clarification
     instead of silently capturing a duplicate.
  2. Describe one that overlaps only in body prose, not heading text;
     confirm the grep step still catches it (this is the main behavior
     this plan is adding beyond what `org_query` alone would find).
  3. Describe a genuinely new modification request; confirm it captures
     correctly (in `TODO.org`, under a sensible parent category, with
     `:ID:`/`:CREATED:` both present), transitions to `PLANNING` with a
     clock opening, and that declining Plan Mode reverts it cleanly to
     `TODO` with the clock closed (`bin/test`'s `org-dev` reload/scratch-
     heading workflow, same as `b95b9fba`'s own live verification pass).
  4. Confirm the depends-on surfacing fires correctly in both directions
     against a heading with a real `:BLOCKER:` (e.g. this very heading,
     `7eb7dd8d`, once its own blocker context is exercised) and against a
     heading referenced only via informal `[[id:...]]` prose.
- Confirm `claude-code-ide-org-capture-file` actually resolves to
  `TODO.org` after the Doom config change (`M-x describe-variable` or an
  `emacsclient -e` read), since this plan's whole capture path is
  contingent on that fix landing correctly.

## After approval

Per CLAUDE.md's Plan-link rule, add
`[[file:~/.claude/plans/todo-autocapture-dedupe.md][Plan]]` to TODO.org
heading `7eb7dd8d-2d9b-4a63-afbd-5878298e42a4`'s body as soon as this plan
is finalized — a separate step from implementation, and (per the same
rule, plus the general "Plan approval and start-implementing are always
two separate checkpoints" rule) not license to proceed straight into the
`:CREATED:` fix, the Doom config change, or the SKILL.md edit without the
user's explicit go-ahead first.
