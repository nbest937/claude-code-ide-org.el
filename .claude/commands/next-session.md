# Next session

Rewritten 2026-09-03, replacing the prompt that opened `b36e6369` — that
slice closed **[48/48]** and is archived. The slice now is `ff7ccb2d`, **Make
the org discipline travel: ship the machinery, relocate the rules**, at
**[0/12]** across 20 member lines.

**The slice is the list.** Open `ff7ccb2d` and read its checklist. Do not
re-derive it from this file. Note it is the first slice composed at real
size: 20 lines, two grouping labels, and six lines with no cookie.

---

## Before anything else

1. **Apply the queue before composing anything.** This is not boilerplate
   this time — the session that wrote this file left an unusually large
   queue: six `DONE`s, one `MAYBE`→`TODO` promotion, a slice reopened
   `REVIEW`→`DOING` and closed again, and every clock event behind them.
   Until it is applied, `TODO.org` shows `TODO` on headings whose work
   shipped, and `ff7ccb2d`'s member checkboxes disagree with their referents.
   That disagreement is *staleness*, not a defect to fix by hand.
2. **Confirm `emacs-tools` is reachable** by calling `org_pending_updates`.
   Read-only, and a reply proves the server is up in a way that seeing the
   tools listed does not.
3. **PR #9 is open, pushed, and its review is closed out.** Branch
   `feature/fix-claude-md-and-slice-conventions`, all four inline review
   threads replied to and resolved on 2026-09-03. **Open question for the
   user, not for you:** whether to merge before continuing.
4. **The org-id catch-up step is no longer prescribed.** This file used to
   say `org_capture` must be followed by
   `(org-id-update-id-locations ...)` or the next `org_amend` fails. That did
   not happen once on 2026-09-03 across **five** capture-then-amend pairs.
   Do not run it prophylactically; if an amend fails with "no org heading
   found", *then* it is the fix, and that recurrence is worth recording.

---

## What is already true, so it is not re-derived

**Three write paths now refuse to mint a slice/container hybrid, and they ask
one question between them.** `dca940c1` forbids a heading that is both; before
2026-09-03 the guards asked direct questions while the lint asked a
descendant-based one.

- `--subtree-has-keyworded-heading-p` — the arrival side. Differs from
  `--container-heading-p` by exactly the root, which is the difference that
  mattered: a keyword-less note *carrying* a `TODO` child used to refile
  straight through.
- `--enclosing-slice-title` — the target side. This heading if it is a slice,
  else the nearest ancestor that is. **Not `:KIND:` inheritance**; the
  question is whether an *ancestor* would acquire keyworded children.
- `--blocker-keyword-inside-slice-p` on `org-blocker-hook` — the third path,
  where nothing arrives: granting a keyword to a note already under a slice.
  It denies **the grant only**, so an existing hybrid can still be closed or
  cancelled on its way out.

**The commit gate's own suite was red and is green.** `bin/pre-commit-test`
ran 5/8 for days because its fixtures still built the level-1 `* Category`
tier that `29439196` retired on 2026-08-27. It is 8/8. And
`bin/check-conventions` with a mistyped flag used to run **zero assertions
and exit 0**; unknown `--flags` and unreadable `ROOT`s are now exit 2,
deliberately distinct from 1.

**`bin/clock-target-check` has a test harness** — `bin/clock-target-check-test`,
12 checks. It shipped without one, which is how both of its defects reached a
code review instead of a suite.

**`fish` is a prerequisite for committing to this repo.** `.githooks/pre-commit`
invokes `bin/check-conventions`, which is fish, as is its own test. This is
why `84b7d8b3` was promoted out of `MAYBE` — it is no longer one peripheral
script's inconsistency.

**`.claude/rules/` is not a plugin component**, verified against the plugin
docs on 2026-09-02 and recorded on `9ae4b17e` along with the measurement that
roughly **660 of CLAUDE.md's 1196 lines** describe machinery that would ship
and currently has no way to. That asymmetry is the slice's whole premise; do
not re-measure it.

---

## The shape of the slice

Four movements, and the first gates the rest.

