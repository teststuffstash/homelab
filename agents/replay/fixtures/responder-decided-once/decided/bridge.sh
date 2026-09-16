# ── bridge ── the per-alert loop variables the gate reads, each set EARLIER in
# responder-argo.yaml's own loop. The block `continue`s on its hit, so the bridge opens the loop it
# lives in and `post.sh` closes it; `reached.sh` is the sentinel the `continue` must skip.
ORG="teststuffstash"
NAME="BlockingCodeownerParkWaiting"
FP="a9be9303edb3954b"
SUBJ="alert:BlockingCodeownerParkWaiting"
TODAY="2026-09-16"
for _ in 1; do
