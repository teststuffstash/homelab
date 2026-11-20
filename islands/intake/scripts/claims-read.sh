#!/usr/bin/env bash
# claims-read — the island intake's ONE read of the live AgentStack claims (homelab#3580): the stack
# islands are declared there (`repos[].intake.facts`, argocd/resources/agentstack/xrd.yaml), and the
# claims are read live — never from the hand-kept mirror agents/stacks.json — so a stack turning
# intake on needs no homelab commit. The read is `agentstacks` get/list on ClusterRole
# `island-intake-read` (agents/coordinator/rbac.yaml).
#
#   bash islands/intake/scripts/claims-read.sh [--push] <out file>
#
# Exit 0 = <out file> holds the `kubectl get agentstacks.platform.teststuff.net -o json` answer with at
# least one claim. Exit 1 = the read failed or answered no items: <out file> is removed and ONE line says
#   island-intake: claims read FAILED — stack islands not walked
# A failed read is never an empty list of stack islands. --push (the workflow's list step) also
# pushes `island_intake_claims_read_ok` 1|0 to $PUSHGATEWAY (job island_intake_claims) — the series
# IslandIntakeClaimsUnread reads (argocd/resources/pushgateway/prometheusrule.yaml).
set -uo pipefail
PUSH=0
[ "${1:-}" = --push ] && { PUSH=1; shift; }
OUT="${1:-}"
[ -n "$OUT" ] || { echo "claims-read: usage: claims-read.sh [--push] <out file>" >&2; exit 2; }
ok=1
kubectl get agentstacks.platform.teststuff.net --request-timeout=30s -o json > "$OUT" 2> "$OUT.err" || ok=0
if [ "$ok" = 1 ]; then
  jq -e '(.items | type) == "array" and (.items | length) > 0' "$OUT" >/dev/null 2>&1 || { ok=0; echo "the answer holds no claim" >> "$OUT.err"; }
fi
if [ "$ok" = 0 ]; then
  rm -f "$OUT"
  echo "island-intake: claims read FAILED — stack islands not walked"
  [ -s "$OUT.err" ] && echo "island-intake: claims read: $(tr '\n' ' ' < "$OUT.err" | cut -c1-300)"
fi
rm -f "$OUT.err"
if [ "$PUSH" = 1 ] && [ -n "${PUSHGATEWAY:-}" ]; then
  printf '# TYPE island_intake_claims_read_ok gauge\nisland_intake_claims_read_ok %s\n' "$ok" \
    | curl -fsS --max-time 5 --data-binary @- "$PUSHGATEWAY/metrics/job/island_intake_claims" >/dev/null 2>&1 \
    || echo "island-intake: pushgateway unreachable — island_intake_claims_read_ok not pushed"
fi
[ "$ok" = 1 ]
