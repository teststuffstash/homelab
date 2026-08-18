# ── bridge ── the launcher variables the gate reads. `ITEM` is the --item payload verbatim; the
# pod name is what the shipped script derives from it (the deterministic key). `KUBECTL`/`KUBE`
# route the read through the PATH-shim so each arm gets its recorded answer.
NS="agent-coordinator"
KUBECTL="kubectl"
KUBE=""
ITEM="repo=homelab item=issue-153 clause=queued-dispatch"
POD="coordinator-homelab-issue-153"
