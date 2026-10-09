# This repository's slice rules

> Read by `/plan-slice` and `/work-slice` (TODO.org :ID: dc21f724). The
> commands ship with the plugin and hold only what the tracker's machinery
> needs; this file holds what is **this repository's practice**: its
> branch-and-PR workflow, its testbed skill, and the engineering lore its
> slices earned. A consuming project writes its own file, or none.
>
> **Grows only by addition**, like the core, and each new item goes to
> the layer it belongs to: machinery to the shipped commands, practice
> here. Moved here from `next-session.md` on 2026-10-09, numbering kept
> so older citations still find their item.

## Step 0, this repository's items

Run after the core's items 1-5.

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
10. *Moved to the shipped `/work-slice` Step 0 on 2026-10-09 (PR #36
   review): it describes the shipped tool's defect, not this repo's practice.*
11. **Load the `org-dev` skill before the first member** (the Skill tool,
   `org-dev`). It is this repo's primer on developing the module: how to
   reload what a member changed, *when* a reload is owed, and how to prove
   it landed. It is triggered rather than always loaded, and a slice
   session's opening is not shaped like its trigger. On 2026-09-25 a
   member landed a new `footnote-check` stub over elisp that existed only
   in the tree; the stub exits 0 silently when Emacs lacks the function,
   so every session ran unchecked for an hour and nothing said so. Added
   2026-09-25 at the user's direction.
12. **A `DOING` slice whose pull request is already open is waiting, not
   in hand.** The shipped `/work-slice` reads the keyword alone, and
   `bin/hooks/review-start` queues `REVIEW` only once a review starts, so
   between `gh pr create` and the first review the slice is still
   `DOING`. Check `gh pr list --state open` before resuming one; if its
   PR is open, queue `REVIEW` on it and take the `NEXT` slice instead.
   This was the old command's own check, kept here when the keyword took
   over in the shipped core (PR #36 review, 2026-10-09).

---

## Standing rules, with what actually happened


> **Add to this list; never refresh it.** The dates are not staleness — they
> are the evidence that turns a platitude into a rule, so keep them and add to
> the list rather than refreshing it. A rule whose incident is forgotten is a
> rule nobody follows.

- **Anchor org parsing on the heading's own property drawer.** A regex
  scanning each heading's whole block attributed **three of eight** footnote
  titles to the wrong heading, because ids get quoted in bodies. Third
  instance of that class; the fix is `org-map-entries`, not a second parser.
- *"Footnote every tracked `:ID:`" moved to the shipped `/work-slice` on
  2026-10-09 (PR #36 review): the footnote hook ships to every consumer.*
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
