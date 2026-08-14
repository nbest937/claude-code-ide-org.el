# Verify f4e628ce in a fresh session

You are a new session started specifically to finish one verification.
Do not re-derive any of the background — it is on the heading. Read
TODO.org `:ID:` f4e628ce-e653-429a-8f3c-0f5d4241b139 first, and the plan
it links (`~/.claude/plans/cheerful-riding-robin.md`), then do the
following and nothing else.

## The one unknown

Permission-block detection is implemented, wired and unit-tested, but has
never fired. `PermissionRequest` is registered in `.claude/settings.json`,
`bin/hooks/block-start` is executable and passes `bin/block-hooks-test`.
A probe in the previous session produced a real six-minute permission
wait and **no `block_start`** — that session had `PermissionRequest`
added to its settings *after* it began.

So the question this session exists to answer is exactly:

> Does a session pick up a hook for an event type that was not registered
> when the session started?

This session *was* started with it registered. That is the only
difference, and it is why a fresh session is required rather than useful.

## What to do

1. Confirm the baseline is clean:

   ```sh
   grep -h '"kind":"block' ~/.claude/org-updates/*.jsonl 2>/dev/null | wc -l
   ```

   Expect `0`. If it is not zero, some block events already exist —
   report that and stop, because it changes the interpretation entirely.

2. Note the wall-clock time, then run:

   ```sh
   echo afk-probe:1
   ```

   A permission prompt should appear, forced by the `ask` rule in
   `.claude/settings.local.json` (gitignored). **If no prompt appears,
   the session is not in manual mode** — stop and say so; nothing below
   is meaningful without a real prompt.

3. **Leave the prompt unanswered for five to ten minutes.** Then approve.

   The upper bound is load-bearing, not a suggestion. The guidepost gap
   threshold is 1200s, and a wait longer than that gets split by the
   ordinary gap rule whether or not any of this code works — which is the
   exact trap the feature's first test fixture fell into. Only a
   sub-threshold wait can distinguish the block events from the threshold
   doing the work.

4. Check what landed:

   ```sh
   grep -h '"kind":"block' ~/.claude/org-updates/*.jsonl | jq -r '.ts + "  " + .kind + "  " + (.tool_use_id // "-")'
   ```

   Then `org_pending_updates`, to see whether the span is split around
   the wait rather than running through it.

## What each outcome means, and what to record

**A matching `block_start`/`block_end` pair, and a split span** — the
feature works. Set the heading to `DONE` with an outcome note, and record
the real finding, which is about the harness rather than the feature:
*a hook for a new event type needs a session restart, unlike a new
matcher on an already-registered event.* DONE.org `:ID:` 135033ff
established that `PreToolUse`/`PostToolUse` config takes effect live, and
that is now known to be the narrower claim. The org-dev skill's section 5
generalises in the opposite direction and should be corrected.

**A pair, but the span is not split** — the events are reaching the queue
and the elisp is not consuming them. `bin/test` covers the split against
synthetic events, so compare a real event's shape against the fixtures in
`config-test.el`; the likeliest culprit is a field name.

**Still no events, with a real prompt held** — the fault is upstream of
`bin/hooks/block-start`, since that script passes its harness when fed a
payload directly. Capture the hook payload to find out what actually
arrives:

```sh
# temporarily, in .claude/settings.json's PermissionRequest hook
command: "cat >> /tmp/permreq.json"
```

Then report whether `PermissionRequest` fires at all, and whether its
payload carries `tool_use_id`. Both are assumptions from the docs that
have never been checked against this environment.

## Housekeeping

- The `ask` rule is a probe, not a convention. Remove
  `Bash(echo afk-probe:*)` from `.claude/settings.local.json` when done.
- Delete this file once the heading closes.
- Do not start any other work in this session. If the verification
  finishes quickly, stop and report rather than picking up the backlog.
