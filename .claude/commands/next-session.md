# Next session

Rewritten 2026-08-28, replacing the prompt that drove `979e02b6`. That slice
closed the declared-versus-inferred gap; this one opens `b36e6369`.

**The slice is the list.** Do not re-derive it — open `b36e6369` and read its
checklist. Its predecessor `979e02b6` closed 2026-08-31 at 48/48. Each line carries the member's id, current keyword and title, and
the `:BLOCKER:` names every member still carrying a cookie.

---

## Before anything else

1. **Confirm `emacs-tools` is reachable** by calling `org_pending_updates`.
   It is read-only, and a reply proves the server is up in a way that seeing
   the tools listed does not.
2. **Apply the queue first, and note that the slice cannot be committed until
   you do.** `b36e6369` was composed with three of its own members captured in
   the same session, so its `:BLOCKER:` names three keywordless headings and
   `bin/lint-org` reports three errors — which `.githooks/pre-commit` refuses.
   That is not a defect to fix; it is `c74f8663`, a member of this slice,
   demonstrating itself.
3. **Two new tools exist as of 2026-08-28 and are callable from this session
   for the first time**: `org_divide` (task mitosis — insert a parent above a
   heading and demote it under, id and history staying with the child) and
   `org_set_property` (set a property by `:ID:`; `:BLOCKER:` is validated,
   prefixes expanded, `append` unions). Reach for the second instead of
   `emacsclient` + `org-entry-put`.

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

1. **Clear blockers and dead wood** — `915378ac`, `46d225c7`, `c31b6c76`,
   `5a5e87c9`. `915378ac` is the last open child of `478d6ec9`, which is
   blocking the *previous* slice. **Closing that container is its own step** —
   a container at `[10/10]` does not close itself — and the previous slice
   *still* will not close, because `9651d4c8` gates it and needs the user.
   `c31b6c76` and `5a5e87c9` are twins: both are time-of-day test flakes.
2. **Stop fighting the tools** — `c8a97d9d`, `2b2db914`, `c74f8663`.
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
4. **The files stay orderly** — `0086614a`, `5f1068f9`, `33864a0f`,
   `b7b46a26`, `8c662dfb`. The middle three move together or not at all:
   `5f1068f9`'s own body says its DONE.org twin is "worth doing in the same
   pass rather than twice", and `b7b46a26` blocks `33864a0f`.
5. **The checks learn** — `542924c1`, `d2a0f54c`.

**Cut line: stop after phase 3.** Phases 1–3 are one argument about the gap
between what the tools know and what they say; 4 and 5 are hygiene and can
wait for a session with less momentum.

---

## Four that need a nod before building

- **`c74f8663`** — whether `org_capture` takes an initial state is a decision
  about the queue's one exception, not a build.
- **`5f1068f9`** — approach A is measured and recommended, but the alternative
  (move the datetree to its own file) is a real question about where meta-work
  lives and must not be settled as a side effect of a sort.
- **`8c662dfb`** — condensing ten bodies is ten judgements.
- **`b7b46a26`** — whether a commit-derived `CLOSED:` is worth having at all,
  and how the approximation is marked so a reader can tell the 39 derived from
  the 58 measured. `7771fc63` is the precedent for refusing a plausible guess;
  the new evidence is that `38b92521`'s manifest already computed git-derived
  times for 13 of them and ordered an archive sweep by them.
- **`ff1352b3`** — not a member, but the same kind: whether a body-returning
  read is a mode on `org_outline` or its own tool.

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
- **Never type a UUID from memory.** Two were fabricated in one session; the
  tools refused both. Write the 8-character prefix and let the tool expand it.
- **A sentence claiming something was filed is not a filing action.** One was
  written into a source comment and was false for hours.
- **Footnote every tracked `:ID:` in every response**, with its exact title
  looked up rather than recalled.
- **Never `git stash` to compare.** Copy the file aside.
- **Never pass `--no-verify`.**
