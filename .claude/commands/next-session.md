# Next session

Rewritten 2026-08-25, replacing the slice-less plan of 2026-08-24. That
revision predates slices existing, so it duplicated a list that now lives in
one place.

**The job is to finish the current slice, not to grow it.** `c44c2119` is at
`[9/21]` and every one of the nine completions came from work found *while*
doing the planned work. Ten new headings were filed today and are
deliberately **not** members. Resist adding more; a new slice can be cut later.

**The slice is the list.** Do not re-derive it here — open `c44c2119` and read
its checklist. Each line carries the member's id, current keyword and title,
and the slice's `:BLOCKER:` names every member still carrying a cookie.

---

## Before anything else

1. **Confirm `emacs-tools` is reachable** by calling `org_pending_updates`. It
   is read-only, and a reply proves the server is up in a way that seeing the
   tools listed does not.
2. **Apply the queue first, before touching the slice.** As of this writing 7
   items are pending across 3 headings, including two state changes —
   `8ca6541d` → `DONE` and `a7f4b40c` → `CANCELLED`. The slice's checkboxes are
   *derived from each referent's keyword*, so applying changes what the slice
   should say.
3. **Then fix the slice by hand, and expect to.** `0acc1df2` — regenerate a
   slice's depiction from its referents — is designed and **not built**. So
   after apply, `8ca6541d`'s checkbox will still read `[ ]` against a `DONE`
   heading, and the cookie will still read `[9/21]`. Tick it, bump the cookie,
   and run `M-x claude-code-ide-org-refresh-slice-blocker`.

That third step is the first thing that will bite, and it is an argument for
making `0acc1df2` a member. **That is a decision for the user, not a thing to
do quietly** — it would be expanding the slice.

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
  itself divides, the id going with the leaf. Relevant only if a member
  inflates while being worked.

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

**Cheapest first, because two of them are minutes.**

1. `e1284bdb` — one paragraph. Its normaliser shipped 2026-08-24; all that
   remains is writing the two-blank-lines convention down, which is nowhere.
   Grepped twice today: absent from both `org-conventions.md` and CLAUDE.md.
2. `f421c5c3` — small, and it protects a rule that is currently silent. The
   signal already exists: `--plan-seam`'s "first body line" condition *is* the
   test for "no prospective half".
3. `edd47f32` and its three children — the ceremony, and the largest remaining
   block. `7ae6562d` is the missing tool; `e1284bdb` only needs wiring into the
   same command once written down; `aa1ba915` is the `SessionStart` prompt that
   makes any of it happen without being remembered.
4. `7fbab3b3` — the archive step, which belongs in that same ceremony rather
   than as its own ritual.
5. `961f15b6`, `21c91613`, `3063c3e5`, `82df2a6c` — the four genuinely large
   ones. `21c91613` carries a user decision between three recorded options.

**Cut line: stop after 4.** That would take the slice from `[9/21]` to roughly
`[15/21]` and leaves the ceremony coherent. **If the session is short, do 1 and
2** — together they are under an hour and both close members outright.

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
