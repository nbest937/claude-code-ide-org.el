# Plan — Queue capture/amend, write-through when free (`b5f94b88`)

*Revised 2026-08-13 after a critical review of the first draft, and after
`3d0487f4` shipped. Changes are marked **[rev]**. Step 0 of the original
plan (giving this plan its own file, restoring `hazy-moseying-sky.md`) is
**done** — commit `7970e13` — and has been removed rather than left to be
re-executed.*

## Context

The user wants to interject a question or proposal while a session is
already in flight — which, in their words, "often leads to something new
to capture or amend." Today that collides: `org_capture` writes
`TODO.org` immediately, the org skill's prose edits go through the
`Edit` tool straight to disk, and the human has the buffer open. The
session that prompted this hit "the file had been modified on disk since
you last read it" twice.

Their literal proposal was a blocking lock. `b5f94b88` records why that
looks wrong — waiting reintroduces the hang class the queue exists to
avoid, and a lock cannot bind the `Edit` tool anyway — and reframes it as
a *missing queue*: state changes already defer to a human review pass;
capture and amend do not.

**Decided with the user:**
- v1 covers **capture and amend**. Structural writers (`org_refile`,
  `org_archive`, `org_move_sibling`, `org_sort_children`) stay immediate.
- Capture **writes through when the file is free** and queues only when
  it is busy.

Intended outcome: an interjection never collides and is never lost. In
the common case the heading appears at once, exactly as now.

## What "busy" means — **[rev]** and why the check is advisory

Every MCP write runs inside one Emacs process, and Emacs is
single-threaded, so two concurrent sessions calling `org_capture` are
already serialised. MCP-vs-MCP corruption is not reachable.

The real collision is the `Edit` tool writing the file on disk while
Emacs holds the buffer, plus `org-capture`'s `:immediate-finish` save
committing a human's half-finished edits. So the busy test is **is the
target buffer modified** — the `buffer-modified-p` check used ad hoc
throughout the prompting session, promoted to a rule.

**[rev] State it as advisory, not decisive.** The first draft implied the
check makes write-through safe. It does not: nothing is held between the
check and the write, so a keystroke or an `Edit` call landing in that
window still collides. The window is narrow and the check removes the
*common* case, which is worth having — but the docstring must say
"reduces the collision window" rather than "prevents collisions", or the
next reader will trust it further than it earns. Do not add a lock to
close the gap; that is the design this heading already rejected.

**[rev] Deliberately not treated as busy:** `buffer-read-only`. The user
sets it to guard against their own keystrokes, and clearing it is
established practice.

**Honest limit, state it in the docs:** this helps only when Claude uses
`org_amend` instead of the `Edit` tool. The `Edit` tool consults nothing
and cannot be intercepted. The mechanism is a practice plus a safety
net, not enforcement.

## Design

### 1. Two new event kinds

`capture` and `amend`, on the existing JSONL line. Add nullable fields to
`bin/hooks/queue-append`'s `jq -n` template, in the same style as the
existing `state`/`from`:

| field | capture | amend |
|---|---|---|
| `id` | the **pre-minted** heading ID | target heading ID |
| `title` | heading text | — |
| `target` | parent `:ID:` or category title | — |
| `tags` | tag list | — |
| `text` | — | the prose block |
| `note` | short reason | short reason |

### 2. The write-through gate — **[rev]** pin the reply strings

The tool decides; the hook writes. `queue-append` already parses tool
replies, so extend that:

- Tool wrote through → `Captured: ...` / `Amended: ...` → hook appends
  **nothing**.
- Tool deferred → `Queued capture: ...` / `Queued amend: ...` → hook
  appends the event.

**[rev]** This is a string contract between two files that change
independently, and this project has already been bitten once by a reply
parse going stale when a message was reworded (`queue-append` still
carries a comment about recovering an id from a reply shape that no
longer exists). Getting it wrong double-applies or silently drops.

So: define the four prefixes as **named constants in `config.el`**, have
the tools build replies from them, and add a shell assertion that
`bin/hooks/queue-append`'s cases match those literals — a test that fails
when either side is reworded alone, rather than one that only exercises
today's spelling.

