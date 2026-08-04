#!/bin/sh
# Claude Code statusLine command.
#
# Case study for "maximum Emacs, minimal shell" (TODO.org's
# shell-standardization item, option 1): every piece of logic --
# parsing the stdin JSON payload, locating the "current default org
# task," formatting both the model name and the task info -- lives in
# Elisp (claude-code-ide-org-write-statusline-report and its helpers
# in config.el), not here. This script only shuttles bytes: write
# stdin to a temp file, ask Emacs to read it and write the formatted
# result to a second temp file, cat that back out. No jq, no
# string/field handling of any kind -- which is also why plain POSIX
# sh is enough; there's nothing left that needs a fancier shell.
#
# Fails soft (empty/partial output, never an error or a hang) if Emacs
# or the org data isn't reachable -- a status line must never break the
# prompt. Same fire-and-forget shape as bin/hooks/session-pause/-resume
# and .claude/hooks/session-context.sh.

in="$(mktemp)"
out="$(mktemp)"
cat >"$in"

emacsclient -e "(claude-code-ide-org-write-statusline-report \"$in\" \"$out\")" >/dev/null 2>&1

cat "$out" 2>/dev/null
rm -f "$in" "$out"
