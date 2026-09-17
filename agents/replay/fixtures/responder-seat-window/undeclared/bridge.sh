# ── bridge ── the loop variables and the window record, both set EARLIER in responder-argo.yaml:
# NAME/FP by the alert loop, SEATWIN by the once-per-workflow ConfigMap read. The gate `continue`s
# on its hit, so the bridge opens the loop it lives in and `post.sh` closes it.
ORG="teststuffstash"
NAME="GarageClusterFlapping"
FP="49b03e57e5d0cc1f"
TODAY="2026-09-17"
# The SAME live window as the declared twin. The only difference is the alert: `GarageClusterFlapping`
# is NOT in the declared set and must still triage — scoping by alert NAME rather than by node or
# namespace is the whole point. A namespace-wide mute would have hidden the REAL findings of the
# rf=3 rollout (garage-2 flapping, the write-probe 400s), the operator's own boundary on this leg.
SEATWIN='[{"id":"wk-03-1789600000","by":"node-maintenance.sh","opened_at":"2026-09-17T05:00:00Z","until":"2026-09-17T08:00:00Z","reason":"node-maintenance window on wk-03 — planned cordon/drain/shutdown","node":"wk-03","note":"","alerts":["KubeDaemonSetRolloutStuck","KubeDaemonSetMisScheduled","KubeNodeUnreachable","KubeletInstanceUnreachable","KubeNodeNotReady","KubePodNotReady","CiliumUnreachableNodes","CiliumAgentScrapeDown","TargetDown"]}]'
for _ in 1; do
