# claude-code-ide-org

Doom Emacs module exposing org-mode operations to Claude Code as MCP tools,
plus org-mode skills for Claude Code sessions.

The goal is natural-language manipulation of `.org` files from within Emacs,
via `claude-code-ide`, without needing to internalise Emacs chord sequences.

Trustworthy tracking of where attention/time actually went on tracked
tasks is a second, **optional** capability: developed here, shipped
switched off, and turned on per-user with the plugin's `time_tracking`
option. What "trustworthy" requires in practice (interval granularity,
how much manual confirmation is acceptable, what reports need to come out
the other end) is deliberately left open, driven by concrete reporting
needs rather than by whatever CLOCK-drawer mechanics exist at a given
point.

**It was a co-equal goal until 2026-09-18** (`:ID:` 8bbae3aa); committing
to a switch *is* the ordering. That reorders the goals without rewriting
the history: the event queue, the session hooks and the review pass exist
for the second goal, and the queue was built because concurrent sessions
writing live clock state produced a sustained run of desync bugs. This is
the only record of why the queue exists at all.

---

## This file is a starting point; the artifact is the authority

**Read this before the claims below, because it qualifies all of them.**
This file is loaded into every session by default while the things it
describes are not. So a stale claim here *outranks the truth* until
someone deliberately checks, and the sections describing mechanisms that
have been cut over are the highest-risk kind — the prose outlives the
code that justified it.

Which artifact wins depends on the question:

| question | authority |
|---|---|
| what the system does | the code and its tests |
| how Emacs is configured | the live `~/.config/doom/config.el` |
| what is planned, blocked, or next | `TODO.org`, via `org_outline`/`org_query` |
| what a number means | the `defcustom`'s own docstring |

**This is about *state*, not about *rationale*.** Why a decision went the
way it did lives only in a heading body or in this file, and cannot be
recovered from the code — which is why the load-bearing reasons are
quoted here rather than left to a lookup. Distrust the file's account of
what *is*; do not distrust its account of *why*.

**And accuracy does not retire the risk — it disguises it.** An accurate
CLAUDE.md makes answering from it instead of from the artifact harder to
notice. Most wrong claims never came from this file: of roughly a dozen
on 2026-08-11, four traced here; the rest were unchecked inference, a
session's own earlier summaries, and a silently-failing command's empty
output read as a result.

`bin/check-conventions` mechanises the part of this that can be
mechanised — that cited `:ID:`s resolve and the keyword set agrees
everywhere. It cannot check a claim that is merely out of date, which is
most of them.

---

## Architecture: the event queue

Ships as `skills/org/references/org-event-queue.md` and loads here as
`.claude/rules/org-event-queue.md`. The one line that must survive a
broken promotion: **state and clock changes are queued, not applied** —
`org_set_todo`, `org_clock_in` and `org_clock_out` change nothing when
called; `org_pending_updates` shows what waits.

---

## Reading the tracker

**Start with `org_outline`, not a file read.** Since 2026-09-09 it
carries each heading's own body summary beneath its line (`:ID:`
2a399034 — the read split), so it answers most orientation questions
outright; drawers stay behind an explicit `org_body` call (`drawer=PLAN`
/ `DEBRIEF` / `LOGBOOK` for one drawer, no argument for the heading
whole). Pass `bodies=false` on a full-file call: pre-convention bodies are long
enough to swamp an unscoped index (`:ID:` e128e4fa).
Drop to `org_query` for a predicate ("what's blocked",
"everything `:research:` and not DONE") and to a targeted read only once
you have an `:ID:` and a reason.

**Pass `active_only`, and ignore DONE by reflex.** What a finished heading
records is *history*; the current state of the implementation is in the
code, the tests and the config, which are authoritative in a way a body
written weeks ago is not. TODO.org exists to inform planning, orchestration
and coordination of *future* work — read it for what to do next, not for
what the system currently is.

**DONE.org is reference, never orientation.** Do not survey it to start a
session; it will not tell you what to work on. Open it when something live
names an ID in it — a `:BLOCKER:`, a body cross-reference, a docstring, or
this file.

---

## Repository layout

`ls` answers most of this; only the non-obvious parts are written down.
The elisp lives in `modules/tools/claude-code-ide-org/` (`config.el` plus
its ERT suite). `bin/` holds the test suites and `bin/hooks/` every hook
wired in `.claude/settings.json` — what each hook appends is in the
session-tracking rules (`.claude/rules/org-session-tracking.md`), not
repeated here.

