# ── bridge ── the launcher variables the WIP cap block reads. RUN_CMD and TASK are set so the
# pre-flight guard's `case "$TASK" in issue-[0-9]*)` matches. NS and PROJECT are the namespace
# and project the kubectl selector filters on. KUBECTL and KUBE are resolved by kube.sh; in the
# replay PATH-shim, KUBECTL=stub kubectl and KUBE="" (no tofu/kubeconfig).
#
# World: one Running pod + one Unknown pod + one Pending Unschedulable old pod. With WIP=3,
# the count of 2 (Running + Unknown counted, wedged pod excluded) passes — demonstrating that
# a wedged pod does NOT hold a WIP slot, and that Unknown-phase pods (node-lost) are counted.
RUN_CMD="goose run --recipe .agents/fix.yaml --params issue=937"
TASK="issue-937"
NS="agent-runs"
PROJECT="test-project"
AGENT_WIP_LIMIT="3"
# kube.sh resolution: in the replay PATH-shim, kubectl is on $PATH via the stubs.
KUBECTL="kubectl"
KUBE=""