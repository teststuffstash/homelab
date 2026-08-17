# ── the three arms ── each changes $POD so the recorded kubectl read answers differently. The
# live-holder arm is run in a subshell because `session_atomic_gate` EXITS 3 on refusal; the rc is
# printed and the refusal (captured through the command substitution) is re-emitted to stderr so
# it lands in the action stream without leaving a stray file in the fixture dir.
echo "REACHED: live holder"
POD="coordinator-homelab-issue-153"
set +e
live_err="$( { session_atomic_gate; } 2>&1 )"
live_rc=$?
set -e
printf 'LIVE_HOLDER rc=%s\n' "$live_rc"
printf '%s\n' "$live_err" >&2

echo "REACHED: terminal holder"
POD="coordinator-homelab-issue-99"
session_atomic_gate
printf 'TERMINAL_HOLDER create proceeds\n'

echo "REACHED: no holder"
POD="coordinator-homelab-issue-7"
session_atomic_gate
printf 'NO_HOLDER create proceeds\n'

echo "REACHED: end"