Five things you would not guess:

- **`.claude-plugin/`, `hooks/` and `skills/` are the plugin surface**
  (2026-09-09, `:ID:` b0e478f7): the manifest, the shipped hook wiring
  (mirroring `.claude/settings.json` — a repo enables one or the other,
  never both), and the org skill whose `references/` carry the machinery
  prose and conventions. `bin/claude-org-setup` promotes those references
  into a consuming repo's `.claude/rules/` — this repo runs it on itself,
  so the machinery files under `.claude/rules/` are **generated**, marked
  by their header; hooks refuse an edit to a copy, so edit the reference.

- **`plans/` is a frozen archive.** Plan Mode's files in
  `~/.claude/plans` used to be linked from headings and copied here; that
  pattern is retired (below), and Claude Code deletes the originals after
  its retention period, which is left to happen. The copies here are the
  record for the headings that still link one — which is why
  `bin/sync-plans --check` and `bin/lint-org` accept a plan that is gone
  from the source but archived, and refuse only one that is in neither.
- **`.claude/hooks/session-context.sh` is the one hook not under
  `bin/hooks/`**, for no recorded reason. It produces the "what was I last
  doing" context injected at `SessionStart`. Whether the two directories
  should be consolidated is open.
- **`.claude/commands/`** holds prompt files
  Claude Code exposes as slash commands — `next-session.md` is `/next-session`.
  Since 2026-09-21 it is **static**: it names no slice, finds the one in hand
  (the `DOING` slice with no open PR, else the `NEXT` one), and points at
  that slice's `:PLAN:` drawer. Only Step 0 and the standing rules live
  there, and they grow by addition.
- **`bin/check-org-dev-skill`** checks the org-dev skill's own claims still
  hold; pre-commit runs it whenever that skill is staged.
- **`.warp/.mcp.json`** — see below; do not delete it.

**`.warp/.mcp.json` is Warp's own project-scope MCP config — do not
"clean it up."** Warp's native MCP config is `~/.warp/.mcp.json` and the
project's `.warp/.mcp.json` (verified against its docs 2026-09-10); its
docs now also list Claude Code's `.mcp.json` as readable behind a toggle
(2026-09-24, untested here). MCP standardises the `mcpServers`
schema, not a location, so two files is the correct minimum — and a
symlink would forbid the one improvement the Claude side can take,
`${VAR:-default}` expansion in `url`. Warp's project servers are
approval-gated and session-scoped. The original investigation
(`:ID: 6a6d5b4e-0327-4578-a44a-356576870ceb`, DONE.org) chased a proxy
that was unnecessary; the real bug was this project's HTTP server
answering `200` where the MCP spec requires `202 Accepted`.

**One-time setup per clone:** `git config core.hooksPath .githooks` —
the setting is not version controlled, and a `SessionStart` check says so
when it is missing. It redirects *every* hook, so check `.git/hooks/`
holds nothing but `.sample` files first.

Run the tests with `bin/test`. They exercise the four wrapper functions
against scratch org files in a temp directory — no Doom, no real Emacs
config, no touching real org-id/clock state.

The module is symlinked into `~/.config/doom/modules/tools/claude-code-ide-org/`
and enabled in `~/.config/doom/init.el` under `:tools claude-code-ide-org`.

The org skill's canonical home is `skills/org/` — the plugin's unit of
travel — with `.claude/skills/org` a symlink into it, so this repo's
sessions discover it exactly as before. `skills/brainstorming/` ships the
same way, ported from superpowers (its `.upstream` names the source).
`org-dev` stays a real directory under `.claude/skills/`, testbed-only
and unshipped.

## Scripting conventions

**The boundary is Emacs, not audience** (decided 2026-09-04, `:ID:`
84b7d8b3, which retired fish from the repo):

- **A script that needs the running Emacs keeps its logic in elisp**,
  behind a thin POSIX `sh` stub whose only job is moving bytes — write
  stdin to a temp file, call `emacsclient`, cat the reply.
  `bin/statusline.sh` and `bin/check-org-dev-skill` (core in
  `bin/lib/check-org-dev-skill.el`) are the shape.
- **A script that must survive an Emacs outage stays plain shell.** The
  queue-append hook family exists precisely so a stopped Emacs costs
  nothing; routing it through `emacsclient` would reintroduce the
  dependency the queue escapes. `jq` is fine there — logic beyond field
  mapping is not.
