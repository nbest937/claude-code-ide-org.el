# Refactor clock/TODO-state driving to an append-only event queue + interactive batch-apply review

Epic: TODO.org `:ID: b5f7c5c7-7ad6-4c68-9cce-3479db1f1644`.

> **Revised 2026-08-11, after an audit against what shipped. Read this
> first.**
>
> This is the epic-level map, written 2026-08-06 before any of it existed.
> Two later plans were written *against real code* and **supersede it
> wherever they disagree**:
>
> - `~/.claude/plans/event-queue-format.md` — the schema, writer and reader
> - `~/.claude/plans/review-and-cutover.md` — the review command and the cutover
>
> Superseded decisions below are marked inline rather than deleted; the
> reasoning that produced them is still worth having, and several were
> overturned for instructive reasons. **Nothing in this file should be
> executed from without checking the marker.**
>
> Status: Phase 0 partly discharged, Phase 1 shipped, Phase 2 nearly
> complete, Phase 3 partly cancelled, Phases 4–6 not started. Per-phase
> detail is on the phase headings.
>
> The one thing here that is *not* stale and *not* superseded is the
> Context section — the analysis of why live driving failed, and the
> accepted trade. That still holds and is still the reason the epic exists.

## Context

A day and a half of real use of the live-driving model — Claude Code sessions
mutating TODO keywords, the shared org clock, and `:LOGBOOK:`/`:SESSIONS:`
drawers directly and synchronously — produced two clock-marker desync
incidents, a malformed concurrent-write `CLOCK:` line, an idle-clock-hijack
bug, a clock-ownership gap, a zero-time-clock erasure bug, and the discovery
that org's native state-change logging hangs Emacs indefinitely when
triggered non-interactively, forcing permanent `org-inhibit-logging`
suppression. Root cause (per the epic's own analysis): org's clock/logging
model assumes one human, one buffer, one synchronous keypress; this project's
workload is concurrent sessions, background agents, and non-interactive
`emacsclient` calls.

The redesign: sessions stop touching live org state for TODO transitions and
clock start/stop. They append JSON events to per-session queue files. A
human-triggered interactive Emacs command reviews the accumulated events and
applies the approved subset through org's real machinery (`org-todo`,
`org-clock-in`, `org-clock-out`), so native logging finally works. Read-only
tools and structural edits (query, clock-report, refile, archive, capture,
sort, move) stay direct — only the two incident-causing categories move.

Accepted trade (CLAUDE.md "Direction"): org state is only as fresh as the
last human review pass. Apply is always human-triggered, never programmatic.

## Decisions settled with the user (2026-08-06)

1. **Scope**: whole epic, phased, in one plan. Later phases get revised if
   the Phase 0 gates surprise us — that's expected, not a plan failure.
2. ~~**Queue location**: per-project, gitignored —
   `<repo>/.claude/org-updates/<session_id>.jsonl`. Hooks already have
   `CLAUDE_PROJECT_DIR`; matches the in-repo gitignored `clock-status.json`
   precedent; keeps review scoped to one project's org files.~~
   **SUPERSEDED.** Shipped as a global `~/.claude/org-updates/`, via the
   `claude-code-ide-org-queue-directory` defcustom (overridable per project
   with `CLAUDE_ORG_QUEUE_DIR`). Consequence not yet faced: review is
   therefore *not* scoped to one project's org files, which was the stated
   reason for the original choice. Nothing has needed it yet because there
   is one project; revisit before there are two.
3. ~~**Attribution**: `session_id` (and optional `agent_id`) become explicit
   tool arguments on the queue-writing MCP tools, following
   `org_log_background_plan`'s existing precedent (config.el:1908). Missing
   session_id → events land in `unattributed.jsonl`, never dropped.~~
   **SUPERSEDED, and for a reason worth keeping.** MCP tools are served by
   Emacs and *never receive* `session_id` — it exists only on hook stdin.
   A tool-side writer therefore could not key files by session at all, so
   the write moved to a `PostToolUse` hook (`event-queue-format.md`,
   decision 1). This also got subagent attribution for free: `agent_id` and
   `agent_type` arrive on the same payload, which is why `16160d23` needs
   no schema change. And the fallback inverted — an event with no
   `session_id` is **dropped**, not filed under `unattributed.jsonl`,
   deliberately: there is no file to write to, and inventing a filename
   would let a stray unkeyed event masquerade as a real session's work.

