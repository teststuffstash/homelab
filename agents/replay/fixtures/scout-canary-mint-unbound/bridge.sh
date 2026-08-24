# ── bridge ── call `scout_canary_mint` with the cleanup path to assert the local-var split fix.
#
# The `scout-seams` block (composed just above) defines `scout_canary_mint` in its REAL form.
# This bridge sets up the minimal env and calls the function with `mode=cleanup`, which
# exercises both `sess` and `key` variables — the exact expansion that triggered the unbound
# variable death under `set -u` before the fix.
#
# The kubectl stub (on PATH via the replay runner) handles the `kubectl delete` mutation:
# it records the CALL and returns 0 (mutations are always served as optional).
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CANARY_PROJECT="teststuffstash"

# Call the cleanup path — this is the code path that was dying with `sess: unbound variable`.
# After the fix (separate `local` declarations), both `sess` and `key` expand correctly.
scout_canary_mint "test/model" "true" "cleanup"