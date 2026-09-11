# Next session

A plan for `afea7e4f` — **Join the transcript to the record: span
synopses, readable sessions, weighted attribution**.

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

## What is already true, so it is not re-derived

> **SLICE-SPECIFIC, and permanent as a *section*.** This heading always
> appears and its contents never survive a rewrite: it exists so the next
> session does not re-measure what this one already established. Keep it to
> findings a session would otherwise spend real time rediscovering.

**PR #22 is the standing preliminary.** The whole plugin slice
(`c19fbbf5`, ~95 commits on `feature/plugin-package`) is OPEN and
unmerged. Step 0.5's survey will find it; the merge is the user's
decision, and this slice's branch should be cut *after* it lands —
GitHub closes a stacked PR when its base is deleted at merge (Standing
rules, last entry but one).

**The join is measured, not hypothesized.** Every queue `resume` event
in the measured session matched a transcript user message on timestamp —
**28 of 28 within two seconds** (`295cde3a`, 2026-09-01). Transcripts
live at `~/.claude/projects/<project-slug>/<session-id>.jsonl`, one JSON
object per line, every user message ISO-timestamped. The join is
retroactive over every session ever recorded; no hook change and no new
durable field is needed anywhere in this slice.

**The queue defines what a prompt is.** Raw `type:"user"` transcript
entries are contaminated — stop-hook feedback and tool results are
injected in the user role (45 raw against 36 real prompts in one
session; 276 against ~25 in another). Filter to the queue's `resume`
timestamps; this is `9e627dc0`'s trap, walked into twice already.

**Why spans lack synopses today** (`--review-annotation-label`): an
item's label is the note its *enclosing clock event* carried, authored
at `org_clock_in`/`out` time. A span reconstructed from unbracketed
guideposts has no enclosing event — that is what made it unattributed —
so it gets only the synthesized provenance label. `325679af` fills
exactly that hole with joined prompt text.

**`fbaf8009` executes FIRST despite sitting last on the checklist.**
`org_slice_add_member` is append-only (`b112878e`, filed at
composition), so the declared order could not be repaired; the slice's
`:PLAN:` says so. It is pure rendering: the `cwd` is already on every
queue event (`5461c349`) and the destination tracker falls out of where
the `:ID:` resolves. No join, no transcript, cheapest first.

**The review buffer code to start from**: `--review-render`,
`--review-annotation-label`, `--review-insert-remainders` in
`config.el`. Multi-project data is live — euchre sessions append real
events now — so `fbaf8009` can be verified against genuine two-project
queues, not fixtures alone.

**`96ddf1ef`'s promotion (MAYBE → TODO) may still be queued at pickup.**
Step 0.1's staleness rule applies: the file shows MAYBE until the apply
lands; do not fix it by hand.

**The suite's baseline is 598/598** (as of the so-long guard,
2026-09-10). Any failure is real. And if Emacs beachballs at a ceremony
again, `sample <pid>` *before* killing it — `489d6f61` holds the one
existing stack and is promoted by a second occurrence.

## Step 1 — Where: the tracker and cwd rendering

`fbaf8009` — group headings gain the destination tracker (the project
directory name of the file the `:ID:` resolves in), and unassigned-span
groups say which session `cwd` produced them. Rendering only; the
column-alignment rationale in the group-heading code (`c2132d3f`) is
the style to match, not fight. Verify against the real two-project
queue.

## Step 2 — What: the prompt join in the review buffer

`325679af` — the slice's namesake. Each run renders its opening
prompt's first line; a lone-timestamp span renders the abutting prompts
either side, truncated. Elisp reads the session's transcript file,
filters to `resume` timestamps (±2s tolerance, measured), truncates
hard. Decide at build time: how much text, where it renders (same line
or a detail on demand), and what happens when the transcript file has
been cleaned up (30-day mortality — degrade to today's behavior,
loudly).

## Step 3 — Pages: the readable session render

`96ddf1ef` — a transcript rendered to org for paging in Emacs. Its body
carries the original observation; the design questions are where
rendered files live (never in the repo), whether rendering is on-demand
or cached, and how a review-buffer span links to its session's page.
Buildable if Steps 1–2 leave room; otherwise its design conversation is
a fine stopping point.

## Step 4 — Meaning: weighted attribution, a conversation

`295cde3a` — research, explicitly. 84% of turns name at least one known
heading id (mean 6.2), so a turn can be attributed to several tasks by
weight, with lag. **Expect this step to end in a design or a refined
question, not code**; it is the member that trusts the join furthest,
and it waits on Steps 1–2 giving the user lived experience of the
joined data.

### Where this will stop

Steps 1 and 2 are the deliverable core — after them the review buffer
answers *where* and *what* for every span, which is the concrete need
that declared this slice. Step 3 is a bonus build; Step 4 is a
conversation. A session that ships Steps 1–2 verified against the real
queue, then stops with Step 3's design questions posed, has done the
slice's day well.

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
