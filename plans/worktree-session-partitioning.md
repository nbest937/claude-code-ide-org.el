# Plan — Worktree-based session partitioning, with a canonical-file caveat

`:ID: 2e09adb7-6e29-499c-a40e-98cd2b327cff`

## Context

The heading (re-read fresh from `TODO.org:940`) asks whether separate Claude
Code sessions can each work in their own `git worktree` of this repo. For
*code*, yes — one checkout + branch per session, no shared-file collisions,
and Emacs' own `uniquify` already disambiguates same-basename buffers at
different paths. `TODO.org`/`DONE.org` are the exception: they must stay a
single canonical copy, not one per worktree. Two failure modes were named:

1. `:ID:` lookups go through `org-id-locations`, a single global hash table
   — a duplicated `:ID:` across two on-disk copies means whichever copy was
   scanned last silently wins.
2. CLOCK/`:SESSIONS:` data written into a worktree-local copy is invisible
   to `org_clock_report`/`org_query`/the agenda until merge, and lost if
   the worktree is torn down first.

The heading's own framing says this "may just be a documentation note
rather than code — not yet decided." The 2026-08-05 update doesn't reopen
that conclusion, just flags that three fresh incidents the same day
(`582cc7f4`, `53b0047d`, `d150c02e` — all about clock/session-identity
desync, not worktrees) should inform this if/when it's planned. None of the
three actually involve a second on-disk file copy, so they don't change the
analysis below; they're a reminder that the *single-clock-single-file*
assumption is generally under more stress lately, not new evidence about
worktrees specifically.

**Revision note:** this plan went through one self-review round before
being finalized. The first draft proposed an Elisp guard in
`claude-code-ide-org--at-id` as the primary code deliverable; that guard
turned out to be broken as designed (see "Rejected/deferred approach"
below) and, more importantly, unnecessary once the actual fix — described
next — was found and verified.

## Research findings (traced through source, verified where possible)

**1. How the canonical file is anchored today.**
`~/org/claude-code-ide-org/TODO.org` is a symlink to
`/Users/neil.best/git/claude-code-ide-org/TODO.org` (the main checkout).
Doom's `org-agenda-files` is set to
`(directory-files-recursively org-directory "\\.org$")`
(`~/.config/doom/config.el:77`), which walks `~/org` and picks up that
symlink. `claude-code-ide-org--tracked-files` (`config.el:527-533`) is just
`claude-code-ide-org-query-files` or `(org-agenda-files)` — i.e. the same
resolved set. **`DONE.org` is *not* symlinked into `~/org`** (confirmed:
`~/org/claude-code-ide-org/` contains only the `TODO.org` symlink) — it's
reachable solely via `TODO.org`'s `#+ARCHIVE: DONE.org::* Done` directive,
resolved relative to whatever file is doing the archiving.

**2. `org_*` MCP tools are already cwd-independent — confirmed, not
assumed.** Every ID-based tool (`org_clock_in`, `org_set_todo`,
`org_archive`, `org_refile`, `org_move_sibling`, `org_sort_children`,
`org_log_background_plan`, plus internal helpers) routes through
`claude-code-ide-org--at-id` (`config.el:54-66`), which calls
`(org-id-find id 'marker)`. Reading `org-id-find` (`org-id.el:399-416`) and
`org-id-find-id-file` (`org-id.el:712-721`): the steady-state path is a
pure hash-table lookup into `org-id-locations`, keyed by ID string, with no
reference to the calling process's working directory anywhere.
`org-id-locations-file` itself defaults to a path under the Emacs user
directory, also cwd-independent. **A Claude Code session's shell `cwd`
being inside a worktree cannot, by itself, misdirect an `org_*` MCP tool
call** — the call is dispatched into the one shared Emacs server process,
and that process's `org-id-locations` doesn't care where the caller is
rooted.

**3. The real mechanism behind failure mode (1) — traced and confirmed.**
`org-id-find` falls back to `(org-id-update-id-locations nil t)`
(`org-id.el:411-412`) whenever the cached location for an ID misses or no
longer resolves. Reading `org-id-update-id-locations` (`org-id.el:527-606`):
the rescanned file list is agenda files + archives, then
`org-id-extra-files`, then `org-id-files`, then — critically —
**`(mapcar #'buffer-file-name (org-buffer-list 'files t))`, every Org file
currently open as a live buffer in that same Emacs process**
(`org-id.el:554`), appended *after* the agenda files. Files are scanned in
list order into an alist later converted to a hash table; for a shared ID,
a later-scanned file's entry silently overwrites an earlier one. If a
worktree-local copy of `TODO.org` is ever opened as a live Emacs buffer,
and any ID lookup subsequently misses (routine, on any new heading), the
worktree copy's — necessarily duplicate, since a full `git worktree`
checkout copies every existing `:ID:` — entries win. Org logs `"Duplicate
ID %S"` to `*Messages*` when this happens (`org-id.el:594-596`), but
nothing surfaces that to Claude over MCP.

