# Next session

> **CONSUMED 2026-09-18. Do not work from the middle band below.**
> `8bbae3aa` is in `REVIEW` with PR #28 open; all nine members closed.
> This file is a plan, not a convention — the next composer replaces
> everything from *What is already true* to *Where this will stop*.
>
> **Four things it got wrong, kept here because the next plan can avoid
> them rather than because they matter now.** Three premises were false
> and one member was mis-sequenced, and *all four came from this file
> while none came from the headings themselves*:
>
> - `org-session-tracking.md` is **not** "entirely time tracking" — its
>   first section is mixed, and dropping it would have taken
>   `apply-detect`, `footnote-check` and the whole ceremony with it.
> - `claude-org-setup` does **not** write hook wiring, so `--time` was a
>   new capability rather than an extension — and it was never built,
>   because a plugin `userConfig` option replaced it.
> - The stale-interval report does **not** stop finding things when
>   clocking is off; it scans file text and still catches a hand-clocked
>   interval.
> - `5fb70821` was placed last as "deciding nothing", while its own body
>   said it sequences first. Its body was right.
>
> The pattern, which is the useful part: each wrong claim was written
> while looking at the *slice*, and each heading that contradicted it was
> written while looking at the *thing*. Prefer the heading.

A plan for `8bbae3aa` — **Ship the tracker without the clock** — which took
the nomination on 2026-09-17, ahead of the sequence below.

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

---

## The sequence, re-cut 2026-09-17

**The old order assumed time tracking was on the critical path.** It is not, and
that is the whole reason this file changed hands. Of 128 open headings, 55 sit
in `Queue`, `Apply` and `Clock`; weighting by the corpus's own priority
mechanism changes nothing, but the behavioural evidence is overwhelming — on
2026-09-17 every apply failure and every unanswerable review question came from
a span or a clock item, and none from capture, refile, blockers, slices,
conventions or lint. So the useful half was being held hostage by the half still
under construction.

| | slice | where it stands |
|---|---|---|
| — | `35582d95` | merged, PR #24 |
| — | `749301a0` | **merged 2026-09-17, PR #25 — but not closed**, see below |
| 1 | `8bbae3aa` — this one | shortest path to `6a207b00`, which is `WAITING` on the slices and would then wait on one |
| 2 | `8a2eb687` | the correctness slice; re-scope it when it comes up, since `4acd8ad0` is time-tracking work that belongs with the backlog rather than here |
| 3 | `6521dd56` | corpus pass, internal |
| 4 | `f9fe9fac` | datetree, internal |

**Finish `749301a0` before starting this one** (the user, 2026-09-17). Its last
member is `406e9200`, which reopened during its own review: `507754ba`'s
condition — *"once the aggregator is fixed"* — stopped holding when four more
aggregator fixes landed after it closed in August, and `89351a23` was filed for
the re-derivation. Neither is a feature this slice disables; both are
corrections to **this repo's** accumulated record, and time tracking stays on
here. So the test the user set — defer anything that is about to be disabled —
does not fire, and no cookie is dropped.

*The honest caveat: that tail is unbounded.* `507754ba` is a measurement of
unknown size and `89351a23`'s size depends on its result. If the measurement
comes back clean, `89351a23` closes `CANCELLED` with the number and the slice
closes behind it quickly. If it does not, weigh the re-derivation against
starting here — the user's instruction was to finish first, not to finish at any
price.

---

## What is already true, so it is not re-derived

- **The shape is decided, not open.** Scripts ship, wiring does not: a hook has
  no "disabled" state, so wired and unwired are the only forms available, and
  shipping unwired keeps the opt-in to a single file edit. **Not two plugins** —
  time tracking is a *layer* on task tracking rather than a peer, since spans
  attribute to headings the task half manages and both share one queue, one
  review buffer and one watermark file. The one unmeasured assumption under that
  decision is a member, `5fb70821`, not a footnote.

- **What survives the cut, measured against the shipped surface:** capture with
  `:CATEGORY:` enforcement, refile, divide, query, outline, the slice machinery
  with derived cookies and blockers, the `:PLAN:`/`:DEBRIEF:` drawers, the
  conventions as promoted rules, `lint-org`, `check-conventions`, the footnote
  hook. The queue and the review pass survive too: `org_set_todo` is queued
  because org's state-change logging needs a genuinely interactive command,
  which has nothing to do with time.

- **The hook inventory is already taken.** Out: `session-pause`,
  `session-resume`, `block-start`, both `block-end` rows, and the
  `queue-append clock_in` / `clock_out` matchers. Staying: `queue-append todo`,
  `capture`, `amend`, `apply-detect`, `footnote-check`, `session-context.sh`.
  `clock-target-check` is the sharp one and has its own member.

