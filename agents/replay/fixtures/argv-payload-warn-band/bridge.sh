# ── bridge ── the shipped guard, same single seam as its over-ceiling twin.
. "$REPLAY_ROOT/agents/argv-guard.sh"
ag_limit() { printf '%s' 512; }

POD="agent-oracle-fleet-issue-77-r1"
HARNESS="goose"

# 460 bytes = 89% of the stand-in ceiling: inside the warn band (AG_WARN_PCT=80), under the cliff.
WRAPPED="$(head -c 460 /dev/zero | tr '\0' 'x')"
