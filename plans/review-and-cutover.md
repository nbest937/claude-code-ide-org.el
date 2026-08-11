# Review-and-apply command, then the write-path cutover

Covers two TODO.org sub-tasks of the event-queue refactor (`b5f7c5c7`),
deliberately as one plan in two phases:

- **Phase A** — `720b2dcf`, build the interactive review-and-apply command
- **Phase B** — `feba67eb`, flip the write paths to append-only

They are planned together because Phase B cannot land before Phase A
works — the moment the tools stop mutating live state, something has to
apply the queued events — and because most of B's requirements fall out
of A's design rather than being discoverable on their own. Both headings
carry a link to this file.

## Context

Driving live org state synchronously from Claude Code sessions produced
a sustained run of desync, ownership and logging bugs, all tracing to one
mismatch: org's clock/logging model assumes one human at one buffer,
while this project's workload is concurrent sessions, background agents
and non-interactive `emacsclient` calls. Sessions now append events to a
per-session queue (`32272061`, DONE — see
`~/.claude/plans/event-queue-format.md`). What is still missing is the
other half: a human-triggered command that turns those events into real
org state, and the cutover that makes the queue the only write path.

Everything the apply step depends on is already verified, not assumed
(`3d576d29`, DONE):

- `org-clock-in` takes `START-TIME`, `org-clock-out` takes `AT-TIME`;
  both produce correct backdated `CLOCK:` lines non-interactively.
- A state-change log line backdates by shadowing
  `org-current-effective-time` around `org-todo` — **not** by let-binding
  `org-log-note-effective-time`, which `org-add-log-setup` (`org.el:11031`)
  overwrites.
- The deferred note can be driven directly: call `org-store-log-note`
  with an empty (or note-bearing) `*Org Note*` buffer current, having set
  `org-log-note-window-configuration`. Empty yields a bare `State` line;
  non-empty yields the `\\` continuation.
- An *active* timestamp inside `:LOGBOOK:` reaches `org-agenda`; an
  inactive one and `CLOCK:` lines do not. That is what makes guidepost
  annotations show up in the agenda for free.

## Design decisions carried in

From `32272061` and the conversations around it — not reopened here:

1. **Two modes, not one.** Subagent-derived intervals are mechanically
   knowable and may be proposed as real `CLOCK:` entries for bulk
   acceptance. Human-session intervals must **not** be auto-written: the
   command renders guideposts and the human draws the interval.
2. **No rounding.** `consolidate-history`'s 5-minute rounding and
   zero-drop (`config.el:900`/`991`) do not apply. Apply writes exactly
   the endpoints confirmed. This means apply must call raw
   `org-clock-out`, **not** `claude-code-ide-org-clock-out`, which
   consolidates.
3. **Guidepost span labels** inherit the enclosing `clock_in`'s `note`,
   and stay unlabelled when there is none. Transcript-derived labels
   (`0c8644ff`, MAYBE) are a later upgrade, deferred on scope grounds,
   not capability.
4. **Retire the tool-side guards** at cutover (settled 2026-08-07):
   `bin/hooks/pretooluse-transition-guard` and `bin/clock-notify` both
   exist to police live state against concurrent writers. After cutover
   there are none. The org-side hooks stay — they still guard genuine
   hand-edits in Emacs.

## Phase A — the review-and-apply command (`720b2dcf`)

### Buffer and mode

New `claude-code-ide-org-review` command opening a `*org-review*` buffer
in a major mode derived from `special-mode` (read-only, standard `q`/`g`).

Checked per `c084553c`'s standing instruction: **`org-agenda-bulk-*` is
not reusable here.** `org-agenda-bulk-mark` (`org-agenda.el:10652`) keys
off `org-hd-marker` text properties on agenda-formatted lines, pushes to
the global `org-agenda-bulk-marked-entries`, and navigates by
`next-single-property-change` on that same property — it only works in a
buffer org-agenda itself built. Its *design* is the model to copy: a
marker text property per line, an overlay for the mark character, and a
marked-entries list. `tabulated-list-mode` was considered and rejected:
it re-renders rows from `tabulated-list-entries`, which fights in-place
editing of an interval.

Rendering, grouped by heading via
`claude-code-ide-org--queue-events-by-id`, with spans from
`--aggregate-guideposts`:

```
Heading title                                    3d576d29
  [x] state    TODO -> DOING          09:00   plan approved, resuming
  [ ] clock    <09:00>--<09:15>               clarify backend schema design
  [x] clock    [11:30]--[11:48]               initial implementation   (agent)
      unattributed: 2 guideposts
```

Each line carries a marker to its heading plus the underlying event
plist in text properties. Keys: `m`/`u` mark and unmark, `t` toggle,
`e` edit an interval's endpoints in the minibuffer, `RET` jump to the
heading, `x` apply marked, `g` refresh, `q` quit.

### Apply

One item at a time, synchronously, inside this one interactive command
so native logging fires with no `org-inhibit-logging` anywhere.

**Three hook interactions must be handled — this is the part most likely
to go wrong silently:**

- `claude-code-ide-org--trigger-auto-clock-in` (`config.el:1636`) fires
  on any transition to `DOING`/`PLANNING` and calls `org-clock-in` with
  no time, i.e. *now*. Live evidence from `3d576d29`'s verification: it
  also destroys the pending state-change note, which then never lands.
  Suppress it by binding the module's own existing re-entrancy guard,
  `claude-code-ide-org--auto-clock-in-active` (`config.el:1603`), to `t`
  for the duration of apply. Reusing that variable rather than inventing
  a new suppression flag is deliberate.
