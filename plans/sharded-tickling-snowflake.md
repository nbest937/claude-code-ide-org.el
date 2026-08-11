# Case study: apply "maximum Emacs, minimal shell" to the statusline

## Context

`TODO.org`'s "Evaluate choice of shell and standardize all project
scripts" (`:ID: 84b7d8b3-5161-4146-9167-0e7e2100e365`) lists five
options for this project's `bin/`/`bin/hooks/` scripts, reordered by the
user to lead with **option 1: pure Emacs** — push JSON parsing and all
logic into Elisp (native `json-read-file`, no external `jq`/Python
dependency), shrinking the shell wrapper to a near-unconditional stub:
write stdin to a temp file, call `emacsclient -e` with that file's path,
cat whatever comes back. This plan applies that option to the statusline
feature specifically, as a concrete case study the rest of the decision
can be judged against — paired with a POSIX `sh` wrapper, since a truly
minimal stub has no need for fish's (or bash's) extra features.

Current state (built earlier this session): `bin/statusline.fish` still
does one piece of real shell-side logic — `jq -r
'.model.display_name // empty'` — to pull the model name out of the
stdin JSON, then concatenates it with the task-info string Elisp
produces (`claude-code-ide-org-write-statusline-report`, which currently
only handles the task-info half). This plan removes that last piece of
shell-side JSON handling.

## Approach

**Elisp (`config.el`), in the existing "Statusline" section:**

- New `claude-code-ide-org--statusline-model-name (input-path)`: reads
  the statusLine hook JSON payload from INPUT-PATH via `json-read-file`
  (bound to `json-object-type 'alist`, matching this file's existing
  JSON convention — see `claude-code-ide-org--session-context-hook-json`
  and the audit-log encoder), and returns `model.display_name`, or `""`
  if the field is absent or the file is unparseable. Wrapped in
  `condition-case` so a malformed/missing payload fails soft, matching
  every other hook-facing function in this file (`claude-code-ide-org-
  write-session-context-report`'s docstring documents the same
  fail-soft convention).
- `claude-code-ide-org-write-statusline-report` gains an `input-path`
  parameter (was output-path only — confirmed no existing test binds
  the old one-argument signature, so this is a clean signature change,
  not a breaking one): writes `(claude-code-ide-org--statusline-model-
  name input-path)` followed by `(claude-code-ide-org--statusline-task-
  string)` to `output-path`. `--statusline-task-string` itself is
  unchanged — the five existing tests for it keep passing as-is.

**Shell wrapper, renamed `bin/statusline.fish` → `bin/statusline.sh`:**

```sh
#!/bin/sh
in="$(mktemp)"
out="$(mktemp)"
cat >"$in"
emacsclient -e "(claude-code-ide-org-write-statusline-report \"$in\" \"$out\")" >/dev/null 2>&1
cat "$out" 2>/dev/null
rm -f "$in" "$out"
```

No `jq`, no fish-isms, no string manipulation of any kind — every
existing comment currently documenting the fail-soft/temp-file
conventions in the fish version moves to the Elisp docstrings instead,
since that's now where the logic actually lives.

**Wiring (`.claude/settings.json`):** update the `statusLine.command`
from `fish ${CLAUDE_PROJECT_DIR}/bin/statusline.fish` to `sh
${CLAUDE_PROJECT_DIR}/bin/statusline.sh`.

## Files

- `modules/tools/claude-code-ide-org/config.el` — new
  `claude-code-ide-org--statusline-model-name`, updated
  `claude-code-ide-org-write-statusline-report` signature.
- `modules/tools/claude-code-ide-org/config-test.el` — new tests (see
  Verification).
- `bin/statusline.sh` (new, replaces `bin/statusline.fish`).
- `.claude/settings.json` — `statusLine.command` updated.

## Verification

- `bin/test`: new regression tests —
  `claude-code-ide-org--statusline-model-name` returns the right value
  for a well-formed payload, `""` for a payload missing the field, and
  `""` (not an error) for malformed JSON; an end-to-end
  `claude-code-ide-org-write-statusline-report` test writing a real
  payload to one temp file and asserting the combined model+task output
  on the other. All 5 existing `--statusline-task-string` tests must
  keep passing unchanged.
- Live: reload `config.el` (per the org-dev skill — this is a plain
  function-body/signature change, no `after!`/hook-registration
  involved, so a live reload is sufficient, no restart needed), then
  run `bin/statusline.sh` directly with a fabricated JSON payload on
  stdin and confirm the output matches what the old fish version
  produced for the same live clock state.
- Validate `.claude/settings.json` with `jq -e .` after the edit, same
  as when `bin/statusline.fish` was first wired in.
- Update the "Evaluate choice of shell" TODO with a note that this case
  study is done and where to find it, so the decision has a concrete
  data point to reference instead of only hypothetical tradeoffs.