Decisions made in this plan (revisit if they chafe, but they're settled
enough to build on):

4. **No runtime feature flag / dual mode.** The write-path flip (Phase 4)
   is one commit, made only after the apply and read sides exist. Rollback
   is `git revert`, not a defcustom. Dual-path handlers in every tool cost
   more than they insure against for a single-user project.
5. **The `:SESSIONS:` drawer is retired.** *(Disputed — see the amendment
   after this list. Do not act on this decision without resolving it.)*
   Confirmed with the user
   2026-08-06: nothing writes it under this design — pause/resume become
   queue events (its raw-log role moves to the per-session `.jsonl` files,
   which are more durable and carry the same per-turn granularity), and the
   reviewed, human-confirmed residue lands in `:LOGBOOK:` as the
   active/inactive annotation lines clock-template.org now demonstrates.
   `org_log_background_plan`'s "Background-planned" `:SESSIONS:` write is
   likewise replaced by a queued event with the real (session_id, agent_id)
   key (16160d23). Historical `:SESSIONS:` drawers stay in place as legacy
   history — no migration. Consequence for Phase 6: 2b0988ed
   (`:SESSIONS:`/`:LOGBOOK:` ordering) becomes moot → CANCELLED-with-pointer,
   contrary to the epic's earlier "likeliest survivor" guess.
6. ~~**Apply lifecycle**: every event carries a UUID `event_id`; applying
   appends an `applied` event (listing consumed `event_id`s) to the same
   per-session file — append-only is preserved, whole-line `O_APPEND`
   appends from two writers are safe. The review command offers deletion of
   fully-applied files for dead sessions as a separate, explicit cleanup
   action. Readers ignore events referenced by any `applied` record and
   tolerate a trailing partial line (crash-safety).~~
   **SUPERSEDED.** No `event_id` field exists. Applied state lives in a
   *sibling* `<session_id>.applied` file, and — after one failed attempt —
   holds a **set** of applied `ts` strings, not a high-water mark: a
   watermark cannot advance past an item the human skipped, which on
   2026-08-07 produced an apply that recorded no progress at all and would
   have re-proposed and re-applied everything. Events are never appended to
   by the reader, so the queue file has exactly one writer. Partial-line
   tolerance survived as designed.
   **The cleanup action was never built, and that is now load-bearing** —
   see the amendment below.

> **Amendment 2026-08-11 — the unresolved question underneath decisions 5
> and 6.** `9d2fcdad`, written a day after decision 5, treats the
> `:SESSIONS:` question as deliberately deferred and `MAYBE`. Decision 5
> calls it confirmed. Both cannot be current, and it is not bookkeeping:
> it decides whether a drawer, its parser, its consolidator and their
> tests get deleted.
>
> The argument recorded in `9d2fcdad` is not the strongest one available.
> The real question is what a *drained queue file* is. Decision 6 above
> contemplated deleting fully-applied files; `event-queue-format.md` argues
> the opposite ("deletion loses history the review UI may still want").
> That disagreement decides `:SESSIONS:`'s fate on its own:
>
> - CLAUDE.md's stated job for `:SESSIONS:` is the full wall-clock arc
>   *including the gaps*. After the cutover, `:LOGBOOK:` holds only the
>   human-confirmed residue — the gaps exist **only** in the raw queue
>   files.
> - So if queue files are disposable, the arc-including-gaps has no durable
>   home and something must keep it. If queue files are permanent, the
>   `.jsonl` does that job strictly better than the drawer ever did: it
>   carries `session_id`, `agent_id`, `agent_type` and `source`, none of
>   which `:SESSIONS:` records.
>
> **Resolve "is a drained queue file a permanent record or a spool?" and
> `:SESSIONS:`'s fate follows without needing to be argued separately.**
> The cost of declaring them permanent is unbounded queue growth; the cost
> of declaring them a spool is that retiring `:SESSIONS:` becomes a real
> loss rather than a tidy-up.

## Phases

### Phase 0 — Verification gates (sub-tasks c084553c, 3d576d29). Do first; findings can reshape everything below.

