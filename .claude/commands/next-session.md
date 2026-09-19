# Next session

A plan for `f6d160c2` — **A rule the agent can recite and still misses is a
rule in the wrong place: count the misses, then move the rules out of
recall** — which took the Slices nomination on 2026-09-19, displacing
`8a2eb687` (its demotion is queued, not applied).

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

> **This revision is composed differently from its predecessors, on
> purpose.** Each member's step below is written *from that member's
> `:PLAN:` drawer*, in slice order — the user's convention as of
> 2026-09-19: a plan lives in the heading's drawer, not in a plan file, and
> this file is the composition over the drawers. Where a step and a drawer
> disagree, the drawer wins for the same reason the slice wins on
> membership. Every step ends with a **Decision** line naming what is
> unresolved and whose it is, or `none`; that line is the marker `c10bfb15`
> asks for, written as a literal token so a check can assert it.

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

## The sequence, re-cut 2026-09-19

**The nomination moved because the problem the analysis names is upstream of
every other slice.** A correctness slice, a corpus pass and a datetree fix are
all executed by sessions that forget rules they can recite, and each of those
slices has already paid for that: the 2026-09-18 plan got three premises wrong
from the slice's altitude, and this one was composed through two of the
defects it exists to reduce (Step 0 item 10, and *What is already true*
below). Lowering the miss rate first makes the others cheaper; the reverse is
not true.

| | slice | where it stands |
|---|---|---|
| — | `8bbae3aa` | merged, PR #28; closed |
| 1 | `f6d160c2` — this one | measurement first, then the load path, then compression, then the tools |
| 2 | `8a2eb687` | the correctness slice, demotion queued; re-scope it when it comes up, since `4acd8ad0` is time-tracking work that belongs with the backlog rather than here |
| 3 | `6521dd56` | corpus pass, internal |
| 4 | `f9fe9fac` | datetree, internal |

`6a207b00` stays `WAITING` on `8a2eb687` and `6521dd56`; this slice does not
change that, though members 2, 3 and 6 each change what a consumer receives
and should be verified against a consumer install, not only here.

**The branch is `feature/miss-rate`** — or whatever name the user prefers at
step 7; the slice carries code in six of eight members, so it is not
maintenance.

---

## What is already true, so it is not re-derived

- **The numbers.** Always loaded, every session, in this repo: **1,573 lines /
  13,590 words** across CLAUDE.md (494) and seven unscoped rule files. A
  consumer receives the plugin's share of that, **1,003 lines / 9,143 words**,
  of which `org-time-tracking.md` is 260 lines for a feature that defaults to
  off. `befaed0a`'s target was *under 200 lines* for CLAUDE.md alone; CLAUDE.md
  fell 23% while the surface it was split into grew to two and a half times
  the file the target was set against. Path-scoped and therefore *not* in the
  budget — but see member 2 — `org-conventions.md` (1,082) and
  `org-conventions-local.md` (113). Re-measure with one loop over CLAUDE.md
  and `.claude/rules/*.md`, testing for real YAML frontmatter (first line
  `---`), not the string `paths:` — `org-categories.md` says "carries no
  `paths:` scope" in prose and a naive grep reads it as scoped.

- **What "open" means for a path-scoped rule.** Claude Code's memory docs:
  "Path-scoped rules trigger when Claude reads files matching the pattern, not
  on every tool use" — the Read tool on a matching path. An Emacs buffer is
  not open; a Bash `sed` is not open; an `org_*` call is an MCP call carrying
  no path and is not open. A session that obeys "start with `org_outline`, not
  a file read" therefore never loads the conventions. Verified on the session
  that composed this slice: five captures and a dozen Bash reads of
  `TODO.org`, and the conventions were never injected.

- **The tiers of enforcement, strongest last**, because members 5, 6 and 7
  place themselves on them: prose the model must recall; an argument the
  model must fill (a recall miss becomes a fabrication, and nothing checks
  it); a hook reading a record the model did not write (real, but transcripts
  are pruned — `4acd8ad0` — and `last_assistant_message` is only the final
  block); the tool doing the step itself and *returning* evidence. Only the
  last makes the omission unreachable. Judgement can never reach it, but a
  narrowed context lets judgement leave the first tier, which is what a
  checker subagent is for.

