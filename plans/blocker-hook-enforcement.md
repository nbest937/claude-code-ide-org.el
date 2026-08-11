# Plan — Make org-blocker-hook actually consult :BLOCKER:

`:ID: 087e73e9-bb24-43b6-a972-b7f103d04017`

## Context

Today `claude-code-ide-org--blocker-clock-running-p`
(`modules/tools/claude-code-ide-org/config.el:1549`) is the only function
registered on `org-blocker-hook`. It denies a `DONE` transition solely
when a clock is currently running on that exact heading — it never reads
`:BLOCKER:` at all, and `org-depend` (the package that natively defines
`:BLOCKER:`/`:TRIGGER:` semantics) is not `require`d anywhere in this
project. Every `:BLOCKER:` property already in `TODO.org`/`DONE.org`
(e.g. `TODO.org:232`, `DONE.org:119`, `DONE.org:389`) is therefore purely
advisory: `org_set_todo` will happily transition a blocked heading to
`DONE`.

Confirmed live from `org.el` itself
(`~/.config/emacs/.local/straight/repos/org/lisp/org.el:9794-9802`):
`org-todo` invokes `org-blocker-hook` via
`(run-hook-with-args-until-failure 'org-blocker-hook change-plist)`. That
combinator ANDs the results across every registered function — it stops
and blocks at the *first* one returning nil, and only permits the change
if *every* function returns non-nil. So a second, independent function
can simply be `add-hook`ed alongside the existing clock check; no
restructuring of `--blocker-clock-running-p` is needed, and — per this
project's own established discipline for the sibling `org-trigger-hook`
functions (see the "Deliberately no re-entrancy boolean guard" comment at
`config.el:1670`) — hook run *order* is not something to rely on: `add-
hook` prepends by default, so the actual call order is the reverse of
registration order. Each blocker function must therefore stay fully
self-contained and correct regardless of where it lands in the list.

