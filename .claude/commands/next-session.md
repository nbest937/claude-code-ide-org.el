# Next session

Rewritten 2026-09-02, replacing the prompt that opened `b36e6369`. That
slice is at **[45/51]** with six members left, and the shape of the
remaining work is different from what this file described before: phases 1–3
are long done, and what is left is mostly **decisions** rather than typing.

**The slice is the list.** Open `b36e6369` and read its checklist. Do not
re-derive it from this file.

---

## Before anything else

1. **The branch is pushed.** `feature/code-knows-more-than-it-says` is on the
   remote with 94 commits as of 2026-09-02 — the first push of this slice's
   work. Keep working on it; there is no branch to cut. **Open question for
   the user, not for you:** whether to merge it to `main` before continuing,
   since 94 commits is a large integration point and the slice is 88% done.
2. **Confirm `emacs-tools` is reachable** by calling `org_pending_updates`.
   Read-only, and a reply proves the server is up in a way that seeing the
   tools listed does not.
3. **Apply the queue before composing anything.** Unchanged and still true.
4. **A new heading is invisible to `org_amend` until org-id catches up.**
   After `org_capture`, run
   `emacsclient -e '(org-id-update-id-locations (claude-code-ide-org--tracked-files))'`
   or the amend fails with "no org heading found". Hit twice on 2026-09-02.

---

## What is already true, so it is not re-derived

**`bin/check-conventions` exists and is wired into `.githooks/pre-commit`.**
This is the big one, and it changes how you add a check.

- The harness — failure accumulator, report format, exit-code discipline —
  lives in **`bin/lib/check.fish`**, sourced by both `check-conventions` and
  `check-org-dev-skill`. **Adding a check means adding an assertion to
  `check-conventions`, not writing a second script.** That split is the whole
  point of `d2a0f54c`; do not undo it.
- Two assertion families today: every 8-character `:ID:` cited in the docs
  resolves (to an org heading or a git object), and the TODO keyword set
  agrees across `TODO.org`'s header, the rules file, the org skill's
  transition table, and the `org_set_todo` tool description.
- `pre-commit` passes `--docs-only`, because the full run delegates to
  `check-org-dev-skill`, which shells to `emacsclient`. **A machine with no
  Emacs running must still be able to commit.**
- **`bin/check-conventions-test` asserts exit codes, never output**, and
  includes a case where the fixture is *correct* so the rest cannot pass
  vacuously. Match that shape.
- Two traps it already hit, so you do not rediscover them: a bare
  `[0-9a-f]{8}` matches *inside* a full UUID and produces phantom failures
  (require the run not be adjacent to a hex digit or a dash); and matching
  keywords across the whole skill file false-positives on correct prose about
  a *retired* keyword, so the keyword assertion is scoped to table rows.

**The documentation was corrected on 2026-09-02, nine headings' worth.** Do
not re-report these as gaps:

- CLAUDE.md opens with **"This file is a starting point; the artifact is the
  authority"**, including which artifact wins per question, and the
  state-versus-rationale distinction.
- **"Session tracking"** now describes confirmed intervals and turn-boundary
  guideposts, says plainly that no hook writes a CLOCK entry, and states that
  a `DOING` heading normally has no running clock.
- **The three interval numbers are documented** — `guidepost-gap-threshold`
  (grouping and display only), `span-idle-floor` (the consequential one),
  `span-minimum-interval` (a named no-op).
- **The open-a-clock rule carries the grouping exception** and its scope: the
  exemption bites only on a hand `C-c C-t`, because apply short-circuits the
  trigger for every heading.
- The rules file's header template now includes `#+STARTUP:` and **matches
  both org files byte for byte**; it also documents that a `:BLOCKER:` on a
  `MAYBE` heading is dormant.
- The org skill documents **drawer-scoped timestamp reading** and the
  **sibling-survey idiom**; the org-dev skill documents that **`load-file`
  does not pick up a changed `defcustom` default**.

**Slice incidentals were fixed twice on 2026-09-01/02.** The window now opens
at **first work**, not `:CREATED:` — a slice nobody has started has no window
and no incidentals. And a slice no longer claims **another slice's declared
members**; the exclusion skips `CANCELLED` slices and is *reported* in the
refresh line, not applied silently.

---

## Two tools that used to time out over MCP — fixed 2026-09-02

**`org_capture`, `org_set_property` and `org_divide` work over MCP now.**
Do **not** reach for the `emacsclient` fallback this file used to prescribe;
that path has a data-loss trap and is now filed as `8326a46f`.

