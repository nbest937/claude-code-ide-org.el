# Design the append-only event-queue format and per-session file lifecycle

TODO.org `:ID: 32272061-1d78-4726-b13b-90338edb2ba5`, sub-task of the
event-queue refactor (`b5f7c5c7`). Wave 1 of that epic's revised
sequencing: the schema is the shared contract for `720b2dcf` (review-and-
apply), `63a642c7` (pending-queue tool), `feba67eb` (write-path cutover)
and `290b6fc5` (statusline), so it freezes first and alone.

## Context

Driving live org state synchronously from Claude Code sessions has
produced a sustained run of desync, ownership and logging bugs, all
tracing to one mismatch: org's clock/logging model assumes one human at
one buffer, while this project's workload is concurrent sessions,
background agents and non-interactive `emacsclient` calls. The fix is to
stop writing live state from sessions at all — sessions append events to
a plain per-session file, and a human applies the approved subset later
through org's real machinery inside a genuinely interactive command.

This sub-task defines only the event format and the file lifecycle.
Nothing here changes behavior on its own; it is the contract the rest of
the epic builds against.

**Phase 0 is discharged** (`3d576d29`, DONE): `org-clock-in` accepts
`START-TIME` and `org-clock-out` accepts `AT-TIME`, both verified to
produce correct backdated `CLOCK:` lines non-interactively; state-change
log lines can be backdated by shadowing `org-current-effective-time`;
and an active timestamp inside `:LOGBOOK:` reaches `org-agenda` while an
inactive one does not. No re-planning was triggered.

## Decisions settled with the user (2026-08-07)

1. **Hook writes, tool validates.** MCP tools are served by Emacs and
   never receive `session_id` — it arrives only on hook stdin. So the
   MCP tool resolves the `:ID:` and returns `"queued, pending review"`,
   and a `PostToolUse` hook writes the JSONL line where `session_id`
   already is. Same shape as the existing
   `bin/hooks/posttooluse-record-planning-owner`.
2. **`clock_in`/`clock_out` events survive**, but purely as attribution
   and guidepost material — never as applied intervals. `pause`/`resume`
   are heading-less, so without them a return to a heading that never
   left `DOING` misattributes every subsequent guidepost. They
   contribute *active* timestamps to `:LOGBOOK:`, informing the human's
   composition of `CLOCK:` entries rather than becoming them.
3. **Aggregation happens at ingestion, not in the file.** Raw guideposts
   are dense (one pair per turn). The reader collapses them for review;
   the queue file itself stays lossless.
4. **No auto-rounding at apply.** `consolidate-history`'s 5-minute
   rounding and zero-drop (`config.el:900`/`991`) do not carry into the
   new model — that behavior is what silently ate a real 2-minute
   interval on 2026-08-06. Apply writes exactly the endpoints the human
   confirms.

Three layers, and only the middle one is lossy — in presentation only:

```
queue file (append-only, raw)  ->  ingestion (aggregated view)  ->  apply (exact)
```

## Event schema

One JSON object per line. Field names and the timestamp format
deliberately match the existing audit log (`--log-event`, `config.el:156`)
so both logs read the same way.

```json
{"ts":"2026-08-07T09:12:03-0500","kind":"clock_in","id":"3d576d29-…","state":null,"session_id":"52e09dcc-…","agent_id":null,"source":"org_clock_in"}
```

| Field | Meaning |
|---|---|
| `ts` | ISO 8601 with offset — `%Y-%m-%dT%H:%M:%S%z`, as `--log-event` already emits |
| `kind` | `todo` \| `clock_in` \| `clock_out` \| `pause` \| `resume` |
| `id` | heading `:ID:`; `null` for `pause`/`resume`, which are session-global |
| `state` | TODO keyword; only for `kind:"todo"`, else `null` |
| `session_id` | from hook stdin |
| `agent_id` | `null` today; the slot `16160d23` (MAYBE) fills without a schema change |
| `source` | originating tool or hook name, mirroring `--log-source`'s attribution convention |

Line order within a file *is* the sequence — no `seq` field. Readers must
skip any unparseable line rather than failing the file, so a torn final
line from a hard crash costs one event, never the queue.

> **Amended 2026-08-07, post-implementation.** A `note` field was added
> after checking the schema against `clock-template.org`: nullable,
> populated from `tool_input.note`, carrying a 3–10 word description on
> `todo`/`clock_in`/`clock_out` and `null` on `pause`/`resume` (which
> come from hooks Claude never invokes, so no call site can supply one).
> Without it a drained queue would produce bare `CLOCK:` lines and
> unlabelled `State "X" from "Y"` lines — strictly poorer than the
> template, where every non-`CLOCK:` line carries a label. `clock_out`'s
> `id` was also fixed: the tool takes no `id` argument, so its reply now
> names the id it actually closed and `queue-append` recovers it from
> there.

## File layout and lifecycle

- One file per real `session_id`: `~/.claude/org-updates/<session_id>.jsonl`.
  One writer stream per file, so no contention. `agent_id` rides on the
  event, not the filename — a subagent contributes 1-2 events, not enough
  to justify file proliferation.
- Path from a new `defcustom claude-code-ide-org-queue-directory`,
  following `claude-code-ide-org-audit-log-file`'s precedent
  (`config.el:121`) of a customizable path with a sane default.
- **Never mutate the file after a partial apply.** A session may still be
  appending to it. Instead the apply command records progress in a
  sibling watermark file `<session_id>.applied` holding the `ts` of the
  last applied event; the reader treats everything at or before that
  watermark as consumed. Truncation would race an appending writer;
  deletion loses history the review UI may still want.
- Watermark writes reuse `--write-clock-status`'s atomic temp-file +
  `rename-file` pattern (`config.el:1846`), so a concurrent reader never
  sees a half-written watermark.
