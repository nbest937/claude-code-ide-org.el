# Plan — Org skill: commit a newly-captured TODO immediately, when safe

`:ID: 3cb3f955-f10a-47cd-84ab-e629d73ea59d`

## Context

CLAUDE.md's standing rule ("any time a new task is described in
conversation, create an org heading ... rather than only tracking it in
conversation memory") only ever edits the working tree. Nothing commits
that edit, so the capture sits as an uncommitted change — alongside
whatever else may already be mid-flight in the same file — until a human
notices and commits by hand. This task adds prose guidance to the org
skill (`.claude/skills/org/SKILL.md`) telling Claude to commit the
capture itself, immediately, *when it is safe to do so*, and to say
explicitly when it judges it unsafe and leaves the working tree alone
(today's behavior) instead.

Confirmed from `git log --format=full` (`cbf7da2`, `a982297`, `7989347`):
every prior "capture" commit in this repo already follows one convention
— first line `Add TODO: <heading title>` (or more generally `Add
<KEYWORD>: <title>` — not confirmed for non-TODO initial keywords since
no example exists yet, but consistent with the pattern), a body paragraph
explaining the capture, and a trailing `Co-Authored-By: Claude Sonnet 5
<noreply@anthropic.com>` line. No `Claude-Session:` trailer appears in
these historical commits even though the harness's own commit-message
template includes one — this plan follows the *harness's* prevailing
convention at commit time rather than hardcoding a fixed trailer, since
that's an orthogonal harness concern, not something this task should
freeze in place.

No pre-commit hook exists in this repo (`.git/hooks/` has only Git's
stock `.sample` files), so there's no hook-driven side effect to account
for beyond `git commit` itself.

### Boundary with the sibling heading (782cda6c)

[[id:782cda6c-111c-454e-93eb-b2b27012078b][Audit for clock/session
bookkeeping noise before committing during a clocking-suppressed
session]] is a different task, not implemented here. Division of labor:

- **This task (3cb3f955)** owns the *mechanics* of "commit the capture,
  when git-state-safe": is the repo in a normal state (not mid-rebase/
  merge/cherry-pick), and — the part that actually answers this
  heading's open question — is the file's entire post-capture diff
  attributable purely to the capture Claude just wrote (see Design's
  post-edit diff-shape check below). If the diff contains anything else
  — a deletion, an extra hunk, content Claude didn't just author — a
  scoped `git commit -- <file>` would silently sweep that in too, so the
  answer this plan lands on is: **don't auto-commit in that case**, full
  stop. This task does not attempt to distinguish which of that extra
  content is "genuine work" vs. noise — it only detects *that* extra
  content exists and treats that fact alone as disqualifying.
- **782cda6c** owns the harder, narrower judgment call this task
  explicitly declines: when a clocking-suppressed session is about to
  commit and finds `:LOGBOOK:`/`:SESSIONS:` deltas already present (from
  other concurrent sessions' ordinary activity, per that heading's
  concrete incident), whether those specific deltas are genuine
  attributable work worth folding into *some* commit, vs. noise to be
  excluded or flagged. That question only arises once a file is already
  known to be non-clean — which is exactly the case this task's "don't
  auto-commit" rule already refuses to touch. So the two tasks compose
  cleanly: this task's conservative check is the gate; 782cda6c's
  eventual capability (if built) would only ever be consulted on the
  cases this task declines, never overridden by them. Not merging the
  two headings — 782cda6c is about arbitrary already-open sessions'
  clock/session bookkeeping noise specifically (a narrower category than
  "any unrelated uncommitted hunk"), so it doesn't fully subsume this
  task's broader "don't commit unrelated stuff" mandate even after it's
  built.

## Design

### What "safe" means (the core algorithm)

Prose to add to the org skill, expressed as a sequence Claude follows
immediately after creating a capture heading (title, tags, properties,
`:CREATED:`, and initial TODO state — i.e. after the capture edit is
fully written, per the existing "new heading from an approved Plan" rule
which already says to stop before *further* edits, not before this
book-keeping step):