- **Test harnesses and dev tooling are bash**, unremarkably.
- **No fish.** It reached the commit gate (`bin/check-conventions`)
  undeclared, which is what turned a style question into this decision.
- **Python was considered and declined** for JSON handling: every such
  script ends in `emacsclient` anyway, so elisp avoids adding a runtime.

---

## Engineering practices

**Rule**: any new feature should be tested to the extent possible and
reasonably feasible before being considered done. Automated where the
feature has a mechanical surface to test against (elisp via `bin/test`/
`config-test.el`, shell scripts via direct invocation); a documented
manual verification pass otherwise. "Reasonably feasible" is doing real
work here — some things (e.g. a skill's *trigger-matching* against its
own description, as opposed to the accuracy of its documented content)
are inherently fuzzy and not worth forcing into a deterministic test;
say so explicitly rather than skipping verification silently.

**Rule**: work that wants its own **integration point** lands on a
`feature/short-name` branch and merges. What earns one is not a taxonomy:
several commits that should arrive together, work you might abandon, or
something you want to review as a unit — and a slice always is one.

**Maintenance between such chunks may land on `main` directly.** Applying
the review queue, debriefing and closing work that already merged, filing
headings, correcting a stale cross-reference: none of these wants an
integration point.

*The maintenance clause was added 2026-09-04 after its absence
manufactured branches for single bookkeeping commits.* **Do not
re-tighten the rule to "work does not land directly on `main`"** — that
absolute wording contradicts the earned-integration-point test, the
contradiction resolves toward the absolute clause every time, and the
cost is that a merge is a decision, so manufacturing merges devalues
the ones that matter.

**The test, when unsure: would you want to review this as a unit, or
abandon it as a unit?** If neither, it is maintenance. Anything carrying
code or tests answers yes almost by definition, so this exemption is
narrower than it reads.

A one-helper fix committed straight onto the branch you are already on
still does not need its own — and note that assumed you *were* on one,
which is exactly what stops being true the moment a slice merges.

This is deliberately not "one branch per task": **do not demand a
per-heading branch decision, and do not exempt bug fixes** —
feature-vs-bugfix has never predicted the practice; wanting an
integration point is the whole test.

**Rule**: a branch merges to `main` through a **pull request**, never a
local merge (`:ID:` c7bf2121) — `gh pr create` when the branch is ready.
Git hooks refuse a local merge on `main` and a commit onto a branch that
has already merged. The trap that first broke the practice: a question offering "merge now or hold" decides *timing*
and silently decides *mechanism* too; ask which, or say which. (Whether
this covers a merge carrying only bookkeeping is an open question on
the heading — no bookkeeping-only branch has ever existed, since
maintenance lands on `main` as direct commits.)

**The grouping vocabulary — story, epic, slice, twin — moved into the
plugin with the conventions** (2026-09-09, the `:ID:` 9d009401
read-through): the definitions, the emergent-vs-declared axis, the
mitosis rules and their guards live in the org conventions
(`.claude/rules/org-conventions.md`, promoted from the shipped
reference) and in the org skill's "Dividing a heading that outgrew
itself". The one-screen map, so the words used below parse: an *epic*
is a `:CATEGORY:` label on the task; a *story* is emergent — a task
that acquired keyworded children, detected and never declared; a
*slice* is declared, and sequences members by reference; a *twin* is
the failure mode — two headings for the same work, where scheduling one
and forgetting the other is arbitrary, and it is caught by review,
never by the composer. A worked heading is never simply given children:
it *divides* (`org_divide`), and the original becomes the **child**.

**Rule**: a plan lives in its heading's **`:PLAN:` drawer**, not in a
plan file (the user, 2026-09-19; the plan-file link rule that stood here
was retired 2026-09-21). Plan Mode is still worth entering for its
read-only phase and its approval checkpoint, but what it produces is
written into the drawer with `org_amend` `drawer=PLAN`, and no
`[[file:~/.claude/plans/…]]` link is written. A slice's plan is its own
drawer, composed from its members', and where it and a member disagree
the member wins — the 2026-09-18 slice plan got four things wrong from the
slice's altitude and none of them came from a heading. Older headings keep
their links; see `plans/` above.

**Rule**: the heading body is a **record of what holds, not a design
doc** — the `:PLAN:` drawer is the design doc. The body carries a short
statement, then what shipped, was verified, was measured or was ruled
out, and why a decision went the way it did. It is **not a log**: a
dated, blow-by-blow body implies a completeness it never has, so readers
take what is absent as not having happened (the user, 2026-09-21). It
does not restate design the drawer already holds.

