#!/usr/bin/env bash
# SessionStart hook: surface "what was I last doing" automatically —
# the currently clocked-in org heading (if any) plus every WAIT-state
# heading across claude-code-ide-org-query-files (or org-agenda-files)
# — as additionalContext, so it's already known walking into the
# session instead of something Claude has to ask or look up.
#
# Fails soft (exit 0, no output) if Emacs isn't reachable, or if the
# elisp side errors before writing the report: claude-code-ide-org-
# write-session-context-report's temp file is only ever populated on a
# clean run (see its docstring in config.el), so an empty/missing file
# is treated identically to "Emacs unreachable" here — no error banner
# either way. Same shape as the existing session-start-recovery-check
# hook, which this deliberately mirrors.
cat >/dev/null

out="$(mktemp)"
# The project root and the option reach elisp through the ENVIRONMENT,
# not through the form's text (review finding on PR #28). Interpolating a
# path into an elisp string literal breaks on a `"' or `\' in the path,
# and the breakage is invisible: emacsclient's output is discarded, $out
# stays empty, and the `[[ -s ]]' guard below treats that exactly like a
# stopped Emacs. `getenv' cannot be broken by the value's contents.
# Values are escaped for an elisp string literal, not interpolated raw
# (review finding on PR #28): a `"' or `\' in the path would otherwise
# produce a malformed form, and the failure is invisible -- emacsclient's
# output is discarded, $out stays empty, and the `[[ -s ]]' guard below
# treats that exactly like a stopped Emacs.
#
# NOT `getenv' in the form, which is the obvious-looking fix and is
# wrong: `emacsclient -e' evaluates in the SERVER's process, so `getenv'
# reads Emacs's environment rather than this hook's and silently yields
# nil -- measured 2026-09-18, it unscoped every report while looking
# like it worked.
elisp_string() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
proj="$(elisp_string "${CLAUDE_PROJECT_DIR:-}")"
tt="$(elisp_string "${CLAUDE_PLUGIN_OPTION_TIME_TRACKING:-}")"
emacsclient -e "(claude-code-ide-org-write-session-context-report \"$out\" \"$proj\" \"$tt\")" >/dev/null 2>&1

if [[ -s "$out" ]]; then
  cat "$out"
fi
rm -f "$out"

exit 0
