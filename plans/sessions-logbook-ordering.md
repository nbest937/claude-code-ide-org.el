# Reorder :SESSIONS: entries to match :LOGBOOK: ordering

Tracks TODO.org `:ID: 2b0988ed-eb92-4fa7-904a-cb2d10941bfd`.

## Context

Org's own `:LOGBOOK:` (native `CLOCK:` lines, and native TODO-state-change
log notes) is newest-first because org itself inserts each new entry right
after the drawer's opening marker (`org-clock-find-position`,
`org-add-log-note`) — this project's clock-writing paths
(`claude-code-ide-org-clock-in`/`-out` at
`modules/tools/claude-code-ide-org/config.el:346`/`372`) call
`org-clock-in`/`org-clock-out` directly, so the newest-first `:LOGBOOK:`
order is inherited for free from org, not implemented by this project.

`:SESSIONS:` is this project's own drawer, written by
`claude-code-ide-org--log-session-event` (config.el:331) via the generic
`claude-code-ide-org--append-to-drawer` (config.el:266), which always
inserts at `org-element-contents-end` — the *bottom* of the drawer, right
before `:END:`. That makes `:SESSIONS:` oldest-first, the reverse of
`:LOGBOOK:`, exactly as the TODO body describes.

### Sanity check: is newest-first actually the right call?

The TODO body explicitly asks not to just assert the title's premise. Real
weighing:

- **For matching `:LOGBOOK:`:** consistency between the two drawers when a
  user reads a heading's property area — both would put "what just
  happened" at the top, with no need to scroll past growing history to see
  it. This also matches the near-universal "changelog/commit-log/journal"
  convention (`git log`, Slack, most changelogs) of newest-at-top.
