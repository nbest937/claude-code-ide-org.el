# Next session

Rewritten 2026-08-28, replacing the prompt that drove `979e02b6`. That slice
closed the declared-versus-inferred gap; this one opens `b36e6369`.

**The slice is the list.** Do not re-derive it — open `b36e6369` and read its
checklist. Its predecessor `979e02b6` closed 2026-08-31 at 48/48.

**What the slice is about**, since its body deliberately does not repeat it:
the tools *know* things they do not report — a span's real interval, which ids
a blocker names, whether an event will change anything — so a human reads a
number that is not the number. And they *ask* for things they should not:
clearing a read-only flag by hand, setting a keyword in a second call,
retyping what the tool already resolved. The title borrows `6cc71c36`, which
named the first half: *the code knew more than it said*.

Measured in the session that composed it: the read-only clear/restore dance
ran about twelve times; `writes 0:01 in 1` was rendered over a nineteen-minute
span with no way to tell which number meant what; a `:BLOCKER:` error cleared
itself only on apply; and three verification traps fired twice each, every one
a *silence* read as a pass. Each line carries the member's id, current keyword and title, and
the `:BLOCKER:` names every member still carrying a cookie.

---

## Before anything else

1. **Confirm `emacs-tools` is reachable** by calling `org_pending_updates`.
   It is read-only, and a reply proves the server is up in a way that seeing
   the tools listed does not.
2. **Apply the queue before composing anything.** A heading captured this
   session is keywordless until you do, so a `:BLOCKER:` naming one is inert
   and `bin/lint-org` errors — which `.githooks/pre-commit` refuses. That is
   not a defect to fix; it is `c74f8663`, a member of this slice, and it cost
   this slice a commit on 2026-08-28.
3. **Two tools added 2026-08-28 that predate no habit yet**: `org_divide`
   (task mitosis — insert a parent above a heading and demote it under, id and
   history staying with the child) and `org_set_property` (set a property by
   `:ID:`; `:BLOCKER:` is validated, prefixes expanded, `append` unions).
   Reach for the second instead of `emacsclient` + `org-entry-put`, which is
   still the reflex.

---

## What is already true, so it is not re-derived

- **`org_outline` scoped to one heading now leads with that heading's front
  matter** — `:CREATED:`, `:CATEGORY:`, `:KIND:`, the `:BLOCKER:` *value* with
  each id's current keyword, and the plan file. "What is this, what blocks it,
  what is under it" is one call and no body read.
- **`scope` accepts an 8-character `:ID:` prefix**, and an id-shaped scope that
  resolves to nothing says so rather than reporting a missing file.
- **`PLANNING` is retired** (`c954f650`). The sequence is
  `TODO → NEXT → DOING → {WAITING, REVIEW} → DONE`. The `ExitPlanMode`
  promotion hook is gone; Plan Mode needs no state change of its own.
- **A slice's blocker culls finished members**, so it shrinks as the slice
  progresses and is empty when every member lands.
- **A story member's relevant children are nested under it** as indented
  member lines — not every child, the ones that belong to this slice, and
  especially any that blocks another member.
- **`a` in the review buffer no longer advances.** Assigning makes a line
  markable rather than finishing it.
- **`M-x claude-code-ide-org-goto`** jumps to a heading by title, with the
  8-character prefix leading each candidate so an abbreviation is typeable.
  Interactive only — no MCP registration, no schema cost.
- **A closed slice is a record, not a projection.** `refresh-slice` skips a
  slice whose own keyword is terminal, so later work cannot rewrite finished
  history. A cookie-less line in a closed slice means the slice is *done
  with* that member, not that it was cancelled.
- **Slices are exempt from the `:PLAN:` lint and are not wrapped at close.**
  That lifecycle protects a reader from a closed *task's* design claims; a
  slice designs nothing.
- **The twin asymmetry has a name** (CLAUDE.md). Ask it as a review question
  on any list: *does anything here have a twin that is not here?*

---

## Two traps that are specific to editing a slice body

Both were hit while composing `b36e6369`, and neither is obvious.

- **A slice's member list must sit in the slice's own body, above any
  subheading.** `--slice-members` stops at the first subheading, so a `**
  Members` section puts the whole list out of reach — the refresh silently
  found zero members and wrote an empty blocker.
