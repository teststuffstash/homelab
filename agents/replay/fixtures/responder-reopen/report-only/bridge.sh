# ── bridge ── the per-alert loop variables the two reopen blocks and the verdict block read. Every
# name here is set EARLIER in responder-argo.yaml's own loop (`$NAME`/`$FP` from the alert, `$SUBJ`
# from the subject derivation, `$ROUTE_STACK`/`$ROUTE_REPO`/`$CLAIMS` from the routing lookup,
# `$WIN` from the observation-window probe) — never a harness invention. A bridge that renames
# things is a bridge that pins a different clause.
#
# The alert is the live 2026-08-09 one: NodeDiskIOSaturation on wk-01, whose subject `node:wk-01`
# already had a CLOSED issue (homelab#103) from a previous, completed life.
ORG="teststuffstash"
NAME="NodeDiskIOSaturation"
FP="1f3a9c72b0d45e86"
SUBJ="node:wk-01"
ROUTE_STACK="platform"
ROUTE_REPO="teststuffstash/homelab"
CLAIMS='{"items":[]}'   # the AgentStack read degraded to the stacks.json belt; no extra candidates
WIN=""                  # no ArgoCD observation window open, so the doorbell is allowed to ring

# The doorbell is the verdict half's only non-`gh` I/O. A shell function shadows the binary — the
# seam-redefinition pattern this harness already uses for `mc_now` and `gb_ledger` — and writes into
# the SAME action stream the gh/kubectl PATH-shims do, so "did this dispatch" is asserted in one
# vocabulary instead of two. Returns 0: the clause's `&& echo rang … || echo bell failed` must take
# the ring branch, because a bell that failed is a different fixture.
curl() { printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"; }

# The ONE body-grammar parser (ADR-122 (3), homelab#1431). responder-argo.yaml defines `ib()` just
# after its homelab clone, pointing at /work/homelab; the fixture shadows only the PATH, so the REAL
# agents/issue_body.py out of the checkout is what reads the verdict and writes the machine block —
# the `curl` seam above, and machine-comment.sh in fix-debounce, verbatim.
ib() { python3 "$REPLAY_ROOT/agents/issue_body.py" "$@"; }
