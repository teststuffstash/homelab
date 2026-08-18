# ── observation point ── not pod code. In reviewer-session.sh the statements after the exit
# contract are `/tmp/rc` + the upload + `exit "$FINAL"` — the two values printed here ARE what the
# pod exits on, which the launcher's pod-exit read then propagates to the Argo workflow. Printing
# them is the assertion (a resolution fixture asserts on enforcement it does not run, the
# goal-ancestor pattern); exiting with FINAL makes the harness's RC line pin the exit code the pod
# would actually produce — THE contract, not a printout.
echo "FINAL: ${FINAL:-unset}"
echo "TERMINAL_OK: ${TERMINAL_OK:-unset}"
exit "${FINAL:-0}"
