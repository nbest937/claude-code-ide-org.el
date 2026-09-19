# Time tracking: measured internals

> Ships with the **claude-code-ide-org** plugin and is **deliberately not
> promoted** into `.claude/rules/` — the same choice as
> `org-emacs-setup.md`. This is *why the numbers are what they are*, read
> when changing one or doubting a recorded interval, never needed to act.
> The rules a session follows are in `org-time-tracking.md`, which does
> promote; it points here.
>
> Split out 2026-09-19 (a PR #28 review finding). The promoted file had
> grown to 335 lines — 29% of the always-loaded rules — in a default
> install where none of it applies. The decision to promote
> unconditionally stands and is unchanged: what moved is reference
> material, not a gate, so nothing new is switchable and a consumer who
> turns the feature on still gets every rule.

### The three numbers that shape a recorded interval

All three are `defcustom`s, all three run at their defaults, and none was
written down here until 2026-09-02. They apply in order:

| variable | default | decides |
|---|---|---|
| `claude-code-ide-org-guidepost-gap-threshold` | 1200 s | how guideposts group into spans for review |
| `claude-code-ide-org-span-idle-floor` | 120 s | how much idle *inside* a span is absorbed rather than split on |
| `claude-code-ide-org-span-minimum-interval` | 0 s | below which a run is dropped rather than written |

**A fourth input is not a number, and it matters most to a repo that is
not this one.** Guideposts are keyed on `(timestamp, kind, project)`, so
a **project boundary splits a span** — and it is the only thing that
still does, a permission block having become a subtraction rather than a
split. The queue is a single global directory under `~/.claude/org-updates/`,
shared by every project a session runs in; before the change two repos'
turns in the same window clustered into one span, crediting one
project's minutes to the other's heading. Both sides must be *known* and
different — `cwd` has only been recorded since 2026-09-04 and cannot be
backfilled, so a missing value means "unknown", never "elsewhere", and a
span predating the field is never shattered by it.

**The threshold no longer defends any duration, and reading it as though
it still does is the mistake this section exists to prevent.** A span
used to be written as one CLOCK line end to end, so where the threshold
fell decided how much idle became work — which is what made its
derivation load-bearing. Since 2026-08-18 apply writes one line per run
of `resume` → `pause` *inside* the span, so the threshold now governs
**grouping and display only**: how many items a human is shown and how
wide each reads. Moving it moves lines around the review buffer without
moving a single recorded minute.

Its value is still well founded, for what it now does. 1200 s sits inside
a band containing *no observations at all* — measured over 422 events,
the longest short gap was 1061 s and the shortest long gap 2070 s — and
span count is flat across 1200–1800 s, so every value in the band yields
an identical reconstruction. It was 900 s until 2026-08-13, just below
the band, splitting five spans nothing justified splitting.

**The idle floor is the consequential one — it is what decides how much
idle the record claims as work.** Two runs separated by less than 120 s
merge into one line. Strictly less, so a gap of exactly 120 s splits.
The trade is deliberate and measured: splitting at every idle gap turns
one span into 54 CLOCK lines against 39 at two minutes, while raising
the floor to 300 s would write 30.89 h where 120 s writes 23.05 h —
re-absorbing nearly eight hours of the idle the floor exists to keep
out. Legibility is all a larger floor buys; accuracy is the point.

**The minimum interval is a named no-op, deliberately.** Zero means
exactly today's behaviour: what keeps sub-minute intervals out of the
drawer is two *rendering* conditions, which are consequences of the clock
format rather than a policy anyone chose. Naming it makes the policy
settable without changing it — a knob that cannot be turned is not a
knob — and the value it should take is a reporting decision, not an
implementation one.

**Do not infer any of these from a drawer.** They are the reason two
CLOCK lines on the same heading can describe adjacent work and still be
separate lines, and the reason a turn you remember taking thirty seconds
may appear nowhere at all.

### Stale-interval recovery: mechanism and history

The rule — that the report asks and a session must not invent a stop
time, and the one call that closes an interval once the user answers —
is in `org-time-tracking.md`. What follows is why it works that way.

A crash or system shutdown can kill Emacs (or the whole machine) before
the `Stop` hook gets a chance to pause a running interval, leaving a
CLOCK line open indefinitely. Because
`org-clock-persist` is set to `history` (not `t`/`clock`) in the Doom
config, a restart does *not* auto-resume that in-memory clock state — so
detection works by scanning the actual *text* of tracked org files for an
unclosed `CLOCK:` line or an unclosed `Resumed` entry, never by checking
`org-clocking-p`.

Checked via a third hook, `SessionStart` → `bin/hooks/session-start-recovery-check`
→ `claude-code-ide-org-write-session-start-report`. Self-limiting to
"first thing each day": it only reports intervals whose open timestamp
predates today, so once closed (or if nothing was ever left open) it
stays quiet regardless of how many sessions start that day. The report is
injected as `additionalContext`, which Claude is expected to relay to the
user as a question — the hook itself has no way to literally prompt.


**The report asks; it never proposes.** It states the timestamp the
interval opened at — a fact it has — and asks what time work actually
stopped, explicitly instructing the relaying session not to invent one.
A guess would be worse than none — a plausible suggestion is harder to
reject than no suggestion at all (measured and retired 2026-08-14,
`:ID:` 7771fc63).

**Configuration** (`defcustom`s; neither is set in
`~/.config/doom/config.el` today, so both run at their defaults):
- `claude-code-ide-org-session-recovery-enabled` (default `t`) — set nil
  to disable the whole check.
- `claude-code-ide-org-query-files` (default nil, falls back to
  `org-agenda-files`) — which files to scan. Shared with the still-MAYBE
  `org_query` tool in TODO.org for when it's eventually built.

**Won't do**: the `pmset` sleep/wake log as a stale-clock guess signal
— declined 2026-08-14 with the guess heuristic itself; the full story
lives on the heading that declined it (`:ID:` 7771fc63). Distinct from
`:ID:` 1a5a5254, which proposes power assertions as a review-time
*attribution* signal and is unaffected.
