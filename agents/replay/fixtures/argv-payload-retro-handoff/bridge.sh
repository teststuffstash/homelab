# ── bridge ── the shipped guard plus the four retro-session variables the block reads (STACK,
# RUN_ID, BRIEF, RUN), each named exactly as retro-session.sh sets it upstream.
. "$REPLAY_ROOT/agents/argv-guard.sh"
ag_limit() { printf '%s' 512; }

STACK="oracle"
RUN_ID="r4"
BRIEF="/tmp/retro-brief-8rvhd.md"
# Stands in for `${DECODE}; goose run --text …` — the decode half is base64 of the brief, which is
# where all the weight is (~4/3 of the source bytes).
RUN="printf '%s' '$(head -c 600 /dev/zero | tr '\0' 'A')' | base64 -d > /tmp/retro-brief.md"
