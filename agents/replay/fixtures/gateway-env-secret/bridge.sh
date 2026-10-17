# ── bridge ── the launcher state at the pod-create seam; each row sets GW_SESSIONS + the env map
# in $REPLAY_WORLD/vars.sh. The fake token is `gws_` + 32 A's.
POD="agent-homelab-120000"; NS="homelab"; KUBECTL="kubectl"; KUBE=""
GOOSE_MODEL="deepseek/deepseek-v4-flash"; SUB_LABEL=""
GW_SESSIONS=""; GW_SESSION_ID=""; GW_ENV_JSON=""; GW_SECRET=""; GW_SECRET_CREATED=""
. "$REPLAY_WORLD/vars.sh"