**Composition, close, revision: in the conventions.** The two-call
composition (`org_amend` with `drawer=PLAN`, then the short body), the
two-call close (the authored resolution, then `drawer=DEBRIEF`, `:ID:`
d5eb32a3) and the read-direction rule — skip `:PLAN:` on a finished
heading, read it on a live one, read `:DEBRIEF:` always — ship in the org
conventions' `:PLAN:`/`:DEBRIEF:` sections. Delegated-subagent work
follows the same shape: ask for a one-paragraph outcome summary, not
per-checkbox status.

This repo's own: the backlog of pre-convention bodies is *not* wrapped
blind (`:ID:` f099379b) — measured 2026-09-02, 88 of 93 carried a debrief a
blind wrap would bury, and no lexical marker finds the seam, so the pass
(`:ID:` 35d25265) reads each body.

---

## Org-mode conventions

They ship as the plugin's `skills/org/references/org-conventions.md`,
promoted into `.claude/rules/org-conventions.md` and path-scoped to
`**/*.org`. A path scope fires only on a Read of a matching file, never on
an org tool, so the first `org_*` call of a session injects a pointer to
them (`:ID:` 436e0991) — Read the section that governs the act. **The ten
`:CATEGORY:` values are in `.claude/rules/org-categories.md`, always
loaded** (`:ID:` b0d55552: behind the path scope, ten headings arrived
unfiled in two days); the history of the level-1 tier stays path-scoped in
`.claude/rules/org-conventions-local.md`.

---

## State transitions and MCP tools

They load here as `.claude/rules/org-state-transitions.md` and
`.claude/rules/org-mcp-tools.md`. The headline that must not be lost:
**no MCP tool applies the queue** — apply is
`M-x claude-code-ide-org-review`, human-run.

---

## Session tracking (`.claude/settings.json`, `bin/hooks/`)

**Two references** (`:ID:` 36952d1f). The hooks that ship unconditionally —
`footnote-check`, `apply-detect`, the guards, the miss counter, the
`queue-append` matchers for `org_set_todo`/`org_capture`/`org_amend`, the
daily ceremony prompt — are `skills/org/references/org-session-tracking.md`.
Everything time-shaped is `skills/org/references/org-time-tracking.md`,
**promoted only where setup was told the feature is on** (`:ID:` 1b69fe4e):
`--time-tracking`, the hooks' own variable, or a repo whose
`.claude/settings.json` wires that variable, which is how this repo gets it.

The wiring exists twice on purpose — this repo through
`.claude/settings.json`, consumers through the plugin's `hooks/hooks.json`
— and a repo must enable only one, or every queue line is appended twice.
The plugin's time rows gate themselves on the `time_tracking` boolean in
`.claude-plugin/plugin.json`'s `userConfig`, **default off**, exported to
hooks as `CLAUDE_PLUGIN_OPTION_TIME_TRACKING`; a consumer sets it with
Claude Code's `/config` command. This repo has no plugin option to read,
so its rows set that variable in the command string: **wiring the row is
the opt-in here** (`:ID:` 1b36c5bd). The gate is in the scripts because
`hooks.json` has no conditional form.

---

## Emacs integration

**A reachable Emacs server is a hard prerequisite** — every MCP tool
goes through it; if tools fail, check that first. Install and wiring
guidance ships as `skills/org/references/org-emacs-setup.md`, read at
install time, so not promoted.

---

## Design notes

- **MCP tools for clock, state and archive; text editing for the rest.**
  Native org functions handle LOGBOOK formatting, timestamp arithmetic and
  the running clock correctly and atomically; text editing risks malformed
  CLOCK entries. Tags, new headings and report summaries need none of
  that, and a small tool surface costs fewer tokens per request.
  `org_query` earned its place because whole-file reads to answer one-line
  questions were slow in practice.
- **IDs rather than titles**: titles are not unique and change; an `:ID:`
  survives renames and refiling.
- **Short snake_case tool names**, diverging from upstream
  `claude-code-ide`, which registers the verbatim elisp function name:
  elisp identifiers keep the full `claude-code-ide-org-` prefix, while
  model-facing names follow MCP convention with an `org_` namespace —
  the domain the model cares about, and a shorter schema.

(The `org-clock-persist-load` trap lives in the **org-dev skill, §2**.)
