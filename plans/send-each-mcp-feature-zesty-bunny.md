# Parallelize the 10 pending MCP-tool tasks across worktrees

## Context

`TODO.org`'s `Roadmap > New MCP tools` section (plus its MCP-adjacent
enforcement/observability siblings) carries ten pending tasks, each with a
fully worked-out `Plan [/]` checklist already written down — elisp function
signatures, gotchas already found empirically (e.g. `org_capture`'s `%i` vs
`%?`), even risk notes. Nothing here needs re-designing; the goal of this
plan is **orchestration**: get all ten implemented in parallel, isolated
worktrees, then integrate them back into `main` one at a time without losing
work or breaking `bin/test`.

The two real design decisions (confirmed with you already):
- **Scope** includes both the four core "New MCP tools" and the six
  MCP-adjacent hooks (enforcement + observability) — ten branches total.
- **Clock/state tracking is coordinator-only, one task at a time.** Org's
  clock is single-threaded (one active heading), so subagents — which have
  no live Emacs connection from an isolated worktree anyway — never call
  `org_set_todo`/clock tools themselves. I drive `DOING`→integrate→`DONE`
  serially as I pick up each finished branch for merge, not at dispatch time.

## Scope: the 10 tasks

| # | Task | :ID: | Branch | ERT-testable in-worktree? |
|---|------|------|--------|---------------------------|
| 1 | `org_capture` | `405e05b6-dc0c-42c1-99ce-7a94d266ca6d` | `feature/org-capture` | yes |
| 2 | `org_clock_report` | `26215a14-6ec9-43a7-981b-5c8e888e65fd` | `feature/org-clock-report` | yes |
| 3 | `org_refile` | `f8f5cc3a-01ba-4523-b6e0-3b93ae656504` | `feature/org-refile` | yes |
| 4 | `org_sort_children` / `org_move_sibling` | `aa6ee083-0bb8-4345-b6ef-f10402cc2c78` | `feature/org-sort-move` | yes |
| 5 | `org-trigger-hook`/`org-blocker-hook` + their config-test.el extension | `e47ac400-dd17-4e6a-91aa-bcd837151610` (test sub-task `799b14be-6849-4e22-8a76-4e214d8a25fe`, folded in) | `feature/org-transition-hooks` | yes |
| 6 | Tool-call audit log | *(none yet)* | `feature/org-audit-log` | yes |
| 7 | Surface current clock state | *(none yet)* | `feature/org-clock-state` | yes |
| 8 | PreToolUse transition guard | *(none yet)* | `feature/pretooluse-transition-guard` | **no** — needs live Emacs + real MCP tool name |
| 9 | Clock-change notifications | *(none yet)* | `feature/clock-notify` | **no** — same |
| 10 | SessionStart context hook | *(none yet)* | `feature/session-context-hook` | **no** — same |

Excluded from this batch (flagged during research, not part of your
selected scope): "Idle-based auto clock-out" (pure `~/.config/doom/config.el`
change, no repo code), "Coarsen :SESSIONS: to session-level", and "Bigger
swings" (remote MCP access, packaging the Warp wiring).

## Step 0 — Prep (coordinator, before dispatching)

1. Add `:ID:` properties (via `emacsclient -e '(org-id-get-create)'`, same
   registry-backed method already used for #3/#4) to the five headings in
   rows 6–10 above, so they're trackable by `org_set_todo` later. (#1–5
   already have IDs.)
2. Confirm no other session currently holds the org clock (`emacsclient -e
   '(org-clocking-p)'`) before starting the coordinator clock cycle.

## Dispatch (parallel, `isolation: worktree`)

Launch all 10 as background `Agent` calls in one batch, `subagent_type:
general-purpose` (needs Bash + Elisp editing + full file access). Each
prompt includes:

