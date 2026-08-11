# Show the TODO keyword, not just clocked in/out, in the statusline

## Context

`claude-code-ide-org--statusline-task-string` (config.el:768-796) renders the
statusline's task info as `" | %s [%s] (%s, %s total)"`, where the third slot
(`status-label`) is currently just `"clocked in"` or `"clocked out"`, decided
by `(org-clocking-p)`.

That binary conflates states this project now distinguishes since the
PLANNING-state feature landed (TODO.org b95b9fba): a `PLANNING` task and a
`DOING` task both show "clocked in" even though they mean different things
(still designing vs. actively implementing), and a `WAIT` task and a `DONE`
task pulled from `org-clock-history` both show "clocked out" even though one
is blocked and the other finished. `status-label`'s `org-clocking-p` check is
also redundant: it's just re-deriving the same binary that already decided
which `marker` branch was taken one `let` binding earlier, not reading
anything from the heading itself.

## Approach

In `claude-code-ide-org--statusline-task-string`, `org-with-point-at marker`
already puts point on the heading in question (it's how `id`/`name` are read
via `org-entry-get`/`org-get-heading` two lines above). Read the heading's
actual TODO keyword there instead of re-checking `org-clocking-p`:

```elisp
(status-label (or (org-get-todo-state) ""))
```

replacing the current:

```elisp
(status-label (if (org-clocking-p) "clocked in" "clocked out"))
```

Same `let*` slot, same downstream `format` call — no other change to the
function's structure, truncation logic, or the `org-clock-sum`/total-minutes
computation.

## Files to change

- `modules/tools/claude-code-ide-org/config.el` — the one-line swap above.
- `modules/tools/claude-code-ide-org/config-test.el` — update the two
  existing tests that assert on the literal "clocked in"/"clocked out"
  strings, since the fixture heading's keyword is `"TODO"` at the point
  those tests clock it in/out (`claude-code-ide-org-clock-in` doesn't itself
  change the TODO keyword):
  - `claude-code-ide-org-test-statusline-shows-clocked-in-task` (line 1258) —
    update the regex to expect `(TODO, ` instead of `(clocked in, `.
  - `claude-code-ide-org-test-statusline-shows-clocked-out-task-from-history`
    (line 1265) — update the regex to expect `(TODO, ` instead of
    `(clocked out, `.
  - `claude-code-ide-org-test-statusline-truncates-long-heading-name` (line
    1273) and `...-prefers-running-clock-over-history` (line 1284) don't
    assert on `status-label` text, so they need no change.
  - Add one new regression test proving the actual motivation: set the
    heading to `PLANNING` (via `claude-code-ide-org-set-todo`) before
    clocking in, and assert the result contains `(PLANNING, `, showing it's
    now distinguishable from `DOING` — the exact ambiguity this change
    fixes.

## Verification

- `bin/test` — all `--statusline-task-string` tests pass, including the new
  `PLANNING`-vs-`DOING` distinction test; full suite still green (currently
  118/118 before this change).
- Live: reload `config.el` in the running Doom Emacs, clock into a real
  heading, and confirm `bin/statusline.sh < /dev/null`-style manual
  invocation (or just watching the live Emacs statusline) shows the actual
  keyword (e.g. `DOING`) instead of `clocked in`.