### 3. The ID is minted at call time either way

`claude-code-ide-org-capture` already calls `(org-id-new)` before writing
and returns the ID so "the caller can immediately act on the new
heading." **Keep that on both paths**, so `org_capture` → `org_set_todo`
keeps working with no new ceremony.

Do **not** call `org-id-add-location` on the deferred path — the heading
does not exist yet, and poisoning the ID cache would make every later
lookup lie.

### 4. `org_set_todo` on a pending ID — the sharpest edge

If a capture deferred, its heading does not exist, so `org_set_todo`
returns `Error: unknown id` — and `queue-append` **drops any event whose
reply starts with `Error:`**. The state would be silently lost.

Fix: when `--at-id` fails, `org_set_todo` and `org_clock_in` consult the
queue for a pending `capture` naming that ID, and on a hit return a
normal `Queued ...` reply. Reading the queue from a tool has precedent in
`claude-code-ide-org-pending-updates`.

### 5. Apply

Extend the `pcase` in `--review-apply-item`:

- **capture** → resolve the target via `--capture-target-spec` *at apply
  time*; insert the heading with the event's pre-minted `:ID:` and a
  `:CREATED:` taken from the **event timestamp**, not from now. Then
  `org-id-add-location`.
- **amend** → go to the ID and append the prose at the end of that
  heading's *own* body, before its first child. Needs an `--end-of-body`
  helper; `--append-to-drawer` shows the `org-end-of-meta-data` idiom.

**[rev] What happens when the target no longer exists.** The first draft
said to resolve at apply time "since the target may have moved" but never
said what to do when it is *gone*. This is not hypothetical: `e51d6ba1`
cancelled four headings in a single pass on 2026-08-13, and a capture
targeting one of them could easily outlive it. Rule: resolution failure
returns an error string for that item, leaving its events unapplied and
the item in the queue, exactly as a stale state transition does. The
human then retargets or dismisses. Never silently fall back to the
capture file's end — a heading filed somewhere nobody chose is the
confidently-wrong record this architecture exists to prevent.

**[rev] `amend` has no conflict detection, and that is a real limit.**
The text lands at the body end regardless of whether the body changed
since queueing — which may be exactly wrong for an amendment written in
response to what the body said. v1 accepts this, because a diff-style
guard is a much larger design, but the review line must show the target
heading's title so a human can spot a body that has moved on, and the
docstring must say the amendment is positional rather than contextual.

### 6. Ordering and dependencies

`--review-items-from-queue` sorts globally by timestamp, so a `capture`
at T0 precedes a `todo` at T1 on the same ID.

- `--review-projected-staleness` must seed IDs created by `capture` items
  in the batch, or the dependent `todo` reads as `unresolved`.
- Applying a `todo` whose `capture` was skipped fails with the existing
  unknown-id error. Honest, needs no new handling — say so in the
  docstring so it is not mistaken for a bug.

### 7. Review buffer — **[rev]** now that `3d0487f4` has shipped

`3d0487f4` landed on 2026-08-13 and changes the surroundings:

- **`a` is taken.** Bindings now in use: `m u t M U a e N d RET x g ?`.
  Pick from the free keys if capture/amend need one — but prefer needing
  none, as `3d0487f4` did by making `:id` mean the same thing for every
  clock item.
- **`--review-describe` has an established shape for proposals that need
  a decision**: `?` in the column state items reserve for `!`, with the
  target named outright. Follow it rather than inventing a third idiom.
- **`--review-heading-title`** already exists for showing a target's
  title, which is what the amend line needs (see §5).

Suggested lines:

```
  capture "Sort :LOGBOOK: chronologically" -> Roadmap        08-13 10:14  short reason
  amend   "Queue attribution is session-scoped"  (4 lines)   08-13 10:16  short reason
```

`amend` text can be multi-line, so show a line count and let the human
preview the full text before marking.

## Files

- `bin/hooks/queue-append` — two kinds, four fields, reply-prefix gate
- `.claude/settings.json` — `PostToolUse` matchers for
  `mcp__emacs-tools__org_capture` and `..._org_amend`