**4. Failure mode (2) has two triggers, one of which no Elisp can
intercept.** Once (3) has corrupted `org-id-locations`, `org_*` tools could
subsequently write into the worktree copy. But the more mundane trigger
needs no cache-miss race: a Claude Code session whose `cwd` is a worktree
could use the org skill's own **text-editing** path (`Read`/`Edit`) against
a relative `TODO.org` path, which inside a worktree resolves to that
worktree's own fully-checked-out copy (both files are git-tracked,
confirmed via `git ls-files`), not the canonical one. This path is not
interceptable by any Elisp guard — it never touches Emacs or
`org-id-locations` at all.

**5. The actual fix: make the second on-disk copy never exist, via
per-worktree `git sparse-checkout` — verified empirically in a disposable
sandbox repo, not this project's repo.** Both failure modes above share one
root cause: `git worktree add` checks out a full second copy of every
tracked file, including `TODO.org`/`DONE.org`. Git's sparse-checkout
mechanism is **per-worktree** (its state lives at
`.git/worktrees/<name>/info/sparse-checkout`, confirmed by inspecting
`git rev-parse --git-path info/sparse-checkout` from inside a test
worktree vs. the main checkout) and supports excluding specific root-level
files in non-cone mode. Verified in a scratch repo (outside this project,
cleaned up afterward — no `git worktree add` was ever run against the real
claude-code-ide-org repo, honoring this task's read-only constraint):

```
git worktree add --no-checkout <path> -b <branch>
cd <path>
git sparse-checkout init --no-cone
git sparse-checkout set --no-cone '/*' '!/TODO.org' '!/DONE.org'
git checkout <branch>
```

Result, confirmed by directly listing the resulting directory: `TODO.org`
and `DONE.org` never materialize on disk in the new worktree at all (every
other tracked file does); the main checkout is completely unaffected
(sparse-checkout state doesn't propagate — confirmed by running
`git sparse-checkout list` from the main worktree afterward and getting
"this worktree is not sparse"). This makes both failure modes **structurally
impossible** rather than procedurally discouraged: there is no second copy
of either file to open in Emacs, scan into `org-id-locations`, or
accidentally `Edit`. This is the direct, concrete answer to the framing
question ("is that already guaranteed, or does something need to
enforce/verify it?") — something needs to *set it up per worktree*, and
that something is a small, fully scriptable, fully testable git recipe.

**Checked for shell-side fallout, not just the Emacs side:** confirmed via
`grep -rn 'TODO\.org\|DONE\.org' bin/ .claude/settings.json .mcp.json` that
no hook or script in this repo resolves `TODO.org`/`DONE.org` by a
repo-relative or `$CLAUDE_PROJECT_DIR`-relative filesystem path — every hit
is a comment citing "TODO.org" as documentation (e.g. "see TODO.org's risk
note"), never an actual file read/open. All real access goes through
`emacsclient` into Elisp, which resolves via `org-id`/`org-agenda-files`
(finding 2), not a path handed to it by the calling shell script. So a
sparse worktree missing these two files on disk introduces no regression
for anything in `bin/`, `.claude/settings.json`, or `.mcp.json`.

## Recommendation: a `bin/worktree-add` helper (code) + a CLAUDE.md note (docs)

### A. Code: `bin/worktree-add` (primary deliverable)

New script, `bin/worktree-add <path> [<branch>]`, wrapping the verified
recipe from finding 5:

- `git worktree add --no-checkout <path> [-b <branch>]` (auto-derive a
  branch name from `<path>`'s basename if `<branch>` is omitted, mirroring
  `git worktree add`'s own default-branch behavior).
- `cd` into `<path>`, run `git sparse-checkout init --no-cone` and
  `git sparse-checkout set --no-cone '/*' '!/TODO.org' '!/DONE.org'`.
- `git checkout <branch>`.
- Print a short confirmation naming the new worktree path/branch and
  stating that `TODO.org`/`DONE.org` are intentionally absent there — use
  the canonical checkout or `org_*` MCP tools instead.

**Repo resolution — a deliberate divergence from this repo's own `bin/`
idiom, called out explicitly so it doesn't read as an oversight.** Every
other script in `bin/` (`bin/test`, `bin/clock-notify-test`, ...) resolves
its repo root from *its own file location*:
`repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`. If
`bin/worktree-add` followed that idiom, its own test
(`bin/worktree-add-test`) would invoke it by absolute path from a
`mktemp -d` throwaway sandbox, and the script would resolve *this actual
repo* (`/Users/neil.best/git/claude-code-ide-org`) as the target to add a
worktree against — running `git worktree add` for real against the live
repo every test run, exactly what this whole planning task was constrained
not to do. Instead, `bin/worktree-add` must resolve its target repo from
**the current working directory** (`git rev-parse --show-toplevel`,
erroring clearly if not run from inside a work tree), the same way `git
worktree add` itself does. This makes the script's target follow wherever
it's invoked *from*, not wherever it physically *lives* — correct for both
real usage (run it from inside whichever checkout you want to branch off)
and for testing it safely against a disposable repo.

This becomes **the** documented way to create a worktree for this project
(see the CLAUDE.md note below) — a plain `git worktree add` is no longer
recommended for this repo specifically, precisely because it silently
recreates the canonical-file hazard finding 5 eliminates.

**Test:** `bin/worktree-add-test`, matching the existing `bin/clock-notify`/
`bin/clock-notify-test` companion-script pattern (a `set -uo pipefail`
harness, `mktemp -d` sandbox, `trap ... EXIT` cleanup — no stubs needed
here since the script only calls `git`, which is safe to invoke for real
against a disposable throwaway repo, unlike `clock-notify`'s
`emacsclient`/`osascript` calls). `cd`s into the throwaway repo before
invoking `bin/worktree-add` by absolute path (exercising the
cwd-resolution design above), then asserts: the new worktree directory
exists; `TODO.org` and `DONE.org` are absent from it; the other tracked
file is present; `git worktree list` (run inside the throwaway repo) shows
the new worktree; and — the regression check this whole design point exists
for — `git -C <this real repo> worktree list` shows **only** the main
checkout, unchanged, before and after the test run. This is mechanically
testable end-to-end with real `git` calls against a disposable repo — no
live Emacs, no `emacsclient`, no touching this project's own `TODO.org`/
`DONE.org` or its worktree list — matching CLAUDE.md's "automated where the
feature has a mechanical surface to test against ... shell scripts via
direct invocation" rule squarely, and it's a stronger bar than
`bin/clock-notify-test`'s own manual-verification caveat (that one concedes
real `emacsclient` behavior isn't exercised; this one doesn't need to
concede anything, since `git` itself is the thing under test and is called
for real, just never against this repo).

### B. Documentation

Add a subsection to CLAUDE.md's "Emacs integration" section (after the
`vterm`/`claude-code-ide` package block, before "Design notes"):

> **Worktrees for code, one canonical org file.** Separate Claude Code
> sessions can each work in their own `git worktree` of this repo — one
> checkout + branch per session, no shared-file collisions for the code
> itself; Emacs' `uniquify` already disambiguates same-basename buffers at
> different paths. Always create the worktree with `bin/worktree-add
> <path> [<branch>]`, never a bare `git worktree add` — the helper applies
> a per-worktree `git sparse-checkout` that excludes `TODO.org`/`DONE.org`
> from the new worktree entirely, so there is never a second on-disk copy
> for `org-id-locations` (a single global hash table in the one shared
> Emacs server process) to collide on, or for a text-editing tool to
> accidentally target. `org_*` MCP tools are already cwd-independent and
> resolve headings correctly regardless of which worktree a session's
> shell is rooted in; the helper's job is narrower — making sure the
> hazard file never exists locally to be opened or edited by hand in the
> first place. Use the canonical checkout's `TODO.org`/`DONE.org` (or
> `org_*` tools, or the `~/org/claude-code-ide-org/TODO.org` symlink)
> from any worktree session that needs to touch org state.

### Rejected/deferred approach: an Elisp guard in `claude-code-ide-org--at-id`

The first draft of this plan proposed adding a canonical-file check to
`claude-code-ide-org--at-id` (`config.el:54-66`) — after `org-id-find`
resolves a marker, reject it unless the marker's buffer file is a member of
`claude-code-ide-org--tracked-files`. Self-review caught two problems with
that, both confirmed by re-reading the actual code rather than assumed:

- `claude-code-ide-org--tracked-files` is `claude-code-ide-org-query-files`
  (nil by default) falling back to `(org-agenda-files)`. `bin/test` runs
  `emacs --batch -Q` (no Doom config loads), and the shared test fixture
  `claude-code-ide-org-test--with-heading` (`config-test.el:19-44`) does
  *not* bind `org-agenda-files` or `claude-code-ide-org-query-files` — only
  individual tests that specifically exercise `org_query`/session-recovery
  bind it locally. Every other existing test's temp-dir heading would fail
  the proposed guard, breaking the bulk of the suite — the opposite of the
  "existing tests keep passing unchanged" a correctness guard must satisfy.
- Separately, `DONE.org` is confirmed *not* in `org-agenda-files` (finding
  1), yet archived headings keep their `:ID:`s and are legitimately
  resolvable (`org-id-update-id-locations` scans `(org-agenda-files t
  org-id-search-archives)`, which does include archive targets). A guard
  reusing `--tracked-files` verbatim would incorrectly reject legitimate
  lookups into `DONE.org`.

A corrected version is possible (a dedicated canonical-file set — tracked
files ∪ resolved archive targets — plus a fixture change binding
`claude-code-ide-org-query-files` everywhere `--at-id` is exercised), but
with the sparse-checkout helper in place, the scenario it would guard
against (a worktree-local `TODO.org` copy existing on disk *and* being
opened as a live Emacs buffer) no longer arises through the documented
workflow at all. Building it now would be defense-in-depth for a path that
requires someone to both bypass `bin/worktree-add` *and* manually open the
resulting stray file in Emacs — two deliberate missteps, not an ambient
risk. **Deferred, not built in this pass.** If it's ever revisited, the
exact mechanism is finding 3 above and the fix sketch is a canonical set of
`(claude-code-ide-org--tracked-files)` plus each tracked file's resolved
`#+ARCHIVE:` target, compared via `file-truename` on both sides.

## Files

- `bin/worktree-add` — new script (recipe in finding 5 / section A).
- `bin/worktree-add-test` — new companion test script, modeled on
  `bin/clock-notify-test`.
- `CLAUDE.md` — new "Worktrees for code, one canonical org file" note in
  the Emacs integration section.

No changes to `config.el`/`config-test.el` in this pass (see "Rejected/
deferred approach").

## Verification

- **Automated:** `bin/worktree-add-test`, run directly (`bin/worktree-add-test`)
  and, if this project wires shell-script tests into a single entry point
  later, alongside `bin/test`. Exercises the full recipe against a
  disposable repo as described in section A — no live Emacs or MCP
  round-trip needed, since the whole deliverable is pure `git` plumbing —
  and explicitly asserts the real repo's own `git worktree list` is
  unchanged by the test run, so the cwd-resolution design (section A) is
  verified, not just argued.
- **Manual:** none required beyond the automated script test — unlike
  `bin/clock-notify`, this script has no Emacs/AppleScript dependency to
  fall back to manual verification for.
- **Documentation:** no automated check, consistent with CLAUDE.md's own
  precedent of treating doc prose accuracy as a manual read-through, not a
  mechanically testable surface. Verified by re-reading the inserted note
  against the rest of the Emacs integration section for tone/cross-reference
  consistency, and confirming it correctly points at `bin/worktree-add`
  once that script exists.
- **Explicitly not attempted in this research pass:** running
  `bin/worktree-add` against the real claude-code-ide-org repo. Everything
  above was verified in a disposable scratch repo created and destroyed
  outside this project, per this task's read-only constraint. Running it
  for real against this repo is exactly what `bin/worktree-add-test`
  automates safely (against a throwaway repo, not this one) — no manual
  live-repo dry run is needed once that test exists and passes.

## After approval

Per CLAUDE.md's Plan-link rule, the heading's body gets
`[[file:~/.claude/plans/worktree-session-partitioning.md][Plan]]` added the
moment this file is finalized — not gated on a later `DOING` transition.
Per the "approval ≠ start implementing" rule, implementation (writing
`bin/worktree-add`, `bin/worktree-add-test`, and the CLAUDE.md note) does
not begin until a separate, explicit go-ahead is given after this plan is
reviewed.
