# Next session

A plan for `8a2eb687`, **Everything passed and the file was still wrong**.
It took the Slices nomination back on 2026-09-21, when `f6d160c2` went to
its pull request (#29). The `NEXT` is queued, not applied.

**The slice is the list.** Open it and read its checklist; this file gives
the plan, not the membership. The two disagree only if one is stale, and the
slice wins — which is also why no cookie or member count appears here. A
count in two places is a count that can disagree with itself, and this is
the copy nothing regenerates.

> **The line above is the only slice-specific text outside the middle
> band.** Read the file as three parts: *Step 0* and *Standing rules* carry
> forward verbatim between slices, everything from *What is already true* to
> *Where this will stop* is replaced wholesale, and this heading names which
> slice the middle is about.

> **This file is composed from the slice's `:PLAN:` drawer**, which was
> itself composed from the members. Only three members carry a drawer of
> their own; the rest are pre-convention, so their plans are read from
> their bodies. Where a step here and a heading disagree, the heading wins,
> for the same reason the slice wins on membership. Every step ends with a
> **Decision** line naming what is unresolved and whose it is, or `none`.
> That line is the marker `c10bfb15` asks for, written as a literal token so
> a check can assert it.

---

## Step 0 — preliminaries

> **CARRY FORWARD VERBATIM.** Nothing below is specific to a slice. When this
> file is rewritten for the next one, this section and *Standing rules* at the
> foot move across unchanged; everything between them is replaced. Amend these
> two only when a session earns a new entry — never to describe the slice in
> hand.

Every item here is on the list because skipping it cost a past session real
work.

1. **Apply the queue before composing anything.** Until it is applied,
   `TODO.org` shows the old keyword on headings whose work shipped, and a
   slice's checkboxes disagree with their referents. **That disagreement is
   staleness, not a defect — do not fix it by hand.** `org_pending_updates`
   says what is waiting; it is also step 2.
2. **Confirm `emacs-tools` is reachable** by calling `org_pending_updates`.
   Read-only, and a reply proves the server is up in a way that seeing the
   tools listed does not.
3. **Clock in before the first thing that writes**, naming the heading, or
   "Review and planning" for cross-cutting meta-work. The drift from question
   to tracked work is invisible from inside the session doing it.
4. **Queue the slice itself → `DOING` the moment its work starts.** The
   member-level rule ("set `DOING` before starting a task") got applied
   to every member of `ff7ccb2d` while the slice sat at `NEXT` for four
   days of its own execution — on a grouping, `DOING` means "at least
   one member is in the mail", which was true from this file's first
   step. It opens no clock (grouping exemption) and costs one queued
   event; without it the slice's LOGBOOK shows a `NEXT`→`DONE` teleport
   and every report that keys on `DOING` is blind to the work in flight
   (the `4133772c` defect, one tier up).
5. **Confirm the new branch will be cut at a commit that already contains
   every piece of prior work you want in it.** Three parts, in order, and the
   third is a question rather than a command:

   - *Fast-forward the intended base*, usually `main`:
     `git fetch origin main:main`. **Not `git pull`** — run from a feature
     branch that updates the feature branch and leaves the base exactly as
     stale as it found it. Not hypothetical: on 2026-09-03 local `main` was
     165 commits behind while `origin/main` was current, so
     `git diff main...HEAD` reported 18 files and 28k lines for a PR that was
     7 files and 768. The branch was fine; only the `main` *label* lied, and
     nothing announced it. (That form refuses while `main` is checked out;
     `git fetch origin` and compare `main` to `origin/main` then.)
   - *Survey what is not in that base yet* —
     `git branch -a --no-merged main` for divergent branches, and
     `gh pr list --state open` for review in flight. Either may hold work
     that belongs underneath the new branch rather than beside it.
   - *Report both lists to the user and ask what should land first.*
     **Whether to merge anything is their decision, not yours** — a branch is
     an integration point, and choosing where it starts is choosing what it
     integrates. Say plainly if both lists are empty; that is an answer too.
6. **Merge back through a pull request, not a local merge.** Every merge
   to `main` for ten consecutive integrations went through one (`#2`–`#10`)
   and *nothing said so anywhere* — so on 2026-09-08 a session merged two
   branches locally, breaking the streak without tripping a check (`:ID:`
   c7bf2121). `gh pr create` when the branch is ready, and note the trap
   that caused it: a question offering "merge now or hold" decides *timing*
   and silently decides *mechanism* too. Ask which, or say which.
7. **Then cut `feature/<short-name>` from the settled base.** What earns a
   branch is wanting a separate integration point, which a new slice always
   is — so do not continue a slice on the branch of the one before it, even
   when that branch is still open. **Maintenance between chunks of real work
   may land on `main` directly** and should: applying the queue, debriefing
   an already-merged heading, filing. A branch per bookkeeping commit is the
   jitter CLAUDE.md's rule was relaxed to stop.
7a. **IMMUTABLE — rename the session to match the new branch.** The
   moment `feature/<short-name>` is cut, the session's name becomes that
   branch name: `/rename feature/<short-name>`. The agent cannot run a
   slash command, so it asks the user for exactly that in the same
   message that reports the cut — not later, and not as an option. A
   session list that shows branch names is the only place the four
   serial slices stay tellable apart after their contexts clear; a
   session named for its opening question is named for the thing it
   stopped being at step 7. Added 2026-09-15 at the user's direction;
   this item carries forward unchanged with the rest of Step 0.
8. **Do not run `org-id-update-id-locations` prophylactically after
   `org_capture`.** A previous revision of this file prescribed it. It did
   not fire once across five capture-then-amend pairs on 2026-09-03. If an
   amend fails with "no org heading found", *then* it is the fix — and that
   recurrence is worth recording.
9. **When the apply hook says the queue was applied mid-session, commit the
   org diff as its own bookkeeping commit before the next amend.** The
   apply pass writes keywords, CLOCK lines and a slice blocker refresh
   into `TODO.org` under you; an amend on top folds the human's pass into
   a commit whose message describes your prose. On 2026-09-15 the diff was
   checked with `git diff --stat` first and committed alone; it was 75
   lines the amend's message would have misattributed.
10. **Capture with no `body`, then `org_amend` the body.** `org_capture`
   drops an argument it does not recognise without saying so (`bbf9fb77`),
   and `body` is one of them: on 2026-09-19 eight captures in one session
   each landed as a title with an empty body, unnoticed for five hours
   because every one had a full `:PLAN:` drawer written by a later
   `org_amend` — a heading with a plan drawer looks composed at a glance.
   Check the file after the first capture of a session, not the reply.
   Added 2026-09-19; carries forward with the rest of Step 0.

---

## The sequence, as of 2026-09-21

| | slice | where it stands |
|---|---|---|
| — | `f6d160c2` | PR #29 open. `63713df3` is awaiting the user's verdict, and `436e0991` still needs its fresh-session check (below) |
| 1 | `8a2eb687` — this one | the gate, then the tools that answer wrongly, then checks and ownership, then divergent copies, then the outage |
| 2 | `6521dd56` | corpus pass, internal |
| 3 | `f9fe9fac` | datetree, internal |

`6a207b00` (the euchre adoption) waits on `f6d160c2`'s merge, not on this
slice. Every member here that changes what a consumer receives should be
checked against a consumer install as well as here: `5e731a23`, `965f94eb`,
`3ad389be` and `7fa68d5c`.

**Branch:** `feature/<short-name>` at step 7, cut from `main` *after* #29
merges. This slice carries code in every member but one.

---

## What is already true, so it is not re-derived

- **Membership was left exactly as found, at the user's direction.** Three
  members are time-tracking only: `53b0047d`, `60ed5b96` and `4acd8ad0`. The
  body already drops `4acd8ad0` in prose (2026-09-17), but the checklist still
  lists it. Do not reconcile that without asking.
- **By count, about four-fifths of the open members benefit a project with
  time tracking off.** Nobody has estimated effort, so do not quote the
  fraction as weighted.
- **Loud failures raise the miss count.** Since `63713df3`, every genuine
  `org_*` refusal appends a `miss` line. A member that turns a silent wrong
  answer into a refusal adds lines where there were none. Read `bin/miss-rate`
  by rule, and expect this slice's rules to *rise*.
- **Carried over from `f6d160c2`: `436e0991`'s check.** In a fresh session
  that uses *only* the org tools on `TODO.org` (no Read of an `.org` file),
  confirm the conventions notice arrives on the first `org_*` call. Then
  queue `436e0991` for `REVIEW` with the evidence. It needs a new session by
  construction, so it is the first thing that session does.

---

## Step 1 — `94e6b615`: one runner for every suite

`bin/test` runs ERT only, and the shell suites run when someone remembers.
Three sat red for a day, and on 2026-09-21 the suites turned out to be
writing their provoked refusals into the calling session's real queue: 24
of the first 29 counted misses. Both are this slice's sentence. Build
`bin/test --all` (or `bin/test-all`): every suite, with each exit code
checked and the `Ran N` line read. Name it in Step 0 as what a branch runs
before its PR.

**Decision (user):** whether pre-push calls it. Measure its wall time first.

## Step 2 — the tools that answer wrongly and look right

Six small members, each shipped with a test proved red first:

- `37bca83a` (already DOING): a query whose first non-blank character is
  `(` is a sexp. Refuse it and name the mini-language, or run it through
  `org-ql-select`. No predicate is dropped, and none ever was.
- `25e7b083`: sweep by *argument*, not by call shape, and take the silent
  shape first. `refresh-slice` still compares ids with `equal` at two sites.
  The capture target resolves through `--id-find` but passes the prefix into
  the `id` spec, so write the failing test before assuming it works.
- `57f37f0e`: the no-change check reads the effective state, meaning the
  file plus the heading's pending todo events. A set-and-revert cancels the
  pair.
- `492a1a30`: `org_divide` still writes `" [/]"` after the title. Use
  `--ensure-statistics-cookie-at-point`'s placement, and look for a third
  inserter.
- `60ed5b96`: the docstring still opens "Always *inactive*". Say what
  `:active` means and who sets it.
- `7b4f4f14`: the watermark distinguishes "applied something" from "a pass
  ran".

**Decision:** none.

## Step 3 — `39039bb6` and `7ee3b71a`: a check that does not catch, a region nobody owns

- `bin/lint-org` errors on a heading `:ID:` that appears twice across the
  tracked files, naming both locations. Only heading properties count.
- Make the slice member region identifiable to *any* writer, so that
  `replace=` preserves it the way it preserves drawers. Refusing `replace=`
  on a `:KIND: slice` heading is the fallback, not the fix.

**Decision:** none.

## Step 4 — two copies of the truth

- `2aeb65d6` leads this step because it gates the user's concurrent
  sessions. `pre-commit-guards` refuses a whole-index commit while the real
  index is non-empty and `CLAUDE_CODE_SESSION_ID` is set, and it counts a
  miss like the other guards. The design and the measured `GIT_INDEX_FILE`
  table are in its drawer. **Decision (user):** an `ALLOW_SWEEP` escape for
  `--amend`.
- `f12f9da4`: compare every defun in `config.el` against the running image
  with `fboundp` (394 measured, 0 unbound). That catches the stale `.elc`
  and an older load of the right file alike. **Decision (user):** warn or
  block. My recommendation is a SessionStart line, not a commit-gate block.
- `8ddd7fa8`: `--at-id` falls back to a scan when the index misses, and its
  error distinguishes "nowhere" from "not where the index says".
- `5e731a23`: apply reads the queued event's `cwd` for a deferred targetless
  capture.
- `965f94eb`: only the basename collision remains. Propose a retitle.
- `53b0047d`: detect a live modified buffer diverging from disk before a
  tool writes. Its clock half is time-tracking only.

## Step 5 — the outage and the unknown

- `3ad389be`. **Decision (user)** among its three options. My
  recommendation is option 1: a timed-out tool write leaves a durable marker
  that SessionStart reports.
- `7fa68d5c`: its "rarely used" caveat is stale, because capture is now the
  normal creation path. Build the fallback once `3ad389be` has decided the
  shared shape.
- `381ea07d`: a timeboxed attempt to reproduce it, with a buffer put through
  revert, consolidate, normalise, then archive. If it does not reproduce,
  the post-condition guard stands and the heading says so.

## Not sequenced

- `2a6a1355` is REVIEW. The question is the user's: how many root causes it
  holds. Bring the candidate seams; the user decides whether it divides.
- `4acd8ad0`: see *What is already true*.

---

## Where this will stop

**The slice closes when its pull request merges**, not when its last member
goes terminal. A session that lands Steps 1 and 2 has done the slice's day.

**Measure it**: members, elapsed days, commits, and review findings per
member. Also read the miss rate for the rules it touches against the
prediction above; `158d7e80`'s 2026-10-12 reading falls inside this slice's
window.

## Standing rules, with what actually happened

> **CARRY FORWARD VERBATIM**, with Step 0. The dates are not staleness — they
> are the evidence that turns a platitude into a rule, so keep them and add to
> the list rather than refreshing it. A rule whose incident is forgotten is a
> rule nobody follows.

- **Never type a UUID from memory.** Write the 8-character prefix and let the
  tool expand it; where a full id is unavoidable, `grep` the `:ID:` line. On
  2026-09-04 a slice's twenty member lines were *generated from `TODO.org`*
  and the result diffed against what landed — one full id was not what recall
  offered. Generate, then diff; do not proofread. Two other full ids were
  typed from memory the same day and both were refused by the tool, which is
  the guard working and not a reason to lean on it.
- **Anchor org parsing on the heading's own property drawer.** A regex
  scanning each heading's whole block attributed **three of eight** footnote
  titles to the wrong heading, because ids get quoted in bodies. Third
  instance of that class; the fix is `org-map-entries`, not a second parser.
- **Footnote every tracked `:ID:` in every response**, title looked up rather
  than recalled. The hook fired four times on 2026-09-03 and every miss was
  an id that arrived *inside* evidence rather than one chosen deliberately.
- **Reproduce the hypothesis before fixing it.** One heading's stated likely
  cause was wrong, and its own body had flagged it unverified for exactly
  that reason. Reproducing took one command and changed the fix entirely.
  Second instance 2026-09-08: `2c77f2cc`'s left-edge failure did not
  reproduce against live data — the guard already worked — and the fix
  narrowed to a pinning test instead of code.
- **Prove a test discriminates.** Copy the file aside and restore `HEAD`'s
  version in place; **never `git stash`**. Every fix on 2026-09-03 was run
  red first, and one regression test was written a commit early and *held
  back rather than committed red*.
- **A comment that overstates a guard is how the next reader stops
  checking.** Three were corrected on 2026-09-03 in the same commits as their
  code.
- **Silence is not a pass.** Check the `Ran N tests` line and the exit code,
  never the absence of `FAILED`. Beware `$?` after a pipeline.
- **Never pass `--no-verify`.** When the org lint blocked a commit because a
  plan file had vanished from `~/.claude/plans`, the fix was restoring it
  byte-for-byte from `plans/` — which is what that archive exists for. It
  happened again on 2026-09-08 (two plan files, four lint errors) and the
  same restoration cleared it.
- **`command` before a shell builtin is not a safety measure.** `command cd`
  skips fish's builtin for an external no-op, so `pwd` reported the wrong
  directory and every check silently ran against the wrong tree. Two existing
  assertions caught it in under a minute.
- **A mutation test must assert its own mutation.** Proving a new lint rule
  reached the real corpus meant deleting a property from `TODO.org` and
  watching it fire. The first attempt edited nothing — its anchor assumed a
  property order `org-entry-put` does not use — so the lint reported no error
  for the honest reason that the file was unchanged. Without the `assert` that
  would have read as *"the rule does not reach the real path"*, a stronger and
  entirely false conclusion than the one under test.
- **`git commit -- FILE` commits the whole file's current diff**, not your
  hunks. On 2026-09-04 that swept an apply pass the user had run between the
  read and the write into a commit whose message described three unrelated
  amendments. Explicit pathspecs protect other *files*, never other *changes*
  — so check `git diff --stat` before committing a file someone else may have
  touched, and if it happened, amend the message to name both authors rather
  than letting the log misattribute the work. Second instance 2026-09-08,
  worse form: `git add -A` on a feature branch swept the user's apply pass
  into a feature commit, discovered only from the merged PR's stat line —
  by then unamendable. Stage by explicit path, always; `-A` is never worth
  the keystrokes it saves.
- **A branch switch rewrites `TODO.org` on disk, and auto-revert follows.**
  On 2026-09-08 a branch cut from an older base reverted the file under
  Emacs, and a debrief amend landed on a copy missing 143 lines — caught
  only because the pre-commit `git diff --stat` showed deletions where an
  append-only session should show none. Do org bookkeeping only from
  `main` (or a branch whose `TODO.org` matches it); after any switch,
  assume the buffer changed under you. Recovery: restore `main`'s copy,
  diff the stale copy against its own base to extract what was added,
  re-apply through the tools.
- **GitHub closes a stacked PR when its base branch is deleted at merge**
  — it does not retarget. On 2026-09-08, merging `#11` with
  `--delete-branch` closed `#13` (stacked on it) unrecoverably: a closed
  PR's base cannot be edited, so it was recreated as `#14`. Either
  retarget the stacked PR to `main` *before* merging its base, or expect
  to recreate it and say so in the new body.
- **Verify against the tree the system actually reads.** On 2026-09-10 the
  org pin was "tested" twice by editing the working tree while the sandbox
  synced *its own clone* — two scrubbed re-clones proved only that the edit
  never reached the sync. The wasted cycle ended the moment the reading
  tree was named out loud, which is §0's reload rule wearing a different
  coat: before a verification run, say which copy of the artifact the
  system under test reads, and check the edit landed there.
- **A green batch run says nothing about the running image, and a
  `defcustom` `:set` is the sharpest case.** On 2026-09-15 a `:set` that
  called a function defined *later in the file* passed the whole suite —
  batch never had the upstream feature loaded, so the setter's guard
  skipped the call — and aborted the live `load-file` halfway through
  `config.el`, leaving the running Emacs on a partial reload. The reload
  rule's precondition was named and the check still lied until it was
  run. Define what a setter calls before the setter, and after any live
  reload check the *last* thing the file defines, not the first.
- **`ln -s TARGET LINK` with LINK an existing symlink to a directory
  creates the link *inside* that directory.** On 2026-09-15 a test check
  did exactly that and dropped a dangling `nowhere` into the plugin's own
  root, found only by `git status` before a push. After any test that
  creates links, check the tree for strays — and write the check so the
  link path cannot already exist.
- **An anchor regexp without a boundary matches its own prefix.** The
  org-dev skill check searched for `'claude-code-ide` and found
  `'claude-code-ide-mcp-http-server` first, reporting a healthy file as
  broken. Anchor to end of line or a symbol boundary; the same class as
  the drawer-anchoring rule above, one level down.
- **Prefer the heading over the slice.** The 2026-09-18 plan for `8bbae3aa`
  got three premises wrong and one member mis-sequenced, and *all four came
  from the plan while none came from the headings*: each wrong claim was
  written while looking at the slice, and each heading that contradicted it
  was written while looking at the thing. Since 2026-09-19 the plan is
  composed from the members' `:PLAN:` drawers for exactly this reason; where
  a step and a drawer disagree, the drawer wins.
- **A full drawer masks an empty body.** On 2026-09-19 eight headings lost
  their captured bodies to a silently dropped argument and looked composed
  for five hours, because each had a `:PLAN:` drawer written by a later
  call. When a tool reports success and the location, check the primary
  artifact for the *content* — the reply says where it wrote, never what.
- **A filename in prose is a link to `sync-plans`.** Its matcher is a
  substring grep, so naming an orphaned plan file in a body re-linked it and
  `--check` demanded the deleted archive back (`ecb1dde8`, 2026-09-19).
  Name the thing, not the path, when writing about a file that is meant to
  be gone.
- **A test run from a session is part of that session.** A Bash tool call
  exports `CLAUDE_CODE_SESSION_ID`, and the git guards count their refusals
  under it. On 2026-09-21 four runs of `bin/git-guards-test` wrote 24
  provoked refusals into the real queue as the session's own misses, and the
  slice's first measurement read 29 where 4 were genuine. Found only because
  the number was read line by line before being reported. A suite that
  drives anything which records must isolate *both* the queue directory and
  the session id, from its first case.