- **Do not write `- [[id:...]]` bullets as prose inside a slice body.** A
  cookie-less list item carrying an id link is exactly the shape reserved for
  a *cancelled or deferred member*, so prose bullets are read as members. Name
  ids as `=c74f8663=` in prose instead; `orgit-rev:` links are safe.

---

## Suggested order

The checklist is already in dependency order, in five phases.

1. **Clear dead wood** — `46d225c7`, `c31b6c76`, `5a5e87c9`. `c31b6c76` and
   `5a5e87c9` are **twins** — both time-of-day test flakes — so do them
   together or neither; see CLAUDE.md on the twin asymmetry.

   `915378ac` was also a phase-1 member and is already **DONE**: it was built
   on 2026-08-29 to close `478d6ec9` and unblock the *previous* slice, so it
   was consumed by that slice's endgame while listed in this one. Nothing is
   wrong — the checkbox is honest — but it is the reason this phase is
   shorter than the list suggests.
2. **Stop fighting the tools** — `c8a97d9d`, `2b2db914`, `c74f8663`,
   `a0028a4e`. The last is the body read `ff1352b3` decided: return a heading
   whole, drawers included, and let the caller extract. It replaces
   grep-plus-awk-plus-Read with one call.
   `c8a97d9d` is the largest felt win and the smallest change: its own child
   already bound `inhibit-read-only` in the apply path and the other write
   tools never followed. Measured: the clear/restore dance ran about twelve
   times in one session.
3. **The review buffer says what it means** — `6cc71c36`, `98c302e0`,
   `9e627dc0`, `44cef181`, `46e4ce2b`, `05c71d99`, `8d0716fe`, `b6e229c7`.
   Do the audit *with* the wording fixes, not before: a one-word repair beside
   an unchanged line three rows down is worse than uniform terseness. And
   `9e627dc0` is here because both its body and `98c302e0`'s say the readout
   rework and the turn-count surfacing must be **one pass** — only its
   review-buffer half is in scope.
4. **The files stay orderly** — `0086614a`, `c60a1c53`, `5f1068f9`,
   `33864a0f`, `b7b46a26`, `8c662dfb`. Two twin pairs in here: `5f1068f9`'s
   own body says its DONE.org counterpart `33864a0f` is "worth doing in the
   same pass rather than twice" (and `b7b46a26` blocks it), while `c60a1c53`
   is `0086614a`'s — one lists the work a slice did not plan, the other flags
   what should have been a member and was not. Same computation, different
   verdict.
5. **The checks learn** — `542924c1`, `d2a0f54c`.

### Where this will stop anyway

Every decision is taken, but the slice **cannot** run wire to wire, and the
reason is architectural rather than a gap:

- **Apply is human-only, by design.** A heading captured during the slice is
  keywordless until someone applies, so a `:BLOCKER:` naming it is inert,
  `bin/lint-org` errors and `pre-commit` refuses. Every capture-to-commit
  cycle therefore crosses a human. `c74f8663` narrows this — a capture that
  passes `initial_state` is keyworded immediately — but it is *in* phase 2, so
  everything before it still stops, and apply itself never becomes automatic.
- **`c8a97d9d` until it ships.** Every write tool needs the read-only flag
  cleared and restored by hand; it ran about twelve times in one session.
- **Judgement inside the work, not before it.** `6cc71c36` is an audit — "does
  this wording distinguish what the code knows?" is a call per site.
  `b6e229c7` has to decide which state items carry no judgement. `c60a1c53`
  needs a threshold for what counts as a forgotten member. `7c4d6ef6` is a
  settling task by definition.
- **`02aaae22`**, the one body in `8c662dfb` that was ever revised. Do it last
  or leave it.

Expect long unattended stretches in phases 1, 2 and 4, and frequent checkpoints
in 3 and 5.

**Cut line: stop after phase 3.** Phases 1–3 are one argument about the gap
between what the tools know and what they say; 4 and 5 are hygiene and can
wait for a session with less momentum.

---

## Decisions taken, all five — nothing waits on the user

- ~~`ff1352b3`~~ — **decided 2026-08-31: two tools, not three, and not a
  mode.** The property schema splits two ways: `BLOCKER` (23) is the only
  property naming another heading, `CATEGORY` and `KIND` are already expressed
  as the outline's grouping and behaviour, and everything else describes one
  heading. So the outline carries relationships and the body carries the rest.
  Filed as `a0028a4e`. Whether `org_outline`'s front matter then shrinks is
  sequenced after it, not decided now.
