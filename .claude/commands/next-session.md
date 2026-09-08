# Next session

A plan for `52bfafdf` — **Only membership and order are declared, and
everything else still needs a hand**.

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
6. **Then cut `feature/<short-name>` from the settled base.** What earns a
   branch is wanting a separate integration point, which a new slice always
   is — so do not continue a slice on the branch of the one before it, even
   when that branch is still open. **Maintenance between chunks of real work
   may land on `main` directly** and should: applying the queue, debriefing
   an already-merged heading, filing. A branch per bookkeeping commit is the
   jitter CLAUDE.md's rule was relaxed to stop.
7. **Do not run `org-id-update-id-locations` prophylactically after
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

**The refresh undoes hand-repair, measured twice.** Members removed from a
slice's incidental list by hand were restored by the next
`claude-code-ide-org-refresh-slice`, because the derivation adds what it
does not already find named. So a wrong incidental list is **not** to be
tidied while waiting for the fix — read it as unreliable instead. This is
the single most useful fact in this file.

**The scale of that wrongness, measured 2026-09-08.** Three closed headings
(`f1ff027e`, `d585d33e` and the closed slice `ff7ccb2d`) appear as
incidentals of *every* open slice. `c19fbbf5`, composed that day and never
worked, lists three incidentals that closed before it existed — the window
has no left edge for an unstarted slice, which is the failure `f9fe9fac`
hit before at 26 incidentals. And a **slice appearing as another slice's
incidental** is contemplated by no rule at all. Two predicates are needed,
not one: ownership, and excluding `:KIND: slice`.

**No tool adds a member line to a slice.** Every membership edit this
session went through a hand-written `emacsclient` call or a direct file
write; the latter caused a buffer/disk divergence that took a manual merge
to repair. `org_set_property` handles `:BLOCKER:` correctly, including
against a read-only buffer; nothing handles the checklist line or the
cookie. That is `635d5abb`'s subject, and the reason it is the Tools
nomination.

**A long `emacsclient -e` form fails on shell quoting.** Write the elisp to
a file in the scratchpad and `(load "…")` it instead — two attempts died on
`End of file during parsing` before that. And a region-replacing edit must
have its end anchor checked: the first rewrite of this slice's own prose
clipped a sentence mid-clause, which was caught only by reading the result
back.

**Both `NEXT`s on the list are correct.** `635d5abb` holds Tools' top-level
nomination and `501a8422` is the `4c834fdb` story's internal one. A slice's
member list showing several `NEXT`s is the convention working — members are
references, and those are other groups' nominations showing through.

---

## Step 1 — Make the derivation trustworthy

`2c77f2cc` — *One incidental lands in every open slice's window, and the
cookies double-count it*. First deliberately, and the ordering was changed
to put it there: it is the only member producing visible garbage on every
refresh rather than waiting to be noticed, and until it lands **no slice's
cookie can be trusted, including those of the slices every other member is
judged by**.

The rule is decided, not open: an incidental completed during a slice in
progress belongs to that slice alone. What remains is implementation
judgement — how the derivation decides which slice was in progress when the
work closed (the natural candidate is the slice whose own members' clocks
interleave the close, falling back to most-recently-worked), plus the
second predicate excluding `:KIND: slice` outright, plus the left-edge fix
so an unworked slice derives an empty list rather than an unbounded one.

Wants a regression test with two open slices and one incidental. Expect the
fix to change several slices' cookies the first time it runs; that is the
point, not a regression.

## Step 2 — Close the `org_amend` targeting gap

Two members, one edit to one function, and they are the reason Step 1's
work is awkward to record while it is happening.

- `635d5abb` — *org_amend cannot continue a list, and the slice revision
  links are always one*. **Tools' `NEXT`.**
- `501a8422` — *Give org_amend a drawer argument, so a plan can be revised
  and written in one call*. The `4c834fdb` story's internal `NEXT`; its
  subject is not a slice, and it is carried here because it is the same
  function and the same defect class. Drop it if that reads as scope creep;
  nothing else depends on it.

The argument for doing them together is on `635d5abb`: the workaround for a
missing target is a direct file write, which leaves Emacs's own copy behind
— the failure the queue exists to prevent everywhere else.

## Step 3 — Make the property rather than reporting it

`acf46449` — *Every slice needs `:COOKIE_DATA:` and no slice creates it;
the lint only reports*. The heading carries both seams: repair at refresh,
prevention at declaration in `org_set_property`'s `:KIND: slice` branch,
and its own conclusion that they are complementary rather than
alternatives, since a slice can be declared by hand.

**Measured 2026-09-08 and recorded there:** composing a slice declared cost
two extra `org_set_property` calls and a hand-typed cookie, all three being
values a mechanism already knows how to derive — and the lint came back
clean, so the friction is composition cost rather than a lint failure. Note
the ordering constraint that measurement exposed: the checklist must exist
before a `:BLOCKER:` can be derived from it.

## Step 4 — Retire the proposal convention

`7f0c9baa` — *The proposal convention's last argument is falsified; an open
slice is its own proposal*. Independent of everything above, and a
convention decision rather than code: edit `.claude/rules/org-conventions.md`,
retire §"Proposing a slice", and **relocate the twin review question that
currently lives inside it** — that paragraph is independent of proposals and
must survive its host.

It has already claimed one member: `198dd00e` was cancelled on this
heading's arrival, since with no acceptance moment there is no body left
calling itself a proposal. Its one surviving fragment — a worked slice
carrying no `orgit-rev:` prompt link — moved to `d749ebd5`.

Open on the heading, deliberately: whether anything replaces the `MAYBE`
signal for an uncommitted slice. The candidate answer is that nothing need
— an unstarted slice has no clocked members and no `DOING`.

## Step 5 — The independent three

Independent of each other and of everything above; take them in any order,
or as the place to make progress when a decision above is not yours to
make.

- `2d2211d5` — *Adding a just-captured heading to a slice cannot be made
  lint-clean*
- `de687e4d` — *A slice closed by the same apply pass freezes with stale
  member lines*
- `1b727475` — *A MAYBE member and a dropped member render identically, and
  the drop is now sticky*

`1b727475` has recurred visibly: this slice's own body carries a sentence
distinguishing its cookie-less lines by hand, because nothing else does.

## Step 6 — Automate the refresh

`d749ebd5` — *The ceremony should refresh open slices, so incidentals and
cookies stop waiting on memory*. Last because it is the pass that makes
everything above stop needing a human to remember it, and it should
therefore run against a derivation that is already correct.

Two things it now owes, the second inherited: refresh every open slice as a
fourth idempotent step in the ceremony's post-apply flow, beside drawer
consolidation and heading separation; and **report a worked slice carrying
no `orgit-rev:` prompt link**, which it can detect even though only the
composer knows which revision applies.

### Where this will stop

Later than the last slice, because most of this is code with a decided
rule behind it rather than a judgement waiting on the user. Step 1 is a
contained fix in one function; Steps 2 and 3 are named seams; Step 5 is
three independent defects. The one place to expect a stop is **Step 4**,
which edits a convention file and relocates prose — and its `MAYBE`-signal
question should be answered rather than assumed.

**A caution particular to this slice:** it is *about* the machinery that
maintains slices, so every member changes how this very list renders.
Re-read the slice after each landing rather than trusting the copy you
started from — and expect cookies to move for correct reasons.

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
  than letting the log misattribute the work.
