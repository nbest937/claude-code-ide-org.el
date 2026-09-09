# Architecture: the event queue

> Ships with the **claude-code-ide-org** plugin. `claude-org-setup` promotes
> this file into a consuming repo's `.claude/rules/` so it is always
> loaded there; until that runs it is on-demand reading, like any skill
> reference. The consuming project's own rules take priority over it.

**State and clock changes are queued, not applied.** This is the single
most important thing to know before calling any of the org tools, because the
tool names suggest otherwise. `org_set_todo` changes no TODO keyword.
`org_clock_in` opens no clock. `org_clock_out` closes none. Each appends
an event to a per-session file and returns; a human later reviews the
accumulated events and applies the approved ones.

A read that still shows the old keyword after you called `org_set_todo`
is therefore **expected, not a failure**. Use `org_pending_updates` to
see what is queued but not yet applied — that is how you tell "waiting
for a human" apart from "the call didn't work."

**The problem it responds to**: driving live org state (TODO keyword,
clock, `:LOGBOOK:` logging) directly and synchronously from Claude Code
sessions — including concurrent and background ones — produced a
sustained run of desync, ownership, and logging bugs. The pattern traced
to one mismatch: org's clock/logging model assumes one human at one
buffer; this project's actual workload is the opposite.

**The shape**: sessions do not touch the live buffer for state/clock
changes. They append events to a plain, per-session file — durable,
cheap, no Emacs required to write. A human, at a moment of their own
choosing, reviews the accumulated events (`M-x
claude-code-ide-org-review`) and applies the approved ones through org's
own native `org-todo`/`org-clock-in`/`org-clock-out`, run inside a
genuinely interactive command — so org's native state-change logging
works instead of needing to be suppressed.

**Load-bearing constraint**: apply is *always* human-triggered, never
invoked by Claude programmatically. Not a style preference — org's native
logging only completes correctly inside a real interactive session; a
non-interactive `emacsclient -e` call hits the exact hang this design
exists to route around. Practical consequence: clock/TODO-state accuracy
is only ever as fresh as the last time a human ran the review pass, not
live. That is an accepted, deliberate trade of "Claude does it all in
real time" for "the record, once confirmed, is actually correct" — not an
oversight to fix later.

**What is still immediate**: read-only queries, tagging, capture, refile,
archive, and sort remain as immediate and Emacs-chord-free as the opening
goal promises. Queuing is scoped narrowly to state transitions and clock
start/stop — the two categories that caused every incident.
