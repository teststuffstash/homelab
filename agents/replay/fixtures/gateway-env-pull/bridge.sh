# ── bridge ── the launcher state at the pod-create seam; each row sets GW_SESSIONS + the bound
# dispatch's outputs in $REPLAY_WORLD/vars.sh.
POD="agent-homelab-120000"; NS="homelab"; KUBECTL="kubectl"; KUBE=""
GOOSE_MODEL="deepseek/deepseek-v4-flash"; SUB_LABEL=""
GW_SESSIONS=""; GW_SESSION_ID=""; GW_ENV_KEYS=""; GW_PULL_URL=""
. "$REPLAY_WORLD/vars.sh"
