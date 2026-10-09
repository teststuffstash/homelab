# ── bridge ── the loop variables, the window record and Alertmanager's view, all set EARLIER in
# responder-argo.yaml: NAME/FP by the alert loop, SEATWIN by the once-per-workflow ConfigMap read
# (already filtered to the windows live FOR TRIAGE — lease or tail), AMSTATE/AM_OK by the claim
# read (fingerprint → silencedBy). The gate `continue`s on a no-session outcome, so the bridge opens
# the loop it lives in and `post.sh` closes it.
ORG="teststuffstash"
NAME="KubePodNotReady"
FP="c0ffee0000000002"
TODAY="2026-09-17"
SEATWIN='[{"id":"wk-03-1789600000","by":"node-maintenance.sh","opened_at":"2026-09-17T05:00:00Z","until":"2026-09-17T08:00:00Z","reason":"node-maintenance window on wk-03 — planned cordon/drain/shutdown","node":"wk-03","note":"","alerts":["KubeDaemonSetRolloutStuck","KubeDaemonSetMisScheduled","KubeNodeUnreachable","KubeletInstanceUnreachable","KubeNodeNotReady","KubePodNotReady","CiliumUnreachableNodes","CiliumAgentScrapeDown","TargetDown"]}]'
AMSTATE='{}'
AM_OK=0
for _ in 1; do
