# ── bridge ── the loop variables and the window record, both set EARLIER in responder-argo.yaml:
# NAME/FP by the alert loop, SEATWIN by the once-per-workflow ConfigMap read. The gate `continue`s
# on its hit, so the bridge opens the loop it lives in and `post.sh` closes it.
ORG="teststuffstash"
NAME="KubeDaemonSetRolloutStuck"
FP="7a89cabb930c2070"
TODAY="2026-09-17"
# The record `agents/seat-window.sh open` writes, already filtered to the LIVE entries by the read
# in responder-argo.yaml (this fixture replays the gate, not the read).
SEATWIN='[{"id":"wk-03-1789600000","by":"node-maintenance.sh","opened_at":"2026-09-17T05:00:00Z","until":"2026-09-17T08:00:00Z","reason":"cordon | drain | shutdown — the pipes are the point","node":"wk-03","note":"","alerts":["KubeDaemonSetRolloutStuck","KubeDaemonSetMisScheduled","KubeNodeUnreachable","KubeletInstanceUnreachable","KubeNodeNotReady","KubePodNotReady","CiliumUnreachableNodes","CiliumAgentScrapeDown","TargetDown"]}]'
for _ in 1; do