**1 — Classify what travels.** `9ae4b17e` is `NEXT` and every other line
assumes its answer. `1caed585` is the paired decision the slice **declined**
and is a real drop, not a pending item.

**2 — Relocate, then prune, in that order.** `d5345abb` moves what is
general org convention into the skill; `9d009401` prunes what is left.
Pruning first risks deleting rules a consuming project needs, which is now a
`:BLOCKER:` rather than a sentence. **`9d009401` is explicitly reserved for
the user** — do not run it as a background pass.

**3 — The machinery's undeclared assumptions**, each of which fails on a
second machine and nowhere here: `1ed7b2b4` (org 9.7+), `84b7d8b3` (which
interpreter), `f8c86914` (one checkout per running Emacs). All three carry
recorded options and no decision.

**4 — Multi-project instrumentation**, meaningful only after the hooks move:
the `f90d745e` pair (`5461c349`, `b862fbf4`) and `83b3cdd6`. They name
`9ae4b17e` in a `:BLOCKER:` for that reason.

The tail — `d7849119`, `b07df584`, `c5b02503` — is reader-facing and can
proceed independently.

**Six lines carry no cookie and only one is a drop.** Five are carried
`MAYBE`s (`e396f94a`, `2e09adb7`, `3cb3f955`, `7eb7dd8d`, `2c5f7c50`); the
drop is `1caed585`. They render identically, which is `1b727475`. **Read the
slice body's sentence, not the cookies.** Two of the five carry a note saying
why they were held rather than promoted — `7eb7dd8d`'s design is written
around the retired `PLANNING` keyword, and `2c5f7c50`'s body argues against
its own proposal.

### Where this will stop

Almost immediately, and by design. `9ae4b17e` is a classification —
judgement, not typing — and three of movement 3's members carry enumerated
options with nothing chosen. `9d009401` is reserved for the user outright. A
session starting here should expect to **ask and record**, not to plan a
wire-to-wire run. The tail is the only place to go if the answer is "not
now."

---

## Standing rules, with what actually happened

- **Never type a UUID from memory.** On 2026-09-03 the slice's 20 member
  lines were *generated from `TODO.org`* rather than typed, and the result
  was diffed against what landed. One id — `3cb3f955`'s — was not what recall
  offered. Generate, then diff; do not proofread.
- **Anchor org parsing on the heading's own property drawer.** A regex that
  scanned each heading's whole block attributed **three of eight** footnote
  titles to the wrong heading, because ids get quoted in bodies. This is the
  third instance of that class; `2c5f7c50` collects them, and the fix is
  `org-map-entries`, not a second parser.
- **Footnote every tracked `:ID:` in every response**, title looked up rather
  than recalled. The hook fired three times on 2026-09-03 and every miss was
  an id that arrived *inside* evidence rather than one chosen deliberately.
- **Reproduce the hypothesis before fixing it.** `0fa403f4`'s stated likely
  cause was a `fish` dependency. It was wrong — stale fixtures — and the
  heading had flagged it unverified for exactly that reason. Reproducing took
  one command.
- **Prove a test discriminates.** Copy the file aside and restore `HEAD`'s
  version in place; **never `git stash`**. Every fix on 2026-09-03 was run
  red first, and one regression test was written a commit early and *held
  back rather than committed red*.
- **A comment that overstates a guard is how the next reader stops
  checking.** Three were corrected on 2026-09-03 in the same commits as their
  code: a capture guard claiming the refusal "lands before the heading
  exists", and a hook header asserting a once-per-session bound the code did
  not enforce.
- **Silence is not a pass.** Check the `Ran N tests` line and the exit code,
  never the absence of `FAILED`. Beware `$?` after a pipeline.
- **Never pass `--no-verify`.** When `bin/lint-org` blocked a commit because
  a plan file had vanished from `~/.claude/plans`, the fix was restoring it
  byte-for-byte from `plans/` — which is what that archive exists for.
- **`command` before a shell builtin is not a safety measure.** `command cd`
  skips fish's builtin for an external no-op, so `pwd` reported the wrong
  directory and every check silently ran against the wrong tree. Two existing
  assertions caught it in under a minute.
