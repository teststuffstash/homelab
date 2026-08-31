# ── shared bridge (doorbell/switchboard-* legs) ── seams for the composed doorbell-fanout +
# switchboard blocks. curl: recorded without draining stdin (payload rides -d → the CALL line).
curl() { printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"; return "${CURL_RC:-0}"; }
# One graduated stack + one NOT graduated — the ungraduated warn is part of the contract.
stacks_json() {
  cat <<'JSON'
{ "stacks": [
  { "name": "circles", "graduated": true,  "repos": ["circles-iac", "circles"] },
  { "name": "newborn", "graduated": false, "repos": ["newborn-app"] }
] }
JSON
}
dp_wake() { printf '%s' "${DP_WAKE:-edge|1788210000}"; }
DISPATCH_PHASE_WAKE=""
# HERE → this shared dir so the block's fanout_clear finds the latch stub beside this bridge.
HERE="$(dirname "$REPLAY_FIXTURE")/switchboard-shared"
KUBECTL=kubectl; KUBE=""