1. **Repo-state check.** Skip auto-commit (leave the working tree as-is,
   today's behavior, and say so) if the repo is mid-rebase, mid-merge, or
   mid-cherry-pick:
   ```
   git rev-parse -q --verify MERGE_HEAD
   git rev-parse -q --verify CHERRY_PICK_HEAD
   test -d "$(git rev-parse --git-dir)/rebase-merge"
   test -d "$(git rev-parse --git-dir)/rebase-apply"
   ```
   Any of these succeeding means "weird state" — don't touch it. This
   isn't only a defensive nicety: confirmed live in a scratch repo, git
   itself hard-refuses a pathspec-limited commit mid-merge (`git commit
   -m "..." -- f.txt` → `fatal: cannot do a partial commit during a
   merge.`, exit 128). This check exists to fail *fast and clearly* with
   an explanation Claude can relay, rather than surfacing that raw `git`
   error to the user unexplained — worth doing even though git's own
   safety net would catch a merge specifically either way. Rebase/
   cherry-pick mid-states aren't necessarily caught by the same partial-
   commit guard, so the check still matters for those.

2. **Post-edit diff-shape check.** There is no reliable "state just
   before the capture" to compare against — the capture rule fires as a
   side effect of conversation, not from a plan that snapshots `git
   status` in advance, so a pre-edit baseline generally won't exist.
   Instead, after the capture edit (heading + initial `org_set_todo`
   call, which itself appends a `:LOGBOOK:` state-change line and saves
   the buffer) is complete, run `git diff -- <file>` and require the
   **entire diff to be pure additions** whose content is exactly what
   Claude just authored — the new heading's lines plus the
   `org_set_todo`-appended LOGBOOK entry, nothing else:
   - No deletions anywhere in the diff.
   - No hunks outside the range Claude just wrote.
   - No added lines Claude doesn't recognize as its own capture content.
   This is the answer to the heading's central open question about
   `git commit -- TODO.org`: that pathspec-limited form commits the
   file's **entire current working-tree content**, regardless of
   index/staging state (`git commit <pathspec>` stages matching paths
   itself before committing) — so it is only safe when the whole diff
   *is* the capture.
   - **Diff is pure-addition and fully attributable to the capture:**
     proceed to step 3.
   - **Diff contains anything else** (a deletion, an extra hunk, content
     Claude didn't just write — e.g. another session's `:LOGBOOK:`/
     `:SESSIONS:` churn landing in the same file, or genuinely unrelated
     in-progress edits): do **not** auto-commit. Leave everything
     uncommitted, exactly as today, and say so explicitly in the
     response (e.g. "left the new heading uncommitted — TODO.org has
     other uncommitted changes too"). This is the disqualifying case
     782cda6c's future work may eventually refine (see boundary above)
     — this task does not attempt to split the diff or judge whether
     the extra content is "genuine."

   **Expected hit rate, stated plainly:** in a real working session this
   check will decline more often than not fire clean. `TODO.org` tends
   to be dirty for stretches of an ordinary session (other in-progress
   heading edits, and — per 782cda6c's premise — continuous
   `:LOGBOOK:`/`:SESSIONS:` churn from the clock/session machinery even
   when nothing else is going on). That's an accepted, correct limitation
   of this task, not a bug to widen scope for here: this lands a
   safe-by-construction gate that fires only when the diff is genuinely
   clean, and the common "file already has other stuff in it" case stays
   uncommitted (today's behavior) until 782cda6c's harder judgment call
   about drawer-only noise exists, if it ever does.

3. **Stage and commit, scoped to the one file.**
   ```
   git commit -m "$(cat <<'EOF'
   Add TODO: <heading title>

   <one short paragraph: what was captured and why, same register as
   existing capture commits like cbf7da2/a982297/7989347>

   Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
   EOF
   )" -- TODO.org
   ```
   - Never `git add -A` / `git add .` — this project's git-safety
     convention (and the harness's own default git protocol) requires
     staging specific files by name. Pathspec-limited `git commit --
     <file>` already satisfies this without a separate `git add` step.
   - Substitute the actual file if the capture landed somewhere other
     than `TODO.org` (this rule is file-agnostic; `TODO.org` is simply
     the common case per CLAUDE.md's examples).
   - First line: `Add <KEYWORD>: ` + the heading title, lowercasing the
     title's first letter to read naturally as a sentence continuation
     (`KEYWORD` is whatever initial TODO state was actually set — `TODO`
     in every existing example). Reword lightly when the literal title
     doesn't read naturally as a commit subject — this is precedent, not
     a verbatim-copy rule: `7989347` ("Add TODO: reorder :SESSIONS:
     entries to match :LOGBOOK: ordering") is a near-verbatim match to
     its heading title, while `cbf7da2` ("Add TODO: org skill should
     commit a new TODO capture immediately, when safe") is a reworded
     paraphrase of its heading title ("Org skill: commit a
     newly-captured TODO immediately, when safe") — both are within
     this convention.
   - Trailer: whatever the harness's own commit-message convention is at
     commit time (currently `Co-Authored-By: Claude Sonnet 5
     <noreply@anthropic.com>`, per the historical commits inspected —
     note the harness's general instructions also mention a
     `Claude-Session:` trailer that these historical commits don't
     actually carry; follow this repo's actual precedent, not the
     template, if the two ever disagree).

4. **Multiple captures in one turn/session.** No special-casing needed:
   since each capture commits immediately, the file is clean again by
   the time the next capture's diff-shape check runs (a clean file's
   post-edit diff is trivially "pure addition, all mine"). The algorithm
   is naturally idempotent across repeated captures.

### Placement in SKILL.md

Add a new subsection after "## Background-planning a batch of NEXT/TODO
headings" and before "## Explaining Org-Mode Syntax" — same document
altitude (a distinct, self-contained procedural subsection, not folded
into "Generating .org content," which is about formatting, not git).
Working title: `## Committing a newly-captured TODO immediately`.

### Why prose, not a mechanical gate

The heading's own question — "prose guidance ... or something more
mechanical?" — is answered by precedent already in this codebase:
CLAUDE.md's read-only-buffer guidance (`config.el`'s five MCP tools
"don't bind `inhibit-read-only`... clear it and proceed, no need to ask
first") is exactly this register — a documented judgment call executed
via ordinary tool calls (`Bash` git commands here, `emacsclient` there),
not a new code path with its own test suite. The repo-state and
pre-edit-cleanliness checks above are individually mechanical
(shell-scriptable, verifiable), but the overall "was this actually a
plain capture, is now a good moment to commit it" call remains a
judgment Claude makes each time — same reasoning CLAUDE.md already gives
for calls "only the model can make." No new elisp, no new MCP tool: this
is purely a `.claude/skills/org/SKILL.md` prose addition, exercised via
the org skill's existing `Bash`-based git access.

## Files

- `.claude/skills/org/SKILL.md` — new subsection (see Design above),
  the only file this task modifies.
- No `config.el` / `config-test.el` changes — this is pure skill prose,
  not a new MCP tool or elisp function, so `bin/test`'s ERT suite is
  unaffected and gets no new tests.

## Verification

Per CLAUDE.md's testing rule, this is "a documented manual verification
pass" for the skill-prose portion (not mechanically testable — whether
Claude *follows* the new prose is the same kind of fuzzy trigger-matching
CLAUDE.md already says isn't worth forcing into a deterministic test),
plus a mechanical check of the one part that genuinely is checkable: the
git commands' actual behavior.

**Mechanically checkable now, ahead of implementation** (confirms both
the disqualifying case and the "hits mostly no-op" premise flagged in
Design): the current repo state already demonstrates it. `git status
--porcelain -- TODO.org` on this branch (`feature/planning-todo-state`)
reports `M TODO.org` right now (confirmed live) — this branch's
`TODO.org` carries substantial unrelated in-flight additions from this
same session's earlier turns, so `git diff -- TODO.org` at this moment
is definitely not "pure addition, all mine" for any one capture. If a
new capture were made to `TODO.org` in this exact session state, the
proposed diff-shape check would correctly find non-attributable content
and decline to auto-commit — the conservative, correct outcome. Also
confirmed live in a scratch repo (`git init`, two branches modifying the
same file, merge conflict, then `git commit -m test -- f.txt`): git
itself refuses a pathspec-limited commit mid-merge with `fatal: cannot
do a partial commit during a merge.` (exit 128) — corroborating step 1's
repo-state check independently of this task's own logic. Both are
plain read-only checks, re-runnable as-is after implementation with no
code changes needed to exercise them.

**Manual walkthrough after the SKILL.md edit lands:**
1. Start from a branch/checkout where `TODO.org` is clean
   (`git status --porcelain -- TODO.org` empty).
2. In a live Claude Code session using the org skill, describe a new
   throwaway task in conversation (triggering CLAUDE.md's capture rule).
3. Confirm Claude creates the heading, then — per the new subsection —
   runs the repo-state check, then the post-edit diff-shape check, and
   (since the diff is pure addition, all its own) commits via a scoped
   `git commit -m "..." -- TODO.org`, not `git add -A`/`git add .`.
4. Inspect the resulting commit: `git show --stat HEAD` should show only
   `TODO.org` touched; `git log -1 --format=%B` should match the
   `Add TODO: <title>` convention with a `Co-Authored-By:` trailer.
5. Repeat with `TODO.org` deliberately left dirty first (e.g. hand-edit
   an unrelated line without committing), describe another throwaway
   task, and confirm Claude's diff-shape check finds the extra hunk,
   explicitly declines to auto-commit, and says why — leaving the
   working tree exactly as today.
6. Repeat with a fabricated mid-rebase/mid-merge state (`git rebase -i`
   stopped at a conflict, or simpler: `touch .git/MERGE_HEAD` in a
   scratch clone) and confirm the repo-state check also correctly
   declines — and, per the live scratch-repo test above, that `git`
   itself would refuse the partial commit even if the check were
   somehow skipped.
7. Clean up any throwaway commits/branches created during this manual
   pass — this is a verification exercise, not real project history.

## After approval

If this plan is approved and implemented, add the
`[[file:~/.claude/plans/capture-commit-safety.md][Plan]]` link to
heading `3cb3f955-f10a-47cd-84ab-e629d73ea59d` in `TODO.org` per
CLAUDE.md's Plan-link rule (as soon as planning finishes — this file
being finalized counts, independent of whether/when the heading is
promoted to `DOING`). Per CLAUDE.md's separate "new-task heading
approval gate" and "two separate checkpoints" rules, do **not**
transition the heading to `DOING` or begin the `SKILL.md` edit itself
without a further, explicit go-ahead beyond plan approval.
