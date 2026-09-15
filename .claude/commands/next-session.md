# Next session

A plan for `35582d95` — **The plugin ships to a second repo unenforced,
uncategorised and over-claimed** — first of the four slices sequenced below.

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
     nothing announced it.
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
8. **Do not run `org-id-update-id-locations` prophylactically after
   `org_capture`.** A previous revision of this file prescribed it. It did
   not fire once across five capture-then-amend pairs on 2026-09-03. If an
   amend fails with "no org heading found", *then* it is the fix — and that
   recurrence is worth recording.

---

## The four slices, in order

**Memoized 2026-09-15 at the user's direction**, so the sequence survives a
cleared context. Each is its own branch and its own pull request, worked
**serially**:

| | slice | why here |
|---|---|---|
| 1 | `35582d95` — this one | smallest, and every member is a day-one defect in the repo the plugin was already deployed to on 2026-09-11 |
| 2 | `749301a0` | already sequenced internally, foundational — both new derivations rest on span correctness — and holds `c9940558`, itself a euchre blocker |
| 3 | `8a2eb687` | the correctness slice; holds euchre blockers `965f94eb` and `5e731a23`, plus `2aeb65d6`, which is what would make future parallelism safe at all |
| 4 | `6521dd56` | corpus passes, least urgent, and `e128e4fa` is inherently attended — the conventions call it "a per-heading act nobody should do by sweep" |

All four together unblock `6a207b00`, which is `WAITING` on exactly them.

**Four concurrent branches were considered and declined**, and the reason is
one number: **200 of the last 200 code commits touch `config.el`**, a single
17,000-line file. Parallel branches would conflict in proportion to the work
done, and resolving those merges is precisely the attended time the plan
exists to save. Subagents remain right for *reading* — measuring, locating,
reproducing, surveying — because a conclusion has no merge cost; they are
wrong for concurrent edits here until `2aeb65d6` lands.

**And measure the slice itself.** The user's stated reason for holding the
established rhythm is to find out whether recent improvements make slices go
better. At close, compare against `afea7e4f`: members, elapsed days, commits,
review findings per member, and — new, and the first slice able to answer
it — `M-x claude-code-ide-org-attention-report` over the slice's span. Record
the comparison in the debrief.

---

## What is already true, so it is not re-derived

- **`org-depend` cannot parse `ids(...)`.** Verified in batch against org
  9.8.7 and the real `org-depend.el`, with a discriminating control: `ids(A)`
  → DONE, `ids(A B)` → DONE, `ids(A B C)` → blocked but only by B, bare `A` →
  blocked. The grammar is two rules — the literal `previous-sibling`, or words
  each matched as an id **exactly equal** to the whole word.
- **The wrapper was an honest misreading, not a typo.** org-depend *does* use
  parentheses, on the `TRIGGER` side (`chain-siblings(KEYWORD)` and friends).
  There is no parallel form for `BLOCKER`.
- **`org-edna-mode` is a trap, not the second option it looks like.** With it
  on, a `:BLOCKER:` holding *bare* uuids raises an unrecognised-form error and
  org-edna treats every parse failure as a refusal — so those headings would
  block unconditionally. Do not reach for it.
- **The read side already disagrees with enforcement.**
  `--outline-blocker-ids` extracts ids by UUID regexp and finds them all, so
  `org_outline`'s `[blocked: …]` marker has been right while the `DONE`-time
  refusal was not. The divergence bites at the human apply pass, which is
  where the refusal was supposed to appear.
- **The category regression has a cause and a date.** Commit `42a3221`
  (2026-09-09) moved the ten `:CATEGORY:` values out of `CLAUDE.md`, which
  loads in every session, into `.claude/rules/org-conventions-local.md`, which
  carries `paths: ["**/*.org"]` and loads only when an org file is in play.
  The first uncategorised capture is the next day; July and August are clean.
  Capturing a heading is exactly a thing done with no `.org` file open.
- **Measure categories from the drawer, never `org-entry-get`** — the latter
  computes the file-name fallback that makes the defect invisible.
