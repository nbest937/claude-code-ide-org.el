# Next session

Rewritten 2026-08-26, replacing the prompt that drove `c44c2119`. That slice
closed at 27 of 27; this one opens `979e02b6`.

**The slice is the list.** Do not re-derive it here — open `979e02b6` and read
its checklist. Each line carries the member's id, current keyword and title,
and the `:BLOCKER:` names every member still carrying a cookie.

---

## Before anything else

1. **Confirm `emacs-tools` is reachable** by calling `org_pending_updates`. It
   is read-only, and a reply proves the server is up in a way that seeing the
   tools listed does not.
2. **Apply the queue.** You no longer need to refresh the slice or normalise
   separation afterwards — apply's settle phase does both now (`a0abf97d`,
   `601c885c`). Consolidating drawers and archiving are still yours to ask for.
3. **Use `org_outline` with `scope`, not `sed`/`awk`.** Three separate times
   in the last session a shell pipeline reproduced, worse, what one scoped
   `org_outline` call returns — truncated titles and no ids. It is the
   structural tool; `org_query` is the predicate tool and returns a flat list
   with no parent/child relation at all.

---

## What is already true, so it is not re-derived

- **Apply settles three things**: the sole-TODO promotion, a slice refresh, and
  heading separation — all after the batch, never per item, because a member
  whose `todo` event has not landed is keywordless on disk.
- **The apply ledger records *when*.** Each consumed event carries the
  timestamp of the pass that consumed it. That is what makes "un-apply the pass
  of 17:17" a filter, and it is how a zero-width span was identified as
  *widowed by a partial apply* rather than split by a clock pair.
- **`org_amend` can revise**, not only append: `replace=true` rewrites the
  body's prose wholesale. It cannot reach a drawer — the writable region starts
  below all of them — so revising a finished heading cannot destroy its
  `:PLAN:`. Commit first; git is the only undo.
- **The human's review pass is clocked**, natively, on a `Review attention`
  heading. The command *is* the event. Burying the buffer ends it.
- **The ceremony prompts itself** at `SessionStart`, once a day, and goes quiet
  when a pass has actually run — derived from that clock, not from anyone
  remembering to stamp anything.
- **A Stop hook that exits 0 cannot speak.** Its stderr goes to the debug log
  and Claude never sees it. Blocking hooks use `exit 2` with the reason on
  stderr (`5787bfc6`).
- **A slice is declared by `:KIND: slice`**, carries a `:BLOCKER:` naming
  exactly its cookie-carrying members, and its member lines are *derived* —
  never hand-set.

---

## The trap, and it is live

**Do not set `DOING` on this slice by hand.** `95c27fca` measured that doing so
opens a clock *on the slice itself*, because `--container-heading-p` does not
recognise one. It is a member of this very slice, and until it is fixed the
slice's own keyword should stay `TODO`.

The retroactive-`DOING` trap (`4f6a6bb1`) is unchanged and is also a member:
`(org-todo "DOING")` clocks in immediately, so recording that something *was*
started credits time to the present.

---

## Settle these before building the middle

Two things are pending that are **not** builds, and they are different kinds
of thing. Do not treat them as one.

**A decision, and it needs the user.** `29439196` — `:EPIC:` versus
`:CATEGORY:` for the heading tier — has been open since 2026-08-19, parked on
"decide it against a report someone actually wants". That report now exists
(`82df2a6c`), so the evidence is quantified rather than argued:

- `:CATEGORY:` populates the agenda prefix column, inherits with no
  configuration, and enables `org-agenda-filter-by-category`. Today that
  column carries **two** distinct values across 274 headings — the file name.
- `:EPIC:` gets none of that and costs one `org-use-property-inheritance`
  entry to match on the property alone.
- **Neither side had this before:** flattening the tier into a label destroys
  the grouped clock report, because `:maxlevel 2` groups by the level-1
  headings *being headings*.

Put it to the user early. It is answerable in a conversation and it gates how
`2e660571` and `9651d4c8` are built.

**A design question, and it may collapse three members into one.**
`2e660571` (generalise `:KIND:`), `29439196` (heading tiers) and `8183fc7c`
(a slice invisible to `org_outline`) are all "a declared thing the code infers
some other way". The user's proposal on `8183fc7c` — carry blocker *ids* in
the general schema rather than a bare `[blocked]` flag — is arguably the
general mechanism `2e660571` is asking for.

Work that out **before** building any of the three. Discovering it halfway
through the second one is the expensive path, and this is the corner worth
looking around. Whether that warrants Plan Mode is a judgement to make at the
time, not a step to follow.

## Suggested order

The checklist is already in dependency order and the first four are one
argument, not four errands.

1. **`6a21e08b`** — the docstring says the feature is off; it is on. Smallest,
   and the next three read the variable it lies about.
2. **`4f6a6bb1`** — the retroactive-`DOING` clock. Unblocks two transitions
   that have been deliberately unqueued for days.
3. **`95c27fca`** — a slice gets clocked and auto-promoted because its members
   are links, not children. Fixing it is what lets this slice carry an honest
   keyword.
4. **`3964c575`** — a container carries clocks it earned before it was one.

**Then the declared-versus-inferred core**, which is where the slice's title
actually lives: `2e660571` (generalise `:KIND:`), `29439196` (heading tiers),
`a0813ae3` (mitosis), `9651d4c8` (plan coverage), `c954f650` (keyword
progression).

**`8183fc7c` and `798bb7a1` last.** Both are the same root seen from the tool
surface: a *declared* grouping is invisible to anything that walks the tree.
`8183fc7c` carries the user's own proposal — expand the general schema to
carry blocker *ids* rather than a bare `[blocked]` flag — measured at +2.2% on
the outline, and it would have answered three questions in the last session
that fell back to shell.

**Cut line: stop after 4.** Those four are one coherent argument about the
clock's relationship to structure, and finishing them lets the slice hold a
keyword it currently cannot.

---

## A reservation to carry, not to ignore

**This slice may be too big.** Eleven members, and unlike `c44c2119` — whose
members were mostly small defects found while doing other work — most of these
are *large design questions* with no obvious end state. `29439196` alone has
been open since 2026-08-19 and is parked on evidence that now exists.

If it stalls, the honest move is to split it rather than let it run: the first
four are mechanical and the rest are research, and those are different kinds of
work wearing one title.

---

## Standing rules, with what actually happened

- **Footnote every tracked `:ID:` in every response.** Measured over one real
  transcript: 41 of 45 footnoted. Three of the four misses were one-line
  narrations before a tool call, which the hook never sees — it reads
  `last_assistant_message`, so only the final response of a turn is guarded.
- **Break it on a copy before believing a test.** Six assertions written last
  session passed against deliberately broken code. Two checked presence where
  order was what mattered; one asserted its own call ordering rather than the
  call site's; one used `should-not` on a return value that was never nil.
- **State the reload precondition before verifying.** Scripts are read per
  invocation; MCP *tool schemas* are negotiated at session start; hook *wiring*
  is read at session start but hook *scripts* are not.
- **A negative from a hand-written probe is worth re-checking.** One reported a
  missing call that was present; the probe had named a function that does not
  exist.
- **Never `git stash` to compare.** Copy the file aside.
- **Never pass `--no-verify`.**