- `claude-code-ide-org--blocker-clock-running-p` (`config.el:1611`)
  denies `→ DONE` while the target heading's own clock runs. Apply must
  therefore never leave a clock open across an `org-todo` call: each
  `org-clock-in`/`org-clock-out` pair is written back to back, with both
  endpoints known up front, before any state transition for that heading.
- `org-clock-out-when-done t` in the Doom config fires on `→ DONE`;
  harmless given the above, since no clock is open by then.

Per item:

- **`CLOCK:` interval** — `(org-clock-in nil START)` then
  `(org-clock-out nil nil END)`, with `org-clock-out-remove-zero-time-clocks`
  bound nil so a short confirmed interval is not dropped.
- **State transition** — `cl-letf` shadow `org-current-effective-time` to
  the event's timestamp, call `org-todo`, then drive `org-store-log-note`
  with the event's `note` in a `*Org Note*` buffer.
- **Guidepost annotation** — an active-timestamp line appended to
  `:LOGBOOK:` via the existing `claude-code-ide-org--append-to-drawer`
  (`config.el:266`), formatted per `clock-template.org`:
  `- <start>--<end> label`. Unattended/agent spans use inactive
  brackets instead. The annotation is written whether or not a `CLOCK:`
  line was accepted for the same span — per the template's legend, it
  records that a human was logged interacting, not that time is claimed.
- **Watermark** — on success, `claude-code-ide-org--queue-set-watermark`
  per session. Applying a subset advances the watermark only to the last
  *contiguous* applied event, so skipped items stay pending rather than
  being silently consumed.

Buffers are saved per heading, reusing `claude-code-ide-org--at-id`
(`config.el:54`) for navigation.

## Phase B — the cutover (`feba67eb`)

A single commit, once Phase A is working. Nothing here is safe earlier.

- **The three wrappers** (`-set-todo`, `-clock-in`, `-clock-out`) stop
  mutating: validate the `:ID:`, return `"queued, pending review"`. They
  stay Emacs-served, so `:ID:` validation survives.
- **`session-pause`/`session-resume`** drop their `emacsclient` call and
  become pure `queue-append` wrappers. They currently do both, an
  additive step taken deliberately during `32272061` so the queue could
  fill without changing behavior.
- **Ownership variables retire.** `--clock-owner-session-id` (`:302`) and
  `--planning-owner-session-id` (`:317`), plus their uses in
  `session-pause`/`-resume` (`:459-534`) and
  `--maybe-record-planning-owner`/`--promote-planning-to-doing`
  (`:1660-1721`). Verified contained: `grep` finds them only in
  `config.el`, `config-test.el`, and prose in CLAUDE.md/TODO.org —
  **nothing in the user's Doom config**.
- **Guards retire**: delete `bin/hooks/pretooluse-transition-guard` and
  `bin/clock-notify` (and `bin/clock-notify-test`), with their
  `.claude/settings.json` entries.
- **`exitplanmode-promote-planning`** becomes a queued `todo` event. Apply
  must collapse a `TODO→PLANNING→DOING` run into one interval rather than
  replaying each event — the concrete case Phase A's reconciliation has
  to get right.
- **Doom config dead code** (`~/.config/doom/config.el`, outside this
  repo, which is why it is easy to miss): `--clock-out-if-clocking` on
  `kill-emacs-hook` and `suspend-hook` (`:88-91`), and
  `org-clock-out-when-done t` (`:67`). Harmless no-ops afterwards, but
  they imply a background clock that no longer exists.
- **CLAUDE.md and the org skill** are `02aaae22`'s job, not this commit's.

## Verification

Phase A, via `bin/test` (ERT), following `config-test.el`'s
`--with-heading` fixture:

- a backdated interval lands with exact endpoints and correct `=> H:MM`
- a short (2-minute) interval survives, where `consolidate-history`
  would drop it
- a state transition writes the native `State "X" from "Y"` line at the
  *event's* timestamp, with the `note` as its `\\` continuation
- with `--auto-clock-in-active` unbound, the trigger hook clobbers the
  note — asserted as a regression test, since this is the failure that
  was found live and would otherwise silently return
- a `TODO→PLANNING→DOING` run collapses to one interval
- guidepost annotations are active-timestamped and land in `:LOGBOOK:`
- partial apply advances the watermark only past contiguous applied
  events; skipped items remain pending

Phase B: the existing suite must still pass with the guards deleted;
`grep` proves no remaining reference to the ownership variables outside
prose. Then an end-to-end pass — run a session, confirm nothing mutates
live org state, run the review command, apply, and check the resulting
`:LOGBOOK:` against `clock-template.org`'s conventions by eye.

Manual, and explicitly *not* automatable: the review command is
interactive by design, and `3d576d29` established that the logging path
behaves differently under `emacsclient -e` than in batch. The interactive
path must be exercised by hand at least once before Phase B is trusted.

## Out of scope

`63a642c7` (pending-queue tool), `290b6fc5` (statusline), `02aaae22`
(docs), `16160d23` (subagent `agent_id`, MAYBE), `0c8644ff`
(transcript-derived labels, MAYBE), `7771fc63` (stale-interval recovery's
fate, whose premise Phase B removes but which is sequenced after this).
