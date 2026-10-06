#!/usr/bin/env bash
# postsync — CONFIRM the kube-prometheus-stack upgrade lease (ADR-150 (3)): the subject's REAL
# checks, then `upgrade-lease.sh confirm` (delete). ArgoCD `Healthy` is not the check (the shallow
# gate, docs/dependency-upgrades.md §4). Every check retries inside ONE bounded budget (CHECK_BUDGET_S,
# below the Job's activeDeadlineSeconds); the first check still failing at the budget's end names
# itself and exits 1 — the lease STAYS, and the management box acts at `expected-end`. Nothing here
# depends on the component it verifies: curl + kubectl + jq (the agent-coordinator image), never a
# Prometheus client that needs Prometheus up.
#   1 Prometheus /-/ready                      4 Alertmanager carries the Watchdog (its API, not a route)
#   2 rule-evaluation failures at zero (5m)    5 the operator Deployment is available at its spec
#   3 Alertmanager /-/ready                    6 every monitoring.coreos.com CRD == the operator image's version
# Env (the Job): SUBJECT, PROM, AM, OPERATOR_NS, OPERATOR_DEPLOY, CHECK_BUDGET_S.
set -uo pipefail
: "${SUBJECT:=argocd/platform/kube-prometheus-stack.yaml}"
: "${PROM:=http://kube-prometheus-stack-prometheus.monitoring.svc:9090}"
: "${AM:=http://kube-prometheus-stack-alertmanager.monitoring.svc:9093}"
: "${OPERATOR_NS:=monitoring}" "${OPERATOR_DEPLOY:=kube-prometheus-stack-operator}" "${CHECK_BUDGET_S:=600}"
deadline=$((SECONDS + CHECK_BUDGET_S))

c() { curl -fsS --max-time 10 "$@"; }
check() {  # check <name> <fn> — retry every 15 s until the shared deadline
  local name="$1" fn="$2" out
  while :; do
    if out="$($fn 2>&1)"; then echo "ok   $name${out:+ — $out}"; return 0; fi
    if [ "$SECONDS" -ge "$deadline" ]; then echo "FAIL $name — $out"; echo "postsync: NOT confirmed — the lease stays, the box acts at expected-end"; exit 1; fi
    sleep 15
  done
}
prom_ready()   { c "$PROM/-/ready" >/dev/null && echo "$PROM"; }
# numeric compare, never an integer-part test: increase() extrapolates, so one real failure right
# after a bump reads 0.66 — `${v%.*}` would have confirmed on it (reviewer catch, #2347)
rules_clean()  { local v; v="$(c "$PROM/api/v1/query" --data-urlencode 'query=sum(increase(prometheus_rule_evaluation_failures_total[5m]))' | jq -e -r '(.data.result[0].value[1] // "0") as $v | if ($v | tonumber) == 0 then $v else error("rule evaluation failures: \($v)") end')" && echo "rule evaluation failures: $v"; }
am_ready()     { c "$AM/-/ready" >/dev/null && echo "$AM"; }
am_watchdog()  { local n; n="$(c "$AM/api/v2/alerts?filter=alertname%3DWatchdog&active=true" | jq 'length')" && [ "$n" -ge 1 ] && echo "Watchdog active ($n)"; }
operator_up()  { kubectl -n "$OPERATOR_NS" get deploy "$OPERATOR_DEPLOY" -o json | jq -e -r 'select((.status.availableReplicas // 0) >= .spec.replicas and (.status.updatedReplicas // 0) == .spec.replicas) | "\(.status.availableReplicas)/\(.spec.replicas) available, image \(.spec.template.spec.containers[0].image)"'; }
crds_match()   {
  # NEVER `kubectl get crd -o json` over the whole cluster: 59 MB of JSON (Crossplane, Cilium, Argo…)
  # OOM-killed the first live run under the Job's memory limit (2026-10-06, exit 137). The group's
  # CRD names come from discovery (api-resources, a few KB), then one lean projection of just those.
  local img ver names
  img="$(kubectl -n "$OPERATOR_NS" get deploy "$OPERATOR_DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')" || return 1
  ver="${img##*:}"; ver="${ver#v}"
  names="$(kubectl api-resources --api-group=monitoring.coreos.com -o name)" || return 1
  [ -n "$names" ] || { echo "no monitoring.coreos.com CRDs"; return 1; }
  # shellcheck disable=SC2086
  kubectl get crd $names -o custom-columns='NAME:.metadata.name,V:.metadata.annotations.operator\.prometheus\.io/version' --no-headers \
    | awk -v v="$ver" '{ n++; if ($2 != v) bad = bad " " $1 "=" $2 } END { if (n == 0) { print "no CRDs read"; exit 1 } if (bad != "") { print "operator " v " vs CRDs" bad; exit 1 } print n " CRDs at " v " = operator" }'
}

[ "${POSTSYNC_DEFINE_ONLY:-0}" = 1 ] && return 0   # test seam: `source` the checks without running them (a seat probe from the jail)

check prometheus-ready prom_ready
check rule-evaluation-failures-zero rules_clean
check alertmanager-ready am_ready
check watchdog-present am_watchdog
check operator-available operator_up
check crds-match-operator crds_match
exec bash /scripts/upgrade-lease.sh confirm --subject "$SUBJECT"
