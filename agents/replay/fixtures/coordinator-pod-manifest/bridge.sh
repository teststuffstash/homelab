# ── bridge ── every variable the heredoc expands, pinned to one per-stack item dispatch so the
# rendered manifest is deterministic. `KUBECTL`/`KUBE` route the create through the PATH-shim,
# which records the STDIN manifest as the action stream.
NS="platform-agents"
KUBECTL="kubectl"
KUBE=""
CREATE_CMD="create"
POD="coordinator-homelab-issue-2700"
POD_SA="agentstack-loop"
COORD_RAIL_LABEL=', "homelab.teststuff.net/subscription-session": claude'
COORDINATOR_POD_DEADLINE_S=3600
IMAGE="ghcr.io/teststuffstash/agent-coordinator:2026.10.15-g45292680478f"
ARGS='["-lc", "echo replay"]'
STACK="platform"
STACK_REPOS="homelab agent-runtime"
MAIN_REPO="homelab"
WIP_LIMIT="2"
MODEL="fable"
AGENT_PUSHGATEWAY_URL="http://prometheus-pushgateway.monitoring.svc.cluster.local:9091"
DOOR_JSON='{"repo":"homelab","unit":"issue-2700"}'
OTLP_ENDPOINT="http://otel-collector.monitoring.svc.cluster.local:4318"
echo "REACHED: create"