`org-depend.el` itself is present on disk (pulled in as an `org-contrib`
build artifact by Doom's `:lang org` module) but is never `require`d —
confirmed by grepping the straight build tree and this project's own
`packages.el`/`config.el`. Reading its real implementation
(`~/.config/emacs/.local/straight/repos/org-contrib/lisp/org-depend.el`,
`org-depend-block-todo`) confirms the semantics this task should mirror:
`:BLOCKER:` holds a whitespace-separated list of IDs; the block only
applies when the *transition itself* is into a done-type state from a
not-done one; each listed ID is checked via `org-entry-is-done-p`
(true for both `DONE` and `CANCELLED`, since those are exactly the
keywords after `|` in this project's `#+TODO:` line) — not a literal
string comparison against `"DONE"`/`"CANCELLED"`, which would silently
drift if the keyword sequence ever changes. `org-entry-is-done-p` is
already used once in this codebase, for exactly this reason
(`claude-code-ide-org--clock-history-head-done-p`, `config.el:449`) — this
task reuses that same primitive rather than reintroducing a hardcoded
string check.

The org skill (`.claude/skills/org/SKILL.md:132-163`, "Dependencies
between tasks") documents `:BLOCKER:`/`:TRIGGER:` today: `:BLOCKER:` can
hold multiple space-separated IDs, and the blocked heading "can't be
marked done until every listed ID is" (done). Critically, **this
project's own `:TRIGGER:` is not org-depend's `:TRIGGER:`** — org-
depend's real `:TRIGGER:` takes an `ID(KEYWORD)` form and *auto-sets* the
target heading's state on trigger. This project's skill instead
documents `:TRIGGER:` as a bare-ID list, purely the *inverse notational
form* of the same blocking relationship ("this heading, once done,
unblocks another... equivalent in intent, not both required" —
SKILL.md:154-158). It carries no auto-transition behavior in this
project's design at all.

An existing example already in `TODO.org` (heading
`7eb7dd8d-...` → `b95b9fba-...`, see the 2026-08-05 update at
`TODO.org:232-245`) is now in a *satisfied* state (the blocking heading
is `DONE`), which is a convenient live smoke-test case once implemented:
the blocked heading should transition to `DONE` cleanly; temporarily
reverting the blocker's `DONE`→`TODO` in a scratch copy (never the real
file) would demonstrate the deny path.

## Design

### 0. `:to` is not always the string `"DONE"` — deliberate scope decision

`org-blocker-hook` has a second caller besides `org-todo`:
`org-entry-blocked-p` (`org.el:10050-10059`, used by
`org-agenda-dim-blocked-tasks` to dim blocked entries in the agenda)
invokes the hook with a **synthesized** plist whose `:to` is the *symbol*
`'done`, not the string `"DONE"` — confirmed by reading that call site
directly. `org-depend-block-todo` itself guards against exactly this
(`(member to (cons 'todo org-not-done-keywords))`, `org-depend.el:376`),
which is why it special-cases both the symbol and string forms.

`(equal (plist-get change-plist :to) "DONE")` — as written below, and
exactly as `--blocker-clock-running-p` already does today at
`config.el:1563` — is nil for the symbol `'done`, so this new function
(like the existing clock check) never fires from the agenda-dimming
path; only from a real `org-todo` state change. This is a **deliberate**
choice, not an oversight, for two reasons: it matches the precedent
already set by `--blocker-clock-running-p` (dimming-via-clock was never
implemented either), and matching the symbol form would mean calling
`org-id-find` — which can visit and open files — once per blocked-
looking entry on every agenda build, inside a hook whose own docstring
(`org.el:2104`) says "functions in this hook should not modify the
buffer" (visiting files isn't a buffer modification, but it's exactly
the kind of I/O-heavy side effect an agenda-wide dimming pass should
avoid). Net effect: `:BLOCKER:`-blocked headings will **not** be
visually dimmed in the Emacs agenda under this implementation, only
refused via `org_set_todo`/`org-todo`. State this reasoning directly in
the new function's docstring so a later reader doesn't "fix" it into a
full symbol-aware match without weighing the agenda-performance
tradeoff.

### 1. New function in `config.el`, alongside `--blocker-clock-running-p`

Add immediately after `claude-code-ide-org--blocker-clock-running-p`
(`config.el:1549-1572`), as a second, independent `org-blocker-hook`
function — not a merge into the existing one, matching this project's
established single-responsibility style for the trigger-hook functions
(`--trigger-demote-conflicting-next` and
`--trigger-auto-promote-sole-todo` are two separate functions covering
one invariant each, not one combined function):

```elisp
(defun claude-code-ide-org--blocker-unresolved-dependency-p (change-plist)
  "For `org-blocker-hook': deny a transition to DONE on the heading at
point while its own :BLOCKER: property lists one or more :ID:s that do
not resolve to a heading in a done-type state (DONE or CANCELLED, via
`org-entry-is-done-p' -- not a literal string comparison, so this stays
correct if the #+TODO: keyword sequence ever changes). :BLOCKER: may
hold multiple space-separated :ID:s (see the org skill's \"Dependencies
between tasks\" section); every one must resolve to a done-type heading
before this permits the change. An :ID: that does not resolve to any
heading at all (stale or typo'd, `org-id-find' returns nil) is silently
skipped rather than treated as blocking -- a non-existent blocker could
never be satisfied and would otherwise wedge the heading permanently,
matching this codebase's existing fail-open discipline for malformed
input (e.g. `claude-code-ide-org--maybe-record-planning-owner'). Only
bare :ID:s are supported -- org-depend's own special token
\"previous-sibling\" (see org-depend.el's `org-depend-block-todo') is
NOT recognized; it falls through `org-id-find' exactly like a typo'd id
and is silently ignored, matching the org skill, which documents only
bare :ID:s for this project's :BLOCKER:. Only ever compares :to against
the string \"DONE\", never the symbol `done' that `org-entry-blocked-p'
(the agenda-dimming caller) passes -- deliberate, see design note above;
matches `claude-code-ide-org--blocker-clock-running-p's own existing
scope. Return non-nil (permit the change) for every requested state
other than DONE, or when the heading has no :BLOCKER: property at all.
CHANGE-PLIST is
the plist `org-todo' passes to every `org-blocker-hook' function; see
`org-trigger-hook's docstring for its shape. Only reads :BLOCKER: or
resolves :ID:s from inside this hook -- never at load or registration
time, same discipline as `claude-code-ide-org--blocker-clock-running-p'.
Registered as a second, independent `org-blocker-hook' function rather
than folded into that one -- `org-todo' ANDs every registered blocker
function's result (`run-hook-with-args-until-failure'), so two small,
single-purpose functions compose correctly regardless of registration
order."
  (or (not (equal (plist-get change-plist :to) "DONE"))
      (let ((blocker-ids (split-string (or (org-entry-get nil "BLOCKER") ""))))
        (catch 'blocked
          (dolist (blocker-id blocker-ids)
            (let ((marker (org-id-find blocker-id 'marker)))
              (when (and marker
                         (not (org-with-point-at marker (org-entry-is-done-p))))
                (setq org-block-entry-blocking
                      (org-with-point-at marker (org-get-heading t t t t)))
                (throw 'blocked nil))))
          t))))
```

Register it right after the existing line, same `with-eval-after-load
'org` block (`config.el:1772-1776`):

```elisp
(add-hook 'org-blocker-hook #'claude-code-ide-org--blocker-clock-running-p)
(add-hook 'org-blocker-hook #'claude-code-ide-org--blocker-unresolved-dependency-p)
```

Note in a code comment at the registration site that `add-hook`'s
default prepend means actual call order is unspecified relative to the
clock check — harmless for the AND outcome, but if *both* would block
simultaneously, whichever runs second overwrites
`org-block-entry-blocking` (only cosmetic: which blocking-reason string
`org_set_todo`'s error message surfaces, not whether it blocks).

### 2. No changes needed to `claude-code-ide-org-set-todo`

Its existing error-reporting path (`config.el:1114-1167`) already
produces a generic `"Error: requested state %s but heading \"%s\" is
still %s — likely blocked (check :BLOCKER: / org-blocker-hook)"` message
whenever `org-todo` silently no-ops due to *any* blocker-hook refusal —
it does not need to know which specific hook function fired. No wrapper
change required.

### 3. `:TRIGGER:` — recommendation: do not enforce the inverse direction in this pass

Concrete reasons, not left open:

- This project's `:TRIGGER:` (per SKILL.md) is declarative-only — a
  notational inverse of `:BLOCKER:` for whichever heading is more
  natural to edit, not org-depend's auto-transitioning `ID(KEYWORD)`
  form. There is no "trigger action" to perform even if enforced.
- The only meaningful enforcement of `:TRIGGER:` would be: when
  evaluating a `DONE` transition on heading H, also treat H as blocked
  if *any other* heading in the tracked files lists H's `:ID:` in its
  own `:BLOCKER:` — but that's just `:BLOCKER:` enforcement again,
  from the other heading. The distinct case worth asking about is
  whether a relationship recorded *only* via `:TRIGGER:` (on the
  blocking heading, with no mirrored `:BLOCKER:` on the blocked one)
  should also be enforced. Doing that would require a *reverse* search
  — scanning every heading across every tracked file for a `:TRIGGER:`
  containing this heading's ID — which is a materially different, much
  heavier mechanism (multi-file scan, closer to `org_query`'s own
  machinery) than the direct `org-id-find` per listed ID this task's
  brief explicitly anchors the design on ("reuse org-id-find the same
  way the existing clock-marker check... already do").
- SKILL.md already tells authors to pick *one* direction ("equivalent
  in intent, not both required") — so the practical convention this
  project should settle on is: **`:BLOCKER:` is the enforced, canonical
  direction; `:TRIGGER:` remains documentation-only**, same as it is
  today. Authors who want enforcement should record the relationship as
  `:BLOCKER:` on the blocked heading.
- Small optional follow-up (not required for this task, flagged for
  whoever implements to decide): add one clarifying sentence to
  SKILL.md's `:TRIGGER:` bullet (`SKILL.md:154-158`) stating explicitly
  that it is never enforced, only `:BLOCKER:` is — prevents future false
  confidence that recording `:TRIGGER:` alone gets you protection.

### 4. Keep CLAUDE.md in sync

CLAUDE.md's "Dependencies between tasks" section currently states: "this
project's own `org-blocker-hook` function
(`claude-code-ide-org--blocker-clock-running-p`) only blocks on a running
clock today, not on `:BLOCKER:`". That sentence becomes stale the moment
this ships. Update it to name both functions and describe the new
enforcement (mirroring this project's own recent diligence about
catching stale citations — see the 2026-08-05 "Annotate NEXT/TODO
dependencies" commit, e889c35, which fixed exactly this kind of drift
elsewhere in the same file). This is a doc-only edit alongside the code
change, not a separate task.

## Files

- `modules/tools/claude-code-ide-org/config.el` — new
  `claude-code-ide-org--blocker-unresolved-dependency-p` function (~20
  lines) plus one new `add-hook` line, both right next to the existing
  clock-blocker function and its registration.
- `modules/tools/claude-code-ide-org/config-test.el` — new tests in the
  existing "Native transition enforcement" section (`config-test.el:691`
  onward), same fixture (`claude-code-ide-org-test--with-heading`) and
  style as the existing `blocker-hook-*` tests.
- `CLAUDE.md` — update the "Dependencies between tasks" paragraph to
  reflect that `:BLOCKER:` is now actually enforced.
- `.claude/skills/org/SKILL.md` — optional: clarify that `:TRIGGER:` is
  documentation-only, never enforced (see Design §3).

## Tests to add (`config-test.el`)

Following the existing `claude-code-ide-org-test-blocker-hook-*` naming
and structure (`config-test.el:703-768`):

1. **`blocker-hook-blocks-done-while-blocker-unresolved`** — heading `id`
   gets `:BLOCKER: other-id`; `other-id` is a second heading left `TODO`.
   Requesting `DONE` on `id` must return the `Error:...blocked` string
   (same assertion pattern as
   `blocker-hook-blocks-done-while-clock-running`) and leave `id`'s state
   unchanged on disk.
2. **`blocker-hook-permits-done-when-blocker-resolved`** — same setup,
   but `other-id` is `DONE` first; requesting `DONE` on `id` must
   succeed (`"TODO state set to DONE"`).
3. **`blocker-hook-permits-done-when-blocker-cancelled`** — same as #2
   but `other-id` is `CANCELLED` instead of `DONE` — confirms
   `org-entry-is-done-p` (not a literal `"DONE"` string check) is really
   what's being used.
4. **`blocker-hook-permits-done-with-no-blocker-property`** — heading
   with no `:BLOCKER:` at all transitions to `DONE` normally (regression
   guard: the new function must never fire on a heading that never
   opted in). This exercises `(split-string (or (org-entry-get nil
   "BLOCKER") "") )` on an empty string — `split-string`'s `OMIT-NULLS`
   argument defaults to non-nil whenever `SEPARATORS` is nil (the case
   here), so `(split-string "")` returns `nil`, not `("")`; that's what
   makes the `dolist` a no-op and the function permit. Load-bearing for
   the `(or ... "")` idiom — worth a one-line comment at the call site
   so a later "simplification" doesn't reintroduce an error on the
   no-property case.
5. **`blocker-hook-requires-all-listed-blockers-resolved`** — `:BLOCKER:
   other-id-1 other-id-2`; only one resolved — still blocked; both
   resolved — permitted. Exercises the "every listed ID" semantics from
   SKILL.md.
6. **`blocker-hook-ignores-unresolvable-blocker-id`** — `:BLOCKER:
   bogus-id`; requesting `DONE` must succeed (stale/typo'd IDs never
   block, per the fail-open design decision above).
7. **`blocker-hook-blocker-can-resolve-across-files`** — mirrors the
   existing `refile-across-files-and-saves-both` test's two-file setup
   (`config-test.el:636`): the blocking heading lives in a second file,
   found via `org-id-find` after `org-id-update-id-locations` covers
   both files. Confirms the check isn't accidentally scoped to the
   current buffer only (a real risk here since `:BLOCKER:` IDs commonly
   point across `TODO.org`/`DONE.org`, per the real
   `7eb7dd8d`/`b95b9fba` example already in this repo). `org-id-find`
   opens the second file's buffer as a side effect of resolving the
   blocker marker — mirror `refile-across-files-and-saves-both`'s own
   `unwind-protect` cleanup exactly (`config-test.el:664-667`:
   `set-buffer-modified-p nil` then `kill-buffer`), or this test leaks
   an open buffer into every test that runs after it in the same batch.

All seven follow the existing fixture (`claude-code-ide-org-test--with-
heading`), inserting a second heading exactly like
`blocker-hook-only-blocks-own-heading` already does
(`config-test.el:735-768`), including its same care around excluding the
single-NEXT-per-level triggers where they'd otherwise interfere
incidentally.

## Verification

- `bin/test`: confirmed baseline today is 122/122 passing. All 7 new
  tests above must pass alongside the existing 122, with no regressions
  — in particular `blocker-hook-only-blocks-own-heading` and
  `set-todo-reports-blocked-transition` (which locally shadows
  `org-blocker-hook` via `let`, so is unaffected by adding a second
  permanent hook function) must still pass unchanged.
- Live smoke test via the `org-dev` skill: reload `config.el` into the
  running Doom Emacs, then use `emacsclient` (read-only queries only, or
  a scratch heading — never the real `TODO.org` heading transitions) to
  confirm: (a) a scratch heading with an unresolved `:BLOCKER:` refuses
  `DONE` via `org_set_todo` with the expected error string; (b)
  resolving the blocker first (setting the blocking heading to `DONE`)
  then permits it; (c) the real, now-satisfied `7eb7dd8d` →
  `b95b9fba-...` example in `TODO.org` still transitions cleanly if/when
  its own work reaches `DONE` — read-only confirmation that the new
  function's presence doesn't accidentally block a legitimately-
  satisfied real-world case.
- Skill-content verification (the SKILL.md `:TRIGGER:`-clarification
  edit, if included) is inherently manual per CLAUDE.md's testing rule
  — no mechanical test for doc accuracy; a read-through is the
  verification.

## After approval

Per CLAUDE.md's Plan-link rule, add
`[[file:~/.claude/plans/blocker-hook-enforcement.md][Plan]]` to `TODO.org`
heading `087e73e9-bb24-43b6-a972-b7f103d04017`'s body as soon as this
plan is finalized — a separate step requiring its own explicit approval
before any `DOING` transition or code edit proceeds, per the "Plan
approval isn't heading-wording/DOING approval" rule.
