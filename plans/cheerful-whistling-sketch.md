# Fix org-agenda-files resolving to nothing (agenda + org_query/org_clock_report)

## Context

User asked why `TODO.org` (symlinked as `~/org/claude-code-ide-org/TODO.org`)
doesn't show up in Emacs's interactive org-agenda view. Investigation (via
live `emacsclient` calls against the running Emacs) found the root cause:
Doom's `org-agenda-files` is `("~/org")` — a bare directory string — and
org's directory-expansion for `org-agenda-files` is **non-recursive**.
`TODO.org` lives one level below `~/org` (inside the `claude-code-ide-org/`
subdirectory), so `(org-agenda-files)` resolves to `nil`.

Digging further surfaced a second, more consequential bug: this project's
own MCP tools are *also* blind right now. `claude-code-ide-org--tracked-files`
(config.el:412-414) is `(or claude-code-ide-org-query-files org-agenda-files)`
— it returns the **raw** `org-agenda-files` variable, not the resolved file
list the `(org-agenda-files)` *function* produces. Passing a bare directory
string straight to `org-ql-select` doesn't expand it the way the interactive
agenda does. Confirmed live:

```
(claude-code-ide-org-query "(todo)") → "No matches."
```

...despite an active `DOING` heading in TODO.org right now. This function
backs three consumers: the stale-interval recovery scan (config.el:469),
`org_query` (config.el:1136), and unscoped `org_clock_report`
(config.el:1288) — all three are currently scanning zero files whenever the
fallback-to-`org-agenda-files` path is taken. Existing tests never caught
this because every test in `config-test.el` binds
`claude-code-ide-org-query-files` directly to an explicit flat file list —
the `org-agenda-files`-with-a-directory fallback path has no coverage at all.

We also discussed whether `DONE.org` (the archive target) should be
reachable for retrospective clock reporting. Conclusion: not urgent to
implement now — `DONE.org` isn't symlinked into `~/org` today, so it's not
actually in scope for either bug fix below. But it's worth capturing as a
documented future consideration so it doesn't need to be re-derived: org's
clocktable machinery has a purpose-built mechanism for this
(`:scope 'agenda-with-archives`, which follows each agenda file's
`#+ARCHIVE:`/`org-archive-location` automatically) rather than needing
`DONE.org` symlinked alongside `TODO.org`.

## Approach

Two independent fixes plus one captured-for-later item. Doom config lives
outside this git repo (personal dotfiles, no test harness); the config.el
fix lives in this repo and needs `bin/test` coverage per this project's
engineering-practices rule.

### 1. Capture as org headings (before any code changes)

Per CLAUDE.md's standing rule ("any time a new task is described in
conversation, create an org heading for it"), use `org_capture` to add:

- One heading under **Developer tooling** (same cluster as the
  currently-DOING checkbox-discipline task) for the actual fix:
  *"Fix org-agenda-files/tracked-files resolving to nothing (agenda +
  org_query/org_clock_report)"*, tag `:code:`, state `NEXT` (decided,
  about to be worked). Transition to `DOING` (`org_set_todo` +
  `org_clock_in`) when implementation actually starts, per the standing
  DOING-transition rule — not yet, since we're still in planning.
- One `MAYBE` heading (new roadmap entry, e.g. under **Clock lifecycle &
  visibility**) capturing the deferred archives question: *"Consider
  `:scope 'agenda-with-archives` for retrospective org_clock_report once
  DONE.org (or any archive) is reachable from tracked-files"* — with a
  short body recording the reasoning above so it isn't re-litigated from
  scratch.

Both headings get `:ID:` + `:CREATED:` per CLAUDE.md's standing rules.

### 2. Doom config: make `org-agenda-files` resolve recursively

File: `~/.config/doom/config.el`, in the existing `(after! org ...)` block
(where `org-clock-out-when-done`, `org-clock-persist`, etc. are already
set — see CLAUDE.md's "Emacs integration" section for the current
contents).

Add:

```elisp
(setq org-agenda-files (directory-files-recursively org-directory "\\.org$"))
```

