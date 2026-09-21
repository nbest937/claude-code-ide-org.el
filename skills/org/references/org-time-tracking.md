# Time tracking (guideposts, spans, clocks)

> Ships with the **claude-code-ide-org** plugin and is promoted only
> where `claude-org-setup` was told time tracking is on (`:ID:` 1b69fe4e).
> What gates the *feature* is the `time_tracking` option, described below.
> Its companion `org-session-tracking.md` carries the task-tracking
> hooks, which are never gated. The consuming project's own rules take
> priority over this file.

**Nothing here applies unless time tracking is switched on.** The hooks
ship *wired*, but every time-tracking script gates itself on the plugin's
`time_tracking` option — declared in `.claude-plugin/plugin.json`'s
`userConfig` and **defaulting to off**. In a default install
`org_clock_in` and `org_clock_out` queue events that nothing consumes, no
guidepost is ever appended, and no span is ever offered.

**This file is loaded because setup was told the feature is on** —
`claude-org-setup --time-tracking`, the hooks' own variable in setup's
environment, or a repo whose `.claude/settings.json` wires that variable
itself. Setup cannot see the plugin option, so the two can still
disagree; the option is what the hooks obey. Turn it on with
Claude Code's `/config` command — a slash command typed in a session,
not a path — which is also where you check which it is. (A marketplace
install could pass `--config time_tracking=true` instead; this plugin is
not published to one, so that route does not apply here.)

**One value, every project.** The option is stored per-user
(`~/.claude/settings.json`, under `pluginConfigs`), not per-repo, so it
cannot be on for one project and off for another. That matches what sits
underneath it: the queue is a single global directory and the review
buffer is one buffer, which is why spans split on a project boundary
rather than being kept apart by separate queues.

**A repo wiring these scripts through its own `.claude/settings.json`**
rather than the plugin's has no option to read. There, wiring the row
*is* the opt-in, and the command sets
`CLAUDE_PLUGIN_OPTION_TIME_TRACKING=true` itself — which is what this
repository does.

