# Sourced, never run: unset every variable that points git at a
# particular repo (TODO.org :ID: 689a3b6e). Bash.
#
# Git exports GIT_DIR to anything it runs from a linked worktree -- a
# hook, `git rebase -x', a `!' alias -- and GIT_DIR overrides `git -C'.
# On 2026-10-27 a pre-push from a review worktree let the suites'
# `git -C "$tmp"' write the real repo, and one of them pushed a fixture
# commit to GitHub main. bin/test-all sources this before any suite
# runs, and every suite that runs git sources it again itself, as each
# already unsets CLAUDE_CODE_SESSION_ID: a suite is also run directly.
#
# Git's own list rather than a hand-picked one, so a variable git adds
# later is covered. A failing call, or a list that no longer names
# GIT_DIR, exits the caller: running on would scrub nothing, silently.
# git's own stderr is left to show, so the refusal names the real cause.

_git_hermetic_vars="$(git rev-parse --local-env-vars)" || {
  echo "git-hermetic: \`git rev-parse --local-env-vars' failed; refusing to run unscrubbed." >&2
  exit 1
}
if ! grep -qx GIT_DIR <<<"$_git_hermetic_vars"; then
  echo "git-hermetic: \`git rev-parse --local-env-vars' did not name GIT_DIR; refusing to run unscrubbed." >&2
  exit 1
fi
# shellcheck disable=SC2086 # one name per line, split on purpose
unset $_git_hermetic_vars _git_hermetic_vars
