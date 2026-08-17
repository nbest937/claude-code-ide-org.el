# Evaluate choice of shell and standardize all project scripts

`:ID: 84b7d8b3-5161-4146-9167-0e7e2100e365`

## Context

`TODO.org`'s heading lists five options for standardizing this project's
`bin/`/`bin/hooks/`/`.claude/hooks/` scripts. Options 4 and 5 (fish-vs-bash
for `bin/statusline.*` specifically) are already moot: the sibling DONE
case-study heading (`e202e93d-cfa7-4d0a-8721-8f06428bc1e4`,
[[file:~/.claude/plans/sharded-tickling-snowflake.md][Plan]]) rewrote
`bin/statusline.fish` as `bin/statusline.sh` — plain POSIX `sh`, no `jq`, no
fish — by moving all JSON parsing and formatting into Elisp
(`claude-code-ide-org--statusline-model-name`,
`claude-code-ide-org-write-statusline-report`, `config.el:798-828`). The
live decision is options 1 vs. 2 vs. 3: pure-Emacs-with-temp-file-handoff,
Python, or a plain-shell (bash/sh) baseline — and whether to retrofit the
winning pattern onto the other existing scripts or only apply it going
forward.

**Full current-state inventory** (`bin/`, `bin/hooks/`, `.claude/hooks/`):

| Script | Shell | Uses `jq`? | Shape |
|---|---|---|---|
| `bin/statusline.sh` | POSIX `sh` | no | stub: stdin→tmpfile→emacsclient→cat tmpfile out |
| `bin/hooks/session-pause` | bash | yes — `jq -R -s .` to **safely encode** `session_id` before interpolating it into an `emacsclient -e` elisp expression string | extracts `session_id`, builds an elisp literal in shell, calls `emacsclient -e "(...)"` |
| `bin/hooks/session-resume` | bash | yes — same `jq -R -s .` pattern | same shape as session-pause |
| `bin/hooks/exitplanmode-promote-planning` | bash (shebang only — no bash-only syntax used) | no | already temp-file→`emacsclient -e` with inline `json-read-file` on the Elisp side |
| `bin/hooks/posttooluse-record-planning-owner` | bash (shebang only) | no | same already-pure-Emacs shape as above, calling `claude-code-ide-org--maybe-record-planning-owner` |
| `bin/hooks/session-start-recovery-check` | bash — one real bash-ism (`[[ -s "$out" ]]`) | no | stub: stdin discarded → tmpfile out → emacsclient → cat if non-empty |
| `.claude/hooks/session-context.sh` | bash — same one bash-ism (`[[ -s "$out" ]]`) | no | same stub shape as above |
| `bin/hooks/pretooluse-transition-guard` | bash — `[[ ]]`, `case` | yes — three uses: extract `tool_name`/`state`/`id`, and build the deny-decision JSON via `jq -n` | synchronous, fail-**closed**, must emit specific PreToolUse JSON on stdout |
| `bin/clock-notify` | bash — `[[ ]]`, a shell function (`extract_response_text`) | yes — five separate `jq -r` queries sniffing four different possible `tool_response` JSON shapes | extracts fields, cross-checks against a live `emacsclient -e '(org-clocking-p)'` call, decides match/mismatch, shells out to `osascript` for a native notification |
| `bin/clock-notify-test` | bash | no (stubs its own fake `emacsclient`/`osascript` on `PATH`) | shell test harness for `clock-notify`'s decision logic — analogous in spirit to `bin/test`, but for a `bin/` shell script rather than `config.el` |
| `bin/check-org-dev-skill` | **fish** | no | ~72-line doctest asserting `org-dev/SKILL.md`'s claims against live state (MCP port, skill-zip magic bytes, `bin/test`'s `build-*` glob, `config.el` line-anchor citations) |
| `bin/test` | bash — `BASH_SOURCE`, array (`emacs_args+=(...)`) | no | meta test-runner (`emacs --batch ... -f ert-run-tests-batch-and-exit`); not a Claude-Code-hook wrapper at all |

