# Shared harness for this repo's documentation-accuracy checks. Bash.
#
# The split this file exists to enforce: a check script is *assertions*,
# and everything else -- the failure accumulator, the report format, the
# exit code -- is harness. Two scripts wanting checks over the same files
# at the same hook would otherwise each carry their own copy of that
# plumbing, and duplicated things drift, which is the exact failure these
# checks exist to catch (TODO.org :ID: d2a0f54c).
#
# Translated from bin/lib/check.fish 2026-09-04 (TODO.org :ID: 84b7d8b3:
# fish exits the commit gate). The fish original's block-local `set' bug
# -- FAIL printed while exiting 0 -- has no bash equivalent, since plain
# assignment in a sourced function is global here; the self-test still
# asserts exit codes rather than output, because that contract is what
# caught it.

fail=0

# Compare a measured value against an expected one.
check() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc: expected '$want', got '$got'"
    fail=1
  fi
}

# Report a check whose verdict was reached some other way.
check_ok() {
  echo "ok   - $1"
}

check_fail() {
  echo "FAIL - $1"
  fail=1
}

# Report a check that could not run, naming why.
#
# Distinct from `check_ok' on purpose: a check that did not run has not
# passed, and printing it as `ok' is the exact failure mode TODO.org
# :ID: 542924c1 collects -- silence read as a result. Distinct from
# `check_fail' too, because a prerequisite that is merely absent is not
# the drift these scripts exist to catch, and blocking a commit with the
# wrong cause is worse than not checking.
#
# Does not set `fail'. A caller that wants a missing prerequisite to be
# fatal calls `check_fail' instead; the choice belongs to the assertion,
# which knows whether the prerequisite is optional.
check_skip() {
  echo "skip - $1: $2"
}
