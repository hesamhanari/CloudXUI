# Run every suite and print a one-line verdict per suite. origin-ca.sh needs
# jq; without it the suite reports SKIP instead of FAIL. Any FAIL also makes
# the runner exit nonzero so automation cannot mistake red for green.
_runner_fail=0
for s in scoped-inputs nginx-gate nginx-prerequisite regression deployment main-flow cert-state origin-ca dns sni xui-gate menu; do
    _log=$(mktemp)
    if sh tests/$s.sh > "$_log" 2>&1; then
        printf 'OK   %s\n' "$s"
    elif grep -q 'jq is required for this test' "$_log"; then
        printf 'SKIP %s (jq not on PATH)\n' "$s"
    else
        printf 'FAIL %s\n' "$s"
        sed 's/^/    | /' "$_log"
        _runner_fail=1
    fi
    rm -f "$_log"
done
exit "$_runner_fail"