> **Status 2026-08-11: partly discharged, and the gate was overtaken by
> events.** `3d576d29` is DONE — backdating works, and so does driving
> `org-store-log-note` directly. The `org-agenda-bulk-*` item was answered
> during `review-and-cutover.md`'s planning (it keys off agenda-built text
> properties and is not callable elsewhere; its *design* was copied).
> `c084553c` is still TODO with one item genuinely outstanding: whether
> `org-element` should replace the regex-and-position drawer editing. That
> question has *gained* weight — both drawer-level data-loss incidents this
> project has had (`ba8249c1`, `b74e0f19`) lived in exactly that code — but
> it no longer gates anything, since the bespoke code was written anyway.

Live-verify in the running Emacs (via `emacsclient`, per the org-dev skill),
and record findings as notes on the two sub-task headings:

- `org-clock-in` accepts an explicit `START-TIME` arg and `org-clock-out`
  an `AT-TIME` arg — confirm they produce correct backdated `CLOCK:` lines
  non-interactively.
- `org-log-note-effective-time` — confirm let-binding it around an
  interactive-context `org-todo` backdates the native state-change log line.
  Also check `org-todo` + `org-add-log-note`/`org-store-log-note` behavior
  when driven from inside a real interactive command (the whole premise that
  native logging works there).
- The agenda lead from c084553c: on a scratch heading, one active- and one
  inactive-timestamp list item inside `:LOGBOOK:`; run `org-agenda-list`;
  confirm exactly the active one appears. This is the mechanism behind the
  review command's "guidepost" annotations.
- Survey per c084553c's instruction: `org-element` structural editing vs.
  the current regex drawer editing for apply-time writes;
  `org-agenda-bulk-*` machinery as a callable base (or at least the model)
  for the review UI. Do not treat prior custom choices as proof nothing
  native exists.

Gate: if backdating turns out unsupported/partial, stop and re-plan Phases
2–4 before writing code.

### Phase 1 — Queue format + writer library (sub-tasks 32272061, 16160d23-schema)

> **Status 2026-08-11: SHIPPED** (`4678572`, amended `8b4f795`, `7d56efe`).
> See `event-queue-format.md` for the authoritative schema. The sketch
> below is wrong in detail: the field is `id` not `heading_id`, there is no
> `payload` and no `event_id`, and `note`/`from`/`agent_type` were added
> later. There is **no elisp writer** — the shell script
> `bin/hooks/queue-append` is the only writer, which is the point: the
> queue must be writable with no Emacs running. `.gitignore` needed no
> entry once the queue moved out of the repo.

- Define the JSONL schema, one event per line:
  `{event_id, kind: todo|clock_in|clock_out|pause|resume|applied, ts
  (ISO-8601 with offset), heading_id (org :ID:, absent for pause/resume),
  session_id, agent_id (optional), payload (kind-specific: e.g. state for
  todo)}`. Compound `(session_id, agent_id)` key per 16160d23 — one file
  per real `session_id`, `agent_id` as an event field, never a synthetic
  `-bgN` label.
- `pause`/`resume` keep today's per-turn-boundary granularity — they are the
  human's reconstruction guideposts (720b2dcf), never coarsened.
- Elisp writer: `claude-code-ide-org--queue-append` (plain `O_APPEND`
  one-line write; model the atomic-write hygiene on
  `claude-code-ide-org--write-clock-status`, config.el:1817, but appending,
  not replacing). Shell writer: a tiny shared helper `bin/org-queue-append`
  (jq-built JSON, `>>`), used by hooks so no Emacs is needed to write.
- Shared elisp reader: parse a queue dir → events grouped by heading and
  (session, agent), latest-wins ordering, applied-filtering, partial-line
  tolerance. Designed once, reused by Phases 2, 3, and 5 (explicit
  instruction in 63a642c7).
- Add `.claude/org-updates/` to `.gitignore`.
- Tests: ERT over scratch queue dirs (same pattern as the existing suite —
  temp dirs, let-bound paths); shell writer exercised by direct invocation.

### Phase 2 — Interactive review-and-apply command (sub-task 720b2dcf)

> **Status 2026-08-11: built and largely verified; `720b2dcf` still DOING.**
> Shipped as `claude-code-ide-org-review` (not `-review-updates`), across
> `c81cba6` and four rounds of bug-fixing. The first interactive apply on
> 2026-08-07 exposed five bugs, four fixed immediately and the fifth
> (`f9f61c04`, stale-transition replay) fixed 2026-08-10. A second
> interactive pass on 2026-08-10 applied a real guidepost span cleanly.
> Two things are outstanding, both recorded on the headings: the
> unattributed-guidepost line shown in `review-and-cutover.md`'s own mockup
> was never implemented (`3d0487f4`), and `f9f61c04` cannot be
> interactively verified until the cutover — see its heading for the knot
> and the hand-written-queue way out.