**Surprising finding, not in the heading's own text:** `bin/check-org-dev-skill`
is fish and has been since it was added (`a6ae9da5`, 2026-07-28) — three
days *before* the "Evaluate choice of shell" heading was written
(2026-07-31) and its body's premise ("the statusline script is fish — the
only fish dependency anywhere in this project") was already false at the
time it was written. It was never flagged because it isn't wired into
`.claude/settings.json` as a hook — it's invoked manually/ad hoc, per
`DONE.org:532-538`, so it never showed up in a `bin/`-hooks audit the way
`statusline.fish` did. This is a second live fish dependency this decision
needs to cover, not a hypothetical.

## Design

### The convention (document in CLAUDE.md)

Add a new **"Scripting conventions"** subsection to `CLAUDE.md`, directly
after "Repository layout" (the heading body's own suggested location):

> Any script invoked by Claude Code (a hook command, the `statusLine`
> command) that receives a JSON payload — on stdin or via `$CLAUDE_*` env —
> must not parse or branch on that JSON in shell. No `jq`, no field
> extraction, no interpolating a parsed field into an `emacsclient -e`
> expression string (the exact hazard `bin/hooks/session-pause`/
> `-resume`'s old `jq -R -s .` encoding worked around — eliminated by
> construction once the shell layer never touches a parsed field at all).
> Write the payload to a temp file and pass *that path* to `emacsclient
> -e`; Elisp reads and parses it itself (`json-read-file`, no external
> dependency) and does all extraction, decision logic, and output
> formatting. The shell wrapper's only job is moving bytes: write stdin to
> a temp file, invoke `emacsclient` with the path, optionally `cat` back
> whatever Elisp wrote to a second temp file. See
> `claude-code-ide-org-write-statusline-report`/`bin/statusline.sh`
> (`config.el:816-828`) as the reference shape.
>
> Baseline shell for these stub wrappers is **POSIX `sh`**, not bash —
> once JSON handling moves out, nothing left in them needs a bash-only
> feature (`[[ ]]`, arrays, `BASH_SOURCE`). Scripts that are *not*
> JSON-payload wrappers — `bin/test` (uses `BASH_SOURCE`, arrays),
> `bin/clock-notify-test` and any future shell test harness (stub
> `PATH`, `trap`-based fixtures) — are unaffected; bash remains a fine,
> unremarkable choice for a local dev-tooling script a contributor
> invokes directly, not something Claude Code itself must be able to run
> unattended on an unknown user's machine.
>
> Fish is not used anywhere in this project [outside `bin/check-org-dev-skill`,
> a deliberate, documented exception — see its header comment for why /
> — the last fish holdout, `bin/check-org-dev-skill`, was rewritten to
> bash as part of this decision]. *(Pick the bracketed clause to match
> whichever check-org-dev-skill sub-decision below is actually taken —
> see "check-org-dev-skill" under Migration list.)*
>
> Python is deliberately not adopted for JSON handling: Emacs is already
> a harder, always-present dependency for every one of these scripts
> (each one ends in an `emacsclient -e` call regardless of shell), so
> routing JSON through Elisp instead of a second interpreter avoids
> adding a runtime assumption rather than trading one for another.

### Worked example 1 (primary): closing the actual injection-hazard case

`bin/hooks/session-pause` and `bin/hooks/session-resume` are the two
scripts the heading calls out **by name** as the motivating precedent
(`jq -R -s .` used specifically to avoid unsafe shell→elisp string
interpolation). They're also the cleanest, smallest migration, so this is
the plan's fully-specified worked example.

**Current** (`bin/hooks/session-pause`, current full file, `bin/hooks/session-pause:1-30`):
```sh
#!/usr/bin/env bash
input="$(cat)"
session_id="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"
if [[ -n "$session_id" ]]; then
  session_id_elisp="$(printf '%s' "$session_id" | jq -R -s .)"
else
  session_id_elisp="nil"
fi
emacsclient -e "(claude-code-ide-org-session-pause $session_id_elisp)" >/dev/null 2>&1
exit 0
```
(`bin/hooks/session-resume` is the same shape, calling
`claude-code-ide-org-session-resume` instead.)

**New Elisp** (`config.el`, next to `claude-code-ide-org-session-pause` at
`config.el:419` / `claude-code-ide-org-session-resume` at `config.el:461`):

```elisp
(defun claude-code-ide-org-session-pause-from-payload (payload-path)
  "Read the Stop hook JSON payload from PAYLOAD-PATH and call
`claude-code-ide-org-session-pause' with its session_id field (or nil
if absent/unparseable). Entry point for bin/hooks/session-pause's
temp-file handoff -- the shell wrapper never parses JSON or builds an
elisp expression string, closing the injection-shaped hazard the old
`jq -R -s .' encoding worked around by construction: a parsed field
is never interpolated into an `emacsclient -e' expression at all."
  (claude-code-ide-org-session-pause
   (condition-case nil
       (let* ((json-object-type 'alist)
              (payload (json-read-file payload-path)))
         (alist-get 'session_id payload))
     (error nil))))

(defun claude-code-ide-org-session-resume-from-payload (payload-path)
  "Same as `claude-code-ide-org-session-pause-from-payload', for
`claude-code-ide-org-session-resume'."
  (claude-code-ide-org-session-resume
   (condition-case nil
       (let* ((json-object-type 'alist)
              (payload (json-read-file payload-path)))
         (alist-get 'session_id payload))
     (error nil))))
```

(The existing `claude-code-ide-org-session-pause`/`-session-resume`
functions keep their current `(&optional session-id)` signature
unchanged — they're also called directly, docstring-documented as
callable via a bare `emacsclient -e`, and covered by existing tests at
`config-test.el:284-335`. The new `-from-payload` wrappers are additive,
not a replacement.)

**New shell wrapper** (`bin/hooks/session-pause`, replacing the whole file):
```sh
#!/bin/sh
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT
cat >"$tmpfile"
emacsclient -e "(claude-code-ide-org-session-pause-from-payload \"$tmpfile\")" >/dev/null 2>&1
exit 0
```
`bin/hooks/session-resume` mirrors this, calling
`-session-resume-from-payload`. Six lines each, no `jq`, no
conditionals, no bash-only syntax — same shape as
`bin/hooks/exitplanmode-promote-planning`'s existing temp-file stub.

### Worked example 2: `bin/clock-notify` (largest migration, has its own retiring test harness)

This is the richest script — five `jq` shape-sniffing queries, a decision
comparing the tool's claimed state against a live `emacsclient -e
'(org-clocking-p)'` cross-check, and an `osascript` call for the actual
macOS notification. Move all of it into Elisp:

- New `claude-code-ide-org--clock-notify-response-text (tool-response)`:
  reimplements `extract_response_text`'s four-shape fallback
  (`tool_response[0].text`, `tool_response.text`,
  `tool_response.content[0].text`, bare string, else the raw value) via
  `alist-get`/`aref` chains against the already-parsed alist — no `jq`
  needed since the whole payload is already in Elisp's hands via
  `json-read-file`.
- New `claude-code-ide-org--clock-notify-decision (payload-path)`: reads
  the PostToolUse payload, extracts `tool_name`/response text, computes
  `claim`/`claimed-clocking` (the `"Clocked in:"`/`"Clocked out:"`/`"No
  clock..."`/`"Error:"` case dispatch), calls `(org-clocking-p)` directly
  — no `emacsclient` subprocess needed, this Elisp *is* already running
  inside the target Emacs — and returns a `(title . body)` cons matching
  the current mismatch/match/unreachable-note text.
- New `claude-code-ide-org-notify-clock-change (payload-path)`: calls the
  above, then `(call-process "osascript" nil nil nil "-e" applescript
  title body)` directly — Elisp shelling out to `osascript` exactly as
  the bash script did, just from the Emacs side instead of the shell
  side. No output is written back to the shell wrapper at all (the
  notification *is* the side effect), so this is a **simpler** stub than
  statusline's — no output tempfile, no `cat`.
- New wrapper (`bin/clock-notify`, replacing the whole file):
  ```sh
  #!/bin/sh
  tmpfile="$(mktemp)"
  trap 'rm -f "$tmpfile"' EXIT
  cat >"$tmpfile"
  emacsclient -e "(claude-code-ide-org-notify-clock-change \"$tmpfile\")" >/dev/null 2>&1
  exit 0
  ```
- **Retire `bin/clock-notify-test` entirely.** Its whole reason to exist
  (a shell harness stubbing `emacsclient`/`osascript` on `PATH` to test
  branching logic that used to live in shell) goes away once that logic
  lives in Elisp — coverage moves to `config-test.el` ERT tests instead
  (see Verification). Deleting it, not leaving it to bit-rot alongside
  logic it no longer exercises, matches this migration's own "the shell
  layer no longer owns this decision" premise.

  One caveat worth flagging, not hidden: `clock-notify-test`'s own docstring
  (`bin/clock-notify-test:9-13`) already notes its test doubles can't cover a
  *live* `osascript` notification actually appearing on screen, or the real
  shape of a live PostToolUse payload — ERT tests inherit exactly the same
  limitation (asserting `call-process` was invoked with the right args via a
  stubbed/advised `call-process`, not that macOS actually displayed
  anything). Not a regression versus today; just not a new capability either.

### Migration list — every remaining script

| Script | Recommended action | Why |
|---|---|---|
| `bin/hooks/session-pause` / `-session-resume` | **Migrate fully** (Worked example 1) | Named-by-heading injection hazard; smallest, cleanest win |
| `bin/clock-notify` (+ retire `clock-notify-test`) | **Migrate fully** (Worked example 2) | Largest concentration of shell-side JSON logic; best return on the "maximum Emacs" argument |
| `bin/hooks/exitplanmode-promote-planning` | **Shebang-only**: `#!/usr/bin/env bash` → `#!/bin/sh` | Already zero-jq, already temp-file→`json-read-file`; no bash-only syntax present — confirm with a POSIX-mode shellcheck pass, then just retitle |
| `bin/hooks/posttooluse-record-planning-owner` | **Shebang-only**, same as above | Same already-pure shape |
| `bin/hooks/session-start-recovery-check` | **Shebang + one-character fix**: `#!/usr/bin/env bash` → `#!/bin/sh`, and `[[ -s "$out" ]]` → `[ -s "$out" ]` | Only bash-ism present is the double-bracket test |
| `.claude/hooks/session-context.sh` | Same as above (`[[ -s "$out" ]]` → `[ -s "$out" ]`, shebang → `#!/bin/sh`) | Same shape, same single bash-ism |
| `bin/hooks/pretooluse-transition-guard` | **Do not force-migrate; keep bash+jq.** Optionally revisit later as its own follow-up. | Synchronous, fail-*closed* gate: its shell layer's real job is checking `emacsclient`'s own exit status and emitting a specific `permissionDecision: deny` JSON shape on stdout inline with the tool call — that's not the fire-and-forget "shell wrapper is a stub" shape the convention targets. `jq -n` here builds *output* JSON safely (no interpolation hazard — `$reason` is a static, script-authored string, not attacker/session-controlled data), so it isn't the same hazard class as `session-pause`'s old encoding either. Forcing this into the temp-file-stub pattern adds an extra `emacsclient` round trip's worth of complexity to a hot, latency-sensitive path for marginal benefit. |
| `bin/check-org-dev-skill` (fish) | **Rewrite to bash**, recommended default over "document as second exception" | Not a JSON-payload wrapper at all — outside option 1's scope entirely, squarely an options-3/4/5 question. Its fish-isms (`function`/`end`, `set var val`, `test ... ; and ... ; or ...`) are all directly expressible in bash (`function`→nothing/`func() {}`, `set`→`=`, `&&`/`\|\|`). Given it predates and contradicts the heading's own "only fish dependency" premise, and given this decision's overall direction (standardize away from fish), rewriting removes the dependency rather than codifying a second undocumented exception. If a rewrite turns up something genuinely fish-specific and valuable, fall back to documenting it explicitly instead — but attempt the rewrite first rather than deciding to keep fish without trying. |
| `bin/test`, `bin/clock-notify-test` (pre-retirement) | **No change** | Not Claude-Code-hook wrappers; local dev-tooling scripts a contributor runs directly. Bash's array/`BASH_SOURCE` features are legitimately used (`bin/test:17-24`), and portability-to-an-unknown-user's-shell is not the concern for something only a contributor with this repo already checked out ever runs. |
| `bin/statusline.sh` | No change (already the precedent) | — |

## Files

- `CLAUDE.md` — new "Scripting conventions" subsection (Design, above).
- `modules/tools/claude-code-ide-org/config.el` — new
  `claude-code-ide-org-session-pause-from-payload`,
  `-session-resume-from-payload`,
  `claude-code-ide-org--clock-notify-response-text`,
  `claude-code-ide-org--clock-notify-decision`,
  `claude-code-ide-org-notify-clock-change`.
- `bin/hooks/session-pause`, `bin/hooks/session-resume`, `bin/clock-notify`
  — rewritten as POSIX `sh` stubs.
- `bin/clock-notify-test` — deleted.
- `bin/hooks/exitplanmode-promote-planning`,
  `bin/hooks/posttooluse-record-planning-owner`,
  `bin/hooks/session-start-recovery-check`,
  `.claude/hooks/session-context.sh` — shebang changed to `#!/bin/sh`
  (plus the `[[` → `[` fix on the latter two).
- `bin/check-org-dev-skill` — rewritten from fish to bash (or, if that
  turns out infeasible, kept as fish with an explicit exception comment
  added to its header — see Migration list).
- `modules/tools/claude-code-ide-org/config-test.el` — new tests (below).
- `.claude/settings.json` — no command paths change (all rewritten
  scripts keep their existing filenames), but re-validate with `jq -e .`
  after any edits touching this file indirectly.

## Verification

Follows the statusline case study's exact test shape
(`config-test.el:1303-1348`: well-formed payload, missing field,
malformed JSON, missing input file, end-to-end combined test) —
generalizes cleanly to every migrated script, since each one is the same
underlying pattern (read a payload, extract/decide, act):

- **session-pause/-resume from-payload**: for each of the two new
  `-from-payload` functions — (1) well-formed payload with a
  `session_id`, asserting it's threaded through to the existing
  `claude-code-ide-org-session-pause`/`-resume` (reuse the existing
  owner-mismatch fixtures at `config-test.el:335+` to assert the
  session-id actually took effect, not just that no error was thrown);
  (2) payload with `session_id` absent → behaves identically to calling
  the base function with no argument (existing `-noop-when-*` tests at
  `config-test.el:307-324` already cover the base function's nil-session
  behavior, so this test only needs to confirm the wrapper resolves to
  nil correctly); (3) malformed JSON → treated as nil session-id, not an
  error; (4) missing payload file → same.
- **clock-notify decision logic**: port each of `clock-notify-test`'s 11
  cases (`bin/clock-notify-test:78-160` — clock-in match/mismatch,
  clock-out match/mismatch, noop, tool-reported error, unreachable,
  unrelated tool_name, and the three `tool_response` shape variants
  including the confirmed-live bare-array shape) into ERT tests against
  `claude-code-ide-org--clock-notify-decision`, asserting on the returned
  `(title . body)` cons instead of a stubbed `osascript` log file. Add
  one further test stubbing/advising `call-process` to confirm
  `claude-code-ide-org-notify-clock-change` invokes `osascript` with the
  decision's title/body (advice-based stub, not a `PATH` shim, since this
  runs inside the same Emacs process now — no subprocess-on-`PATH`
  indirection needed the way the old shell harness required).
- `bin/test` must pass with the new count (currently 95/95 — track the
  new total once tests are added) after every migration step, not just
  at the end.
- Live: reload `config.el` per the org-dev skill (plain function
  additions — a live reload is sufficient, no restart needed) and run
  each rewritten wrapper directly with a fabricated JSON payload on
  stdin, confirming output/side-effects (a real `osascript` notification
  for `clock-notify`, in particular) match the pre-migration behavior for
  the same live clock state.
- `bin/check-org-dev-skill` (if rewritten to bash): run it directly and
  confirm identical pass/fail output to the fish version against current
  repo state; also re-run `bin/check-org-dev-skill` itself as a doctest
  check on `org-dev/SKILL.md` if the rewrite touches anything that
  skill's content cites.
- Validate `.claude/settings.json` with `jq -e .` after any edit (even
  though this plan doesn't expect command-path changes, per-step
  discipline matches the statusline precedent).

## After approval

Per CLAUDE.md's Plan-link rule, add
`[[file:~/.claude/plans/script-shell-standardization.md][Plan]]` to
`TODO.org` heading `84b7d8b3-5161-4146-9167-0e7e2100e365`'s body as soon
as this plan is finalized — a separate step requiring its own explicit
approval before any `DOING` transition or code edit proceeds (this was
background/unattended planning research: no heading edit, no TODO-state
change, and no clock touched by this planning pass itself).