The cause was ours, not org's: each of the three declared an argument its own
description told you to omit (`target`, `append`, `parent_state`), so the
published schema marked it required. The server then signals `json-rpc-error`,
a symbol `claude-code-ide` never passes to `define-error` — so no handler
catches it, the HTTP connection is never answered, and the caller waits until
it times out. `72463b68` carries the full diagnosis; `ce012ad4` is the
upstream half.

**One trap remains, and it is live.** A boolean argument passed explicitly as
`false` arrives as `:false`, which elisp reads as *true* — so `org_amend`
with `replace: false` would replace a body instead of appending to it.
Omitting a boolean is correct; passing one explicitly is not. That is
`a8ccd6ac`, unfixed.


## The six that remain

**The two unattended ones were done on 2026-09-02 and sit at `REVIEW`.** The
four that are left all need the user, which is the point of this section — a
session starting here should expect to *ask*, not to build.

**`33864a0f` — done, at `REVIEW`.** DONE.org's 155 tasks are filed under a
year/month/day datetree, newest first, and `#+ARCHIVE:` now points at
`DONE.org::datetree/`. It is at `REVIEW` rather than `DONE` for one reason:
**the next ceremony is the first live exercise of the archive path.** Wiring
it up surfaced a defect where `org-archive-reversed-order` inserted entries
*before* their day node; that is fixed and tested, but only against fixtures.

**`72463b68` — done, at `REVIEW`.** See the section above. Two of its three
named fixes were split out rather than done: `6495c8a0` and `8326a46f`.

**`542924c1` — Three verification traps, none caught by a check.** Its
proposed `bin/check-elisp` is now *cheap*, because the harness exists — it is
an assertion, not a script. Note it absorbed a sixth case on 2026-09-02: a
green suite that is **structurally incapable** of seeing the defect, where
the honest answer is a stated verification-of-record rather than a test.

**`5fc7b934` — Line-number anchors in org bodies rot.** Four candidates
recorded, none chosen. Needs a decision, and the body argues one of them is
consistent with what the skills already do.

**`9d009401` — CLAUDE.md carries dated history.** Four decisions enumerated
and ten retirement blocks sized (114 lines, ~10% of the file). **Explicitly
reserved for the user**; do not run it as a background pass. The heading says
so and this session stopped on it for that reason.

**`7c4d6ef6` — Settle what a slice proposal is.** Judgement by definition,
and it is the one that would improve every future slice.

### Where this will stop

Apply is still human-only, so every capture-to-commit cycle crosses a human.
Beyond that: four of the six need a decision before any code is written. A
session that starts here should expect to do `33864a0f` and `72463b68`
unattended and then **ask**, rather than plan a wire-to-wire run.

---

## Standing rules, with what actually happened

- **Never type a UUID from memory.** Three were fabricated on 2026-09-02
  alone. The tools refused two; the third made `refresh-slice` report
  `"0 slices refreshed"` and change nothing — a silent no-op, not an error.
  Write the 8-character prefix and let the tool expand it. **`target` on
  `org_capture` is the exception: it needs the full id**, so look it up.
- **Footnote every tracked `:ID:` in every response**, title looked up rather
  than recalled. The hook fired repeatedly on 2026-09-02, and every miss was
  an id that arrived *inside* a finding being reported rather than one chosen
  — ids handed to you by evidence are the ones that escape.
- **Test that a check *refuses*, not that it passes.** The `pre-commit`
  wiring added on 2026-09-02 sat below an early `exit 0` and could never fire
  on a CLAUDE.md-only commit — the exact case its own comment named. Every
  reading of the code looked right; staging a bogus citation caught it in one
  command.
- **When a check fires, ask whether the assertion or the artifact is wrong.**
  The keyword check's first real failure was correct prose about a retired
  keyword. The assertion was wrong.
- **A `grep` is a hypothesis about what it hides.** A single-line pattern
  missed the CLAUDE.md sentence it was looking for because the sentence
  wraps; a bracket in the pattern made an archive count read 0 instead of 7.
  Both were resolved against the primary artifact.
- **Silence is not a pass.** `bin/test` writes to stderr; check the
  `Ran N tests` line and the exit code, never the absence of `FAILED`.
  Beware `$?` after a pipeline — it is the *last* command's status.
- **Mutate semantically and confirm the run count.** Every fix this session
  was mutation-tested to fail exactly its own test and no other.
- **`byte-compile-file` writes a `.elc` that shadows the source.** Delete it.
- **Never pass `--no-verify`. Never `git stash` to compare** — copy the file
  aside.