- **For keeping oldest-first (the status quo):** a pause/resume history
  reads as a small narrative ("started at 9, paused at 10, resumed at
  11…"), and oldest-first is the natural order for that. It's also simply
  *less code to get right* — the current implementation leans on
  "textual order in the drawer equals chronological order" in three
  separate places (detailed under Design below), and flipping the
  convention means each of those either breaks or needs to become
  order-agnostic.
- **Verdict:** proceed with newest-first. The consistency argument is
  real and matches the TODO title's instinct, and CLAUDE.md's own framing
  of the *other* `:SESSIONS:`/`:LOGBOOK:` mismatch (relative drawer
  position) as a "cosmetic quirk" to leave alone doesn't extend cleanly
  to *this* mismatch — drawer position is genuinely cosmetic (both
  drawers are equally easy to find either way), but entry order inside a
  single drawer is what a human actually reads top-to-bottom, so getting
  it consistent with the sibling drawer has real, not just cosmetic,
  reading-order value. The complexity cost below is real but bounded and
  worth paying once.

### Scope boundary vs. the sibling TODO

TODO `:ID: d150c02e-06fe-4514-bf69-e2cc5d8df4c7` ("org_clock_in doesn't
record clock ownership, unlike session-resume") is being planned
independently and touches the same function
(`claude-code-ide-org--log-session-event`) for a different reason —
recording *which session* opened a clock via `org_clock_in`, not entry
*position*. This plan only changes **where** a `:SESSIONS:` line is
inserted, never the session-id/ownership content of the line itself, so
the two changes are orthogonal edits to the same small function and
should not conflict when both land (whichever lands second does a normal
three-way-mergeable diff, not a structural collision).

## Design

The naive version of this task — just prepend instead of append in
`claude-code-ide-org--log-session-event` — is not sufficient by itself.
Three other places in `config.el` currently assume `:SESSIONS:`'s textual
order in the drawer *is* chronological order (true today only because
every write so far has been an append):

1. `claude-code-ide-org--entry-open-interval` (config.el:561) — scans
   forward through the drawer and keeps overwriting `last-event`/`last-ts`
   on every match, so whichever match comes *last in the text* wins as
   "the most recent event." That's correct only under oldest-first
   ordering.
2. `claude-code-ide-org-close-open-interval`'s inline `:SESSIONS:`-closing
   scan (config.el:866–873) does the exact same forward-scan-keep-last
   pattern, for the same reason (finding the trailing unmatched
   `"Resumed"` to decide whether a `"Paused (recovered)"` entry is
   needed).
3. `claude-code-ide-org--consolidate-sessions-text` (config.el:1030,
   via `claude-code-ide-org--parse-session-lines` at config.el:1006) —
   treats the *last element* of the parsed events list as "today's still-
   open interval" (`open-tail`, config.el:1039), and builds one
   `Resumed`/`Paused` pair per calendar day in the order days were first
   encountered in the text (ascending, i.e. oldest day first) — both
   assumptions break under newest-first ordering.

So this task's actual code surface is: `--append-to-drawer`,
`--log-session-event`, `--entry-open-interval`,
`close-open-interval`'s `:SESSIONS:` branch, and
`--consolidate-sessions-text` (+ its helper `--parse-session-lines`).
`claude-code-ide-org-clock-in`/`-out`/`-session-pause`/`-session-resume`
themselves need **no changes** — they already just call
`--log-session-event`, which is where the insertion-point logic lives.

### 1. `claude-code-ide-org--append-to-drawer` (config.el:266)

Add an optional `PREPEND` argument. When non-nil, insert the new line
immediately after the drawer's opening marker line (i.e. at
`org-element-contents-begin`, the same position `org-clock-find-position`
uses for `:LOGBOOK:`) instead of at `org-element-contents-end`. Both the
"drawer exists" and "drawer needs creating" branches need the new
argument threaded through — when creating a fresh drawer, prepend vs.
append are identical (there's only one line), so that branch is
unaffected in practice but should still accept the argument for a
consistent call signature.

This function is also called for `:LOGBOOK:` in three other places
(`--promote-planning-to-doing` config.el:1652,
`--trigger-demote-conflicting-next` config.el:1733,
`--trigger-auto-promote-sole-todo` config.el:1767) — synthetic
"Auto-promoted"/"Auto-demoted" log notes. Those calls are **left as
plain appends** (no `PREPEND` argument passed, defaulting to the current
behavior). Note for the record, not part of this task: those three call
sites already have the *same* newest-vs-oldest mismatch relative to
org's own native `:LOGBOOK:` note insertion (they land at the bottom of
`:LOGBOOK:`, below org's own newest-first native entries) — a real but
separate inconsistency, out of scope here since the TODO is titled and
scoped around `:SESSIONS:` specifically. Worth a follow-up TODO if it
ever proves confusing in practice, not fixed as a drive-by here.

### 2. `claude-code-ide-org--log-session-event` (config.el:331)

Pass `prepend t` to `--append-to-drawer`. This is the only change needed
to make every *live* write path (`clock-in`'s "Resumed",
`clock-out`'s "Paused", `session-resume`'s "Resumed") newest-first, since
they all funnel through this one function.

### 3. `claude-code-ide-org-close-open-interval`'s recovered-Paused write
(config.el:871–872)

Also pass `prepend t` — the recovered `"Paused ... (recovered)"` line is,
at the moment it's written, the newest event for that heading (later than
whatever `"Resumed"` line it's closing out), so it belongs at the top
too, consistent with every other `:SESSIONS:` write.

The scan just above it that decides *whether* to write that line
(config.el:866–873, currently "keep overwriting `last-event` on every
forward match") must change to **first-match-wins**: under newest-first
ordering, the first `Resumed`/`Paused` match encountered scanning forward
from the heading is the most recent event, so the loop should stop after
its first match rather than continuing to the end of the subtree.

### 4. `claude-code-ide-org--entry-open-interval` (config.el:561–578)

Same fix as above, same reasoning: change the `:SESSIONS:` half of this
function (the `:LOGBOOK:` half, matching the still-open `CLOCK:` line, is
untouched — org already writes that newest-first) from
forward-scan-keep-last to first-match-wins.

### 5. `claude-code-ide-org--consolidate-sessions-text` (config.el:1030)
and `--parse-session-lines` (config.el:1006)

`--parse-session-lines` itself needs no change — it already just parses
whatever `Resumed`/`Paused` lines it finds, in the order they appear in
the text, without asserting a meaning for that order. The order-dependent
assumptions all live in `--consolidate-sessions-text`, which should be
made robust to actual timestamps rather than positional order (more
correct regardless of which direction "newest-first" points, and immune
to any future reordering debate):

1. Parse events (unchanged).
2. Determine the open tail **by timestamp**, not by list position: sort a
   copy of the events by `:time`; if the chronologically-last event's
   `:label` is `"Resumed"`, that's the open tail (today's still-running
   interval) — exclude it from day-grouping. This replaces the current
   `(car (last events))` / "last element in parse order" check
   (config.el:1039), which silently assumed the *parsed* list order was
   chronological.
3. Group the remaining (closed) events by calendar day and compute each
   day's min (`Resumed`) / max (`Paused`) — this part
   (config.el:1050–1061) already explicitly sorts each day's events by
   `:time`, so it needs no correctness change, only feeding it
   timestamp-derived day groups instead of parse-order-derived ones.
4. Order the day blocks **descending** by day (newest day first) instead
   of the current ascending `day-order` (config.el:1049,
   `(setq day-order (nreverse day-order))` — currently relies on parse
   order already being ascending; replace with an explicit sort on the
   day-key string, descending).
5. Emit the open tail (if any) first, then the day blocks — mirroring
   `--consolidate-logbook-text`'s already-established convention
   (config.el:983–1004) of "still-open interval kept first, newest
   closed history right after it."
6. Within a day block, keep the existing `Resumed` line then `Paused`
   line order (start then end) — that's a legible pairing independent of
   the newest-first/oldest-first debate, and changing it isn't needed to
   satisfy "matches `:LOGBOOK:` ordering" (which is about day-to-day and
   entry-to-entry recency, not about how a single session's start/end
   pair reads).

Docstrings on `--consolidate-sessions-text`, `--entry-open-interval`, and
`close-open-interval` should be updated to state the new newest-first
convention explicitly, replacing the current prose that describes
appending/trailing-entry behavior.

### 6. `CLAUDE.md` prose

The "Session tracking" section currently describes `:SESSIONS:` as "a
plain timestamped log of every pause and resume" without stating order,
but the "Known cosmetic quirk" paragraph implicitly contrasts it with
`:LOGBOOK:`'s ordering only in the context of *drawer position*, not
*entry order* — matching the TODO body's own note that this is a
distinct issue. No existing CLAUDE.md sentence asserts "oldest-first" in
so many words, so no correction is strictly required, but it's worth
adding one clause noting `:SESSIONS:` is newest-first, matching
`:LOGBOOK:`, now that it's true — for a future reader who'd otherwise
have to infer it from code.

## Migration of already-written `:SESSIONS:` drawers

Every `:SESSIONS:` drawer already on disk (TODO.org, DONE.org, and any
other tracked file) was written oldest-first under the old code. This
plan does **not** include a bulk migration pass. Reasoning:

- `claude-code-ide-org-consolidate-history` (config.el:1071) already
  fully rewrites a heading's `:SESSIONS:` drawer from scratch — and is
  already called automatically at the end of every `clock-out`
  (config.el:414–415) and every `close-open-interval` (config.el:875–876)
  — so the very next time a heading with an old-order drawer is paused
  again, its whole `:SESSIONS:` drawer gets rewritten in the new
  newest-first form automatically, no separate step needed. This is a
  natural, self-healing migration, not a gap.
- Between "a new `Resumed` gets prepended" and "the next `clock-out`
  triggers a rewrite," a previously-oldest-first drawer will briefly read
  as `[new Resumed (top), ...old entries still ascending...]` — locally
  correct (newest thing really is on top) but not fully newest-first
  until the next consolidation. This is the same flavor of harmless,
  self-correcting transient CLAUDE.md already accepts for the
  clock-ownership and drawer-position quirks; not worth special-casing.
- A heading that's already `DONE`/archived and never touched again keeps
  its old-order drawer forever. Also harmless — nobody is actively
  reading a dormant heading's history against a live `:LOGBOOK:` for
  comparison.
- If the user ever wants an immediate, one-time cleanup instead of
  waiting for natural self-healing, `claude-code-ide-org-consolidate-
  history` is already documented as callable directly via `emacsclient`
  for exactly this kind of maintenance pass, per-heading. Worth
  mentioning to the user after implementation, not worth building
  automation for as part of this task.

## Tests (`config-test.el`)

Baseline: 122 `ert-deftest` forms currently pass via `bin/test`.

- **`claude-code-ide-org-test-session-resume-resumes-same-heading`**
  (config-test.el:292) — this test currently drives clock-in → pause →
  resume and asserts three sequential regex matches
  (`"- Resumed \\["`, `"- Paused \\["`, `"- Resumed \\["`) appear in that
  left-to-right order, commented "Resumed, Paused, Resumed — in that
  order" (chronological). **This assertion would keep passing unchanged
  after the fix, for the wrong reason** — with newest-first ordering the
  actual disk sequence becomes (newest Resumed, Paused, oldest Resumed),
  and a plain "which regex matches first" scan can't distinguish that
  from the old chronological meaning, since both labels are the literal
  string `"Resumed"`. This test must be rewritten, not left alone, to
  actually assert the new semantics — e.g. capture all three
  timestamps via `string-match` + `match-string` and assert they are
  *descending* (newest first), rather than just asserting relative
  textual position of label strings.
- **`claude-code-ide-org--entry-open-interval`** — add a new direct unit
  test (no existing one exercises multiple `:SESSIONS:` entries) with a
  fixture drawer written newest-first, e.g. `Resumed <today, open>` then
  `Paused <yesterday>` then `Resumed <yesterday>`, confirming it correctly
  identifies the open interval from the *first* line, not the last.
- **`close-open-interval`'s `:SESSIONS:` branch** — extend
  `claude-code-ide-org-test-close-open-interval-preserves-surrounding-
  content` (config-test.el:1401) or add a sibling test with a
  newest-first multi-entry fixture (not just the current single-Resumed
  fixture) to prove the first-match-wins fix.
- **`claude-code-ide-org-test-consolidate-history-separate-days-stay-
  separate`** (config-test.el:1541) — currently only asserts each of the
  four lines is *present* via independent `string-match-p` calls, never
  their relative order, so it would pass trivially whether day blocks
  come out ascending or descending. Add an explicit order assertion
  (e.g. `(string-match "2026-07-28" disk)` position `<`
  `(string-match "2026-07-27" disk)` position) so the day-descending
  behavior is actually verified, not just incidentally unbroken.
- **New test** for `--consolidate-sessions-text` (or
  `consolidate-history` end to end) confirming the open tail is emitted
  *before* the consolidated day blocks, extending
  `claude-code-ide-org-test-consolidate-history-preserves-open-interval`
  (config-test.el:1519) with a position assertion (currently only checks
  presence via `\\s-*$` anchored regexes, not relative position).
- Every other existing `:SESSIONS:`-touching test
  (`claude-code-ide-org-test-clock-in-out-log-sessions-drawer`,
  `-session-pause-closes-clock`, the five session-identity tests at
  config-test.el:335–390, `-consolidate-history-rounds-merges-and-drops-
  zero`, `-consolidate-history-noop-when-nothing-to-do`) only assert
  presence/absence of specific lines or exact returned strings, not
  ordering, so they're expected to keep passing unmodified — worth a
  final `bin/test` run to confirm rather than assuming.

## Verification

- `bin/test` — full suite green, including the updated/new tests above.
- `org-dev` skill's live-reload step, then a manual smoke test against a
  scratch heading via `emacsclient`/the MCP tools:
  1. `org_clock_in` on a fresh scratch heading → confirm `:SESSIONS:` has
     one `"Resumed"` line.
  2. `org_clock_out` → confirm `"Paused"` now sits **above** `"Resumed"`.
  3. `org_clock_in` again → confirm the new `"Resumed"` sits above both
     prior lines.
  4. `org_clock_out` again (second pause, so `consolidate-history` fires
     with real multi-entry history) → confirm the drawer collapses to
     the expected newest-first, day-descending shape, and that the
     `:LOGBOOK:` drawer's own (unrelated, unchanged) newest-first CLOCK
     ordering still looks correct alongside it.

## After approval

Per CLAUDE.md's Plan-link rule, add
`[[file:~/.claude/plans/sessions-logbook-ordering.md][Plan]]` to
TODO.org heading `2b0988ed-eb92-4fa7-904a-cb2d10941bfd`'s body as soon as
this plan is finalized/approved — a separate step from actually starting
implementation, per the "Plan-approval isn't heading-wording/DOING-
transition approval" rules, requiring its own explicit go-ahead first.