- **Two decisions the analysis proposed that this slice does *not* adopt**,
  so they are not re-argued: *push harder on path-scoping* (falsified twice
  here — `b0d55552` and `befaed0a`'s own test: a rule that must hold with no
  `.org` open cannot be scoped, and the failure is silent); and *separate rule
  from rationale* as stated (CLAUDE.md's thesis is that rationale is the one
  thing the artifact cannot recover; the honest form is *rationale stays iff
  it stops a specific reversal*, and that is member 4's rule).

- **`org_divide` and `org_slice_add_member` time out through MCP and succeed
  through `emacsclient`** — the same call, at once, seven times running on
  2026-09-19 while `org_pending_updates` answered between the failed
  attempts. See `51bcec2c`. If a member needs either, call it once, check the
  file, and fall through to `emacsclient -e '(claude-code-ide-org-…)'` rather
  than retrying the tool.

- **Captures do not ask first, and the session commits them.** Decided by
  the user 2026-09-19: *keep the practice* the log already shows — a session
  files a heading and commits it itself ("File <id>: …"), by explicit path,
  without asking; 24 of the 25 commits before this slice was composed were
  made that way. Approval for a capture is therefore after the fact: the
  commit is small, named for the heading, and cheap to amend or revert. The
  review buffer is not the gate — a capture appears there only on the
  deferred path (Emacs unreachable). `3cb3f955` is this practice written
  down, and what it still owes is its safety predicate: only the touched
  `.org` files staged, never mid-rebase, `git diff --stat` first. The
  plan-derived gate on a new heading's *wording* is untouched by this and
  stays the user's to retire; `24c7b537` (a retitle tool) is what would make
  "fix it after" cheap enough to consider it.

---

## The order, and why it is one direction of travel

The number first, because a slice that cannot show its number moving has
nothing to close on and its instrumentation is cheap. Then the two members
that decide whether a rule *loads at all* — a rule that does not load cannot
be recalled and no compression helps it. Then the budget and the audit
together, one sitting over the same eight files. Then the two tools that move
a judgement out of recall, mechanical first. The ratchet last, blocked on the
budget it asserts.

## Step 1 — `63713df3`: the miss rate

What exists: 67 session queue files in `~/.claude/org-updates/`; 5
`.footnote-blocked` and 2 `.clock-target-nagged` sentinels. Not a rate, three
times over — each sentinel fires at most once per session, only two rules have
a blocking hook, and the hooks see a fraction (`footnote-check` reads the
final text block; `clock-target-check` reads a queue that under-reports the
writes it looks for, by its own header).

Do: every backstop that blocks, refuses or injects appends one line to the
session's queue file — `kind: miss`, the rule's name, the turn — through
`queue-append`, the plain-shell path the hooks already use. The apply pass
ignores kinds it does not render. Then a rate per session, per rule, per day
is one `jq` over the directory, and the ceremony has a number to print beside
the pending count. Retire the sentinels' second job as the record.

Say what it cannot count: the misses the user catches in conversation, which
are the ones the analysis is about. State the hook-visible subset as a floor.

**Decision (user):** whether the user's corrections should be answered with a
capture or amend citing the rule missed — which makes the human's catch a
queue event through the existing matchers, at the cost of being one more rule
the agent must remember. Do not adopt it silently.

## Step 2 — `436e0991`: rules that load only on the discouraged path

The conventions load on a Read of an `.org` file; the tools exist so that no
such Read happens. Three remedies, keyed on the right signal:

1. a `PostToolUse` matcher on the first `org_*` call of a session that
   injects the conventions as `additionalContext` — the `apply-detect` shape,
   costs one large injection per session and only in sessions doing org work;
2. fold the load-bearing parts into the org skill's `SKILL.md` — trigger
   matching is fuzzy, the failure `c10bfb15` already names;
3. the tools carry the rules: `org_capture`'s refusal already lists the
   categories in use, and that is the one convention no session has missed
   since. Rules that ride on a tool result cannot fail to load.

Start with (1) as the cheap interim; (3) is the same shape as Step 5 and is
decided there. Re-run `befaed0a`'s verification honestly this time: a fresh
session that uses *only the tools* on `TODO.org`, and check what loaded.

**Decision (session):** which of the conventions' 1,082 lines are load-bearing
during tool-driven work. Measure by which rules the tools' refusals already
enforce; the remainder is the injection.

## Step 3 — `1b69fe4e`: the time file promoted for a feature that is off

`bin/claude-org-setup` promotes `org-time-tracking.md` unconditionally on the
premise that it "costs a consumer one unread reference". It is read at launch
every session. Setup cannot read the `userConfig` option — that is why the
gate went into the hook scripts — but it can take a flag: `--time-tracking`
(or the same `CLAUDE_PLUGIN_OPTION_TIME_TRACKING` the hooks read, when set)
promotes the file; otherwise it stays in `references/` as the install-time
reading its own header claims to be. The file's opening disclaimer becomes
unnecessary once its presence *is* evidence.

Also: the 54 clock-shaped lines scattered across the other four machinery
files (25 in `org-state-transitions.md`) — pull into the time file where
cheap, leave the rest to Step 4. And name the removal case: a consumer who
turns the feature off later has an orphan, which is `96ad6e95`'s gap.

**Decision:** none. The constraint (setup cannot see the option) is measured
and the flag is the shape the script already uses.

## Step 4 — `bf7e0b8e`: the deletion pass, with a budget

Delete, do not relocate — relocation is what produced 1,573 lines, and the
path-scoped bucket is not "deferred" (Step 2). In scope: dated history and
incident narrative that stops no specific reversal (`9d009401` swept this seam
once; it is worked, not closed); prose describing a mechanism that is wired
and merely narrated; anything Step 5 converts. Out of scope: rationale that is
what stops a reversal — the maintenance clause, the do-not-re-tighten note.

Two audiences, two budgets, one toggle: state the number per mode
(self-hosting, consumer) and per `time_tracking` value, or it will be met in
one configuration and missed in three. Acceptance is the before/after table
and the number Step 8 asserts.

**Decision (user):** the budget itself, and the unit — lines are what
`befaed0a`'s target used and the corpus reports in; words are what a session
pays. Propose both numbers, let the user pick.

## Step 5 — `3cd7b7d3`: the enforcement audit

One read-through of the eight always-loaded files, in the same sitting as
Step 4. For each clause of the shape "before/after X, do Y", sort Y:
*mechanical and cheap* → convert to a hook or tool contract and delete the
sentence once wired (known members: `8a23d6ec` comma-escaping, `3cb3f955`'s
predicate, the duplicate query of Step 6); *judgement* → stays, the only
category that earns always-loaded words; *neither* → retire. Prefer the shape
that makes the omitted step impossible over the shape that reminds; reserve
blocking for what cannot be done inside a tool. Do not mechanise
membership-shaped judgement — the retired auto-promotion trigger is the
evidence.

**Decision (user):** the convert list, before conversion. Present it as a
table — clause, tier today, tier proposed, cost — and convert only what is
approved; this is the step that changes what every session is told.

## Step 6 — `c8773ec2`: `org_capture` runs the duplicate query itself

The transcript in the analysis: a session offered to file a defect
`bbf9fb77` already held, could recite the duplicate-check rule when
challenged, and had not run it. Put the query inside the tool: before
writing, search `TODO.org` and `DONE.org`, return near-matches beside the
capture — or refuse and return them when the match is strong. The check then
runs whether or not the session remembered it. The two weaker shapes (an
evidence argument the model fills; a transcript-reading hook) are on the tier
list above and are not built.

Return the candidates in a form Step 7's pass can consume, so the two share
one query. Start with title-token overlap and measure its misses on this
corpus, which has a known duplicate pair to test on.

**Decision (session):** what "near" means and where "strong" refuses; measure
first, then propose the thresholds with the false-positive count.

## Step 7 — `9fb8c1fb`: the twin pass, a checker subagent with a saturated context

Twins are "caught by review, never by the composer", and no review looks for
one. A subagent whose whole context is the conventions' story and twin
paragraphs plus the candidate headings and their bodies — not the 1,573-line
standing surface — makes the judgement the orchestrator makes badly mid-task.
The invocation is the hard part: "ask the checker first" is a rule again, so
it runs as a *pass* — the ceremony session spawns it when a human is already
reviewing, extending `527be4e3`'s sweep with a second finding. It proposes,
never restructures; a twin is an error, an unattached task is not, and the
report keeps them apart. Its count — twins found per pass — is a second series
beside Step 1's, never folded in; a twin will never be hook-visible.

`7eb7dd8d`'s residue — a request against open work in either direction — is a
candidate third finding once `0eecf8e7` gives it an inverse index; not a
member, note it and move on.

**Decision (user):** whether the pass runs from the ceremony session (the
only invocation that costs no new machinery) or waits for scheduled rituals
to be first-class. Recommend the ceremony; say so and ask.

## Step 8 — `f2030ce9`: the ratchet

`bin/check-conventions` sums lines over CLAUDE.md plus every
`.claude/rules/*.md` whose first line is not `---`, compares to a number kept
in one place, fails with the per-file table on overrun. It must not count the
path-scoped files (they are a separate problem, not a solved one — Step 2),
and it must not be satisfiable by relocation into a promoted reference, which
carries no scope by design. Blocked on Step 4 by `:BLOCKER:`, since a check
with no number always passes.

**Decision:** none once Step 4 has decided the number and unit.

---

## Where this will stop

**This slice has an integration point, so it closes when its pull request
merges** — not when its last member goes terminal. `REVIEW` is the window
between the last member closing and the merge, and review findings arrive
there by construction.

A session that lands Steps 1 and 2 has done the slice's day: after those two
the rate is visible and the conventions reach the sessions that do org work.
Steps 3–5 make the surface *honest*; 6–8 make the fix *structural*.

**And measure the slice** as its predecessors were: members, elapsed days,
commits, review findings per member, and
`M-x claude-code-ide-org-attention-report` over its span, against
`8bbae3aa`, `749301a0` and `35582d95` — plus, uniquely, **its own number**:
the miss rate from Step 1, before and after. If that number does not move,
the slice did not do what it said, whatever else it shipped.

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
