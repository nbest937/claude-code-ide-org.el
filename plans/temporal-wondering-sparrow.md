# Make apply safe to run a second time, and close 720b2dcf

## Context

The event-queue epic (`b5f7c5c7`) is past its midpoint: the queue writer,
reader, schema, and the interactive review-and-apply command all exist and
`bin/test` is green at 157/157. The remaining work is gated on one thing —
the apply command has been run interactively exactly once (2026-08-07), that
run produced **five** bugs, and four were fixed. The fifth (`f9f61c04`) is a
design gap, not a mechanical slip, and it still writes plausible-looking
wrong history. Until it is closed, apply cannot be run again safely, and
`720b2dcf` cannot be marked DONE, and the cutover (`feba67eb`) is blocked
behind it.

There is also unrecognised debt from that first run. The queue holds **62
events, none marked applied** — no `.applied` watermark file exists anywhere.
60 of them belong to session `d847eab1` and span 2026-08-07 08:19 →
2026-08-08 09:11. They include the exact five `todo` events that first apply
already applied for real, plus 51 `pause`/`resume` guideposts recorded while
live clocking was *still running* (the cutover has not happened; `session-pause`
still calls `emacsclient` **and** appends). Running apply against that queue
today would re-propose realized transitions, write duplicate `CLOCK:` intervals
over ones already in `:LOGBOOK:`, and trip `f9f61c04` for real — the queue
holds `720b2dcf → PLANNING` stamped 11:51 Aug 7, and that heading is
currently `DOING`.

Intended outcome: a queue that contains only genuinely-unapplied work, an
apply path that cannot silently regress a heading, a second interactive pass
that comes back clean, and `720b2dcf` closed — leaving `feba67eb` as the next
real step.

## Decisions settled with the user (2026-08-10)

1. **Archive the stranded `d847eab1` queue file** rather than backfilling a
   `.applied` set or leaving it for the new guard to catch. Nothing is lost:
   the state transitions were applied by hand and the guideposts' intervals
   were already written by live clocking.
2. **`f9f61c04` gets both halves** — visible current-state in the review
   buffer *and* a machine-checkable `from` recorded at queue-append time.
   Display alone relies on the human noticing; a schema check alone refuses
   silently.
3. **`c084553c` runs now, reframed as a post-hoc audit** of what got built,
   not as the pre-build gate it was written as. Its remaining checklist items
   are the note/drawer-writing layer where all five bugs actually occurred.

## Step 0 — bookkeeping first

- Already on the right branch: `feature/event-queue-format`. No new branch.
- Add `[[file:~/.claude/plans/temporal-wondering-sparrow.md][Plan]]` to
  `f9f61c04` and `c084553c` in `TODO.org`. Two headings sharing one plan file
  follows the existing `720b2dcf`/`feba67eb` precedent, and for the same
  reason: two documents that must agree is the worse failure mode.
- Set `f9f61c04` → `DOING` via `org_set_todo` before starting (it is `NEXT`).
  `720b2dcf` is already `DOING` and stays there until Step 3 closes it.

## Step 1 — clear the first-pass debt

Move `~/.claude/org-updates/d847eab1-9e6d-4d67-baf2-457715870457.jsonl` to
`~/.claude/org-updates/archive/`. Confirm `--review-items-from-queue` ignores
the subdirectory (it uses `directory-files` on the queue dir; verify it does
not recurse and does not match the subdir as a file).

Record in `f9f61c04`'s body what was archived and why — 60 events, date range,
and the two reasons they are not pending work (transitions applied by hand,
intervals already written live). This is the kind of data decision that looks
arbitrary in six months without the note.

Do **not** delete the file. It is the only surviving record of what the first
interactive pass was actually offered, and Step 3 will want to compare against
it.

## Step 2 — `f9f61c04`: the stale-replay guard

### 2a. Record the prior state at append time

`bin/hooks/queue-append` is a bash writer with no Emacs access by design — it
must stay that way, since writing the queue without a running Emacs is the
premise of the whole refactor. So the prior state has to come back in the
tool's own reply, exactly the way `clock_out`'s heading id already does
(`queue-append` lines ~90-95, `recovered_id`).

- `claude-code-ide-org-set-todo` (`config.el:1202-1229`): capture
  `(org-get-todo-state)` *before* calling `org-todo`, and include it in the
  success reply — `TODO state set to DOING (was NEXT): "heading"`. A heading
  with no keyword reports `(was none)`, not an empty string, so the parse is
  unambiguous.
- `bin/hooks/queue-append`: recover it with the same `sed` pattern used for
  `recovered_id`, and emit a `from` field on `todo` events (null for every
  other kind, matching how `state` and `note` are already scoped).
- `claude-code-ide-org--queue-parse-line` (~`config.el:2098`, where `:state`
  is read): carry `:from` through to the parsed plist.
- `--review-items-from-queue` (`config.el:2295`): put `:from` on `'state`
  items alongside the existing `:to`.

Older events with no `from` field parse as nil and must degrade to Step 2b's
behavior rather than erroring — the archived file is not the only queue data
that predates this field.

### 2b. Surface the mismatch in the review buffer

