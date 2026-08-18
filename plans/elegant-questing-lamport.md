# Make the guidepost pipeline produce durations that mean what they say

Epic plan for TODO.org `:ID:` 406e9200. Covers all five children; each links
this file rather than carrying one of its own, following the precedent set by
02aaae22 / c556a9ed.

## Context

A span's duration is wrong in both directions. Measured over 850 post-cutover
guideposts across 15 session queues:

| | |
|---|---|
| kind-blind clustering (today) | **39.97 h** |
| `resume`→`pause` pairing | **24.27 h** |
| overcount from absorbed idle | **+15.7 h**, ~45% |
| long turns rendered as zero-width | 6 turns, 4.88 h |

Two opposite biases. The *visible* symptom — zero-width items that can only be
dismissed — is the minor one, so a fix aimed only at it makes the record worse.

**Why now.** The bias profile inverts under long unattended stretches: fewer
turn boundaries means less idle absorbed and more long turns lost. The defect
becomes dominant exactly when nobody is watching, which is the opposite of what
CLAUDE.md's second goal asks for.

## Decisions taken during planning

1. **Merge idle below a floor** rather than one CLOCK line per turn. Maximum
   fidelity would produce up to 54 lines on one span and write 43 `=> 0:00`
   entries the code elsewhere calls "an interval never observed".
2. **Silence the auto-clock-in trigger, but fix the statusline first** — the
   trigger is currently the only producer of a live clock.
3. **Do not activate the dead block logic.** It would change numbers on the
   existing record; it is a separate finding, noted below.

## Order — statusline first, record last

### 1. Statusline reads the queue, not the live clock — `290b6fc5`

`--statusline-task-string` (`config.el:758-786`) uses `org-clocking-p` /
`(car org-clock-history)`. Once step 2 silences the trigger, nothing produces a
live clock and the statusline would degrade to "last *applied* heading",
lagging until the next review pass. 290b6fc5 already specifies the fix — point
it at the queue files' latest event — and its body anticipates this exact
moment: *"once those stop being live in real time."*

**This must land before step 2**, or the regression is real. Refile 290b6fc5
under 406e9200 as a fifth child.

### 2. The two mechanisms — `226ed53b`

**(a) Clustering becomes minimally kind-aware.** In
`--aggregate-guideposts` (`config.el:3139-3160`), split iff
`gap > threshold` **AND the adjacency is not `resume`→`pause`**.

The gate is on *adjacency kind*, not on pairing — there is no "matching pause"
to find, and trying to define one is ambiguous under `resume,resume,pause`.
Treat a missing `:kind` as splittable; the fixture at `config-test.el:3134`
supplies `:ts` only.

Measured against the corpus: 52 spans (from 59), **all four zero-width spans
eliminated**, and `config-test.el:3089` and `3665` both still pass. The
inverted form of this predicate — gating on pause→resume instead — absorbs
idle in `resume→resume` gaps and breaks both tests; it was the first draft and
it was wrong.

Leave the block clause (`config.el:3147-3154`) outside the gate.

**(b) Apply writes one CLOCK line per run of work**, merging across idle gaps
shorter than a new `claude-code-ide-org-span-idle-floor` (default 120 s).
In `--review-apply-clock` (`config.el:3639-3711`).

**Only when `:suggested` is non-nil.** A confirmed interval — `e` sets
`:suggested nil` at `config.el:5182` — writes exactly one line at the human's
endpoints. This preserves the invariant stated at `config.el:3187`: *"apply
writes exactly the endpoints the human confirmed."* Without this condition the
feature discards the very endpoints the human just drew.

Three consequences that must be handled in the same change:

- **Idempotency moves per sub-interval.** `--logbook-has-interval-p`
  (`config.el:3611-3628`) is keyed on the item's own rendered `[start]--[end]`,
  which is no longer written. Left alone, a replay double-writes everything —
  and partial failure becomes normal, since the `unwind-protect` at
  `config.el:3696-3703` cancels mid-item.
- **`--review-describe` must show the written total** beside the displayed
  span (`config.el:4292-4311`). The median span writes 46% of what it displays;
  confirming a number that is not the one recorded is worse than the overcount.
