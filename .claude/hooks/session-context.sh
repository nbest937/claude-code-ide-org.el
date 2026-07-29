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
emacsclient -e "(claude-code-ide-org-write-session-context-report \"$out\")" >/dev/null 2>&1

if [[ -s "$out" ]]; then
  cat "$out"
fi
rm -f "$out"

exit 0
