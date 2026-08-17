# Make a permission-blocked turn visible to the queue

TODO.org `:ID:` f4e628ce-e653-429a-8f3c-0f5d4241b139

## Context

The `Stop` hook fires when a *turn* ends. A turn that stalls mid-flight waiting on a
tool-permission prompt has not ended, so no `pause` is written and the queue records one
unbroken span. Measured 2026-08-11: a turn ran `resume` 13:55:19 → `pause` 14:53:10
(57m51s), of which **54m11s was a single tool call awaiting approval** and roughly 3m40s
was work. Nothing in the queue distinguishes the two.

This matters more after 2026-08-14's decision (`:ID:` b8e6007a) that the agent record is
the *precise* layer and the human's own attention is the coarse hand-logged one. A
57-minute span for 4 minutes of agent activity is a defect in the layer that is supposed
to be mechanically correct — and it is the one case a gap threshold cannot reach, because
no gap exists: the block sits *inside* a continuous run of guideposts.

Intended outcome: the review pass offers only intervals during which the agent was
actually running, and the blocked interval is removed mechanically rather than by the
human noticing.

## The signal

Claude Code has first-class hooks for this; nothing needs inferring from `Notification`
matchers:

| event | meaning | payload |
|---|---|---|
| `PermissionRequest` | Claude is asking for permission | `session_id`, `tool_name`, `tool_use_id` |
| `PermissionDenied` | the human said no | same |
| `PostToolUse` | the tool ran (so permission was granted) | same |

`tool_use_id` is the join key, and it makes the bracket exact. `PreToolUse` is *not* used:
it fires before the prompt, so it cannot distinguish a blocked call from a fast one.

**Honest limit to state in the heading**: the interval `PermissionRequest → PostToolUse`
covers the human's decision latency *plus* the tool's own execution. For the motivating
case that is 54m11s of waiting and seconds of running. Long-running approved tools will
overstate the block slightly; that is acceptable and much smaller than today's error.

## Implementation

### 1. `bin/hooks/queue-append` — two new kinds

Add `block_start` and `block_end` to the kind whitelist (the `case` at the top, currently
`todo|clock_in|clock_out|pause|resume|capture|amend`) and to the `jq -n` object builder.
Both carry `tool_use_id` and `tool_name` in addition to the existing common fields; neither
carries an `:ID:`, since a block is a fact about the session, not about a heading.

The `Error:` tool_response suppression must **not** apply to these kinds — a denied or
failed tool call still ends a real block.

### 2. `bin/hooks/block-end` — a new, deliberately cheap hook script

`PostToolUse` with matcher `*` fires on every tool call, so it must not do real work in the
common case. This script stats one sentinel and exits:

- `PermissionRequest` → `queue-append block_start`, then `touch` a sentinel at
  `~/.claude/org-updates/<session_id>.blocked/<tool_use_id>`
- `block-end` → `[[ -e <sentinel> ]] || exit 0` first; only on a hit does it call
  `queue-append block_end` and remove the sentinel.

The sentinel directory is ephemeral coordination, not record — the queue remains the
append-only source of truth. Clean up stale sentinels on `SessionEnd`, and treat an
orphaned sentinel as harmless (it only costs one unmatched `block_start`, which the reader
below ignores).

### 3. `.claude/settings.json`

```
PermissionRequest  *  -> bin/hooks/queue-append block_start   (plus sentinel)
PermissionDenied   *  -> bin/hooks/block-end
PostToolUse        *  -> bin/hooks/block-end
```

Note `PostToolUse` already has five matcher-scoped entries for the `org_*` tools; this adds
a sixth, unscoped one.

### 4. `config.el` — pair the events and split the spans

Two functions, next to `claude-code-ide-org--aggregate-guideposts` (config.el:2978):

- `claude-code-ide-org--block-intervals (events)` — pair `block_start`/`block_end` by
  `tool_use_id`, returning `(START . END)` pairs. Unmatched starts are dropped rather than
  extended to "now": an unmatched start means the session died mid-prompt, and inventing an
  end is the class of guess `:ID:` 7771fc63 retired.
- Extend `--aggregate-guideposts` to take those intervals and **cut** at them. It currently
  clusters bare `:ts` values and ignores event kind entirely, so this is the natural seam:
  a timestamp falling inside a block is skipped, and a block boundary forces a span break
  the same way a gap over threshold does.

Per the answered design question: **split and drop**, not annotate. A permission block is
not ambiguous evidence like a commit-less gap — it is a mechanically certain fact that the
agent was stalled, so deciding it automatically is warranted where suggesting a heading is
not.

## Verification

1. **`bin/queue-append-test`** — extend for the two new kinds: whitelist acceptance, field
   mapping including `tool_use_id`, and specifically that `Error:` in `tool_response` does
   *not* suppress a `block_end`. That file's own header warns that a fixture which never
   takes production's shape is a test of the fixture, so capture one real
   `PermissionRequest` payload before writing fixtures.
2. **`bin/test`** — ERT coverage for `--block-intervals` (pairing, unmatched start dropped,
   interleaved ids) and for the split in `--aggregate-guideposts`. Reproduce the measured
   case as a fixture: a 57m51s run of guideposts with a 54m11s block inside it must yield
   two short spans, not one long one. Confirm each test fails without its fix, per the
   standing rule.
3. **Live** — hook-config changes for `PreToolUse`/`PostToolUse` take effect *within the
   current session* in this environment (established 2026-07-29, DONE.org `:ID:` 135033ff,
   which also flagged that the org-dev skill's "new session required" claim is too broad).
   Confirm the same holds for `PermissionRequest` rather than assuming it; if it does not,
   verification needs a fresh session and the plan should say so.
4. **End to end** — trigger a real permission prompt, wait a measurable minute, approve,
   then check that `org_pending_updates` offers spans that exclude the wait.

## Risks

- **`PermissionRequest` may not fire at all under an allowlist or `bypassPermissions`.**
  That is correct behaviour — no prompt, no block — but it means the feature is invisible
  in exactly the configurations that never prompt, and the test above must run in a mode
  that does.
- **Background jobs.** This session runs as a background job; whether permission prompts
  and their hooks behave identically there is unverified and worth checking during step 3.
- **Blocks that span a `Stop`.** If a turn is interrupted while blocked, `block_start` has
  no partner. Handled by dropping unmatched starts, but it means an interrupted block still
  reads as work — a smaller residue of the same bug, worth recording rather than fixing.
