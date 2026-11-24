#!/usr/bin/env bash
# tests/test_check.sh: Run the test suite and fail on any shell-level error

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out=$(bash "$DIR/test_ashboy.sh" 2>&1)
rc=$?
printf '%s\n' "$out"

if grep -q -e "command not found" -e "unbound variable" <<< "$out"; then
    echo "FAIL: undefined command or variable detected in the output above"
    exit 1
fi
exit $rc