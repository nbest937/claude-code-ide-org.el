# Next session

Rewritten 2026-08-25, replacing the slice-less plan of 2026-08-24. That
revision predates slices existing, so it duplicated a list that now lives in
one place.

**The job is to finish the current slice, not to grow it.** `c44c2119` is at
`[11/23]`, and every completion so far came from work found *while* doing the
planned work rather than from the plan. A dozen headings filed on 2026-08-25
are deliberately **not** members. Resist adding more; `979e02b6` is the
proposed next slice and is where new work belongs.

**The slice is the list.** Do not re-derive it here — open `c44c2119` and read
its checklist. Each line carries the member's id, current keyword and title,
and the slice's `:BLOCKER:` names every member still carrying a cookie.

---

## Before anything else

1. **Confirm `emacs-tools` is reachable** by calling `org_pending_updates`. It
   is read-only, and a reply proves the server is up in a way that seeing the
   tools listed does not.
2. **Apply the queue first, before touching the slice.** The slice's
   checkboxes are *derived from each referent's keyword*, so applying changes
   what the slice should say.
3. **Then run `M-x claude-code-ide-org-refresh-slice`.** It rewrites every
   member line from its referent, recomputes the cookie, and regenerates the
   `:BLOCKER:`. Built 2026-08-25 (`0acc1df2`); before it existed this step was
   manual and silently skippable, because nothing detects the drift — the lint
   compares `:BLOCKER:` against the checkbox list, and both go stale together.

---

## What is already true, so it is not re-derived

Everything below shipped 2026-08-25, after the previous revision.

- **Slices exist and work.** A slice is declared by `:KIND: slice`, holds its
  members as a checkbox list of `[[id:]]` links, and carries a `:BLOCKER:`
  naming exactly the cookie-carrying ones. `bin/lint-org` errors if the two
  disagree; `claude-code-ide-org-refresh-slice-blocker` fixes it. The
  convention is in `.claude/rules/org-conventions.md`.
- **A slice's checkbox is derived, never judged**: `DONE`→`[X]`,
  `DOING`/`REVIEW`/`PLANNING`/`WAITING`→`[-]`, `TODO`/`NEXT`→`[ ]`,
  `CANCELLED`/`MAYBE`→ *cookie deleted*. A cancelled or deferred member keeps
  its line and loses its cookie, so it neither counts nor inflates.
- **A slice declares membership and order and nothing else.** Its body is one
  sentence expanding the title, plus the checklist and one `orgit-rev:` link
  per revision of this file. General rules belong in the conventions file, not
  in the slice.
- **The 8-character prefix resolves everywhere.** `--id-find` wraps
  `org-id-find` at 16 call sites, so every tool taking an `id` accepts a
  prefix, and `org_amend` expands `[[id:PREFIX]]` before writing. **Write the
  prefix and stop** — resolving a tail by hand is now the thing that
  introduces the error. Heading creation by *text edit* still bypasses this;
  `bin/lint-org` is the backstop and caught three fabrications today.
- **`orgit-rev:` links cost nothing.** `43201e64` shipped a stub registration
  in `bin/lint-org`; before it, every commit link added a permanent warning.
- **`DOING` means started and owed a return — "in the mail"** — not executing
  right now. It is durable and plural; the *clock*, not the keyword, records
  execution. A leaf held for the user's judgement is `WAITING`.
- **`2758f3a0` fires and is accurate.** It blocked four turns today and every
  block was a real unfootnoted id. Its child `5787bfc6` carries the remaining
  half: the `stopReason` never reaches the model, so the block is opaque.
- **Task mitosis is settled but unbuilt** (`a0813ae3`): a leaf that outgrows
  itself divides, the id going with the leaf.
- **Three words, corrected 2026-08-25 and not interchangeable.** An **epic**
  is the grouping a task belongs to — proposed as an `:EPIC:` label rather
  than `:CATEGORY:`, which is overloaded. A **story** is a task that acquired
  keyworded children; `--container-heading-p` detects one, and "container" is
  the code's older word for it. A **slice** names members by reference and
  sequences them. Earlier drafts called a story an "epic" throughout.
- **Apply binds `inhibit-read-only`** (`97b030a4`). A read-only TODO.org no
  longer fails a pass. Other paths — including `refresh-slice` — still stop,
  deliberately.

---

## The trap, and it is live

