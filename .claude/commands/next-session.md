# Next session

A plan for `749301a0` — **A span is only as true as its owner, its edges and
its payload** — second of the four slices sequenced below.

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

## The four slices, in order

**Memoized 2026-09-15 at the user's direction**, so the sequence survives a
cleared context. Each is its own branch and its own pull request, worked
**serially**:

| | slice | why here |
|---|---|---|
| 1 | `35582d95` — **at `REVIEW`, PR #24 open** | smallest, and every member was a day-one defect in the repo the plugin was already deployed to on 2026-09-11 |
| 2 | `749301a0` — this one | already sequenced internally, foundational — both new derivations rest on span correctness — and holds `c9940558`, itself a euchre blocker |
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
better. At close, compare against `afea7e4f` *and* `35582d95`: members,
elapsed days, commits, review findings per member, and
`M-x claude-code-ide-org-attention-report` over the slice's span. Record
the comparison in the debrief. `35582d95`'s own comparison is still open on
its body — its review findings and attention number arrive with PR #24's
review and the next apply — so the closing session of *this* slice may be
the one that completes both.

---

## What is already true, so it is not re-derived

Every item below was measured on a member's body, most against the raw
queue corpus. Do not re-run the falsified ones; do re-check the caveats.

- **A session id is not a stable key for a stretch of work, and nothing in
  this project can make it one.** Claude Code re-keys an interactive
  session mid-work (`~/.claude/jobs/<id>/` appears 32 minutes in; upstream
  #59848 closed, #76220 open). So every repair *reconciles lanes after the
  fact*; none may assume the key holds. Two instances are measured on two
  different event pairs: a turn's `resume`/`pause` (`9202b39d`) and a
  clock bracket's `clock_in`/`clock_out` (`b57c7515`). They pair through
  different functions (`--span-events` adjacency against
  `--lane-clock-pairs`), so the question the slice opens with is whether
  the repair belongs per-pairing-function or once, where lanes are formed.
- **The depth counter is falsified, and not marginally.** Merged-stream
  depth (`resume` +1, `pause` −1) latches: one lost `pause` and no run is
  ever emitted again — 13.61 h against 22.79 h over the 844-guidepost
  corpus, and a daily reset errs in both directions. Keying the open set on
  `session_id` still latches (18.46 h). **Do not rebuild it.**
- **"Compute runs per session, then union the results; never pool the
  events first" stands as written** (`7d739afd`), vindicated by the run
  that falsified the counter. The union's own magnitude is **0.11 h, 0.5%**
  over ten days — an argument about *where*, not *whether*: wire
  `--merge-time-intervals` (unwired since 2026-08-10) where totals cross
  headings; leave per-heading CLOCK lines as computed. The CLOCK-line
  versus report-time question is deliberately still open and "should not
  be decided by whoever happens to touch this first".
- **What survived `9202b39d` is a targeted linking rule**: a session whose
  stream *opens* with a `pause` is a background job whose first turn began
  elsewhere; pair it with the nearest preceding unclosed `resume` in
  another session. Fires once over the corpus, recovers 0.62 h exactly.
  Caveats: multi-candidate ambiguity untested (the implementation picks
  the latest), and `b57c7515` shows a second shape it never fires on — a
  lane that opens normally and still holds half a bracket opened elsewhere.
- **The split-span loss has two causes, not one** (`c54c4215`). Splitting
  emits only endpoints, never the complement — 369 s in three gaps on the
  fixture. And *widowing*: a partial apply consumes a point's neighbour, so
  the survivor degenerates to zero width; this compounds with how carefully
  a human reviews. The complement fix does not touch widowing; that needs
  the aggregator to see consumed events (`--queue-events` with
  `include-consumed`, as `--review-suggest-heading` already does). The
  fixture is on that heading's body — three 2026-08-25 guideposts, with
  their session id — dismissed, not destroyed, replayable.
- **The threshold is not the cause of any of this.** 935 s against 1200 s
  clustered fine; exclusions split it. Raising the threshold changes
  nothing, and the threshold no longer defends any duration anyway (the
  session-tracking rules say why).
- **A 0-run span applied as suggested writes an annotation and no CLOCK
  line** (`2deb090f`) — `--review-apply-clock`'s `(unless observed …)`
  branch. Measured 2026-09-14 on the meta-work node and `Review attention`
  alone: **18 annotations asserting 99 minutes that nothing counts**, a
  steady leak from 2026-08-24 on, and the task headings were not audited.
  The user's position is settled: accepting such a span *is* the assertion
  that the minutes were attention. Today only `e` — retyping both
  timestamps unchanged — can say so.
- **Two projects' guideposts already cluster into one span** (`c9940558`):
  exactly two groups over the whole history render two cwds, and both are
  real. Small because euchre has 14 events against 722; it scales with the
  second project and it is silent. `5461c349` recorded the `cwd` field for
  this and named a second obligation: normalise a worktree's cwd to its
  main checkout, or one project splits into one span per worktree.
- **The story above the slice is `406e9200`, `DOING`, 10 of 16**, with a
  plan file (`~/.claude/plans/elegant-questing-lamport.md`) that governed
  the finished ten and is *design*, not instruction, for these six. Its
  standing decisions still bind: idle merges below the 120 s floor; the
  auto-clock-in trigger stays silenced; the dead block logic stays
  unactivated. Read the plan for why; do not re-decide them here.

---

## The order, and why it is one direction of travel

The slice body sets it: **owner, then edges, then payload.** A change to
lane identity alters which events a boundary rule even sees; a boundary
change alters what the writer is handed. Fixing the writer first would mean
fixing it twice.

## Step 1 — `b57c7515` and `9202b39d`: one stretch of work, two lanes

Take the two together, because the first decision is shared: **does lane
reconciliation happen once, where lanes are formed, or in each pairing
function?** Both bodies reach "once" from opposite directions. Measure before
designing, as `b57c7515` asks: how often an id changes mid-session over the
whole queue history, and whether the transcript's `sessionId` or a
`leafUuid` chain can bridge the two files retroactively — the events carry
enough to re-pair if something looks.

Then the two fixes, which stay two even if the reconciliation is one: the
clock bracket (`--lane-clock-pairs`) and the turn (`--span-events`). The
surviving leading-`pause` rule is a special case of whatever lands; keep its
measured result (0.62 h, one firing) as a regression fixture, and add the
second shape `b57c7515` found, which that rule never fires on.

**The test that matters replays the corpus.** Each body carries exact
timestamps and session ids; the fixture is the `.jsonl`, and the assertion is
an hour total, not a string. The falsified counter was believed for three
days because it was argued rather than run.

## Step 2 — `7d739afd`: wire the union where totals cross headings

The smallest member and mostly a wiring decision. Wire
`--merge-time-intervals` at report time — clocktables and totals across
headings — and leave CLOCK lines alone, which is what the 0.5% measurement
recommends. **Do not decide the CLOCK-line half**; say in the debrief that it
stays open, and why the number makes it cheap to leave open.

## Step 3 — `c9940558`: a project boundary splits

Treat a `cwd` change as `--aggregate-guideposts` already treats its
exclusions: a boundary splits rather than clusters through. Two consequences
to handle in the same change: each span's annotation then names one tracker,
and a worktree's cwd must normalise to its main checkout first or one project
becomes one span per worktree (`5461c349`'s second obligation — `config.el`
already knows the `gitdir: <main>/.git/worktrees/<name>` shape). The two
measured groups are the fixture. This is the euchre blocker in the slice;
say so in its close.

## Step 4 — `c54c4215`: emit the complement, and see the consumed

Two halves, as the body says. Emit the complement segments of (span minus
exclusions) — a span reduced to nothing yields no item; interior gaps yield
one item each. Then widowing: let the aggregator consult consumed events when
deciding whether a lone timestamp is genuinely lone. Decide whether the
zero-width endpoints are still worth rendering once the gaps are offered;
that is presentation, and it may answer itself.

## Step 5 — `2deb090f`: accepting a 0-run span claims its minutes

Last, because it is the writer, and everything above changes what it is
handed. One act that accepts the envelope as attention, distinct from `e`'s
correction of bounds; the bracket style is a red herring (the CLOCK line is
always written inactive). Read `01849bef` first — same keystroke family, same
question of what the assertion means — and `996fd2bd` for the automatic half.
**Then audit the task headings**: the 99-minute figure covered one heading
family; the true total is the number that belongs in the debrief.

### Where this will stop

Step 1 is the deliverable core and the hardest: after it, one stretch of
work has one owner however many session ids it crossed, and the corpus
replay is the proof. Steps 2 and 3 are small once Step 1's lane model is
settled. Steps 4 and 5 are the edges and the payload, each with a
ready-made fixture.

A session that ships Step 1 with the corpus replay green, then Step 3 for
the euchre blocker, has done the slice's day well. **The slice closes when
its pull request merges**, not when its last member goes terminal — and
when it does, `406e9200` has no open children left and wants its own close,
which is that story's decision and not the slice's.

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
