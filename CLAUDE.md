# claude-code-ide-org

Doom Emacs module exposing org-mode operations to Claude Code as MCP tools,
plus org-mode skills for Claude Code sessions.

The goal is natural-language manipulation of `.org` files from within Emacs,
via `claude-code-ide`, without needing to internalise Emacs chord sequences.

A second, co-equal goal — never spelled out until now, though a large share
of this project's actual work has gone toward it — is trustworthy tracking
of where attention/time actually went on tracked tasks. What "trustworthy"
requires in practice (interval granularity, how much manual confirmation is
acceptable, what reports actually need to come out the other end) is
deliberately left open here, not pinned to whatever CLOCK-drawer mechanics
happen to exist at a given point: it should be driven by concrete reporting
needs, most of which haven't been fully articulated yet.

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
CLAUDE.md makes answering from it more often correct, which makes the
habit of answering from it instead of from the artifact harder to notice:
the same behaviour with better odds. The evidence is that most wrong
claims never came from this file. On 2026-08-11, of roughly a dozen wrong
claims, only four traced here; the rest came from unchecked inference,
from a session's own earlier summaries, and three times from reading a
silently-failing command's empty output as a result.

`bin/check-conventions` mechanises the part of this that can be
mechanised — that cited `:ID:`s resolve and the keyword set agrees
everywhere. It cannot check a claim that is merely out of date, which is
most of them.

---

## Architecture: the event queue

**Moved into the plugin, 2026-09-09** (`:ID:` b0e478f7): the full text
ships as `skills/org/references/org-event-queue.md` and is promoted by
`bin/claude-org-setup` into `.claude/rules/org-event-queue.md`, which is
the copy every session here loads. The one line that must survive even a
broken promotion: **state and clock changes are queued, not applied** —
`org_set_todo`, `org_clock_in` and `org_clock_out` append events for
human review and change nothing when called; `org_pending_updates` shows
what waits.

---

## Reading the tracker