Notes for whoever implements this:
- This is a one-time scan at config-load time, not dynamic — a newly
  symlinked `.org` file under `~/org` needs an Emacs restart (or
  re-evaluating this line) to be picked up. Accepted tradeoff, matches the
  user's stated preference ("leaning towards making it recursive").
- `~/org/.orgids` does not match `\\.org$` (ends in `ids`, not `org`), so
  no false positive there.
- `DONE.org` is not currently symlinked anywhere under `~/org`, so this
  change alone does not pull archives into the agenda — consistent with
  the "not urgent" conclusion above.
- This is a personal-dotfiles change outside the git repo; no automated
  test is possible. Verification is manual (see below).

### 3. config.el: fix `claude-code-ide-org--tracked-files` to resolve directories

File: `modules/tools/claude-code-ide-org/config.el:412-414`.

Change:

```elisp
(defun claude-code-ide-org--tracked-files ()
  "Files to scan for stale open intervals (and, later, org_query)."
  (or claude-code-ide-org-query-files org-agenda-files))
```

to call the resolving function instead of returning the raw variable:

```elisp
(defun claude-code-ide-org--tracked-files ()
  "Files to scan for stale open intervals, org_query, and org_clock_report."
  (or claude-code-ide-org-query-files (org-agenda-files)))
```

(Also drop the stale "(and, later, org_query)" — `org_query` is built now,
not later; update the docstring to name all three current consumers, matching
the pattern already used at config.el:544/566/601/1091/1122/1259.)

This fixes all three consumers that fall back to `org-agenda-files`
(recovery-scan, `org_query`, unscoped `org_clock_report`) in one place,
without touching any call site.

**Test coverage** (`config-test.el`): every existing test that exercises
`--tracked-files` binds `claude-code-ide-org-query-files` directly to an
explicit file list, so the `org-agenda-files` fallback path — and
specifically its directory-expansion behavior — has zero coverage today.
Add at least one new test (near the existing `org_query`/recovery-scan
tests, e.g. alongside the `claude-code-ide-org-test-capture-id-immediately-resolvable`-style
fixtures) that:
- leaves `claude-code-ide-org-query-files` nil,
- sets `org-agenda-files` to a **directory** containing a scratch `.org`
  file (using this file's existing `claude-code-ide-org-test--with-*`
  scratch-directory helpers rather than real user files),
- calls `claude-code-ide-org-query` (or checks `--tracked-files` directly)
  and asserts the scratch file's heading is actually found —
  i.e. reproduces the "No matches." bug and proves it's fixed.

### 4. Branch

This touches tracked repo code (`config.el`) with new test coverage and a
real (if small) behavior fix — per CLAUDE.md's branch rule, do this on
`feature/fix-tracked-files-resolution` rather than directly on `main`. The
Doom config edit (step 2) is outside the repo and not subject to that rule.

## Verification

1. `bin/test` passes, including the new directory-fallback test.
2. After the Doom config change (requires either restarting Emacs or
   manually re-evaluating the updated `(after! org ...)` block —
   state which one was actually done when reporting back, per this
   project's reload-transparency convention):
   - `emacsclient -e '(org-agenda-files)'` returns a list containing
     `TODO.org`'s resolved path (not nil).
   - Interactively open the org agenda (`org-agenda`) and confirm the
     `DOING` heading from `TODO.org` appears in the global TODO list.
3. `emacsclient -e '(claude-code-ide-org-query "(todo)")'` returns the
   actual `DOING` heading instead of `"No matches."`.
4. `org_clock_report` with no `:ID:` returns a nonzero total reflecting
   the currently-open clock on TODO.org's `DOING` heading.
5. Confirm the two captured org headings (NEXT fix task, MAYBE archives
   note) exist in TODO.org with `:ID:`/`:CREATED:` set, before archiving
   anything — and update the NEXT heading's state/checkboxes to match
   whatever actually happened, per CLAUDE.md's Plan-checklist-reconciliation
   rule, before it's ever marked DONE.