- ~~`c74f8663`~~ — **decided 2026-08-31: option 1.** `org_capture` gains an
  optional `initial_state` and writes the keyword with the heading. A creation
  has no prior state, so nothing is hidden from the review pass; every
  *subsequent* transition still routes through the queue. Buildable
  unattended.
- ~~`5f1068f9`~~ — **decided 2026-08-31: approach A.** One
  `(org-sort-entries nil ?R nil nil "CREATED")` with point before the first
  heading; the anchor sorts last on its own. Its one objection — that the
  anchor is last by an *absence* — is answered by a lint assertion that the
  `:DATE_TREE:` anchor is the final level-1 heading, not by a fabricated
  timestamp. Moving the datetree to its own file stays open and is not
  foreclosed. The first sort is a large reordering and wants its own commit.
  Buildable unattended.
- ~~`8c662dfb`~~ — **settled 2026-08-31 by measurement.** Measured across all 472
  commits: **nine of the ten bodies have never lost a line**, so this
  heading's own test ("was it ever revised, or only appended to?") answers
  itself for nine, and compress-then-wrap applies with no per-heading call.
  Only `02aaae22` shows a shrink, and it is the one container in the list, so
  do it last or leave it. The nine are unattended work.
- ~~`b7b46a26`~~ — **decided 2026-08-31: option B.** Write `CLOSED:` from git
  for the 39 headings that lack one, and mark each `:CLOSED_SOURCE: git`. The
  question turned on whether anything reads `CLOSED:` as a *measurement*:
  nothing does — `org-archive-subtree` uses it as a placement key,
  `bin/lint-org` as a threshold, `f4b07fc0`'s backfill as a presence test — so
  the machine case for refusing an approximation does not exist, and the
  marker exists for the human, which is `7771fc63`'s ground. 13 of the 39
  already have git-derived times in `38b92521`'s manifest. Buildable
  unattended.

Everything else in the list is buildable unattended.

---

## Standing rules, with what actually happened

- **Ask Emacs, not a regex.** `org-map-entries` bounds entries by
  construction and is the parser of record. Two scans by regex were wrong the
  same way in one session: an `:ID:` extraction matched a line in the
  *previous* heading's body, and a scan for headings lacking `:CREATED:`
  walked into a datetree and answered 0 where the answer was 1. The org-dev
  skill's §0b now covers reading, not just building.
- **Silence is not a pass, and it lied three ways in one session.**
  `bin/test` writes to **stderr**, so a bare pipe shows nothing while exiting
  0. A deliberately broken file made the suite exit **255** having run no
  tests, and a count of `FAILED` lines read that as success. Check the
  `Ran N tests` line and the exit code, never the absence of a word.
- **`check-parens` is not a syntax check.** An unescaped `"` inside a
  docstring terminates the string and turns the rest into code while parens
  stay balanced. It happened twice, and cost nine spurious failures the second
  time. Read forms instead — but **bound the loop**, because
  `(while t (forward-sexp))` only terminates when the file is *broken*
  and spins forever on a clean one (found by running it, 2026-08-29):

  ```elisp
  (while (not (eobp)) (forward-sexp) (skip-chars-forward " \t\n"))
  ```

  wrapped in `condition-case`, which reports the line the reader actually
  gives up on and terminates either way.
- **A mutation that does not parse proves nothing.** Break semantically —
  invert a predicate, return nil — and confirm the run count before the
  failure count.
- **A splice whose two markers can be mis-ordered must assert their order.**
  Replacing a region with `body[:start] + new + body[end:]` silently
  *duplicates* everything between them when `end < start`. It happened to a
  slice body on 2026-08-29: the revision links sat before the section being
  replaced, and the cookie went *up*, which read as plausible on a slice that
  had just grown.
- **A sentence describing an action is not the action.** Twice: a source
  comment reading "Removal is filed" when nothing was, and a reply announcing
  an edit to a saved file that had not been made.
- **Never type a UUID from memory.** Two were fabricated in one session; the
  tools refused both. Write the 8-character prefix and let the tool expand it.
- **A sentence claiming something was filed is not a filing action.** One was
  written into a source comment and was false for hours.
- **Footnote every tracked `:ID:` in every response**, with its exact title
  looked up rather than recalled.
- **Never `git stash` to compare.** Copy the file aside.
- **Never pass `--no-verify`.**