- **`--review-insert-remainders` needs a hard rule** (`config.el:5192-5231`):
  a remainder may never extend past the endpoint the human just set. Today,
  narrowing inside a turn leaves a `resume`→`pause` boundary in the leftovers,
  which under (a) refuses to split — producing a remainder that strictly
  *contains* the item just narrowed. `config-test.el:3213` and `3268` pass
  through this because they count events, not time.

**(c) Silence `--trigger-auto-clock-in`** (`config.el:2130-2172`). It cannot
queue an event instead: no Elisp writes the queue, Emacs never learns the
`session_id` (`config.el:2113-2115`), and a lone `clock_in` yields no review
item and is archived away by `--queue-file-drained-p`.

**Keep the `--auto-clock-in-active` binding at `config.el:3805`.** Its second
job — preventing the trigger from destroying the pending state-change note
during `--review-apply-state` (`config.el:3782-3788`) — survives regardless.

Note `--blocker-clock-running-p` (`config.el:2069-2092`) goes quiet: nothing
opens a clock outside apply. A safety net falling silent, not a break; record
it rather than discovering it.

### 3. Zero-width spans — `31f766ab`

Cause 2 (an open cluster) **dissolves as a consequence of (a)** — verify rather
than implement. Cause 1 remains: a real sub-minute span renders
`[HH:MM]--[HH:MM]` because org timestamps are minute-precision. Decide then:
render seconds in the review buffer only, or accept and document. Cheap either
way, and only meaningful once (a) has removed the noise.

### 4. Phantom resumes — `09c134c4`

**Test the free hypothesis before instrumenting.** There are 9
`resume`→`resume` adjacencies in the corpus and 8 unmatched resumes — two
`UserPromptSubmit` with no intervening `Stop` is what an interrupt or a queued
follow-up looks like, and that may account for all of them with no phantom
involved. Check that first; it needs no new code.

If instrumentation is still wanted, record `transcript_path` (plus an offset),
not prompt text, in `bin/hooks/queue-append:210-248` — it answers the question
retroactively rather than only prospectively. All 467 resumes are currently
identical on `(source, agent_id, agent_type)`, so nothing stored today can
discriminate.

### 5. Correct the accumulated record — `507754ba`

Last, and only now specifiable: "corrected" means whatever the fixed aggregator
produces. 98 post-cutover CLOCK lines, 38 in TODO.org and 60 in DONE.org.
**Recompute durations; preserve every heading attribution** — guideposts carry
no heading, so attribution cannot be derived and is the one thing review
actually contributed. Write the deltas as a reviewable list before applying.

## Verification

- `bin/test` green. New tests: the adjacency gate (long turn survives, ordinary
  threshold still splits, nil `:kind` splittable); per-run splitting with the
  idle floor; `:suggested nil` writes one line at confirmed endpoints;
  remainder never extends past a human endpoint.
- **Re-run the corpus measurement** — the same script that produced 39.97 h
  should report **24.27 h written** after (a)+(b), and **zero** zero-width
  spans. This is the assertion that the epic worked.
- The six known long turns (`08-17 15:28→16:37`, `08-11 13:55→14:53`,
  `08-11 21:30→22:27`, `08-14 20:43→21:26`, `08-17 13:09→13:46`,
  `08-17 16:49→17:17`) must appear as real spans, not points.
- `bin/lint-org` unchanged at 0 errors / 28 warnings; `org_pending_updates`
  still renders (it reuses `--review-items-from-queue` verbatim).
- Reload per the org-dev skill and confirm in the running Emacs, not only in
  batch.

## Recorded, not fixed here

- **The block logic is dead in production.** `--review-guidepost-p` admits only
  `pause`/`resume`, so `blocks` is always nil and the splitting clause never
  fires. f4e628ce is `DONE` and archived on the strength of tests that exercise
  it directly. Activating it would change numbers on the existing record —
  worth its own heading.
- **(a)+(b) is arithmetically identical to full `resume`→`pause` pairing.** The
  threshold survives as a *grouping and display* control only; its 1200 s
  derivation (96a51c2f) no longer defends any duration. Say so in
  `guidepost-gap-threshold`'s docstring.
- The aggregator docstring's claim that spans render as *active* timestamps
  (`config.el:3097-3099`) is already false — `--review-format-annotation` uses
  inactive (`config.el:3591`). Fix while in the file.