- `--review-describe` (`config.el:2640`): for `'state` items, resolve the
  heading's live keyword and render the transition as `NEXT → DOING`. Use the
  existing `--at-id` resolution the renderer already relies on for heading
  titles; do not re-implement it.
- When the live keyword differs from the item's `:from`, mark the line
  visibly (a `!` flag plus the actual current state, e.g.
  `! NEXT → PLANNING  (now DOING)`).
- `--review-apply-state` (`config.el:2437`): refuse a flagged item and report
  why, rather than applying it. The human can still override deliberately —
  the design's premise is that they are the validation step — so make the
  override an explicit act (e.g. re-marking a flagged item confirms it),
  never the default.
- Extend `claude-code-ide-org-review-help` (`config.el:2574`) to explain the
  flag. The help buffer is the only place this convention will be documented
  at the moment it matters.

### 2c. Tests

Add to `config-test.el`, following the existing apply-path test style:

- A `todo` event whose `:from` disagrees with the heading's live state is
  rendered flagged and is **not** applied — asserting the heading's keyword
  and `:LOGBOOK:` are both untouched. This is the literal Aug 7 shape:
  queued `→ PLANNING` against a heading now `DOING`.
- A matching `:from` applies normally, with the backdated `State` line intact.
- A `nil` `:from` (pre-field event) applies without erroring.
- `queue-append`: a `todo` event carries `from` recovered from the reply, and
  a reply without a `(was ...)` clause yields `null` rather than garbage —
  add to `bin/queue-append-test`, which already covers the `recovered_id`
  parse.

## Step 3 — the second interactive pass (human-triggered)

This is the gate `720b2dcf` names as still owed, and it is **the user's action,
not mine** — apply only completes correctly inside a genuinely interactive
Emacs session; driving it from `emacsclient -e` hits the exact hang this whole
design routes around.

After Steps 1-2 land and `config.el` is reloaded in the running Emacs:

1. Do some ordinary tracked work so the queue holds fresh, real events
   (a `todo` transition and a few pause/resume guideposts). A queue with one
   item does not exercise the between-items state leakage that produced
   `3d93021d`.
2. `M-x claude-code-ide-org-review`, mark, and apply.
3. Check afterwards: every applied transition landed on its own heading; the
   `State` lines are inside `:LOGBOOK:`; no `CLOCK:` at *now*; a `.applied`
   file now exists for the session and a refresh (`g`) no longer re-proposes
   applied items.

Whatever this turns up gets captured as its own heading before being fixed —
the same discipline that produced `3d93021d` and `f9f61c04` from the first
pass. If it comes back clean, `720b2dcf` → `DONE` with a `*Verified, not just
implemented:*` outcome note covering both passes.

## Step 4 — `c084553c`, reframed as an audit

Rewrite the heading's framing from "do this before building" to "review what
was built," recording honestly that events overtook it and that `3d576d29`
already answered its one load-bearing item (backdated timestamps). Then work
the remaining checklist against the code that now exists:

- **`org-element` vs. this module's regex/position drawer editing** — the
  highest-value item. `--consolidate-logbook-text`, `--parse-clock-lines`,
  `--parse-session-lines` and `--append-to-drawer` are all hand-rolled text
  manipulation, and one of them silently deleted data as recently as
  `ba8249c1`.
- **`org-add-log-note` / `org-store-log-note` outside `post-command-hook`** —
  `--review-apply-state` drives this directly and its correctness argument
  currently lives in a comment. Confirm the approach against org's own source
  rather than against a working example.
- **`org-agenda-bulk-*`** — whether the review UI should be calling it rather
  than reimplementing marking.

Findings that imply changes become their own headings; the audit itself ends
`DONE` with a summary of what was checked and what was deliberately left as-is.

## Verification

- `bin/test` green, with the new tests failing against pre-Step-2 code
  (assert this explicitly — a test that passes both ways proves nothing).
- `bin/queue-append-test` green.
- **Reload precondition:** `config.el` changes need
  `emacsclient -e '(load-file ".../config.el")'` before any live check means
  anything; only function bodies change here, so a `load-file` is sufficient
  and no restart is needed. The `.claude/settings.json` hook wiring is not
  touched, so no new Claude Code session is required.
- End-to-end is Step 3, by hand. Nothing in Steps 1-2 is proven by batch
  tests alone — `3d576d29` established that this path behaves differently
  under `emacsclient -e` than in batch, and `3d93021d`'s live symptom never
  did reproduce in batch.

## Out of scope, deliberately

- **`feba67eb`, the cutover.** It is what Step 3 unblocks, not part of this
  plan. Its own plan (`~/.claude/plans/review-and-cutover.md`) already covers it.
- **`7771fc63`** (fate of stale-interval recovery) and **`9d2fcdad`**
  (fate of `:SESSIONS:`) — both correctly sequenced after the cutover.
- **10 unpushed commits** on `feature/event-queue-format`, and `main` ahead of
  `origin/main` by 7. Not touched without a separate ask.
- **Cosmetic:** `claude-code-ide-org-close-open-interval` returns a propertized
  string that garbles `emacsclient` output as `*ERROR*: Unknown message:`.
  Harmless, and it belongs to the recovery subsystem `7771fc63` may retire
  wholesale — not worth fixing ahead of that decision.
