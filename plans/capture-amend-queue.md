# Plan — Queue capture/amend, write-through when free (`b5f94b88`)

> **Step 0, before anything else — this file's identity.**
> Claude Code reuses one plan file per conversation, so this plan
> overwrote the previous contents of `hazy-moseying-sky.md`, which held
> the two plans for `6b1e73c4` and `f290161c`. **Both of those headings
> link this path**, so their links now point at an unrelated plan.
> The old content survives at `plans/hazy-moseying-sky.md` and in git
> history. First implementation action: copy this plan to its own file
> under `~/.claude/plans/`, restore `hazy-moseying-sky.md` from the
> archived copy, and link the new file from `b5f94b88`. Then run
> `bin/sync-plans`. Do this *before* any code, so the archive never
> carries the wrong plan under a linked name.

## Context

The user wants to interject a question or proposal while a session is
already in flight — which, in their words, "often leads to something new
to capture or amend." Today that collides: `org_capture` writes
`TODO.org` immediately, the org skill's prose edits go through the
`Edit` tool straight to disk, and the human has the buffer open. This
session hit "the file had been modified on disk since you last read it"
twice.

Their literal proposal was a blocking lock. `b5f94b88` records why that
looks wrong — waiting reintroduces the hang class the queue exists to
avoid, and a lock cannot bind the `Edit` tool anyway — and reframes it as
a *missing queue*: state changes already defer to a human review pass;
capture and amend do not.

**Decided with the user, 2026-08-13:**
- v1 covers **capture and amend**. Structural writers (`org_refile`,
  `org_archive`, `org_move_sibling`, `org_sort_children`) stay immediate.
- Capture **writes through when the file is free** and queues only when
  it is busy. Today's immediacy is preserved; only contended writes
  defer.

Intended outcome: an interjection never collides and is never lost. In
the common case the heading appears at once, exactly as now.

## What "busy" means, and why it is narrower than it first appears

Worth stating because it changes the mechanism. **Every MCP write runs
inside one Emacs process** — the tools server — and Emacs is
single-threaded, so two concurrent sessions calling `org_capture` are
already serialized. MCP-vs-MCP corruption is not reachable.

The real collision is **the `Edit` tool writing the file on disk while
Emacs holds the buffer**, plus `org-capture`'s `:immediate-finish` save
committing a human's half-finished edits.

So the busy test is: **is the target buffer modified?** — i.e. does
someone have unsaved work in it. That is exactly the manual
`buffer-modified-p` check used ad hoc throughout this session, promoted
to a rule.

Deliberately **not** treated as busy: `buffer-read-only`. The user sets
it to guard against their own keystrokes, not to block this tool, and
clearing it is established practice. Read-only keeps today's behavior.

**Honest limit, state it in the docs:** this helps only when Claude uses
`org_amend` instead of the `Edit` tool. The `Edit` tool consults nothing
and cannot be intercepted. The mechanism is a practice plus a safety
net, not enforcement.

## Design

### 1. Two new event kinds

`capture` and `amend`, carried on the existing JSONL line. Add nullable
fields to `bin/hooks/queue-append`'s `jq -n` template, in the same style
as the existing `state`/`from` (populated per kind, null otherwise):

| field | capture | amend |
|---|---|---|
| `id` | the **pre-minted** heading ID | target heading ID |
| `title` | heading text | — |
| `target` | parent `:ID:` or category title | — |
| `tags` | tag list | — |
| `text` | — | the prose block |
| `note` | short reason | short reason |

All read from `$payload.tool_input.*`, which `queue-append` already does.

### 2. The write-through gate, and how the hook learns about it

The tool decides; the hook writes. `queue-append` already parses tool
replies (`(was NEXT)`, `Clocked out: ... (id: ID)`), so extend that:

- Tool wrote through → replies `Captured: ...` / `Amended: ...` →
  **hook appends nothing** (it already happened).
- Tool deferred → replies `Queued capture: ...` / `Queued amend: ...` →
  hook appends the event.

Gate it on the reply prefix, next to the existing `Error:*) exit 0`
case at `bin/hooks/queue-append:96`. Getting this wrong double-applies,
so it needs a shell test both ways.

### 3. The ID is minted at call time either way

`claude-code-ide-org-capture` (config.el:1275) already calls
`(org-id-new)` before writing and returns the ID so "the caller can
immediately act on the new heading." **Keep that on both paths.** The
deferred path returns the same shape, so `org_capture` → `org_set_todo`
keeps working with no new ceremony.

Do **not** call `org-id-add-location` on the deferred path — the heading
does not exist yet, and poisoning the ID cache would make every later
lookup lie.

### 4. Consequence that must not be missed: `org_set_todo` on a pending ID

If a capture deferred, its heading does not exist, so `org_set_todo`
returns `Error: unknown id` — and `queue-append` **drops any event whose
reply starts with `Error:`**. The state would be silently lost. This is
the sharpest edge in the plan.

Fix: when `--at-id` fails, `org_set_todo` and `org_clock_in` consult the
queue for a pending `capture` naming that ID, and on a hit return a
normal `Queued ...` reply. Reading the queue from a tool has precedent —
`claude-code-ide-org-pending-updates` already does it.

### 5. Apply

Extend the `pcase` in `--review-apply-item` (config.el:2856):

