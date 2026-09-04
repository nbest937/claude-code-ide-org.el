# claude-code-ide-org

A Doom Emacs module that exposes org-mode operations to [Claude
Code](https://claude.com/claude-code) as MCP tools, plus org-mode skills
for Claude Code sessions — so `.org` files can be read, queried, and
managed in natural language from within Emacs, without memorising org's
chord sequences.

It has a second, co-equal goal: **trustworthy tracking of where
attention actually went** on tracked tasks. Much of the machinery here —
the event queue, the session hooks, the review pass — exists for that
goal rather than the first one.

## The one design decision to understand first

**State and clock changes are queued, not applied.** When a Claude
session calls `org_set_todo` or `org_clock_in`, no org file changes.
The event lands in a per-session queue file; a human later runs
`M-x claude-code-ide-org-review`, inspects the accumulated events, and
applies the approved ones through org's own native commands.

This is deliberate. Org's clock and logging model assumes one human at
one buffer; concurrent agent sessions writing live state produced a
sustained run of desync and ownership bugs before the queue existed. The
trade: the org record is only as fresh as the last review pass, but once
confirmed it is actually correct.

Read-only queries, capture, refile, archive, and body amendments remain
immediate.

## What's here

| path | contents |
|---|---|
| `modules/tools/claude-code-ide-org/` | the elisp module (`config.el`) and its ERT suite |
| `bin/` | test suites (`test`, `lint-org`, `check-conventions`, …) |
| `bin/hooks/` | Claude Code hook scripts (session pause/resume guideposts, permission-block bracketing, queue append) |
| `.claude/skills/` | the `org` and `org-dev` skills, auto-discovered by Claude Code |
| `.claude/rules/` | org-file conventions, path-scoped to `**/*.org` |
| `plans/` | archive of Plan Mode plan files that org headings link (the working copies live in `~/.claude/plans/`) |
| `CLAUDE.md` | agent instructions — the detailed, authoritative documentation of conventions and architecture |

## Install

This is a personal testbed, not yet a packaged plugin (packaging is
tracked work). The wiring, as it runs today:

1. Symlink the module into your Doom config and enable it:

   ```sh
   ln -s "$PWD/modules/tools/claude-code-ide-org" \
         ~/.config/doom/modules/tools/claude-code-ide-org
   # then in ~/.config/doom/init.el, under :tools
   #   claude-code-ide-org
   ```

2. A running Emacs server is a **hard prerequisite** — every MCP tool
   goes through `emacsclient`. The Doom config starts one automatically.
   The module needs **org 9.7+** and says so loudly at load — the org
   bundled with Emacs 29 (9.6.x) is not enough; Doom's straight-managed
   org is.

3. `.mcp.json` registers the `emacs-tools` MCP server for the `claude`
   CLI. (`.warp/.mcp.json` is a deliberate duplicate for Warp — see
   CLAUDE.md before "cleaning it up".)

4. Claude Code hooks are wired in `.claude/settings.json` and write to
   `~/.claude/org-updates/`. They need no setup beyond cloning.

5. Git hooks need one manual step per clone (the setting is not version
   controlled):

   ```sh
   git config core.hooksPath .githooks
   ```

## Tests

```sh
bin/test               # ERT suite for the elisp, against scratch org files
bin/lint-org           # org-file convention lint (also runs pre-commit)
bin/check-conventions  # cited :ID:s resolve, keyword sets agree
```

The suites run against temp directories — no Doom, no real org-id or
clock state.

## Known limitations, accepted deliberately

These read as bugs and are not; each is a recorded trade-off.

- **The org record lags.** TODO keywords and clocks reflect the last
  human review pass, not live state. A `DOING` heading normally has *no*
  running clock, and CLOCK lines arrive in bursts when someone applies.
- **A resumed session can briefly credit the wrong task.** If your next
  prompt is about a different task than the one that paused, the resume
  guidepost still points at the last-paused one. It self-corrects at the
  next real `org_clock_in`; the cost is a short stray interval.
- **Tracked-file discovery is restart-bound.** `org-agenda-files` is
  computed once at config load, so a newly added org file needs an Emacs
  restart to be seen by the tools.
- **Portability to other repos is tracked, unfinished work** — the
  conventions and machinery documented in CLAUDE.md do not yet ship
  anywhere.

CLAUDE.md documents all of this in depth — it is written for agent
sessions, but it is also the honest reference for humans.