The core deliverable. New interactive command (working name
`claude-code-ide-org-review-updates`), one keybinding:

- Scan pending queue files via the Phase 1 reader; reconstruct per-heading
  proposed transitions and intervals; collapse event chains (e.g.
  TODO→PLANNING→DOING from the ExitPlanMode path) into one coherent
  proposal, not independent replays.
- Review buffer: mark/unmark, jump-to-heading, edit-an-interval,
  apply-marked — org-agenda-bulk / magit-status as the interaction model
  (use whatever Phase 0's survey found callable).
- Apply calls the real `org-todo` / `org-clock-in` / `org-clock-out`, one
  item at a time, synchronously, inside this interactive command, with
  backdated timestamps per Phase 0's confirmed mechanisms — no
  `org-inhibit-logging`.
- **Two modes, structurally distinct** (core design principle from the
  heading): subagent-derived events (authoritative `duration_ms`) may be
  proposed as real `CLOCK:` entries and bulk-accepted; human-session events
  must never auto-write `CLOCK:` — render pause/resume guideposts as
  *active*-timestamp annotation lines beside `:LOGBOOK:` and let the human
  draw the interval, with an editable suggested default at most. `CLOCK:`
  lines stay inactive-timestamped, the sole arithmetic source of truth.
- Testable in isolation against synthetic queue files, before any writer
  flips — ERT for the reconstruction/collapse logic; a documented manual
  pass for the interactive buffer itself (per the engineering-practices
  rule: the fuzzy-interactive part is declared manual, not silently
  skipped).

### Phase 3 — Read side (sub-tasks 63a642c7, c9292ce8)

> **Status 2026-08-11: half of this phase is CANCELLED.** `c9292ce8`, the
> read-time overlay for `org_query`/`org_clock_report`, was cancelled —
> the second bullet below is dead and should not be built. `63a642c7`
> (the read-only pending-queue tool) is still TODO and unblocked; it reads
> the Phase 1 reader and touches nothing the cutover touches, so it is
> available as parallel work at any time.

- New read-only MCP tool `org_pending_updates`: queued events grouped by
  heading and session, on the Phase 1 reader. This is what a human consults
  before deciding to run the review pass.
- Overlay for `org_query` + `org_clock_report`, pure read-time, no write
  side effects, honoring the sub-task's settled sub-decisions: default to
  the calling session's own pending events (+N-from-other-sessions count);
  latest event wins; clock totals shown as "applied: X, +Y pending review",
  never merged; overlapping intervals union, not sum (union particulars
  deliberately deferred until real queued data exists).

### Phase 4 — Flip the write paths (sub-task feba67eb) — the cutover commit

> **Status 2026-08-11: not started; this is the critical path.**
> `review-and-cutover.md`'s Phase B is the authoritative version and is
> more current than the bullets below — but it is a *list of edits* where
> its Phase A is a sequenced plan, and it still needs an ordering that
> keeps the suite green between edits. Two corrections to the bullets
> below: `--trigger-auto-clock-in` was **not** retired, it is kept and
> suppressed during apply via the module's own re-entrancy guard (retiring
> it would break hand-edits made directly in Emacs, which still want it);
> and `--clock-owner-session-id`/`--planning-owner-session-id` were
> verified contained to this repo, so deleting them touches no Doom config.

- `claude-code-ide-org-set-todo` / `-clock-in` / `-clock-out`
  (config.el:1114/346/372) become queue appends: keep `:ID:` validation and
  truthful return strings ("queued, pending review", per c9292ce8's
  contradiction concern), add `session_id`/`agent_id` args to tool schemas.
  No buffer mutation, no `:SESSIONS:` writes, no consolidate-on-the-fly.
- `bin/hooks/session-pause` / `session-resume` → bare `bin/org-queue-append`
  calls, no `emacsclient` at all.
- `bin/hooks/exitplanmode-promote-planning` → queue append of a `todo`
  event (DOING) — the review command's collapse logic (Phase 2) handles the
  PLANNING→DOING chain.
- `bin/hooks/pretooluse-transition-guard` → queue-aware: validate against
  the latest *queued* state for the heading (jq over queue files), falling
  back to disk state via `emacsclient` when nothing is queued.
