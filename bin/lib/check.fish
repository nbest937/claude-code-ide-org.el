# Shared harness for this repo's documentation-accuracy checks.
#
# The split this file exists to enforce: a check script is *assertions*,
# and everything else -- the failure accumulator, the report format, the
# exit code -- is harness. Two scripts wanting checks over the same files
# at the same hook would otherwise each carry their own copy of that
# plumbing, and duplicated things drift, which is the exact failure these
# checks exist to catch (TODO.org :ID: d2a0f54c, and its stated overlap
# with :ID: d7849119, whose note says whichever lands first should build
# the harness so the other only adds assertions).
#
# The plumbing is also where the bug was, which is the argument for
# writing it once. `bin/check-org-dev-skill' accumulated failures with a
# bare `set' inside an `if' block -- block-local in fish -- so `fail'
# stayed 0 and the script exited 0 while printing FAIL, making every
# failure it ever reported invisible to callers. Every assignment to
# `fail' below is `set -g' for that reason, and the self-test asserts the
# exit code rather than reading the output.

set -g fail 0

# Compare a measured value against an expected one.
function check
    set -l desc $argv[1]
    set -l got $argv[2]
    set -l want $argv[3]
    if test "$got" = "$want"
        echo "ok   - $desc"
    else
        echo "FAIL - $desc: expected '$want', got '$got'"
        set -g fail 1
    end
end

# Report a check whose verdict was reached some other way.
function check_ok
    echo "ok   - $argv[1]"
end

function check_fail
    echo "FAIL - $argv[1]"
    set -g fail 1
end
