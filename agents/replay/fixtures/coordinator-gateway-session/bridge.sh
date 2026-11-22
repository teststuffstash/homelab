# ── bridge ── the launcher variables the block reads, pinned to one platform item dispatch; a row's
# vars.sh moves what its condition needs. The manifest env the pod would carry (the old-proxy ref
# rail, MODEL = the scan's --model) is exported, as the pod has it.
set -u
STACK="platform"; LAUNCH=""; RESOLVE_CLASS=""
RUN_CMD="Reconcile EXACTLY ONE work unit"
POD="coordinator-homelab-issue-2700"
MODEL="fable"; GO_CTX_ENV=""
BRIEF_PATH="/work/homelab/agents/coordinator/README.md"; PERM_MODE="bypassPermissions"
GW_REPLY_HTTP="200"; GW_REPLY_BODY='""'; LATCH_RC=0; TOKEN_PRESENT=1
. "$REPLAY_WORLD/vars.sh"
REST_FLAGS="--append-system-prompt-file ${BRIEF_PATH} --permission-mode ${PERM_MODE}"
COMMON_FLAGS="--model ${MODEL} ${REST_FLAGS}"
