# Enforce a single NEXT action per level of the task tree

## Context

GTD's "single next action" idea says at most one heading at a given
level of the task tree should ever be `NEXT` at a time. Today nothing
enforces that in org — `NEXT` can accumulate on multiple siblings
silently, and a sibling group can be left with an unambiguous single
`TODO` survivor that never gets promoted. This mirrors the existing,
already-shipped "Native transition enforcement" feature (DONE-blocked-
while-clocked, auto-clock-in-on-DOING) — same mechanism
(`org-trigger-hook`/`org-blocker-hook`, registered globally so they
catch a hand-edit exactly like a Claude tool call), applied to a new
invariant. TODO.org heading ID `05da96ad-37de-41d4-b918-692644749394`
("Skill logic" → "Enforce a single NEXT action per level of the task
tree") is the tracked task; this plan is its implementation record —
per CLAUDE.md, the heading itself gets trimmed to a concise
description plus this plan's link, not a transcription of this file.

Two decisions were made explicitly by the user during planning (not
engineering judgment calls):
- A sibling group of size 1 (no siblings at all) is **never**
  auto-promoted or re-promoted — auto-promotion only resolves conflicts
  among ≥2 competing candidates. A solitary heading can sit in plain
  `TODO` indefinitely.
- Hook-driven automatic transitions log **identically to a manual
  transition** (no logging suppression) — plus an explicit note
  explaining *why* the automatic change happened, so `Auto-demoted`/
  `Auto-promoted` entries are distinguishable from ordinary state
  changes in the LOGBOOK.

## Design

### Shared sibling-walking helper

No existing helper walks "siblings of the heading at point" (confirmed
by search — `org-map-entries` elsewhere in config.el is always scoped
to `'file`). Add one, built on org's own `org-get-next-sibling`/
`org-get-previous-sibling` (verified: these naturally stop at the
enclosing parent's boundary, or the file's boundary for top-level
headings — no special-casing needed for "top-level headings sharing no
parent"):

```elisp
(defun claude-code-ide-org--map-siblings (function &optional include-self)
  "Call FUNCTION with point at each same-level sibling of the heading
at point. Self is included only when INCLUDE-SELF is non-nil. Point is
restored afterward."
  (save-excursion
    (org-back-to-heading t)
    (when include-self (funcall function))
    (save-excursion (while (org-get-next-sibling) (funcall function)))
    (save-excursion (while (org-get-previous-sibling) (funcall function)))))
```

### Explanatory note on every automatic transition

Reuse the existing `claude-code-ide-org--append-to-drawer` (config.el
~line 266 — the same find-or-create-drawer helper already used for
`:SESSIONS:` entries) to append a plain note line into `:LOGBOOK:`
right after each automatic `org-todo` call, e.g.:

```elisp
(claude-code-ide-org--append-to-drawer
 "LOGBOOK"
 (format "- Note taken on %s \\\\\n  %s"
         (format-time-string "[%Y-%m-%d %a %H:%M]")
         cause-text))
```

This is a direct, non-interactive buffer insertion — it does not go
through org's interactive note-prompt machinery, so it can never hang
a batch run or pop a note buffer. `org-todo` itself still runs
unmodified, so whatever the user's real `org-todo-log-states`/
`org-log-done` config does for a normal transition still happens
exactly as it would manually; this note is additive.

### Two trigger-hook functions

```elisp
(defun claude-code-ide-org--trigger-demote-conflicting-next (change-plist)
  "For `org-trigger-hook': GTD's \"single next action\" per level. The
moment any heading's TODO state becomes NEXT, demote every OTHER
heading in the same sibling group that is currently NEXT back to TODO,
with an explanatory :LOGBOOK: note. No-op unless CHANGE-PLIST's :to is
\"NEXT\". Demoting a sibling re-enters `org-todo' (hence this hook)
for that sibling -- safe by construction, see
`claude-code-ide-org--trigger-auto-promote-sole-todo's docstring."
  (when (equal (plist-get change-plist :to) "NEXT")
    (let ((new-next-heading (org-get-heading t t t t)))
      (claude-code-ide-org--map-siblings
       (lambda ()
         (when (equal (org-get-todo-state) "NEXT")
           (org-todo "TODO")
           (claude-code-ide-org--append-to-drawer
            "LOGBOOK"
            (format "- Note taken on %s \\\\\n  Auto-demoted: superseded by sibling \"%s\" becoming NEXT."
                    (format-time-string "[%Y-%m-%d %a %H:%M]")
                    new-next-heading))))))))

(defun claude-code-ide-org--trigger-auto-promote-sole-todo (_change-plist)
  "For `org-trigger-hook': whenever this heading's sibling group (self
included, group size >= 2) has exactly one member in TODO and none in
NEXT, promote that lone TODO to NEXT, with an explanatory :LOGBOOK:
note. Deliberately unconditional on CHANGE-PLIST's :to -- a transition
to DONE/CANCELLED/WAIT/MAYBE/DOING on ANY sibling can be what drops
the group to one TODO survivor, not just a transition into/out of
NEXT. Always re-derives group state fresh from the live buffer, never
from CHANGE-PLIST -- this is what keeps this safe against re-promoting
a heading that `claude-code-ide-org--trigger-demote-conflicting-next'
just demoted: by the time this function evaluates, any sibling still
NEXT already shows as NEXT in the buffer, so the next-p guard below
correctly refuses to create a second simultaneous NEXT. A group of
size 1 (no siblings) is never eligible -- auto-promotion only resolves
conflicts among competing candidates, it is not a rule that a solitary
heading must always be NEXT."
  (let (todo-markers next-p (group-size 0))
    (claude-code-ide-org--map-siblings
     (lambda ()
       (setq group-size (1+ group-size))
       (let ((state (org-get-todo-state)))
         (cond ((equal state "NEXT") (setq next-p t))
               ((equal state "TODO") (push (point-marker) todo-markers)))))
     'include-self)
    (when (and (> group-size 1) (not next-p) (= (length todo-markers) 1))
      (org-with-point-at (car todo-markers)
        (org-todo "NEXT")
        (claude-code-ide-org--append-to-drawer
         "LOGBOOK"
         (format "- Note taken on %s \\\\\n  Auto-promoted: sole remaining TODO in its sibling group."
                 (format-time-string "[%Y-%m-%d %a %H:%M]")))))))

(with-eval-after-load 'org
  (add-hook 'org-trigger-hook #'claude-code-ide-org--trigger-demote-conflicting-next)
  (add-hook 'org-trigger-hook #'claude-code-ide-org--trigger-auto-promote-sole-todo))
```

Place immediately after the existing "Native transition enforcement"
block in config.el (~line 1550), extending its existing `with-eval-
after-load 'org` registration form rather than adding a second one.

**Why no re-entrancy boolean guard** (unlike `claude-code-ide-org--
auto-clock-in-active`): a blanket "skip while re-entrant" guard would
disable exactly the nested re-derivation that prevents a double-NEXT
race. Instead, correctness is structural:
- `org-trigger-hook` runs at the very end of `org-todo`, so a nested
  `org-todo` call cannot corrupt outer work still pending.
- Termination is bounded: demote only moves NEXT→TODO and only fires
  on `:to == "NEXT"`; a heading it just demoted can't re-satisfy that
  precondition on itself. Promote only moves TODO→NEXT; a heading it
  just promoted no longer counts as a TODO candidate. Recursion depth
  is bounded by sibling count, not unbounded.
- Interaction with the existing pair of hooks is null: the DONE
  blocker only blocks `:to "DONE"`; auto-clock-in only fires on
  `:to "DOING"`. Neither new function's transitions (→TODO, →NEXT) can
  be blocked or open a clock.

Keep the two behaviors as **separate** functions (matching the
existing one-hook-per-concern precedent) rather than merging into one,
even though both walk the same `--map-siblings` helper — the trigger
conditions genuinely differ (conditional on `:to` vs. unconditional
scan).

## Test coverage (config-test.el, "Native transition enforcement" section, ~line 644-760)

New `ert-deftest`s:
1. `demotes-old-next-sibling-among-top-level-headings` — A=NEXT, B=TODO; set B→NEXT; A demoted to TODO with an "Auto-demoted" note, B stays NEXT.
2. `demotes-old-next-sibling-among-direct-children` — same, one level down, proving parent-scoping (not just top-level).
3. `does-not-touch-next-in-unrelated-subtree` — `** B` under `* P1` going NEXT must not touch `** C` under `* P2`.
4. `promotes-sole-remaining-todo-when-sibling-goes-done` — A=NEXT→DONE, B=TODO, C=TODO; reduce group to exactly one TODO via a non-NEXT transition and confirm promotion with an "Auto-promoted" note.
5. `leaves-non-todo-sole-survivor-alone` — sole remaining candidate is WAIT/MAYBE/DOING, not TODO; must not be force-promoted.
6. `leaves-two-todos-alone` — group with two TODOs and no NEXT: no promotion (off-by-one guard).
7. `single-next-no-sibling-conflict-is-noop` — one NEXT among otherwise-non-TODO siblings; nothing changes.
8. `does-not-recreate-double-next-on-demote-then-promote-race` — 2-sibling group A=NEXT, B=TODO; set B→NEXT; confirm exactly one of {A,B} ends up NEXT afterward (A must not be re-promoted after being demoted).
9. `pre-existing-invalid-state-collapses-to-one-next` — hand-construct 2 siblings already (invalidly) NEXT, transition a 3rd sibling to NEXT; exactly one NEXT survives.
10. `fires-through-bare-org-todo` — mirrors `...auto-clocks-in-on-direct-org-todo`, proving enforcement lives in org itself.
11. `lone-heading-with-no-siblings-is-not-auto-promoted` — the standard single-fixture heading (no siblings) landing on TODO is never auto-promoted, and a manually-demoted solitary NEXT stays TODO.

**Required sweep, not optional:** confirmed live that
`claude-code-ide-org-test-blocker-hook-only-blocks-own-heading`
(config-test.el ~688) inserts a second top-level sibling (`other-id`,
left at default `TODO`) and then transitions `id` to `DOING` — at that
moment the two-member group is `{id=DOING, other-id=TODO}`, exactly
one TODO, none NEXT, so the new promote hook fires and silently flips
`other-id` to NEXT mid-test. Audit every existing test that inserts a
second/third same-level heading and transitions any member; fix
affected ones the same way `claude-code-ide-org-test-set-todo-reports-
blocked-transition` already isolates itself — locally `let`-shadow
`org-trigger-hook` (or rebind to just the subset of hook functions
that test actually intends to exercise) so unrelated fixtures aren't
silently mutated by an unrelated global hook.

Drop refile/capture-based test scenarios — neither goes through
`org-todo`, so no trigger fires at refile/insert time; the invariant
is only corrected lazily on that group's next actual state change,
matching the original spec's "or it was already the case" phrasing.
Worth one sentence of comment in config.el, not a test.

## TODO.org heading update (separate from this plan file)

Per CLAUDE.md, no transcription of this plan into org. Trim the
heading body to a short description of intent (single-NEXT-per-level,
mirroring GTD) and add `[[file:~/.claude/plans/twinkling-meandering-graham.md][Plan]]`
when the heading transitions to `DOING` — not before, per the existing
"Plan Mode gets a link added at DOING" rule and the separate approval-
gate rule for heading edits. This plan does not itself transition the
heading to DOING.

## Verification

1. `bin/test` — full suite must pass, including all new tests above
   and the swept/fixed pre-existing ones. Watch specifically for the
   `claude-code-ide-org-test-blocker-hook-only-blocks-own-heading`
   contamination identified above.
2. Live check in the running Doom Emacs (per the org-dev skill):
   reload config.el, hand-create two sibling `TODO` headings in a
   scratch file, set one to `NEXT` via `M-x org-todo`, confirm no
   interactive note prompt appears and the LOGBOOK gets the plain
   state-change entry; manually set the other to `NEXT` too and
   confirm the first is demoted back to `TODO` with an "Auto-demoted"
   LOGBOOK note; delete/DONE one sibling from a 2-TODO group and
   confirm the survivor auto-promotes with an "Auto-promoted" note.