- **`org_divide` times out through MCP and it is not our code.** 0.013 s in
  batch against full-size copies. Do not re-measure it; see `51bcec2c`. If a
  member needs a divide, call it and check the file rather than retrying.

---

## The order, and why it is one direction of travel

`eb6c4a9b` first, because it is the only member that fails *loudly*:
`clock-target-check` blocks a stop when write activity has no `clock_in`, so the
moment clocking is off it blocks the first real turn of every consuming session.
It must come out in the same change as the guideposts, not after.

Then the wiring itself (`0c5577dc`), then the two surfaces that *instruct* —
the promoted rules (`36952d1f`) and the tool registrations (`01f7a19c`) — in
that order, because a rule telling an agent to call a tool that is gone is a
louder failure than a tool nobody is told to call.

Then the two that straddle the cut: `6956a46e`, where one SessionStart payload
carries a time-tracking report and a task-tracking one, and `1b36c5bd`, the
opt-in that puts the wiring back.

`d3149a81` last among the doing, because it verifies the claim the whole slice
rests on. `5fb70821` is research and can run at any point; it decides nothing
this slice does, only whether the two-plugin question reopens later.

## Step 1 — `eb6c4a9b`: the hook that enforces what is being removed

Take it out of `hooks/hooks.json` with the guideposts. Decide in the same breath
whether it returns with the opt-in: it backstops the rule that a session names
the heading its first write belongs to, which is a *task*-tracking rule about
attribution, so a variant checking for any queued activity rather than
specifically a `clock_in` may be worth more than deletion.

## Step 2 — `0c5577dc`: the wiring change

The rows listed above, out. Every script stays on disk. State the reload
precondition when verifying: `hooks.json` is read at session start, so a change
here cannot be observed in the session that makes it.

## Step 3 — `36952d1f`: rules that instruct clocking

`org-state-transitions.md`'s transition table has clock instructions in four
rows and clock-closing in four more; `org-session-tracking.md` is *entirely*
time tracking and should simply not promote without the opt-in. The open
question is a forked table versus a conditional clause, and the conditional has
a bad record here — a path-scoped rule that does not load is a rule that does
not apply, and a reader holding a condition is the same bet.

## Step 4 — `01f7a19c`: the clock tools' registration

Leave registered, gate on a `defcustom`, or remove. Removal is not viable — this
repo needs them and it is the same module. The argument for gating is that a
tool in the schema is an invitation, and this project's evidence is that an
agent calls what it is offered.

## Step 5 — `6956a46e`: one payload, two reports

The stale-interval half is pure time tracking and can never fire with clocking
off; the ceremony half is pure task tracking and a consumer wants it. Weigh
splitting against leaving the stale half to return nothing, which the existing
`[[ -s ]]` guard already degrades silently.

## Step 6 — `1b36c5bd`: the opt-in

A `--time` flag on `claude-org-setup`, in the shape of the existing `--doom` /
`--org` / `--glue`. It inherits the wiring trap: a repo must enable the plugin's
hooks or its own, never both, so the flag has to know which the consumer uses.
`--check` should report the time wiring present or absent rather than ignoring
it.

## Step 7 — `d3149a81`: verify a guidepost-free queue

The claim the slice rests on, and the corpus cannot test it — this repo's queue
has held guideposts since the 2026-08-11 cutover. Build a fixture whose queue
holds only `todo`, `capture` and `amend`. Probe two things that are not obvious:
`--queue-drained-p` is "yields no items" and archiving depends on it, and
`apply-detect` compares watermark mtimes with fewer kinds moving them.

## Step 8 — `5fb70821`: can two manifests share one MCP server?

Research, and the answer decides whether the two-plugin question ever reopens.
Record it either way. The trigger worth writing down now: a consumer wanting the
time half *without* the task half, which is incoherent today and would stop
being so only if spans ever attributed to something other than org headings.

---

## Where this will stop

**This slice has an integration point, so it closes when its pull request
merges** — not when its last member goes terminal. `749301a0` is the standing
demonstration: merged 2026-09-17 and still open, because a member reopened
during review.

A session that lands Steps 1 and 2 has done the slice's day: after those two a
consuming project can install the plugin and not be blocked on the first turn,
which is the whole point. Steps 3 and 4 make it *honest*; the rest make it
*supported*.

**And measure the slice**, as its predecessors were asked to: members, elapsed
days, commits, review findings per member, and
`M-x claude-code-ide-org-attention-report` over its span, against `afea7e4f`,
`35582d95` and `749301a0`. `749301a0`'s numbers are available now that it has
merged, so this is the first comparison with three complete points rather than
two.

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
