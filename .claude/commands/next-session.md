# Next session

A plan for `ff7ccb2d` — **Make the org discipline travel: ship the machinery,
relocate the rules** — at **[0/12]** across 20 member lines.

**The slice is the list.** Open it and read its checklist; this file gives
the plan, not the membership. The two disagree only if one is stale, and the
slice wins.

---

## Step 0 — preliminaries

Not specific to this slice. Every item here is on the list because skipping
it cost a past session real work.

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
4. **Confirm the new branch will be cut at a commit that already contains
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
5. **Then cut `feature/<short-name>` from the settled base.** What earns a
   branch is wanting a separate integration point, which a new slice always
   is — so do not continue a slice on the branch of the one before it, even
   when that branch is still open.
6. **Do not run `org-id-update-id-locations` prophylactically after
   `org_capture`.** A previous revision of this file prescribed it. It did
   not fire once across five capture-then-amend pairs on 2026-09-03. If an
   amend fails with "no org heading found", *then* it is the fix — and that
   recurrence is worth recording.

---

## What is already true, so it is not re-derived

**`.claude/rules/` is not a plugin component.** Verified against the plugin
docs 2026-09-02 and recorded on `9ae4b17e`, along with the measurement
that roughly **660 of CLAUDE.md's 1196 lines** describe machinery that would
ship and currently has no way to. That asymmetry is this slice's whole
premise. Do not re-measure it.

**Three write paths now refuse to mint a slice/container hybrid**, asking one
question between them: `--subtree-has-keyworded-heading-p` (arrival, differs
from `--container-heading-p` by exactly the root),
`--enclosing-slice-title` (target, an ancestor walk and *not* `:KIND:`
inheritance), and `--blocker-keyword-inside-slice-p` on `org-blocker-hook`
(the grant, where nothing arrives). The last denies the grant only, so an
existing hybrid can still be closed on its way out.

**The commit gate's own suite is green again.** `bin/pre-commit-test` ran 5/8
for days because its fixtures still built the level-1 `* Category` tier
retired on 2026-08-27. And `bin/check-conventions` with a mistyped flag used
to run **zero assertions and exit 0**; unknown flags and unreadable roots are
now exit 2, distinct from 1.

**`bin/clock-target-check` has a test harness now** — 12 checks. It shipped
without one, which is how both of its defects reached a code review instead
of a suite.

---

## Step 1 — Classify what must travel

`9ae4b17e` — *Make the org skill and its discipline portable to other
repos*. The `NEXT` member, and every step below assumes its answer. This is a
classification, not typing: which rules are general org convention (portable,
belong in the skill), which are this project's own (stay), and which are
machinery whose prose has nowhere to go.

The paired decision, `1caed585` — *Decide what this module may change on a
user's machine when installed* — is **dropped, not pending**. The slice declined it deliberately; a `MAYBE` in
the blocker set would hold the slice open for work it decided not to do.

## Step 2 — Relocate, then prune, in that order

Two members, and the order is a declared `:BLOCKER:` rather than a
suggestion. First `d5345abb` — *Audit CLAUDE.md for directives that belong in
the org skill instead*. Only then `9d009401` — *CLAUDE.md carries dated
history that costs every session's context* — nested under `02aaae22`, whose
line is a grouping label. Pruning before the classification risks deleting
rules a consuming project needs.

**The prune (`9d009401`) is explicitly reserved for the user.** Four
decisions are enumerated on its heading and ten retirement blocks sized. Do not run it as a
background pass.

## Step 3 — Close the machinery's undeclared assumptions

Three members, each of which fails on a second machine and nowhere here:

- `1ed7b2b4` — *The org 9.7+ dependency is real, undeclared, and unenforced*
- `84b7d8b3` — *Evaluate choice of shell and standardize all project scripts*
- `f8c86914` — *The convention checks compare the live Emacs against whichever
  checkout invoked them*

All three carry recorded options and no decision.

`84b7d8b3` was promoted out of `MAYBE` while this slice was composed, on
evidence: `fish` stopped being one leaf script's inconsistency
and became a prerequisite for committing, via `bin/check-conventions` and
`.githooks/pre-commit`.

## Step 4 — Multi-project instrumentation

Meaningful only *after* the hooks move, which is why all three name
`9ae4b17e` in a `:BLOCKER:`:

- `5461c349` — *Record cwd on queue events, so a span can be attributed to a
  project*
- `83b3cdd6` — *Record the originating project in queue events*
- `b862fbf4` — *Allocate attention across concurrent sessions, which is
  zero-sum*, the judgement the other two exist to make possible

`5461c349` and `b862fbf4` are children of `f90d745e`, a story the slice does
not undertake whole, so its line is a cookie-less grouping label. **That label
is not a drop.**

## Step 5 — The reader-facing tail

Three members that can proceed independently of everything above:

- `d7849119` — *Add README.md and enforce its consistency with CLAUDE.md*
- `b07df584` — *Heading bodies grow into narratives no human will read; decide
  what to stop capturing*
- `c5b02503` — *Hook-injected context is only as reliable as the model
  choosing to relay it*

This is where to go if the answer to Steps 1–3 is "not now."

## Step 6 — Reconsider the five `MAYBE`s

**They are members for serious reconsideration, not decoration.** Once Steps
1–5 are `DONE`, take each one up again and decide whether the slice's own
work has changed its merit — that is the point of carrying them rather than
leaving them out.

- `e396f94a` — *Package the Warp wiring*
- `2e09adb7` — *Worktree-based session partitioning, with a canonical-file
  caveat*
- `3cb3f955` — *Org skill: commit a newly-captured TODO immediately, when
  safe*
- `7eb7dd8d` — *Org skill: auto-capture and dedupe modification requests
  against existing TODOs*
- `2c5f7c50` — *Install orgparse for ad-hoc analysis, and stop reaching for
  regex over org text*

**Promote earlier if evidence arrives along the way** — that is what happened
to `84b7d8b3` in Step 3, whose body's central factual claim had
quietly become false. The test is the same one used there: the reason must be
in the artifact, not in enthusiasm.

Two of the five already carry a note saying what would have to change first.
`7eb7dd8d` is specified in terms of the retired `PLANNING` keyword, so it
needs restating before it can be started at all. `2c5f7c50`'s body argues
against its own proposal, and the evidence keeps landing on that side.

### Where this will stop

Almost immediately, and by design. Step 1 (`9ae4b17e`) is judgement. All
three of Step 3's members carry enumerated options with nothing chosen. Step
2's second half (`9d009401`) is reserved for the user outright. A session starting here should expect to
**ask and record**, not to plan a wire-to-wire run. Step 5 is the only place
to make unattended progress.

---

## Standing rules, with what actually happened

- **Never type a UUID from memory.** On 2026-09-03 this slice's 20 member
  lines were *generated from `TODO.org`* and the result diffed against what
  landed. One full id was not what recall offered. Generate, then diff; do
  not proofread.
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
  byte-for-byte from `plans/` — which is what that archive exists for.
- **`command` before a shell builtin is not a safety measure.** `command cd`
  skips fish's builtin for an external no-op, so `pwd` reported the wrong
  directory and every check silently ran against the wrong tree. Two existing
  assertions caught it in under a minute.