- `modules/tools/claude-code-ide-org/config.el` — reply-prefix constants;
  busy check; rework `claude-code-ide-org-capture`; new
  `claude-code-ide-org-amend` + tool registration; pending-capture
  tolerance in `set-todo`/`clock-in`; `--end-of-body`; describe/apply/
  staleness branches
- `modules/tools/claude-code-ide-org/config-test.el`
- `CLAUDE.md` + `.claude/skills/org/SKILL.md` — prefer `org_amend` over
  the `Edit` tool for body prose; record that subagents may call
  queue-appending tools. Both belong to `02aaae22`.

## Tests

**Every test must be confirmed to fail without the change**, by stashing
`config.el` and re-running. **[rev]** And each must assert the subject
*exists* before asserting anything about it: two tests written for
`3d0487f4` initially passed vacuously because `seq-find` returned nil and
the assertions never ran.

1. Capture writes through when the buffer is clean; heading exists with
   the returned ID.
2. Capture defers when the buffer is modified; **no** heading is written
   and the reply is `Queued capture:`.
3. The deferred ID survives: apply the queued `capture` and the heading
   appears with that exact `:ID:` and a `:CREATED:` matching the event
   timestamp, not apply time.
4. `capture` then `todo` on the same ID apply in one batch, in order, and
   the `todo` does not render `STALE`.
5. `org_set_todo` against a pending-capture ID returns a `Queued` reply,
   not `Error:` — the silent-drop regression.
6. `amend` appends to the body end and does **not** land inside
   `:LOGBOOK:`, `:PROPERTIES:`, or a child heading.
7. **[rev]** A capture whose target has been deleted since queueing
   returns an error string, applies nothing, and leaves its events
   pending — never files the heading somewhere unchosen.

`bin/queue-append-test` (shell):

8. `Captured:` appends **nothing**; `Queued capture:` appends one line —
   the double-apply regression, both directions.
9. `capture`/`amend` field mapping from `tool_input`.
10. **[rev]** The hook's reply-prefix literals match the constants
    `config.el` defines, so rewording one side alone fails the suite.

## Verification

- `bin/test` and `bin/queue-append-test`, both green, with the
  fails-without-the-fix check done explicitly.
- **Reload precondition:** `bin/test` runs `emacs --batch` and reads
  `config.el` fresh, so it needs no reload. Any live check needs
  `emacsclient -e '(load-file ...)'` first — and note that a changed
  `defcustom` default does **not** take effect on reload; it needs an
  explicit `setq` or a restart.
- **[rev] Run it against the live queue before believing the tests.**
  Both defects in `3d0487f4` — a depleted suggestion source and a
  latching guess — were invisible to a green suite and obvious on real
  data within one command.
- Live end-to-end:
  1. With `TODO.org` unmodified, `org_capture` → heading appears at once.
  2. Make the buffer modified, then `org_capture` → reply says queued,
     and `git diff` shows no heading.
  3. `org_set_todo` on that pending ID → `Queued`, not `Error:`.
  4. `M-x claude-code-ide-org-review` → capture and todo render as two
     items; apply both; heading exists with the right ID, state, and
     `:CREATED:`.
  5. Save the buffer, `org_amend` on a real heading → prose appended at
     the body end.
- Confirm the queue gained exactly the expected lines and no more — the
  double-apply failure is invisible in the file otherwise.

## Out of scope

- Structural writers stay immediate.
- `create-lockfiles`: enabling it per-directory via `.dir-locals.el` is a
  reasonable follow-on for second-Emacs contention, but does nothing for
  the `Edit` tool and is not needed here.
- **[rev]** Conflict detection for `amend` (see §5).
- Transcript-derived span labels (`0c8644ff`) remain separate.

## A note for whoever revises this next

**Do not re-enter Plan Mode to revise this plan.** Claude Code writes to
one plan file per *conversation*, which for the conversation that wrote
this is `hazy-moseying-sky.md` — the permanent link for `6b1e73c4` and
`f290161c`. Re-planning would overwrite their record again. Edit this
file directly instead; a revision applying review findings needs no plan
session.