- **The `.gitignore` advice inverts for a *relative* symlink.** A committed
  `../../../claude-code-ide-org` is provenance and enablement in one artifact.
  The ignore line is for *absolute* symlinks only.
- **The 202 override ships nowhere.** `claude-org-setup --glue` prints that
  the glue owns the whole wiring block, while the user's block also carries
  the 202-Accepted override of
  `claude-code-ide-mcp-http-server--send-empty-response` — the real fix from
  the Warp investigation (upstream `8f986c6f`). A user following the printed
  instruction re-breaks every strict MCP client.

---

## Step 1 — `3f4fd744`: make the blocker actually block

The sharpest member and first for a reason beyond severity: every
`:BLOCKER:` written *during* this slice's own work inherits whatever syntax
is in force, so fixing it last would mean fixing it twice.

Write the bare space-separated form — `:BLOCKER: uuid uuid uuid`, no
wrapper — which is what the `org_set_property` validator already produces
internally before wrapping it. Two write sites in `config.el`: the validator
and the slice-blocker refresh. Then rewrite the existing corpus properties,
which the validator itself can do.

**The test that matters is not a string comparison.** Assert that
`org-depend-block-todo` actually *refuses* a `DONE` while a named blocker is
unfinished, and permits it once finished — a test on the property's text
would pass against the broken form too. The `ids(A B C)` control above is the
shape: a blocker naming three ids must block on all three, not on the middle
one.

**Close the read/enforce divergence in the same step**, or say why not. A
marker that reports blocked while the guard permits is worse than either
alone.

## Step 2 — `b0d55552`: categories, root cause first

Two halves and the order is load-bearing.

**First, move the `:CATEGORY:` taxonomy to an always-loaded rule.** That is
the root cause, it is prose rather than code, and it repairs the discipline
for humans and agents alike. The conventions predicted this failure in their
own opening paragraph — "a path-scoped rule that does not load is a rule that
does not apply, and the failure is silent."

**Then make it not depend on being remembered.** Give `org_capture` a
`category` argument, and `bin/lint-org` a rule: a **level-1** heading with no
drawer-local `:CATEGORY:` is an error. Inheritance is the right answer for a
child; a first-degree heading must carry its own. Read from the drawer.

**Re-measure before and after.** The 2026-09-11 count was 10 of 111 level-1
headings uncategorised, all created 09-10 or 09-11. Anything captured since —
including this session's own captures — should be checked, and the count
after the fix is the evidence the step worked.

Decide, while here, whether a missing category should default from the
target's parent or simply be required; the capture reply already names where
the heading landed.

## Step 3 — `784d80c5`: `--org` and the consuming `.gitignore`

Append missing ignore lines rather than clobbering — `--org` already
collision-checks files, so the pattern exists. Four entries generalize
(`settings.local.json`, worktrees, `clock-status.json`, the audit jsonl); the
fifth is the `.claude/skills/<plugin>` symlink, and that one carries the
relative-versus-absolute nuance above: prefer creating and committing the
relative form, and ignore only the absolute one.

Decide whether the entries ship as a template or inline in the script. A
submodule was considered and declined — a vendored second clone breaks the
per-clone port contract and forks the plugin revision per consumer.

## Step 4 — `af2f345e`: stop the glue over-claiming

Decide one of two, and both are defensible: move the 202 override into the
module, guarded and self-retiring when upstream fixes `8f986c6f`; or soften
the printed claim to name what the glue does **not** own.

Until it is decided, the swap instructions must say KEEP the override by
hand — which is what the actual swap did, so the instruction is describing
practice rather than inventing it.

### Where this will stop

Steps 1 and 2 are the deliverable core: after them a consuming repo gets a
`:BLOCKER:` that enforces and captures that carry a category, which is most
of what "the plugin arrives usable" means. Steps 3 and 4 are smaller and
partly decisions rather than builds.

A session that ships Steps 1–2 with the enforcement test verified to
discriminate, then poses Step 4's choice rather than picking it unilaterally,
has done the slice's day well. **The slice closes when its pull request
merges**, not when its last member goes terminal.

---

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
