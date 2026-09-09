# Next session

A plan for `c19fbbf5` — **Ship the plugin: make the machinery and its
prose travel together**.

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

**The slice's first step is unblocked, verified 2026-09-08.** `b0e478f7`'s
`:BLOCKER:` names `d5345abb` (the CLAUDE.md-vs-skill audit), which is
`DONE` in DONE.org — the SKILL and RULE rows are relocated, so the prose
moves once. `9d009401`'s blocker `9ae4b17e` (the portability
classification) is likewise discharged; its four decisions stand and are
recorded on that heading and quoted in `9d009401`'s body.

**Three of the five members were deferred *into* the packaging step by
the user on 2026-09-08, and their bodies say so.** `ecf66d45` is decided
*with* the portable half (its forecast-vs-record boundary design happens
at packaging); `b862fbf4` waits for hooks to ship user-level, and then
for multi-project `cwd` data to accumulate — it likely cannot *finish* in
the next session no matter what; `e396f94a` stays `MAYBE` with its
promotion trigger being "packaging starts", so the manifest step names
it. Do not re-litigate these deferrals; the bodies carry the reasoning.

**The tool surface changed on 2026-09-08/09, and a fresh session has the
new schemas.** `org_amend` continues a list (single newline when both
sides are list items) and takes `drawer=` (PLAN/DEBRIEF, created when
absent). **A heading's lifecycle is two calls at each end**: compose
with `org_amend drawer=PLAN` then the short body; close with the
authored resolution then the debrief via `drawer=DEBRIEF` — CLAUDE.md's
`:PLAN:` rule carries the procedure. `org_set_property` `KIND=slice`
completes the declaration: `:COOKIE_DATA:`, the `[/]` cookie, and the
`:BLOCKER:` derived from an existing checklist. `org_slice_add_member`
adds a member line (with `after=` for ordering) and writes the
`Planned:` lead when a checklist is born — never hand-edit a checklist.
A drop is declared in the slice's `:DROPPED:` property; cookie absence
alone means nothing and is re-derived. `org_outline`'s `scope` takes
several ids or prefixes at once, one block each. The `Planned:` lead is
load-bearing (anchors the member region; self-healed by refresh), so
prose bullets above it are safe. The ceremony refreshes open slices
itself and **reports a worked slice carrying no `orgit-rev:` prompt
link** — expect it to name `c19fbbf5` at first work; at pickup add one
link per revision of this file since composition, oldest first
(`git log --oneline --follow` on this file lists them, `db4e1bf`
onward), rather than waiting for the nag.

**Incidental attribution now REQUIRES the slice to be `DOING`**
(`:ID:` 58e6c6a0, the user's ruling): a slice owns a close only while a
`DOING` span from its state history contains it, and a close made while
no slice is `DOING` belongs to no slice. Step 0.4 — queue the slice
`DOING` the moment its work starts — is therefore no longer bookkeeping
hygiene but the precondition for any fast-tracked incidental being
credited at all. Skip it and incidental work done during the session
vanishes from every list, silently and correctly.

**The suite's baseline is zero failures** — 580/580 as of PR #21
(2026-09-09). Any failure is real.

**CLAUDE.md's prune arithmetic is already measured; do not re-measure.**
~660 of ~1200 lines are machinery that ships with the plugin; three
sections (state transitions, engineering practices, session tracking)
hold 69% of the file; the contested remainder after packaging relocates
its share is ~70 lines, and the read-through of those is `9d009401`'s
remaining work, reserved for the user in the loop. The file *grew* +15%
during the slice that asked it to shrink; the packaging move is what
actually reverses that, not further pruning.

## Step 1 — Build the package

`b0e478f7` — *Package the plugin: references, setup command, machinery
prose*. Nearly the whole slice, and everything else in it is sequenced
by this step's progress. Four deliverables, landing together so
instructions and machinery travel in one change:

- the plugin manifest (`.claude-plugin/plugin.json`);
- the conventions shipped as skill `references/`;
- the `bin/` setup command that promotes conventions into a consuming
  repo's `.claude/rules/` — per-repo, full strength, consent-by-install,
  per `9ae4b17e`'s recorded decisions;
- CLAUDE.md's ~580 lines of machinery prose (queue architecture,
  transition rules, tool tables, session tracking) moving into the
  shipped references in the same change. Guards travel with their
  conventions (`9d009401`'s settled decision 4): the dated blocks
  protecting live rules move intact, never compressed.

Two decisions surface *inside* this step and are the user's: what the
setup command may touch on a consuming machine (`1caed585`, still
`MAYBE`, is the standing question — the manifest may collapse it), and
whether hooks ship user-level (`b862fbf4`'s precondition; shipping them
is what gives cross-project allocation anything to compare).

## Step 2 — Decide the Warp wiring at the manifest

`e396f94a` — *Package the Warp wiring*, `MAYBE` on purpose. Its own body
names the trigger: packaging starting is the decision point, and the
manifest is where "does the Warp wiring get packaged?" has an answer.
The outcomes are: in the package (promote and generalise the snippet),
or explicitly not (stays `MAYBE` for a future upstream PR, or
`CANCELLED` with the body kept). **A user decision; expect to stop.**

## Step 3 — The contested read-through

`9d009401` — *CLAUDE.md carries dated history that costs every session's
context*, already `DOING`. After Step 1 relocates the shipped share,
what remains is the genuinely contested ~70 lines of dated history —
and this heading has said three times, correctly, that the read-through
**needs the user in the loop, not a background pass**. The session's
job is to prepare the diff view (what moved, what remains, per-block),
then stop and read it *with* them.

## Step 4 — The timeline boundary, if reached

`ecf66d45` — *Nothing lays out future work on a timeline the agenda can
show*. Decided with the portable half by the user's deferral. The work
is design before dates: forecasts (active timestamps) must stay apart
from the record (inactive spans, CLOCK lines), and whether slices get
dates at all is open. Both are judgement questions — treat this step as
a conversation to have if Steps 1–3 leave room, not code to write.

## Step 5 — What b862fbf4 can and cannot do yet

`b862fbf4` — *Allocate attention across concurrent sessions, which is
zero-sum*. If Step 1 ships hooks user-level, the only action here is
verifying multi-project `cwd` data starts accruing; the judgement design
explicitly waits for real data to judge against. **Do not attempt to
close this member in the next session**; progress is "the precondition
now holds and data is accumulating", stated plainly.

### Where this will stop

Earlier than the last slice, and by design: the last slice was decided
rules awaiting code, this one is code awaiting decisions. Step 1's build
is the autonomous core, and even it contains two user calls (the install
surface, the hooks' scope). Steps 2 and 3 are explicit stops — a
manifest decision and a shoulder-to-shoulder read-through — and Steps 4
and 5 are conversations and preconditions, not deliverables. A session
that ships the manifest, references and setup command, then stops with
the CLAUDE.md diff prepared for joint review, has done the slice's day
well.

**A caution particular to this slice:** it moves prose that other
sessions load as context. Between the packaging commit and the next
session start, CLAUDE.md's description of the machinery and the shipped
references' description are two copies; any interim session reads only
the former. Land the move and its CLAUDE.md pointer stubs in one commit,
never split across a session boundary.

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
