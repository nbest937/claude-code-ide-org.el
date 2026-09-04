# testdata

Recorded inputs kept so a feature can be exercised against something that
actually happened, rather than a fixture written to match the expectation.

Each subdirectory is a whole `CLAUDE_ORG_QUEUE_DIR` — point the variable at it
and the review machinery reads it exactly as it reads the live one:

```sh
CLAUDE_ORG_QUEUE_DIR=testdata/span-with-no-runs bin/some-test
```

That is the same override `bin/block-hooks-test` and `bin/clock-target-check-test`
already use, so nothing new has to be taught to read these.

Files are named by session id because that is what the queue writer produces and
what the reader expects. The **directory** name carries the meaning.

## `span-with-no-runs/`

One real session queue, 149 events spanning 2026-09-03 14:10 to 2026-09-04
10:08. Kept at the user's request on 2026-09-04, unapplied, as a specimen.

**The specimen is the interval bounded by these two events:**

```
09:52:53  pause      ┐  derives as: 0:06 span, no runs, 0 turns
09:58:52  resume     ┘                (no completed turn in it)
```

A `pause` followed by a `resume` with nothing between — the gap *between* turns,
where the human was reading or away and the agent was not running. It has no
`resume` → `pause` pair, so it has no run.

Two features would consume it, and neither exists yet:

- **`5a6d2c75`** — an unassigned span's readout omits the evidence that would
  make its heading obvious. This span reached review `UNASSIGNED`; reconstructing
  what it was needed the queue *and* the transcript.
- **`01849bef`** — flipping a span's timestamps to active. A no-run span is the
  likeliest candidate for the human's own attention and the least likely to be
  distinguishable from absence, which is what makes it the interesting case
  rather than a convenient one.

### Why the whole file, and not just the specimen

**Spans are derived, never stored.** The review pass clusters guideposts by
`claude-code-ide-org-guidepost-gap-threshold` at read time, so what an interval
derives to depends on its neighbours. Trimming to a window can silently change
the answer.

That is not hypothetical. A sibling span in this same file, `[10:00]--[10:03]`,
was reported as `0:03, no runs, 0 turns` and then stopped being one — two later
events (`10:04:43 pause`, `10:08:48 resume`) turned its cluster into one holding
a run. Nothing was applied; the derivation simply moved. Keep the file whole and
the specimen keeps deriving to what this README claims.

### Provenance and contents

Copied byte-identical from `~/.claude/org-updates/`. Audited before committing,
since this repo is public: no `$HOME` paths, nothing matching a
credential shape, and the only free prose is in three `amend` events whose text
is already committed to `TODO.org` in this same repository.

Event kinds present: 46 `pause`, 36 `resume`, 21 `clock_in`, 21 `clock_out`,
20 `todo`, 3 `amend`, 1 `block_start`, 1 `block_end` — so the file also happens
to be a usable sample of every kind the queue writes except `capture`.