- Appends are a single `printf` of one newline-terminated line via `>>`.
  Lines are far under `PIPE_BUF`, so `O_APPEND` writes are atomic on
  POSIX — no locking needed.

## Write path

A single new shared script, `bin/hooks/queue-append`, invoked by every
hook that needs to emit an event. It reads the hook payload on stdin and
builds the line with `jq -n`, reusing the jq-based JSON construction the
existing hooks already use (see `bin/hooks/session-pause`'s comment on
why jq rather than shell interpolation).

- `PostToolUse` on `org_set_todo` / `org_clock_in` / `org_clock_out` →
  `todo` / `clock_in` / `clock_out`. Reads `.tool_input.id`,
  `.tool_input.state`, `.session_id`. **Skips the append when
  `.tool_response` starts with `"Error:"`** — the wrappers' `--at-id`
  already returns error strings rather than throwing, so this is a clean
  signal that the `:ID:` did not resolve.
- `Stop` → `pause`; `UserPromptSubmit` → `resume`. `bin/hooks/session-pause`
  and `-resume` lose their `emacsclient` calls entirely and become thin
  wrappers over `queue-append`.

Fire-and-forget and always `exit 0`, matching every existing hook.

> **Deviation taken at implementation time.** `session-pause`/`-resume`
> *keep* their `emacsclient` call and append to the queue alongside it.
> Dropping it before `720b2dcf` exists would stop pausing the live clock
> at turn boundaries while the MCP tools still open real clocks,
> inflating every interval with idle time, with nothing able to apply the
> queued events instead. Removing the `emacsclient` half is `feba67eb`'s
> cutover.

## Reader (elisp)

The shared parsing layer all three downstream sub-tasks consume — built
once here, per `63a642c7`'s own instruction not to implement it three
times.

- `claude-code-ide-org--queue-files` — list pending `.jsonl` files.
- `claude-code-ide-org--queue-events (&optional session-id)` — parse to a
  list of plists, watermark-filtered, skipping unparseable lines.
- `claude-code-ide-org--queue-events-by-id` — group by heading `:ID:`,
  resolving `pause`/`resume` attribution by walking `clock_in`/`clock_out`
  in file order.
- `claude-code-ide-org--aggregate-guideposts (events &optional threshold)`
  — collapse consecutive guideposts separated by less than THRESHOLD into
  one span. Threshold from a new `defcustom
  claude-code-ide-org-guidepost-gap-threshold`, default 15 minutes,
  explicitly tunable since the right value is TBD until real queue data
  exists. Reuses `--merge-time-intervals` (`config.el:913`), which
  already does sort-and-merge on `(START . END)` conses.

No writing, no org buffer access — this layer is pure data, which is what
makes it cheap to test.

> **Deviations taken at implementation time.** `--aggregate-guideposts`
> does *not* reuse `--merge-time-intervals`: that merges only touching or
> overlapping intervals, with no gap tolerance, which is a different
> question from clustering nearby points. `--parse-iso8601` shape-checks
> before calling `date-to-time`, which otherwise accepts `"nonsense"` and
> returns a near-epoch time that would sort a garbage line ahead of every
> real event. A generic `--atomic-write` was added rather than reusing
> `--write-clock-status`, which is hardwired to its own defcustom path.

## Files touched

- `modules/tools/claude-code-ide-org/config.el` — two new `defcustom`s,
  the reader functions, the watermark writer.
- `modules/tools/claude-code-ide-org/config-test.el` — ERT coverage.
- `bin/hooks/queue-append` — new.
- `bin/hooks/session-pause`, `bin/hooks/session-resume` — drop
  `emacsclient`, delegate to `queue-append`.
- `.claude/settings.json` — add `PostToolUse` matchers for the three
  mutating tools.

Deliberately **not** touched: `claude-code-ide-org-set-todo`,
`-clock-in`, `-clock-out` still mutate live state. Flipping them is
`feba67eb`'s cutover commit, and doing it here would leave the repo in a
state where events are queued but nothing applies them.

## Verification

Automated, via `bin/test` (ERT), following `config-test.el`'s existing
patterns — `--with-heading` for scratch org files and
`--audit-log-entries` (`config-test.el:84`) as the model for reading JSONL
back:

- round-trip: append each of the five kinds, read back, assert field
  values and ordering
- a torn/garbage line is skipped without failing the file
- watermark filtering: events at or before the watermark are excluded;
  later ones survive; a session appending after a partial drain is
  still read correctly
- attribution: the interleaved A→B→A case from the design discussion
  attributes every guidepost to the right heading
- aggregation collapses a dense run at the default threshold and leaves
  a sparse one alone
- the watermark write is atomic (no partial file observable)

Shell-side, `bin/hooks/queue-append` is invoked directly with synthetic
payloads on stdin — the same way `bin/clock-notify-test` already exercises
its hook — asserting the emitted line for each hook event, and asserting
that an `"Error:"` tool response produces no line at all.

End-to-end manual pass: run a real session touching two headings with a
return to the first, then inspect the resulting `.jsonl` and confirm the
reader groups it correctly.

**Outcome:** shipped in `4678572` and amended in `8b4f795`. `bin/test`
138/138 (14 new), `bin/queue-append-test` 30/30, plus a cross-boundary
pass where the real hook script wrote a nine-event `A → B → A` stream
that the real Emacs reader attributed correctly and drained to zero,
leaving the queue file intact.

## Out of scope

The review UI (`720b2dcf`), the pending-queue MCP tool (`63a642c7`), the
write-path cutover (`feba67eb`), the statusline (`290b6fc5`), and
subagent `agent_id` population (`16160d23`, MAYBE). This sub-task ships a
schema, a writer, a reader and their tests — no behavior change to any
existing tool.
