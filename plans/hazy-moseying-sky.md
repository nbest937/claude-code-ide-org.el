This file holds **two independent plans**, planned in one conversation
and deliberately kept together because Claude Code mints one plan file
per conversation. Both `6b1e73c4` and `f290161c` link here.

They touch adjacent code — the review buffer and the watermark file —
but neither depends on the other, and either can be implemented alone.

---

# Plan 1 — Chain-aware staleness in the review batch (`6b1e73c4`)

## Context

`claude-code-ide-org--review-state-stale-p` guards against the 2026-08-07
hazard: a queued `todo` event applied long after the heading moved on, so
apply faithfully regresses it and writes a plausible-looking but wrong
`State "PLANNING" from "DOING"` line. It compares the event's `from`
against the heading's state **read from the file**.

Post-cutover nothing moves the file until apply moves it, so a batch that
holds a *chain* on one heading (`TODO -> DOING`, then `NEXT -> DONE`)
records the same `from` on every event — whatever the unmoved file said.
Apply the first and the file moves; the second re-checks its `from`
against a file that moved *because of this very batch*, and is refused.

Observed live 2026-08-11 (`0308e7d7`, `9f3c35c7`, each `TODO -> DOING`
then `TODO -> DONE`): the buffer rendered clean, apply refused two of six
items with `refused stale TODO -> DONE ... (heading is now DOING)`, and
the post-apply refresh then showed them `STALE`.

**Verified against the live queue 2026-08-11**, and the evidence is
stronger than the heading recorded. Every `todo` event written by
`org_set_todo` takes `from` from the file, which never moves, so a chain
records one `from` throughout:

- `0308e7d7` — `TODO -> DOING`, `TODO -> DONE`, both `from: TODO`
- `9f3c35c7` — `TODO -> DOING`, `TODO -> DONE`, both `from: TODO`
- `47c027d2` — a **three**-link chain the heading did not record:
  `TODO -> NEXT`, `TODO -> DOING`, `TODO -> DONE`, all three `from: TODO`

The `ExitPlanMode` hook is the exception and matters to the design: it
passes `QUEUE_APPEND_FROM` explicitly, so `f290161c`'s promotion recorded
`from: PLANNING` against a file still saying `TODO`. Its events are
already self-consistent. This is exactly why the rule below accepts
`from` matching **either** the pre-batch baseline **or** the projected
state — one writer produces each shape, and both are legitimate.

The cost is not the wasted keystroke. A flag that fires on nearly every
chain trains the reader to confirm without reading — which is the exact
reasoning `f9f61c04` used when it decided *not* to flag legacy `null`-`from`
events. A guard that is always on is indistinguishable from no guard.

**Intended outcome:** a chain applies in one pass with no prompts, and
org computes each written `from` from reality so the `:LOGBOOK:` history
comes out correct. Genuine out-of-band divergence still stops apply.

