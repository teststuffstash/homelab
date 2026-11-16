# ── bridge ── the scan state the footprint blocks read by the time the queued loop runs. Every
# name is one the shipped script sets above that loop — never a harness invention.
HERE="$REPLAY_ROOT/agents"
. "${HERE}/footprint.sh"
# `live_worker_pod_count` lives in kube.sh (one predicate, two readers) — sourced as the scan
# sources it. kube.sh also RESOLVES kubectl/kubeconfig; pin both to the stub and no flags so the
# recorded CALL lines do not depend on whether this checkout carries a tofu/kubeconfig.
. "${HERE}/kube.sh"
KUBECTL="kubectl"
KUBE=""
# ── seam (ADR-122 (3), homelab#1431) ── the ONE issue-body parser, resolved beside the scan.
IB_PY="$REPLAY_ROOT/agents/issue_body.py"
slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
LOOP_NS="agent-coordinator"
# The scan's default (coordinator-scan.sh top level, not inside a sentinel): the persistence guard.
C4C5_PERSIST_S=900
# `inprog` is fetched at the top of the repo loop; `prsjson` (+ its read flag) by the open-PR list;
# both arrive as recorded files because those reads sit far above the blocks under replay.
inprog="$(cat "$REPLAY_WORLD/gh/issue-list-inprog.json")"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list-open.json")"
prsjson_fetch_rc=0
# The WIP pod probe (not sentinelled — it also runs the zombie reaper) leaves the parsed list in
# `WIPPODS_JSON` and sets `wippods_ok` only on a read that parsed. The world's one pod file
# answers it here and answers the session-belt's own `kubectl get pods` read below.
WIPPODS_JSON="$(cat "$REPLAY_WORLD/kubectl/get-pods.json")"
wippods_ok=1
wip_busy=""
orphans=""
ITEM_CLASS_ROWS=""
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|...\n"
}