**Do not queue a retroactive `DOING`.** `4f6a6bb1`: `(org-todo "DOING")` opens
a clock immediately, verified in batch, so recording that something *was*
started credits time to the present. Two transitions are waiting on this and
were deliberately **not** queued — `961f15b6` and `e1284bdb` are both `DOING`
under the current sense and neither is being worked.

Applied together they would clock in on the first, clock in on the second
(closing the first and leaving a stray sub-minute interval), and finish with a
clock left running. Settle `4f6a6bb1` before setting either.

---

## Suggested order

**Do 1 and 2 first and put them to bed.** Both were carrying decisions; both
decisions are now made, so neither needs a conversation before it can start.

1. **`21c91613` — decided: record the apply time alongside each consumed
   event.** `("ts" . "applied-at")` rather than a bare list. Not the cheapest
   option, and chosen against the cheapest deliberately: a `.applied.bak`
   snapshot can only undo the *most recent* pass, and the incident this
   heading was filed for is exactly the case that is not — a third apply had
   already landed and been committed, which is what made "un-apply everything
   since the last commit" roll back 85 events instead of 54. The field makes
   "un-apply the pass of 17:17" a filter instead of a reconstruction.

   Costs one field and no new write path: the ledger is
   `{"applied": [ts, …]}`, re-read 2026-08-25 rather than assumed, and it is
   rewritten wholesale on every apply. Read the heading's recovery record
   before starting; it is the requirements document.

2. **`82df2a6c` — evaluate Org's own lenses against this corpus.** Agenda
   views, sparse trees, column view. It is *evidence-producing*, which is why
   it is early rather than last: three separate decisions are parked on it.
   `29439196` says flattening should be decided against it; `961f15b6`'s
   separate-datetree question is explicitly waiting for "a report someone
   actually wants"; and the `:EPIC:` versus `:CATEGORY:` choice turns on
   whether org's native agenda integration is worth anything here.

   The corpus is better suited to it than when the heading was written:
   `CLOSED:` is populated, drawers are consistent, the datetree has real day
   nodes, and a slice with 23 members exists to point column view at.

**Then the ceremony, which is the largest remaining block.**

3. `e1284bdb` — one paragraph. Its normaliser shipped 2026-08-24; all that
   remains is writing the two-blank-lines convention down, which is nowhere.
   Grepped twice: absent from both `org-conventions.md` and CLAUDE.md.
4. `f421c5c3` — small, and it protects a rule that is currently silent. The
   signal already exists: `--plan-seam`'s "first body line" condition *is* the
   test for "no prospective half".
5. `edd47f32` and its three children. `7ae6562d` is the missing tool;
   `e1284bdb` only needs wiring into the same command once written down;
   `aa1ba915` is the `SessionStart` prompt that makes any of it happen without
   being remembered.
6. `7fbab3b3` — the archive step, which belongs in that ceremony rather than
   as its own ritual.
7. `961f15b6` and `3063c3e5` — the two remaining large ones.

**Cut line: stop after 6.** **If the session is short, do 1 and 2** — they
are the two that unblock other things, and nothing else in the slice is
waiting on anything.

**No open decisions remain among the members.** Both that carried one have
been settled above; the rest are builds with designs already recorded on the
heading.

---

## Standing rules, with what actually happened

- **Footnote every tracked `:ID:` in every response.** Not once per session —
  per response. Four turns were blocked today, each for an id footnoted
  earlier and dropped on re-mention, including one in a sentence *about*
  having dropped footnotes.
- **Write the 8-character prefix; let the tool expand it.** See above.
- **Check a buffer against disk before clearing `buffer-read-only`.** On
  2026-08-25 the TODO.org buffer held 1274 bytes of the user's unsaved draft
  while looking stale; writing through it would have destroyed the work.
- **A rule that reports nothing may be asleep rather than satisfied.** The
  slice `:BLOCKER:` assertion went silently inert for an hour when its
  detector was a tag and the tags were deleted. Prove a check is awake by
  breaking something on a *copy*.
- **Never `git stash` to compare.** On a clean tree `stash` saves nothing and
  the paired `pop` takes an *older* stash. Copy the file aside.
- **Measure the blast radius before writing a lint rule**, and measure the
  right thing. "27% of headings have no inbound reference" was offered as an
  objection to mitosis and answered nothing: it measured density, not damage.
- **Never pass `--no-verify`.**