**Start with `org_outline`, not a file read.** It is roughly 40x smaller
than the file and answers most orientation questions on its own. TODO.org is
~118,000 tokens and the median active heading body is 50 lines, so reading
around to find something costs more than the answer is usually worth. Drop
to `org_query` for a predicate ("what's blocked", "everything `:research:`
and not DONE") and to a targeted read only once you have an `:ID:` and a
reason.

**Pass `active_only`, and ignore DONE by reflex.** What a finished heading
records is *history*; the current state of the implementation is in the
code, the tests and the config, which are authoritative in a way a body
written weeks ago is not. TODO.org exists to inform planning, orchestration
and coordination of *future* work — read it for what to do next, not for
what the system currently is.

(`--outline-map` keeps a filtered-out heading that is an *ancestor* of a
surviving one, so `active_only` never re-parents a live child; `:ID:`
98908aff has the history.)

**DONE.org is reference, never orientation.** Do not survey it to start a
session; it will not tell you what to work on. Open it when something live
names an ID in it — a `:BLOCKER:`, a body cross-reference, a docstring, or
this file.

The exception to "the code is authoritative" is *why* a decision went the
way it did, which lives only in a body — which is why the load-bearing ones
(the `.warp/.mcp.json` investigation, the retired guess heuristic) are
quoted directly in this file rather than left to a lookup.

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
  by their header; edit the reference and re-run setup, never the copy.

- **`plans/` is the archive, not the working copy.** Claude Code owns
  `~/.claude/plans` and Plan Mode writes there, so that is the file org
  headings link and a revision edits. A plan is copied here *iff* some
  heading in TODO.org or DONE.org links it, which is what makes an
  unlinked plan history-less. `bin/sync-plans --check` reports drift;
  `.githooks/pre-push` refuses a push while the archive is stale.
- **`.claude/hooks/session-context.sh` is the one hook not under
  `bin/hooks/`**, for no recorded reason. It produces the "what was I last
  doing" context injected at `SessionStart`. Whether the two directories
  should be consolidated is open.
- **`.claude/commands/`** holds prompt files
  Claude Code exposes as slash commands — `next-session.md` is `/next-session`,
  the sequenced slice of work queued for the next session. It is a *plan*, not
  a convention: expect it to be rewritten or deleted once consumed, unlike
  everything else under `.claude/`, which is standing configuration.
- **`bin/check-org-dev-skill`** checks the org-dev skill's own claims still
  hold — run it after editing that skill.
- **`.warp/.mcp.json`** — see below; do not delete it.

**`.warp/.mcp.json` is deliberate, not duplication — do not "clean it
up."** It is currently byte-for-byte identical to the root `.mcp.json`,
and Warp can read the root file directly, so a cleanup pass will reliably
propose deleting it. Both are kept on purpose: the separate file is
evidence this project has actually been verified working under Warp's own
agent, and it is a seam for the two clients to diverge later if the
`claude` CLI and Warp ever need different settings against the same tools
server. The investigation behind it is archived in DONE.org
(`:ID: 6a6d5b4e-0327-4578-a44a-356576870ceb`) — worth reading before
touching either file, because the proxy the files were originally meant to
support turned out to be unnecessary: the real bug was this project's HTTP
server answering `200` where the MCP spec requires `202 Accepted`.

**One-time setup, required for `.githooks/` to do anything:**

```sh
git config core.hooksPath .githooks
```

That setting lives in `.git/config`, which is not version controlled, so a
fresh clone silently has no hooks until it is run. The hooks themselves are
tracked precisely so they are reviewable and shared — putting them in
`.git/hooks/` instead would make them invisible local state, which is the
same problem the `plans/` archive exists to fix. Note that `core.hooksPath`
redirects *every* hook: check `.git/hooks/` holds nothing but `.sample`
files before setting it (it did here, 2026-08-11).

Run the tests with `bin/test`. They exercise the four wrapper functions
against scratch org files in a temp directory — no Doom, no real Emacs
config, no touching real org-id/clock state.

The module is symlinked into `~/.config/doom/modules/tools/claude-code-ide-org/`
and enabled in `~/.config/doom/init.el` under `:tools claude-code-ide-org`.

The org skill's canonical home is `skills/org/` — the plugin's unit of
travel — with `.claude/skills/org` a symlink into it, so this repo's
sessions discover it exactly as before. `org-dev` stays a real directory
under `.claude/skills/`, testbed-only and unshipped.

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
- **Python was considered and declined** for JSON handling: Emacs is
  already the harder, always-present dependency — every such script
  ends in `emacsclient` anyway — so elisp avoids adding a runtime
  rather than trading one.

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

**Rule**: work planned via Claude Code's own Plan Mode gets a single
permanent link — `[[file:~/.claude/plans/<slug>.md][Plan]]` — written
into the heading's **`:PLAN:` drawer**, added as soon as the first round
of planning finishes (right after `ExitPlanMode` is called and the plan
file is finalized), not gated on the heading later transitioning to
`DOING`. This matters because approval and the `DOING` transition don't
always happen in the same beat as planning — e.g. the user may
deliberately stop right after a plan is written, before deciding whether
to implement it — and the link should exist the moment a real plan file
does, independent of what happens next. A plan link *is* planning
content, so it belongs with the rest of the prospective prose (`:ID:`
b75d553a): planning before composition simply includes the link in the
normal two-call composition below. When the drawer already exists before
a Plan Mode session, `org_amend` with `drawer=PLAN` appends the link
inside it directly (`:ID:` 501a8422). Revisions
(re-entering Plan Mode on the same
task) edit that same plan file in place — Claude Code reuses the
existing plan file path for a continuation of the same task — so the
link is written once and never needs updating to point at a new file. No
transcription of the plan into org, ever; the link is the record.

Nothing moves at `DONE`: the link has lived in `:PLAN:` since
composition (2026-09-02, `:ID:` b75d553a), which is what keeps a
forward-looking pointer out of the retrospective readout a finished body
becomes. (A pre-convention heading's link still travels into the drawer
whenever its body is retroactively wrapped.) A task with no separate Plan Mode
session simply carries no link — that's expected, not a gap to fill in.

The link is also what makes the plan durable, which is why it is not
gated on anything: `bin/sync-plans` copies only those plans some heading
links, so an *unlinked* plan is never archived and has no history at all.
Verified 2026-08-14 — the sync refused a freshly written plan until its
heading linked it.

**Rule**: where a plan is linked, the heading body is a **journal, not a
design doc** — the plan is the design doc. The body carries what
happened: what shipped, how it was verified, what was measured, what was
falsified, and why a decision went the way it did. It does not restate
design the linked plan already holds.

**Composition, close, revision: in the conventions.** The two-call
composition (`org_amend` with `drawer=PLAN`, then the short body), the
two-call close (the authored resolution, then `drawer=DEBRIEF`,
`:ID:` d5eb32a3), the read-direction rule — skip `:PLAN:` on a finished
heading, read it on a live one, read `:DEBRIEF:` always — and the
policy for revising pre-convention bodies all ship in the org
conventions' `:PLAN:`/`:DEBRIEF:` sections
(`.claude/rules/org-conventions.md`), moved there 2026-09-09 with the
evidence that settled them. A heading closed by the two-call close owes
archiving nothing further, and delegated-subagent work follows the same
shape: ask for a one-paragraph outcome summary in the final report, not
per-checkbox status.

What stays here is this repo's own. *The backlog pass*: its rule was
"wrap unedited" and is retired (`:ID:` f099379b) — `cbe282ec` chose it
to keep 30 purely prospective bodies cheap, but measured 2026-09-02, 88
of 93 unwrapped headings carry a debrief a blind wrap would bury, and
no lexical marker finds the seam. The pass is `:ID:` 35d25265, which
reads each body; there is no cheaper honest option. *And the standing
example*: `:ID:` b5f94b88 has both a plan and a substantial body — the
"epic wearing a child's clothes" reasoning and the plan-file-overwrite
incident are journal, not design, and belong in neither drawer.

---

## Org-mode conventions

Moved to the plugin's **`skills/org/references/org-conventions.md`**,
promoted by `bin/claude-org-setup` into
`.claude/rules/org-conventions.md` — path-scoped to `**/*.org`, so it
loads only when an org file is actually in play. This repo's own
additions — the ten `:CATEGORY:` values and the history of the level-1
tier — stay hand-maintained in `.claude/rules/org-conventions-local.md`.

The test that used to govern what stayed in this file — a rule that must
hold when no `.org` file is open cannot live in a path-scoped rule — is
now met by the promoted machinery rules instead, which carry no path
scope and load in every session: the queue architecture, the state
transitions, the tool tables and session tracking all live there, and
their sections below are pointer stubs.

---

## State transition rules

**Moved into the plugin, 2026-09-09**: the transition table, every clock
rule, and the `NEXT`/nomination invariants ship as
`skills/org/references/org-state-transitions.md` and load here as
`.claude/rules/org-state-transitions.md`. They are unchanged by the
move — follow that file exactly as this section was followed.

---

## MCP tools (`modules/tools/claude-code-ide-org/config.el`)

**Moved into the plugin, 2026-09-09**: the tool tables — queued,
immediate, conditional, read-only — ship as
`skills/org/references/org-mcp-tools.md` and load here as
`.claude/rules/org-mcp-tools.md`. The headline that must not be lost:
the three queued tools change nothing when called, and there is no MCP
tool that applies the queue — apply is `M-x claude-code-ide-org-review`,
human-run.

---

## Session tracking (`.claude/settings.json`, `bin/hooks/`)

**Moved into the plugin, 2026-09-09**: the hooks table, the three
numbers that shape a recorded interval, permission blocks and
stale-interval recovery ship as
`skills/org/references/org-session-tracking.md` and load here as
`.claude/rules/org-session-tracking.md`. The wiring exists twice on
purpose — this repo through `.claude/settings.json`, consumers through
the plugin's `hooks/hooks.json` — and a repo must enable only one of
the two, or every guidepost is appended twice.

---

## Emacs integration

**A reachable Emacs server is a hard prerequisite** — every MCP tool
goes through `emacsclient`; if tools fail, check that first. The
install and wiring guidance — Doom module, the org 9.7 floor, the
pinned port, per-repo setup — ships as
`skills/org/references/org-emacs-setup.md` (deliberately not promoted
into rules: it is read at install time, not needed every session).

---

## Design notes

- **Why MCP tools over text editing for clock/state/archive?**
  Native org functions handle LOGBOOK formatting, timestamp arithmetic, and
  internal state (the running clock timer) correctly and atomically. Text
  editing risks malformed CLOCK entries or stale timer state.

- **Why text editing for everything else?**
  Tag changes, new headings, and time report summaries don't require
  org-mode's internal state — they're straightforward text operations the
  org skill handles well. Keeping the MCP tool surface small reduces
  per-request token overhead. Cross-file reads used to fall in this bucket
  too, but were slow enough in practice (whole-file reads to answer
  one-line questions) to justify `org_query` as a dedicated tool instead.

- **Why IDs rather than heading titles?**
  Titles are not unique and can change. `:ID:` properties are stable
  references that survive renames and refiling.

- **Why short snake_case tool names rather than upstream's convention?**
  Upstream `claude-code-ide` registers each MCP tool's name as the verbatim
  elisp function name (e.g. `claude-code-ide-mcp-xref-find-references`).
  This module deliberately diverges: elisp identifiers follow elisp
  convention (full `claude-code-ide-org-` package prefix), while
  model-facing tool names follow MCP convention — short snake_case with an
  `org_` namespace prefix (e.g. `org_clock_in`). snake_case is the
  prevailing style for MCP tools, the `org_` prefix names the domain the
  model actually cares about, and shorter names reduce per-request schema
  overhead.

(The `org-clock-persist-load` trap — why calling it inside `(after! org
...)` breaks org-mode outright, and why the breakage only shows on a fresh
boot — lives in the **org-dev skill, §2**, which triggers when the Doom
config is being changed. It used to be duplicated here.)