- The **verbatim** `Plan [/]` checklist and body text for that task from
  `TODO.org` (already transcribed in the Explore agent's report this
  session — reuse it directly, don't re-derive).
- Pointers to reuse: the shared dispatcher `claude-code-ide-org--at-id`
  (config.el:45), the existing tool-registration block at the bottom of
  `config.el`, and `config-test.el`'s fixture macro
  `claude-code-ide-org-test--with-heading` + disk-verification helper
  `claude-code-ide-org-test--disk-contents` (the pattern that exists
  specifically because two earlier tools silently failed to save).
- **Branch naming**: first thing in the worktree, `git checkout -b
  feature/<name>` (the table above) — satisfies CLAUDE.md's feature-branch
  rule regardless of what the isolation mechanism auto-generates.
- **Composability instruction** for tasks 6/7 (and 5, if it adds an
  `org-after-todo-state-change-hook` entry): register via `add-hook`, never
  `setq`, on the shared hook variables (`org-clock-in-hook`,
  `org-clock-out-hook`, `org-after-todo-state-change-hook`) — multiple tasks
  add to the same hooks, and `add-hook` composes regardless of merge order.
- **Verification split**, stated explicitly per task:
  - Tasks 1–7: write ERT tests reusing the existing fixture/disk-check
    pattern, run `bin/test`, and do not report done until it's green.
  - Tasks 8–10: cannot be verified from a worktree (no live Emacs, no real
    MCP server, can't confirm the literal `mcp__emacs-tools__*` tool name).
    Write the shell script(s) under `bin/hooks/`, do **not** touch
    `.claude/settings.json` (coordinator owns that file — three tasks
    would otherwise each try to create/edit the same untracked file), and
    end the report with an explicit "needs coordinator verification: exact
    hook entry + tool name + live cross-check" note rather than claiming
    success.
- Commit (not push, not merge) when done, with a normal commit message —
  integration is the coordinator's job.

## Integration (coordinator, strictly sequential — this is where the real time goes)

For each task, in this order:

**Wave A** (core tools, TODO.org priority order): `org_capture` →
`org_clock_report` → `org_refile` → `org_sort_children`/`org_move_sibling`

**Wave B** (adjacent, ERT-verifiable): `org-transition-hooks` →
`org-audit-log` → `org-clock-state`

**Wave C** (adjacent, needs live verification — batched last so
`.claude/settings.json` is written once): `pretooluse-transition-guard` →
`clock-notify` → `session-context-hook`

Per task, once its subagent reports done:
1. `org_set_todo <id> DOING` (opens the clock) — the *only* task clocked at
   any given moment.
2. Rebase its branch onto current `main`; resolve conflicts (expect them in
   `config.el`'s bottom registration block and `config-test.el`'s appended
   test groups — every branch touches both).
3. Run `bin/test` on the merged result.
4. For Wave C tasks only: write/extend `.claude/settings.json` with the
   hook entry the subagent's report specified, verify the real
   `mcp__emacs-tools__*` tool name against `.mcp.json`/live registration,
   and manually trigger the hook once to confirm it fires correctly against
   live Emacs.
5. Merge to `main`, `org_clock_out`, `org_set_todo <id> DONE`, `org_archive
   <id>` (per CLAUDE.md's archiving convention for `:code:`-tagged DONE
   tasks).
6. Move to the next task.

## Verification (end-to-end)

- After every merge: `bin/test` must pass on `main` before continuing to
  the next task — never stack an unverified merge under another.
- After Wave C: manually exercise each hook once against the real Emacs
  instance (trigger a blocked transition, a clock in/out, a session start)
  and confirm the expected side effect actually happens, not just that the
  script exits 0.
- Final state check: `git log --oneline main` shows 10 clean merges (or 10
  squashed commits, coordinator's call at merge time), `TODO.org` shows all
  ten headings `DONE` and archived to `DONE.org::* Done`, and no stray
  `:LOGBOOK:`/`:SESSIONS:` entries left open.