**`:LOGBOOK:` CLOCK entries** (org's own, native mechanism) hold
  *confirmed intervals* — work time a human accepted at a review pass.
  **No hook writes one.** Since the 2026-08-11 cutover the `Stop` and
  `UserPromptSubmit` hooks append **turn-boundary guideposts**: bare
  timestamps, naming no heading and touching no clock. The review pass
  clusters those into spans, and a human confirms or corrects each one
  before it becomes a CLOCK line. So the *emission* is still per-turn;
  the *record* is not, and intervals are per-decision rather than per-turn.

  Two consequences that read as bugs and are not. A `DOING` heading
  normally has **no running clock** — live CLOCK lines are only ever
  written by the review pass, so every `DOING` heading sits clockless
  between passes. And CLOCK lines arrive in **bursts when someone
  applies**, not continuously as work happens, so their timestamps
  describe when the work was, never when the line was written.

The time-tracking rows of `hooks/hooks.json`. None reaches Emacs — each
appends a line to the session's queue file and exits:

| Hook                | Script                        | Appends       |
|---------------------|-------------------------------|---------------|
| `Stop`              | `bin/hooks/session-pause`     | `pause`       |
| `Stop`              | `bin/hooks/clock-target-check`| nothing — *blocks the stop*, once per session, when write activity has no `clock_in` |
| `UserPromptSubmit`  | `bin/hooks/session-resume`    | `resume`      |
| `PermissionRequest` | `bin/hooks/block-start`       | `block_start` |
| `PostToolUse` (unscoped) | `bin/hooks/block-end`    | `block_end`, if a block is open |
| `PermissionDenied`  | `bin/hooks/block-end`         | `block_end`, if a block is open |

Two `PostToolUse` `queue-append` matchers belong here too, wiring
`org_clock_in` and `org_clock_out` to the queue. The three that wire
`org_set_todo`, `org_capture` and `org_amend` are task-tracking and ship
unconditionally — see `org-session-tracking.md`.

**`clock-target-check` blocks rather than appends.** It backstops the
rule that a session names the heading its first write belongs to, which
lives in the state-transition rules. It cannot name a heading — that
judgement belongs to the rule, not the hook.

`session-pause` and `session-resume` are one line each — `exec
queue-append pause` / `resume`. They are *guideposts*: timestamps marking
when the agent was running, which the review pass clusters into spans. A
stopped Emacs costs nothing.

**Permission blocks** (`:ID:` f4e628ce). `Stop` fires when a *turn* ends,
and a turn stalled on a permission prompt has not ended — so the wait
used to be credited as agent work. `block-start` and `block-end` bracket
it and the review pass removes the bracketed interval. The pair shares
one **sentinel** per session, `<session_id>.block-open`, because
`PermissionRequest` carries no `tool_use_id` to key on and prompts
serialise, so at most one block is ever open; `block-end` runs on every
tool call, so its common path is one `stat`.

### The three numbers that shape a recorded interval

Three `defcustom`s decide how guideposts become CLOCK lines, all at
their defaults: `claude-code-ide-org-guidepost-gap-threshold` (1200 s,
grouping and display only), `claude-code-ide-org-span-idle-floor`
(120 s, and the consequential one — it decides how much idle the record
claims as work), and `claude-code-ide-org-span-minimum-interval` (0 s, a
named no-op).

**Do not infer any of them from a drawer.** They are why two CLOCK lines
on one heading can describe adjacent work and still be separate, and why
a turn you remember taking thirty seconds may appear nowhere at all.

Their derivations — the 422-event measurement behind 1200 s, the 54-vs-39
line count and the eight hours that 300 s would re-absorb, and why a
settable no-op is still worth naming — are in
`org-time-tracking-internals.md`, which is not promoted. Read it before
changing one; you do not need it to act.

### Stale interval recovery

A crash can leave a CLOCK line open. `SessionStart` reports any interval
opened before today, and the report carries its own instructions — it
states when the interval opened, asks when work stopped, and names the
recovery call. **Do not invent a stop time**: a plausible suggestion is
harder to reject than none (`:ID:` 7771fc63). Detection and its two
`defcustom`s are in `org-time-tracking-internals.md`.

## Clock side effects of state transitions

**Everything in this section is inert with the default wiring.** It
applies only where the time-tracking hooks are installed; the keyword
semantics themselves, which apply always, are in
`org-state-transitions.md`.

**"Side effect" means the call you must make, not something that happens
to the file.** Every entry queues an event; the CLOCK line appears when a
human applies it. You still make exactly these calls, in exactly these
places — but nothing here edits an org file at the moment you act.

| Transition                | Side effect                         |
|---------------------------|-------------------------------------|
| `TODO`     → `NEXT`       | None                                |
| `TODO`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `NEXT`     → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `DOING`    → `DONE`       | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `WAITING`    | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `REVIEW`     | Close the CLOCK (call `org_clock_out`) |
| `DOING`    → `CANCELLED`  | Close the CLOCK (call `org_clock_out`) |
| `WAITING`  → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `REVIEW`   → `DOING`      | Open a CLOCK (call `org_clock_in`)  |
| `REVIEW`   → `DONE`       | None                                |
| Any        → `MAYBE`      | None                                |

`REVIEW` behaves exactly like `WAITING`: entering it closes the clock,
leaving it for `DOING` opens one, and `REVIEW` → `DONE` touches nothing
because no clock is running. On a *grouping*, entering `REVIEW` closes
the grouping's clock only if the grouping holds the running one, exactly
as the `from DOING` rule below says.

**At most one heading carries a running clock**, because org runs one —
which is why `DOING` being plural is not a contradiction. What records
actual execution is the clock; the keyword records what is owed.

**Rule**: a transition *to* `DOING` opens a clock **when you are starting
work now**. Two exceptions. A **retroactive** `DOING` — recording that a
heading was started earlier — opens nothing, and the queue honours that:
`org_set_todo` and `org_clock_in` are separate calls precisely so state
and clock are decided separately, and apply suppresses the auto-clock
trigger for every item it lands (`:ID:` 4f6a6bb1). A hand `C-c C-t` in
Emacs *does* clock in at once, so recording that something *was* started
is a queue action, not a keystroke. And a **grouping** entering `DOING`
opens no automatic clock, because there the keyword means "a member is in
the mail"; that exemption bites only on a state changed by hand, and
never suppresses a deliberate `C-c C-x C-i`.

**Rule**: a transition *from* `DOING` closes the clock **if this
heading's clock is the one running**. Because `DOING` is plural, a
heading can be `DOING` with no clock — another heading holds it — and
there is then nothing to close.

**Rule**: before a session's first act that changes anything — a repo
edit, a capture, an amend, any immediate org tool — name the heading the
work belongs to and call `org_clock_in` on it, or on "Review and
planning" (that exact title) for cross-cutting meta-work. No heading yet
means capture one first, with an `initial_state`. The trigger is the
*first write, not the ask*: a session that opens as a question drifts
into tracked work, and the drift is invisible from inside it (`:ID:`
ccfd89ce). A purely read-only session owes nothing.
`bin/hooks/clock-target-check` backstops this at turn end, once per
session; it reports and cannot name the heading.

**Rule**: `org_clock_out` is the last call of the turn, after the last
write. A `clock_out` closes the run and nothing reopens one before the
turn's `pause`, so work done after it reaches review as *nothing* — not
even an unassigned span (`:ID:` b09aca60).

**A grouping may still be clocked deliberately** (`:ID:` 3964c575,
declined): a parent's own coordination time is real work. The cost is a
reporting one — a clocktable row for a parent shows own plus subtree as
one number (`:ID:` 64d34a64).