- **capture** → resolve the target via the existing
  `--capture-target-spec` (config.el:1239) *at apply time*, since the
  target may have moved since queueing; insert the heading with the
  event's pre-minted `:ID:` and a `:CREATED:` stamp taken from the
  **event timestamp**, not from now — the thought happened when it was
  captured. Then `org-id-add-location`.
- **amend** → go to the ID and append the prose at the end of that
  heading's *own* body, before its first child. Needs a small
  `--end-of-body` helper; `--append-to-drawer` (config.el:271) shows the
  `org-end-of-meta-data` positioning idiom to follow.

### 6. Ordering and dependencies

`--review-items-from-queue` already sorts globally by timestamp, so a
`capture` at T0 precedes a `todo` at T1 on the same ID. Two gaps:

- `--review-projected-staleness` must seed IDs created by `capture`
  items in the batch, or the dependent `todo` reads as `unresolved`.
  This is the same projected-state machinery `6b1e73c4` built.
- Applying a `todo` whose `capture` was skipped fails with the existing
  unknown-id error. That is honest and needs no new handling — but say
  so in the docstring so it is not later mistaken for a bug.

### 7. Review buffer

Add `capture` and `amend` branches to `--review-describe`
(config.el:~2701). Suggested lines, aligned with the two-space column
state lines reserve for `! `:

```
  capture "Sort :LOGBOOK: chronologically" -> Roadmap        08-13 10:14  short reason
  amend   "Queue attribution is session-scoped"  (4 lines)   08-13 10:16  short reason
```

`amend` text can be multi-line, so show a line count and let `e` (the
existing `review-edit-note` binding) or a new key preview the full text.

## Files

- `bin/hooks/queue-append` — two kinds, four fields, reply-prefix gate
- `.claude/settings.json` — `PostToolUse` matchers for
  `mcp__emacs-tools__org_capture` and `..._org_amend`
- `modules/tools/claude-code-ide-org/config.el` — busy check; rework
  `claude-code-ide-org-capture`; new `claude-code-ide-org-amend` + tool
  registration; pending-capture tolerance in `set-todo`/`clock-in`;
  `--end-of-body`; describe/apply/staleness branches
- `modules/tools/claude-code-ide-org/config-test.el` — see below
- `CLAUDE.md` + `.claude/skills/org/SKILL.md` — prefer `org_amend` over
  the `Edit` tool for body prose; record that subagents may call
  queue-appending tools (`16160d23`'s undocumented residue). Both belong
  to `02aaae22`; do them there, not here.

## Tests

`bin/test` (ERT) — each must be confirmed to **fail without the change**,
by reverting `config.el` and re-running. Three tests written earlier this
session passed against unfixed code and proved nothing.

1. Capture writes through when the buffer is clean; heading exists with
   the returned ID.
2. Capture defers when the buffer is modified; **no** heading is written
   and the reply is `Queued capture:`.
3. The deferred ID survives: apply the queued `capture` and the heading
   appears with that exact `:ID:` and a `:CREATED:` matching the event
   timestamp, not apply time.
4. `capture` then `todo` on the same ID apply in one batch, in order,
   and the `todo` does not render `STALE`.
5. `org_set_todo` against a pending-capture ID returns a `Queued` reply,
   not `Error:` — the silent-drop regression.
6. `amend` appends to the body end and does **not** land inside
   `:LOGBOOK:`, `:PROPERTIES:`, or a child heading.

`bin/queue-append-test` (shell):

7. `Captured:` reply appends **nothing**; `Queued capture:` appends one
   line — the double-apply regression, both directions.
8. `capture`/`amend` field mapping from `tool_input`.

## Verification

- `bin/test` and `bin/queue-append-test`, both green, with the
  fails-without-the-fix check done explicitly.
- **Reload precondition:** `bin/test` runs `emacs --batch` and reads
  `config.el` fresh, so it needs no reload; any live check needs
  `emacsclient -e '(load-file ".../config.el")'` first, and its return
  value checked rather than assumed.
- Live end-to-end, which is the pass that actually matters:
  1. With `TODO.org` unmodified, `org_capture` → heading appears at once.
  2. Make the buffer modified (type a character, do not save), then
     `org_capture` → reply says queued, and `git diff` shows no heading.
  3. `org_set_todo` on that pending ID → `Queued`, not `Error:`.
  4. `M-x claude-code-ide-org-review` → the capture and the todo render
     as two items; apply both; heading exists with the right ID, state,
     and `:CREATED:`.
  5. Save the buffer, `org_amend` on a real heading → prose appended at
     the body end.
- Confirm the queue file gained exactly the expected lines and no more —
  the double-apply failure is invisible in the file otherwise.

## Out of scope

- Structural writers stay immediate (user's decision).
- `create-lockfiles`: `b5f94b88` records that Doom disables it with a
  backup-shaped rationale that does not describe a lock file, and that
  `ask-user-about-lock` already has ask-don't-wait semantics. Enabling it
  **per-directory** via `.dir-locals.el` is a reasonable follow-on for
  second-Emacs contention, but it does nothing for the `Edit` tool and is
  not needed for this plan.
- Transcript-derived span labels (`0c8644ff`) and unattributed-guidepost
  assignment (`3d0487f4`) remain separate.
