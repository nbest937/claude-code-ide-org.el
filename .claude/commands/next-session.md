# Next session

A plan for `8a2eb687` — **Everything passed and the file was still wrong** —
third of the four slices sequenced below.

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
| 1 | `35582d95` — **PR #24** | smallest, and every member was a day-one defect in the repo the plugin was already deployed to on 2026-09-11 |
| 2 | `749301a0` — **PR #25 open, back at `DOING`** | its review adopted three findings; `83773daf` is the one still live, and the slice cannot close until it is resolved or dropped |
| 3 | `8a2eb687` — this one | the correctness slice; holds euchre blockers `965f94eb` and `5e731a23`, plus `2aeb65d6`, which is what would make future parallelism safe at all |
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

Every item below was measured this cycle, most of it while auditing
`749301a0`'s own branch. Do not re-derive the falsified ones; do re-check the
caveats.

- **`37bca83a` is re-diagnosed, and its old body is wrong on purpose.**
  `org_query` drops no predicate and never did — its input is org-ql's
  *plain-string* mini-language, so every sexp ever passed to it was parsed as
  whitespace-separated full-text terms. Measured 2026-09-16:
  `tags:research` → 24 headings, `todo:REVIEW` → the three live ones,
  `property:KIND=slice` → every slice. **Do not re-measure "which predicates
  are dropped."** The fix is one decision: a query whose first non-blank
  character is `(` is a sexp, so either parse it as one (`org-ql-select`
  takes sexps natively) or refuse it naming the mini-language. The earlier
  paragraphs on that heading are left standing and are *known false*; read
  the correction at the bottom.

- **`f12f9da4` has two shapes, not one**, both recorded 2026-09-16 while
  recovering a hung Emacs: a stale `.elc` shadowing the source, and the same
  file loaded from an older state with nothing saying so. Any check run
  against either looks exactly like a passing one, which is this slice's
  whole theme in one heading.

- **The `[0/17]` cookie counts three members that are already `DONE` and
  dropped** — `542924c1`, `d2a0f54c`, `72463b68`. The cookie is right and the
  denominator is not the work.

- **`2a6a1355` sits at `REVIEW`** and is *not* in this session's sequence. Its
  marker half was retired rather than fixed on `749301a0`'s branch; what
  remains is a judgement call, not an implementation.

- **`4acd8ad0` is downstream of work that just landed.** The re-key bridge
  shipped in `749301a0`; this member is the observation that the transcripts
  it reads are pruned by Claude Code, so the alias decays silently. It wants
  the bridge in hand, which it now is.

---

## The order, and why it is one direction of travel

The theme is a check that cannot fail, so the sequence runs from *what makes
a verification trustworthy* outward to *what a verification is asked about*.

Starting anywhere else re-runs the same risk the slice is about: every later
step is verified in a live Emacs, and until `f12f9da4` lands there is no
signal distinguishing "the fix works" from "the fix was never loaded." That
is not a theoretical ordering argument — it cost this cycle a hung Emacs and
three separate faults before anything was measurable.

Then the two tools that *answer questions* about the corpus (`39039bb6`,
`37bca83a`), because a wrong answer from either is silent and is read as a
fact. Then the one that *destroys* an answer (`7ee3b71a`). Then two places
where prose and behaviour disagree (`7b4f4f14`, `60ed5b96`), which are small
and are the theme in miniature.

**Six members, not seventeen.** The rest stay in the slice; a slice spans
sessions by design, and this file is a revision of the prompt rather than a
new slice.

## Step 1 — `f12f9da4`: make a stale load say so

The precondition rule (`~/.claude/CLAUDE.md`, and the org-dev skill §0) asks
every session to *state* what must be reloaded. This step gives that
statement something to check itself against. Both shapes need covering, and
the second is the one no existing check sees: the file on disk and the
definition in the image can differ with no `.elc` involved at all.

Land it first and use it for every step after. If it cannot be made to work,
say so and reorder deliberately — do not proceed on the assumption that a
green check means a loaded fix.

## Step 2 — `39039bb6`: a duplicate `:ID:` across the two files

`bin/lint-org` is the backstop for corpus integrity and it checks each file
alone, so an id present in both `TODO.org` and `DONE.org` passes twice. Every
tool here addresses headings by `:ID:`, and `org-id` resolves to whichever it
finds — so a duplicate is not a cosmetic problem, it is two headings wearing
one address.

Check the corpus for existing instances *before* writing the rule, and say
the number either way: a rule added while clean is the cheap case this repo
prefers, and a rule added while dirty needs the repair sequenced with it.

## Step 3 — `37bca83a`: refuse a sexp, or parse it

The mechanism is settled (above), so this is an implementation, not an
investigation. Two shapes, and picking one is the whole step:

- **Refuse**, naming the mini-language. Cheapest, and it makes the tool's
  contract visible at the moment it is violated.
- **Parse it as a sexp.** `org-ql-select` takes one natively, so this is
  plausible and strictly more useful — at the cost of a tool that accepts two
  languages, which is how the confusion started.

Either way the *silent* path must go: "No matches." may never again be the
answer to a query the tool did not understand. Note that every caller in this
repo's history got the language wrong, which is evidence about the tool
description as much as about the callers.

## Step 4 — `7ee3b71a`: `org_amend replace=true` over a slice's checklist

The one thing a slice *declares* is membership and order; everything else is
derived. A `replace=true` amend over a slice body destroys exactly that, and
the refresh will not rebuild it, because the refresh reads the checklist to
know what the members are.

Guard it at the tool, not in prose. Note the shape this repo keeps finding —
`org_set_property` refuses `:ID:` and `:CREATED:` for the same reason — and
check whether the guard belongs to slices alone or to any body carrying a
structure a tool derives from.

## Step 5 — `7b4f4f14`: `apply-detect` on a dismiss-only pass

The hook compares `.applied` watermark mtimes and injects "the record is
fresh, a tracker diff may await a bookkeeping commit." A pass that only
*dismissed* events moves the watermark and wrote nothing to an org file, so
the session is told to go look for a diff that does not exist.

Small, and worth it because the hook exists precisely to stop a session
announcing something untrue.

## Step 6 — `60ed5b96`: a docstring contradicting its own `let*`

Four lines apart, in `--review-format-annotation`. The smallest member here
and the purest statement of the slice's title: nothing failed, nothing was
wrong at runtime, and the file said something false to every reader.

Read the `let*` and rewrite the docstring to it — not the reverse, unless the
code turns out to be the thing that drifted, which is a finding worth saying
out loud.

---

## Where this will stop

Six of seventeen. A session that lands Step 1 and Step 3 has done the slice's
day well: the first makes every later verification mean something, and the
third closes a defect that has already misled one session into answering a
corpus question with `awk`.

**The slice closes when its pull request merges**, not when its last member
goes terminal — `749301a0` is the standing demonstration, having gone back to
`DOING` from `REVIEW` when its own review found three things. Expect the same
here and leave room for it.

**And measure the slice itself**, as `749301a0` was asked to: members, elapsed
days, commits, review findings per member, and
`M-x claude-code-ide-org-attention-report` over its span, compared against
`afea7e4f`, `35582d95` and `749301a0`. Three comparisons now exist, which is
the first point at which the question "are slices going better?" has a trend
rather than a pair.

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