**Chosen approach** (per the heading's first candidate): check a chained
item against the batch's own **projected** state. Rejected: having the
writer record `from` as the previous queued `to` — `from` would then mean
two different things depending on whether an earlier event exists, it
could no longer disagree with reality (the property the check rests on),
and it would force `queue-append` to read its own output file, breaking
the blind-`O_APPEND` property the queue design rests on.

## The rule

Capture, per `:ID:`, the **pre-batch** state from the file once. Then walk
the batch in order, tracking each ID's projected state. A state item is
stale iff its `from` matches **neither**:

- the pre-batch file state (the writer saw an unmoved file — the chain
  case, and also the ordinary single-item case), **nor**
- the projected state left by earlier items in this batch for the same
  `:ID:` (the writer saw a file an earlier queued transition had moved).

Everything `--review-state-stale-p` already gets right is preserved: nil
`from` means "unknown" and never flags; `"none"` compares equal to org's
nil; an `unresolved` `:ID:` stays silent so apply reports it on its own
terms.

## Changes — `modules/tools/claude-code-ide-org/config.el`

All within the review section (~L2433–2985).

**1. New `claude-code-ide-org--review-projected-staleness (items)`**
(place beside `--review-state-stale-p`, ~L2471). Walks ITEMS in order:

- Reads each distinct `:ID:`'s current state **once**, via the existing
  `claude-code-ide-org--review-current-state` — keeping the `unresolved`
  symbol distinction intact — and seeds both `baseline` and `projected`.
- For each `:type state` item: stale iff `from` is non-nil, the ID
  resolves, and `from` normalized (reuse the existing `"none"` → nil
  rule) equals neither `baseline` nor `projected` for that ID. Then set
  `projected` = the item's `:to`.
- `:type clock` items never change a keyword; they advance nothing.
- Annotates each state item with `:stale` (t or nil) via `plist-put`,
  matching how `:marked` and `:stale-confirmed` are already carried.

Reuses `claude-code-ide-org--review-current-state`; no new file-reading
path.

**2. `--review-state-stale-p` (L2445)** — consult the `:stale`
annotation when the key is present, otherwise fall back to today's
single-item file comparison unchanged. That fallback is what keeps
direct callers and the existing tests at config-test.el:2559 and :2604
meaning what they mean.

**3. `--review-apply` (L2652)** — call `--review-projected-staleness` on
ITEMS as its first act, *immediately before* the apply loop, not at
render time. This is what preserves `--review-apply-item`'s existing
guarantee (docstring L2605-2613) that a heading changed *since the buffer
was drawn* is still caught: the baseline is read fresh at apply, and only
this batch's own effects are projected over it.

**4. `--review-render` (L2799)** — annotate before drawing, projecting
over **marked items only**, since unmarked items will not move the file.
Consequences, both correct: an unmarked buffer renders exactly as it does
today, and marking the first link of a chain does not make the rest light
up. `--review-describe` (L2764) needs no change — it calls
`--review-state-stale-p`, which now reads the annotation.

**5. `--review-set-mark` (L2823)** — the `y-or-n-p` fires off the same
annotation, so confirming a chain link is no longer demanded. No
signature change; it already calls `--review-state-stale-p`.

Ordering is already correct: `--review-items-from-queue` (L2428) sorts
globally by timestamp and `--review-apply` iterates in that order, so
per-`:ID:` chain order is preserved.

## Accepted consequence

If the human applies only the first link and leaves the rest, the next
refresh reads a moved file with no batch to explain it, and the leftover
renders `STALE`. That is honest — it is a real divergence at that point —
and it is the case `f290161c`'s dismissal path is for. Worth stating in
the docstring so it is not later mistaken for this bug returning.

## Tests — `modules/tools/claude-code-ide-org/config-test.el`

Add beside the existing stale tests (~L2559-2650), using
`claude-code-ide-org-test--with-heading` and
`claude-code-ide-org-test--disk-contents`:

1. **Chain applies in one batch.** Two items on one `:ID:`,
   `TODO -> DOING` then `TODO -> DONE`, both `from: TODO`, both marked.
   `--review-apply` reports `:applied 2`, `:errors nil`; the file ends
   `DONE`; the log holds `State "DOING" from "TODO"` **and**
   `State "DONE" from "DOING"` — org deriving the second `from` from
   reality is the whole point.
2. **Genuine staleness survives inside a batch.** Same batch plus a
   second `:ID:` whose heading was moved out of band
   (`--set-todo-for-real`); that item is still refused with
   `refused stale`, the chain still applies, and the refused heading's
   file text is unchanged.
3. **A chain does not render `STALE`.** `--review-describe` on the second
   link is `"  "`-prefixed, not `"! "`, both with nothing marked and with
   the first link marked.
4. **Regression:** the existing tests at :2559 (refusal + confirmed
   override) and :2604 (`from` matches reality) pass untouched, proving
   the single-item fallback path is intact.

## Verification

- `bin/test` — expect 167 existing + 3 new, all green. Runs under
  `emacs --batch` from a script, so no reload precondition applies and
  the shell-function trap on inline `emacs` does not either.
- **Live pass, and it needs a reload first:** config.el is already loaded
  into the running Emacs, so `M-x claude-code-ide-org-review` will run the
  old code until
  `emacsclient -e '(load-file "…/modules/tools/claude-code-ide-org/config.el")'`
  succeeds — check its return value rather than assuming, per the org-dev
  skill. Then, on the real pending queue: open the review buffer, confirm
  no chain renders `!`, mark a chain, apply, and read the resulting
  `:LOGBOOK:` lines in TODO.org to confirm the second transition's `from`
  is the first's `to`.
- The buffer's interaction feel is the fuzzy part; per this project's
  "reasonably feasible" rule the live pass above is the documented manual
  check, not something forced into a deterministic test.

## Out of scope

`f290161c` (dismissal) is Plan 2 below. The three permanent residents in
the queue — the `dead-beef` phantom and the two pre-cutover `STALE`s —
are untouched by this change and will still be there after it.

---

# Plan 2 — Dismissing a review item that will never apply (`f290161c`)

## Context

The watermark advances only for **applied** items — deliberately, and
rightly: an item skipped this pass is usually one deferred, not one
refused. But the review keymap offers `m`/`u`/`t`/`e`/`RET`/`x`/`g`/`?`
and no dismissal, so an item that will *never* apply has no exit. It
reappears at every review, forever.

Not hypothetical, and confirmed still present after another ingest-apply
round on 2026-08-11 — three permanent residents:

- the `dead-beef` phantom clock (`5e2a1c04`), deliberately the only
  unresolvable-`:ID:` event that will ever exist, in session
  `5063f096`;
- two pre-cutover `STALE` state events (`8f2c1a90` `TODO -> DOING` 13:09,
  `feba67eb` `NEXT -> DOING` 13:29) in session `9f382f54`, whose
  transitions the tools already performed live. Confirming them would
  write `DOING -> DOING` no-ops, the shape behind `3d93021d`.

Today the only ways out are hand-editing a file the design calls
append-only, or forging watermark entries. Both are worse than the
problem.

**Intended outcome:** a keystroke retires an item permanently, the queue
file is never touched, and *why* it was retired survives for a later
audit.

## Chosen approach

Extend the existing `.applied` file with a `dismissed` **map** keyed by
event timestamp, value a short reason string, reusing
`claude-code-ide-org--atomic-write` (config.el:2178).

A map rather than a bare set because the heading's own design question is
right: "already applied live pre-cutover" and "this event should never
have existed" want different treatment at any later audit, and a reason
costs one `read-string`. Dismissal and deferral stay distinguishable
because deferral remains what it already is — simply not marking.

Rejected: a separate `.dismissed` file (doubles the read and write paths
and the atomicity surface for no gain — both facts concern the same
session's queue and are always read together); and a `kind` the reader
skips (that means writing into the queue, which is append-only by
design).

## Changes — `modules/tools/claude-code-ide-org/config.el`

**1. `--queue-watermark-data (session-id)`** — new, parses the `.applied`
JSON once and returns the whole alist. `--queue-applied` (L2153) becomes
a thin caller.

**2. `--queue-mark-applied` (L2191) must preserve `dismissed`.** This is
the load-bearing edit, not a detail: it currently writes
`(applied . …)` and nothing else, so the moment `dismissed` exists in the
file, any apply would silently erase every dismissal — and the symptom
would be dismissed items quietly returning, which reads as "the feature
doesn't work" rather than "a writer clobbered it". Both writers
read-modify-write the whole object.

**3. `--queue-dismissed (session-id)`** — hash ts → reason, empty when
the key is absent. Mirrors `--queue-applied`'s shape, including its
per-event-not-high-water-mark reasoning.

**4. `--queue-mark-dismissed (session-id ts-strings reason)`** — unions
into the existing dismissed map, preserves `applied`, writes atomically.
Mirror of `--queue-mark-applied`.

**5. `--queue-events` (L2208)** — skip events in *either* set. One extra
hash lookup inside the loop that already consults `applied`.

**6. `claude-code-ide-org-review-dismiss`** — new interactive command.
Reads a reason with `read-string`, confirms with `y-or-n-p`, dismisses
every event behind the item at point via its `:events` list — the same
accessor `--review-record-applied` (L2635) already uses to attribute
events to sessions — then refreshes. The `y-or-n-p` is safe here for the
reason already documented on `--review-set-mark`: apply is only ever
reached from a genuinely interactive command, never `emacsclient -e`.

**7. Bind `d`** in the `dolist` at L2674 — which sits outside the
`defvar` initializer precisely so a live reload picks new bindings up —
and add `d dismiss` to the header line in `--review-render` (L2805).

**Backward compatibility:** existing `.applied` files carry only
`applied`; reading `dismissed` yields nil and an empty table. No
migration step.

**Reversibility:** dismissal records a fact beside the queue and destroys
nothing — the queue file is untouched, so undoing one means deleting a
key from a small JSON file. Worth stating in the docstring; not worth a
`u`-style undo binding until someone wants it.

## Tests — `modules/tools/claude-code-ide-org/config-test.el`

Add beside the existing watermark tests (~L2273-2330), which already set
up a temp queue directory:

1. A dismissed event is filtered out of `--queue-events`, exactly as an
   applied one is.
2. **Clobber regression, the one that matters:** dismiss an event, then
   mark a *different* event applied, and assert the dismissal survives —
   then the reverse order, asserting `applied` survives a dismissal.
3. The reason string round-trips through the file.
4. Dismissal is per-event, not a prefix: dismissing a middle event leaves
   both earlier and later events pending.
5. Backward compat: a watermark file containing only `applied` — today's
   on-disk shape — reads back with an empty dismissed set and unchanged
   applied set.

## Verification

- `bin/test` — the new tests plus the existing suite, all green. Runs
  under `emacs --batch` from a script, so no reload precondition applies.
- **Live pass, reload first:** config.el is already loaded in the running
  Emacs, so the review buffer will keep its old keymap and old filtering
  until
  `emacsclient -e '(load-file "…/modules/tools/claude-code-ide-org/config.el")'`
  returns successfully — check the return value rather than assuming it
  worked, per the org-dev skill.
- Then the end-to-end check this repo has been waiting for: `M-x
  claude-code-ide-org-review`, press `d` on the `dead-beef` phantom and
  on the two pre-cutover `STALE`s, give each a reason, and confirm they
  leave the buffer. Quit and re-run the command from scratch to confirm
  they stay gone. Finally read the two affected watermark files —
  `5063f096-….applied` and `9f382f54-….applied`, two different sessions,
  which also exercises the per-session write path — and confirm each
  still holds its full `applied` list alongside the new `dismissed` map.

## Out of scope

`e3f70e61` (two display defects in how a *failed* item renders, seen on
the same `dead-beef` item) is a separate heading. Dismissing the phantom
removes the occasion to see those defects but does not fix them.