- `bin/clock-notify` → repurpose to "N updates awaiting review" (count
  unapplied events), since live-clock cross-checking is meaningless now.
- Delete `claude-code-ide-org--clock-owner-session-id` and
  `--planning-owner-session-id` (config.el:302/317) and their guard logic —
  after grepping for any remaining dependents, per feba67eb's own warning.
- Retire/disable `claude-code-ide-org--trigger-auto-clock-in` (config.el:1574)
  — clock intent now travels through the queue; an org-trigger auto
  clock-in firing during apply would reintroduce live-clock mutation.
  Check the other trigger hooks (demote-conflicting-next,
  auto-promote-sole-todo) still make sense running at apply time — they
  now fire inside the interactive apply, which is the correct, single-actor
  context for them.
- Audit subsystem (`claude-code-ide-org--audit-*`): now records apply-time
  changes only — verify its hooks behave sanely in that context.
- Rewrite the affected ERT tests: assertions change from "buffer/clock
  mutated" to "event appended, buffer untouched".

### Phase 5 — Statusline (sub-task 290b6fc5)

> **Status 2026-08-11: not started, and no longer really a statusline
> task.** `290b6fc5` has since been reframed as decoupling live "what is
> Claude attending to" visibility from the authoritative org clock —
> which is the same need `63a642c7` and `7771fc63` are circling from the
> tool and recovery-report sides. Three things wanting the same read is a
> signal to design that read path once rather than three times. Unblocked
> and parallelisable; it touches neither the review command nor the
> cutover.

`claude-code-ide-org--statusline-task-string` (config.el:768) reads the
queue dir's latest event (+ pending-review count) instead of
`org-clocking-p`/`org-clock-marker`/`org-clock-history`. Per the sub-task's
explicit instruction: surface "N updates awaiting review" and distinguish
applied vs queued, not just a relocated one-line label. `clock-status.json`
and its org-clock hooks stay (they now reflect apply-time activity only) or
get folded in here — decide when touching the code.

### Phase 6 — Reconcile + document (sub-tasks e51d6ba1, 02aaae22)

> **Status 2026-08-11: not started, but partly pre-empted.** `02aaae22`
> already carries the settled vocabulary for the rewrite — "per-turn
> clocking" splits into per-turn *guideposts* (the emission, which stays
> per-turn) and *confirmed intervals* (the record, which becomes
> per-review); "clocking" as an ongoing condition should be retired rather
> than qualified, since a clock is only ever live for the microseconds
> inside apply; and churn *relocates* to the queue rather than
> disappearing. The reconcile list below is unchanged except that
> `2b0988ed`'s fate depends on the `:SESSIONS:` question, which is
> disputed — see the amendment under decision 6.

- Revisit 53b0047d, 582cc7f4, d150c02e, 2b0988ed, 782cda6c, c954f650: each
  gets CANCELLED-with-pointer or confirmed-still-independent (2b0988ed
  likeliest survivor). 
- Rewrite CLAUDE.md's "State transition rules" / "Session tracking" / "MCP
  tools" sections and the org skill's transition table for the queue+review
  model. Its own sub-task, not a drive-by.

## Files touched (by phase)

- P1: `modules/tools/claude-code-ide-org/config.el` (+`config-test.el`),
  new `bin/org-queue-append`, `.gitignore`
- P2: `config.el` (+tests) — review command
- P3: `config.el` (+tests) — `org_pending_updates` tool registration, overlay
- P4: `config.el` (+tests), `bin/hooks/session-pause`, `session-resume`,
  `exitplanmode-promote-planning`, `pretooluse-transition-guard`,
  `bin/clock-notify`, `.claude/settings.json` (if matchers change)
- P5: `config.el`, possibly `bin/statusline.sh`
- P6: `TODO.org`, `CLAUDE.md`, `.claude/skills/org/SKILL.md`

## Process notes

- Feature branch: ~~`feature/event-queue-review`~~ — the branch actually
  used is **`feature/event-queue-format`**, pushed to origin 2026-08-11.
- First execution step after approval: add the
  `[[file:~/.claude/plans/plan-this-task-clever-cupcake.md][Plan]]` link to
  heading b5f7c5c7's body (the plan-link rule fires now, not at DOING).
- Each phase reloads and live-verifies via the org-dev skill; `bin/test`
  green at every phase boundary.
- Phases 0–3 are safe to land incrementally on the branch; Phase 4 is the
  single behavior-changing cutover and should be its own commit.
