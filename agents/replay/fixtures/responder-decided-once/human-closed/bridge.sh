# ── bridge ── the per-alert loop variables the gate reads, each set EARLIER in the loop. DEC_RAW
# is set by the OPEN search inside the block itself; the closed branch is guarded on it being
# non-empty, so the open search must have SUCCEEDED and simply found nothing — a failed search
# falls through to triage rather than reaching for the closed set.
ORG="teststuffstash"
NAME="NodeRebootingRepeatedly"
FP="9f62f04e462fde41"
SUBJ="instance:192.168.2.63:9100"
TODAY="2026-09-17"
RESPONDER_HUMAN_CLOSE_DAYS=14
for _ in 1; do
# The close EVENT is written here rather than recorded, because the condition under test is
# RELATIVE ("a person closed it N days ago") and a frozen `created_at` would silently cross the
# 14-day threshold twelve days from now — the fixture would flip branch on a calendar date and red
# for a behaviour that never changed. `$REPLAY_WORLD` is the runner's materialized overlay
# (agents/replay/README.md §the runner contract), so this is a recorded world with one derived
# field, not a stub.
mkdir -p "$REPLAY_WORLD/gh"
printf '[{"event":"closed","actor":{"login":"RasmusSoot","type":"User"},"created_at":"%s"}]\n' \
  "$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%SZ)" \
  > "$REPLAY_WORLD/gh/api-repos-teststuffstash-homelab-issues-1663-events.json"
