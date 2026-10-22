#!/usr/bin/env bash
# EXPERIMENT — prove the HARDENED Kargo OSS + Argo Rollouts install in an ephemeral kind cluster
# before anything touches prod. Run: `devbox run e2e` from this directory (CI: the
# platform-kind-kargo workflow on the proxmox-vm runner). Follows docs/patterns/kind-ci.md:
# run-scoped cluster name, stale sweep before create, `docker rm -f -v`, teardown trap with KEEP=1,
# kind node mirror wiring per the ADR-091 env contract, evidence dir.
#
# SINGLE SOURCE: every chart is installed from the committed ArgoCD Application YAML
# (repoURL/chart/targetRevision/destination + .spec.source.helm.valuesObject via yq) and the
# platform manifests are `kubectl apply -k argocd/resources/kargo` — no copied values.
#
# Soft assertions: every check records PASS/FAIL and the run continues, so ONE run yields the
# whole picture (incl. every 403 the kargo SAs hit, from the apiserver audit log). Exit 1 if any
# FAIL. Evidence: e2e-evidence/<ts>/ at the repo root.
set -uo pipefail

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$ROOT" || exit 1
RUN="${GITHUB_RUN_ID:-$$}"
CLUSTER="homelab-kargo-e2e-${RUN}"
CTX="kind-${CLUSTER}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
EVID="$ROOT/e2e-evidence/$TS"
mkdir -p "$EVID"
FX="$ROOT/tests/kind-kargo/fixtures"
SWEEP_MAX_AGE_MIN=180

log() { echo "==> $(date -u +%H:%M:%S) $*" | tee -a "$EVID/run.log"; }
k() { kubectl --context "$CTX" "$@"; }
RESULTS="$EVID/results.tsv"; : > "$RESULTS"
pass() { printf 'PASS\t%s\t%s\n' "$1" "${2:-}" | tee -a "$RESULTS"; }
fail() { printf 'FAIL\t%s\t%s\n' "$1" "${2:-}" | tee -a "$RESULTS"; }
info() { printf 'INFO\t%s\t%s\n' "$1" "${2:-}" | tee -a "$RESULTS"; }
check() { local name=$1; shift; if "$@" >>"$EVID/run.log" 2>&1; then pass "$name"; else fail "$name"; fi; }
wait_for() { # name timeout_s cmd... — poll every 5s
  local name=$1 t=$2; shift 2; local end=$(( $(date +%s) + t ))
  while [ "$(date +%s)" -lt "$end" ]; do "$@" >/dev/null 2>&1 && { pass "$name"; return 0; }; sleep 5; done
  fail "$name" "timeout ${t}s"; return 1
}

# ── teardown (rule 3) + evidence collection ──────────────────────────────────────────────────
collect() {
  log "collect evidence"
  for ns in kargo oracle-kargo argocd cert-manager; do
    k -n "$ns" get pods -o wide > "$EVID/pods-$ns.txt" 2>&1
    for p in $(k -n "$ns" get pods -o name 2>/dev/null); do
      k -n "$ns" logs "$p" --all-containers --tail=-1 > "$EVID/logs-$ns-${p#pod/}.log" 2>&1
    done
  done
  k get projects,warehouses,freight,stages,promotions -A -o yaml > "$EVID/kargo-objects.yaml" 2>&1
  k get analysisruns,analysistemplates -A -o yaml > "$EVID/analysis-objects.yaml" 2>&1
  k get clusterroles,clusterrolebindings -o name 2>/dev/null | grep -i kargo > "$EVID/kargo-cluster-rbac.txt"
  k -n oracle-kargo get roles,rolebindings,serviceaccounts -o yaml > "$EVID/oracle-kargo-rbac.yaml" 2>&1
  k get events -A --sort-by=.lastTimestamp > "$EVID/events.txt" 2>&1
  docker cp "$CLUSTER-control-plane:/var/log/kubernetes/audit.log" "$EVID/audit.log" >/dev/null 2>&1 || true
  if [ -s "$EVID/audit.log" ]; then
    # Every 403 a kargo SA got, deduplicated — the grant-discovery list.
    jq -rc 'select(.responseStatus.code == 403 and (.user.username|startswith("system:serviceaccount:kargo:")) and (.impersonatedUser == null))
            | [.user.username, .verb, (.objectRef.apiGroup // ""), .objectRef.resource, (.objectRef.subresource // ""), (.objectRef.namespace // "<cluster>"), (.objectRef.name // "")] | @tsv' \
      "$EVID/audit.log" | sort | uniq -c | sort -rn > "$EVID/forbidden-by-sa.tsv"
    # Every policy warning/denial annotation on a kargo SA's OWN request (impersonated probes are
    # audited as the admin — audit runs before impersonation — so they never land here).
    jq -rc 'select(.annotations != null and .impersonatedUser == null) | select(.annotations | keys | any(startswith("validation.policy.admission.k8s.io")))
            | [(.impersonatedUser.username // .user.username), .verb, .objectRef.resource, (.objectRef.namespace // "<cluster>"), (.objectRef.name // ""), (.annotations | tostring)] | @tsv' \
      "$EVID/audit.log" | sort | uniq -c > "$EVID/policy-annotations.tsv"
  fi
  k get --raw /api/v1/nodes/"$CLUSTER"-control-plane/proxy/stats/summary 2>/dev/null \
    | jq -r '.pods[] | select(.podRef.namespace|IN("kargo","oracle-kargo","argocd","cert-manager")) | [.podRef.namespace, .podRef.name, ((.memory.workingSetBytes // 0)/1048576|floor|tostring) + "Mi"] | @tsv' \
    > "$EVID/pod-memory.tsv" 2>/dev/null || true
}
cleanup() {
  local rc=$?
  collect || true
  { echo "# results"; cat "$RESULTS"; } > "$EVID/summary.md"
  if [ "${KEEP:-0}" = 1 ]; then log "KEEP=1 — cluster $CLUSTER left running ($CTX)"
  else kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
       docker rm -f -v "$CLUSTER-control-plane" >/dev/null 2>&1 || true; fi
  exit "$rc"
}
trap cleanup EXIT

# ── rule 2: sweep stale own-prefix clusters (cancelled jobs never run their trap) ──────────────
log "pre-create sweep"
now=$(date -u +%s)
docker ps -a --filter 'name=^homelab-kargo-e2e-' --format '{{.Names}}' | sort -u | while read -r name; do
  [ -n "$name" ] || continue
  created=$(date -u -d "$(docker inspect -f '{{.Created}}' "$name")" +%s 2>/dev/null) || continue
  if [ "$name" = "$CLUSTER-control-plane" ] || [ $(( (now - created) / 60 )) -ge "$SWEEP_MAX_AGE_MIN" ]; then
    log "sweep: removing $name"
    kind delete cluster --name "${name%-control-plane}" >/dev/null 2>&1 || true
    docker rm -f -v "$name" >/dev/null 2>&1 || true
  fi
done

# ── cluster ───────────────────────────────────────────────────────────────────────────────────
log "kind create $CLUSTER ($(kind version))"
timeout --foreground -k 15 300 kind create cluster --name "$CLUSTER" --wait 120s || { fail cluster-create; exit 1; }
k version -o json > "$EVID/k8s-version.json" 2>&1

kind_mirror() { # registry mirror-url  (donor: oracle-fleet scripts/lib/e2e-sweep.sh)
  [ -n "$2" ] || return 0
  docker exec "$CLUSTER-control-plane" mkdir -p "/etc/containerd/certs.d/$1"
  printf '[host."%s"]\n  capabilities = ["pull", "resolve"]\n' "$2" \
    | docker exec -i "$CLUSTER-control-plane" tee "/etc/containerd/certs.d/$1/hosts.toml" >/dev/null
  log "kind node mirror: $1 → $2"
}
# ADR-091 env contract; on the VM runner default to the LAN VIPs (SERVICES.md §Registry mirrors).
kind_mirror docker.io "${REGISTRY_MIRROR_DOCKER_IO:-http://192.168.40.20}"
kind_mirror ghcr.io "${REGISTRY_MIRROR_GHCR:-http://192.168.40.21}"

# Audit log for grant discovery — patch the static apiserver pod in place (version-agnostic; no
# kubeadm-API-version-specific kind patches). Metadata level for kargo SAs only.
log "enable apiserver audit log"
docker exec -i "$CLUSTER-control-plane" sh -c 'mkdir -p /etc/kubernetes/audit /var/log/kubernetes && cat > /etc/kubernetes/audit/policy.yaml' <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: [RequestReceived]
rules:
  - level: Metadata
    userGroups: ["system:serviceaccounts:kargo"]
  - level: None
EOF
docker cp "$CLUSTER-control-plane:/etc/kubernetes/manifests/kube-apiserver.yaml" "$EVID/kube-apiserver.orig.yaml"
yq '.spec.containers[0].command += ["--audit-policy-file=/etc/kubernetes/audit/policy.yaml","--audit-log-path=/var/log/kubernetes/audit.log","--audit-log-maxsize=200"]
  | .spec.containers[0].volumeMounts += [{"name":"audit-policy","mountPath":"/etc/kubernetes/audit","readOnly":true},{"name":"audit-log","mountPath":"/var/log/kubernetes"}]
  | .spec.volumes += [{"name":"audit-policy","hostPath":{"path":"/etc/kubernetes/audit","type":"DirectoryOrCreate"}},{"name":"audit-log","hostPath":{"path":"/var/log/kubernetes","type":"DirectoryOrCreate"}}]' \
  "$EVID/kube-apiserver.orig.yaml" > "$EVID/kube-apiserver.audit.yaml"
docker cp "$EVID/kube-apiserver.audit.yaml" "$CLUSTER-control-plane:/etc/kubernetes/manifests/kube-apiserver.yaml"
sleep 20
wait_for apiserver-back-with-audit 180 sh -c "kubectl --context $CTX get --raw /readyz && docker exec $CLUSTER-control-plane test -s /var/log/kubernetes/audit.log -o -e /var/log/kubernetes/audit.log"

# ── helm installs from the committed Application YAML ─────────────────────────────────────────
helm_from_app() { # app-yaml [nowait]
  local f=$1 wait=(--wait) repo chart ver ns rel vals
  repo=$(yq '.spec.source.repoURL' "$f"); chart=$(yq '.spec.source.chart' "$f")
  ver=$(yq '.spec.source.targetRevision' "$f"); ns=$(yq '.spec.destination.namespace' "$f")
  rel=$(yq '.metadata.name' "$f"); vals="$EVID/values-$rel.yaml"
  [ "${2:-}" = nowait ] && wait=()
  yq '.spec.source.helm.valuesObject // {}' "$f" > "$vals"
  local ref="$chart" extra=()
  case "$repo" in
    *://*) extra=(--repo "$repo") ;;
    *) ref="oci://$repo/$chart" ;;
  esac
  log "helm install $rel ($ref@$ver → ns $ns) from $f"
  for attempt in 1 2 3; do # chart/registry fetch flakes are honest retries (rule 5) — the install itself is not retried blindly
    helm --kube-context "$CTX" upgrade --install "$rel" "$ref" "${extra[@]}" --version "$ver" -n "$ns" --create-namespace \
      -f "$vals" "${wait[@]}" --timeout 10m > "$EVID/helm-$rel.log" 2>&1 && { pass "helm-install-$rel"; return 0; }
    grep -qiE 'failed to (fetch|do request)|i/o timeout|TLS handshake|connection reset|500 Internal' "$EVID/helm-$rel.log" || break
    sleep 15
  done
  fail "helm-install-$rel" "$(tail -3 "$EVID/helm-$rel.log" | tr '\n' ' ')"; return 1
}

# ArgoCD: upstream chart, minimal; version = the prod pin (tofu/variables.tf argocd_chart_version).
ARGOCD_VER=$(awk '/variable "argocd_chart_version"/{f=1} f && /default/{gsub(/"/,"",$3); print $3; exit}' tofu/variables.tf)
log "argocd chart $ARGOCD_VER (minimal)"
helm --kube-context "$CTX" upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_VER" \
  -n argocd --create-namespace --wait --timeout 10m \
  --set dex.enabled=false --set notifications.enabled=false --set applicationSet.replicas=0 \
  --set server.replicas=1 > "$EVID/helm-argocd.log" 2>&1 && pass helm-install-argocd || fail helm-install-argocd

helm_from_app argocd/platform/prometheus-operator-crds.yaml  # ServiceMonitor CRD the charts render against
helm_from_app argocd/platform/cert-manager.yaml

# oracle-kargo namespace — from the committed platform manifest (wave -1).
yq 'select(.kind == "Namespace" and .metadata.name == "oracle-kargo")' argocd/platform/oracle-namespaces.yaml | k apply -f - >>"$EVID/run.log" 2>&1 \
  && pass ns-oracle-kargo || fail ns-oracle-kargo
helm_from_app argocd/platform/argo-rollouts.yaml

# Kargo admin Secret (prod: ExternalSecret ← Infisical) — generated in-run.
PW=$(head -c 24 /dev/urandom | base64 | tr -d '=+/')
HASH=$(docker run --rm docker.io/library/httpd:2.4-alpine htpasswd -nbBC 10 "" "$PW" 2>/dev/null | tr -d ':\n' | sed 's/^\$2y/$2a/')
[ -n "$HASH" ] || fail admin-hash "htpasswd container failed"
k create namespace kargo >/dev/null 2>&1
k -n kargo create secret generic "$(yq '.spec.source.helm.valuesObject.api.secret.name' argocd/platform/kargo.yaml)" \
  --from-literal=ADMIN_ACCOUNT_PASSWORD_HASH="$HASH" \
  --from-literal=ADMIN_ACCOUNT_TOKEN_SIGNING_KEY="$(head -c 32 /dev/urandom | base64 | tr -d '=+/')" >>"$EVID/run.log" 2>&1
# No --wait: with the chart's ClusterRoleBindings off, the Kargo pods cannot become Ready until the
# platform RBAC below exists (and that RBAC lands in chart-created namespaces) — the same ordering
# prod has (kargo wave 1, kargo-platform wave 2).
helm_from_app argocd/platform/kargo.yaml nowait

# ── platform manifests (RBAC, Project, VAP [Warn,Audit] as committed, PrometheusRule) ───────────
# Retried: the Project create needs Kargo's (Fail-policy) webhook up; everything else is idempotent.
log "apply -k argocd/resources/kargo"
applied=0
for i in $(seq 1 30); do
  if k apply -k argocd/resources/kargo >> "$EVID/apply-kargo-platform.log" 2>&1; then applied=1; break; fi
  sleep 10
done
[ $applied = 1 ] && pass apply-kargo-platform "attempt $i" || fail apply-kargo-platform "$(tail -3 "$EVID/apply-kargo-platform.log" | tr '\n' ' ')"
k get validatingadmissionpolicybinding kargo-write-guard -o jsonpath='{.spec.validationActions}' > "$EVID/binding-actions-initial.txt" 2>&1

wait_for project-ready 180 sh -c "kubectl --context $CTX get project oracle-kargo -o json | jq -e '.status.conditions[]? | select(.type==\"Ready\" and .status==\"True\")'"
wait_for project-admin-clusterrole 120 k get clusterrole kargo-project-admin-oracle-kargo
wait_for project-roles 120 k -n oracle-kargo get role kargo-admin kargo-viewer kargo-promoter
wait_for controller-read-secrets-rb 120 k -n oracle-kargo get rolebinding kargo-controller-read-secrets

# ── workloads Ready ───────────────────────────────────────────────────────────────────────────
for d in kargo-api kargo-controller kargo-management-controller kargo-webhooks-server; do
  check "ready-$d" k -n kargo rollout status deploy/"$d" --timeout=180s
done
check ready-argo-rollouts k -n oracle-kargo rollout status deploy/argo-rollouts --timeout=180s

# ── analysis on its own ───────────────────────────────────────────────────────────────────────
k apply -f "$FX/analysis.yaml" >>"$EVID/run.log" 2>&1
check ready-analysis-stub k -n oracle-kargo rollout status deploy/analysis-stub --timeout=180s
k apply -f "$FX/analysisrun.yaml" >>"$EVID/run.log" 2>&1
wait_for analysisrun-direct-successful 180 sh -c "kubectl --context $CTX -n oracle-kargo get analysisrun direct-smoke -o jsonpath='{.status.phase}' | grep -x Successful >/dev/null"

# ── Applications + Kargo flow (policy in its committed [Warn, Audit] mode) ────────────────────
k apply -f "$FX/apps.yaml" >>"$EVID/run.log" 2>&1 && pass apps-applied || fail apps-applied
k apply -f "$FX/kargo-flow.yaml" >>"$EVID/run.log" 2>&1 && pass kargo-flow-applied || fail kargo-flow-applied
k apply -f "$FX/warehouse-ert-corpus.yaml" >>"$EVID/run.log" 2>&1

stage_verified() { # stage — Verified condition True for the current freight
  kubectl --context "$CTX" -n oracle-kargo get stage "$1" -o json \
    | jq -e '.status.conditions[]? | select(.type=="Verified" and .status=="True")'
}
wait_for freight-discovered 180 sh -c "kubectl --context $CTX -n oracle-kargo get freight -o json | jq -e '[.items[] | select(.origin.name==\"podinfo\")] | length > 0'"
wait_for stage-smoke-verified 360 stage_verified smoke
wait_for stage-ingester-verified 300 stage_verified ingester
k -n argocd get application oracle-fleet-ingester -o json | jq '{sync: .status.sync.status, health: .status.health.status, op: .status.operationState.phase}' > "$EVID/app-ingester-status.json" 2>&1

# Registry reachability (informational): the runner host, and a kind pod via the Warehouse.
code=$(curl -s -o "$EVID/registry-tags.json" -w '%{http_code}' https://registry.teststuff.net/v2/oracle-fleet/ert-corpus/tags/list || echo curl-failed)
info registry-anon-from-runner "http=$code $(head -c 200 "$EVID/registry-tags.json" 2>/dev/null)"
sleep 10
info registry-anon-from-kind-warehouse "$(k -n oracle-kargo get warehouse ert-corpus -o json | jq -c '[.status.conditions[]? | {type, status, reason, message: (.message // "" | .[0:200])}]')"

# ── Application RBAC: named Applications only ─────────────────────────────────────────────────
KC=system:serviceaccount:kargo:kargo-controller
canI() { [ "$(k auth can-i "$@" 2>/dev/null)" = yes ]; }
check canI-patch-oracle-fleet-ingester canI patch applications.argoproj.io/oracle-fleet-ingester -n argocd --as="$KC"
check canI-patch-oracle-fleet-ingester-shadow canI patch applications.argoproj.io/oracle-fleet-ingester-shadow -n argocd --as="$KC"
check cannot-patch-platform-dummy sh -c "! kubectl --context $CTX auth can-i patch applications.argoproj.io/platform-dummy -n argocd --as=$KC | grep -x yes >/dev/null"
check patch-oracle-fleet-ingester-as-controller k -n argocd patch application oracle-fleet-ingester --type merge -p '{"metadata":{"labels":{"e2e-probe":"ok"}}}' --as="$KC"
check patch-shadow-as-controller k -n argocd patch application oracle-fleet-ingester-shadow --type merge -p '{"metadata":{"labels":{"e2e-probe":"ok"}}}' --as="$KC"
check patch-platform-dummy-refused sh -c "! kubectl --context $CTX -n argocd patch application platform-dummy --type merge -p '{\"metadata\":{\"labels\":{\"e2e-probe\":\"x\"}}}' --as=$KC"

# Settle, then: no Forbidden in Kargo controller logs, and the audit-log 403 list (discovery).
log "settle 60s, then forbidden scan (Warn phase)"
sleep 60
collect
forbidden_in_logs() {
  local n=0 f
  for f in "$EVID"/logs-kargo-*.log "$EVID"/logs-oracle-kargo-argo-rollouts*.log; do
    [ -e "$f" ] || continue
    if grep -iE 'forbidden|cannot (get|list|watch|create|update|patch|delete)' "$f" > "$f.forbidden"; then
      n=$((n + $(wc -l < "$f.forbidden"))); else rm -f "$f.forbidden"; fi
  done
  [ "$n" -eq 0 ] || { echo "forbidden lines: $n"; return 1; }
}
check no-forbidden-in-logs-warn-phase forbidden_in_logs
cp "$EVID/forbidden-by-sa.tsv" "$EVID/forbidden-by-sa.warn-phase.tsv" 2>/dev/null
cp "$EVID/policy-annotations.tsv" "$EVID/policy-annotations.warn-phase.tsv" 2>/dev/null
if [ -s "$EVID/policy-annotations.warn-phase.tsv" ]; then
  fail policy-quiet-under-normal-operation "$(wc -l < "$EVID/policy-annotations.warn-phase.tsv") annotated kargo request(s) — see policy-annotations.warn-phase.tsv"
else pass policy-quiet-under-normal-operation; fi
k get --raw /metrics 2>/dev/null | grep '^apiserver_validating_admission_policy_check_total' > "$EVID/vap-metrics.warn-phase.txt"

# ── flip the binding to Deny (the TEST exercises Deny; prod starts at [Warn, Audit]) ───────────
log "binding → [Deny, Audit]"
k patch validatingadmissionpolicybinding kargo-write-guard --type merge -p '{"spec":{"validationActions":["Deny","Audit"]}}' >>"$EVID/run.log" 2>&1
sleep 5

# Probe pairs: the REAL SA (records which layer refuses — RBAC first, then the policy), and a
# synthetic kargo-namespace user in system:masters (RBAC allows everything, so ONLY the policy
# can refuse — proves each rule regardless of what RBAC already blocks).
PROBE_AS=(--as=system:serviceaccount:kargo:vap-probe --as-group=system:masters --as-group=system:authenticated)
probe() { # name sa expect-layer(policy|rbac|either) -- kubectl args...
  local name=$1 sa=$2 want=$3; shift 4
  local out; out=$(k "$@" --as="system:serviceaccount:kargo:$sa" 2>&1); local rc=$?
  local layer=none
  grep -q "kargo-write-guard" <<< "$out" && layer=policy
  grep -q "attempting to grant RBAC permissions not currently held" <<< "$out" && [ "$layer" = none ] && layer=rbac-escalation
  grep -qi "forbidden: User" <<< "$out" && [ "$layer" = none ] && layer=rbac
  echo "[$name real=$sa] rc=$rc layer=$layer: $out" >> "$EVID/probes.log"
  if [ $rc -ne 0 ] && { [ "$want" = either ] || [ "$want" = "$layer" ]; }; then pass "deny-real-$name" "layer=$layer"; else fail "deny-real-$name" "rc=$rc layer=$layer"; fi
  out=$(k "$@" "${PROBE_AS[@]}" 2>&1); rc=$?
  echo "[$name synthetic] rc=$rc: $out" >> "$EVID/probes.log"
  if [ $rc -ne 0 ] && grep -q "ValidatingAdmissionPolicy 'kargo-write-guard'" <<< "$out"; then pass "deny-policy-$name"; else fail "deny-policy-$name" "rc=$rc"; fi
}
MC=kargo-management-controller
probe crb-cluster-admin "$MC" either -- create clusterrolebinding e2e-evil --clusterrole=cluster-admin --serviceaccount=kargo:kargo-controller
probe clusterrole-star "$MC" either -- create clusterrole e2e-evil --verb='*' --resource='*'
probe namespace-evil "$MC" either -- create namespace evil
probe secret-non-project-ns "$MC" either -- -n default create secret generic e2e-evil --from-literal=a=b
probe rolebinding-cluster-admin "$MC" policy -- -n oracle-kargo create rolebinding e2e-evil --clusterrole=cluster-admin --serviceaccount=kargo:kargo-controller
probe app-unannotated kargo-controller either -- -n argocd patch application platform-dummy --type merge -p '{"metadata":{"labels":{"e2e":"evil"}}}'
probe app-strip-annotation kargo-controller policy -- -n argocd patch application oracle-fleet-ingester --type json -p '[{"op":"remove","path":"/metadata/annotations/kargo.akuity.io~1authorized-stage"}]'
probe relabel-namespace "$MC" policy -- label namespace default kargo.akuity.io/project=true
# Positive controls under Deny: the shapes Kargo itself writes must pass (server dry-run runs admission).
check allow-project-admin-clusterrole-shape k create clusterrole kargo-project-admin-e2e --verb=update,delete --resource=projects.kargo.akuity.io --resource-name=e2e --dry-run=server "${PROBE_AS[@]}"
check allow-secret-in-project-ns k -n oracle-kargo create secret generic e2e-ok --from-literal=a=b --dry-run=server "${PROBE_AS[@]}"

# Kargo still works under Deny: make the management controller RE-CREATE its per-Project RBAC
# (the writes the policy guards), then a fresh Freight through both Stages.
log "Deny phase: force Kargo to rebuild its Project RBAC + promote new Freight"
k delete clusterrolebinding kargo-project-admin-oracle-kargo >>"$EVID/run.log" 2>&1
k delete clusterrole kargo-project-admin-oracle-kargo >>"$EVID/run.log" 2>&1
k -n oracle-kargo delete role kargo-admin kargo-viewer kargo-promoter >>"$EVID/run.log" 2>&1
k -n oracle-kargo delete rolebinding kargo-admin kargo-viewer kargo-promoter kargo-controller-read-secrets kargo-project-admin >>"$EVID/run.log" 2>&1
k annotate project oracle-kargo kargo.akuity.io/refresh="$(date +%s)" --overwrite >>"$EVID/run.log" 2>&1
wait_for deny-project-admin-clusterrole-rebuilt 180 k get clusterrole kargo-project-admin-oracle-kargo
wait_for deny-project-admin-crb-rebuilt 60 k get clusterrolebinding kargo-project-admin-oracle-kargo
wait_for deny-project-roles-rebuilt 120 k -n oracle-kargo get role kargo-admin kargo-viewer kargo-promoter
wait_for deny-read-secrets-rb-rebuilt 120 k -n oracle-kargo get rolebinding kargo-controller-read-secrets
# New Freight: widen discovery so the Warehouse finds a tag it has not seen, and refresh it.
k -n oracle-kargo patch warehouse podinfo --type json -p '[{"op":"replace","path":"/spec/subscriptions/0/image/discoveryLimit","value":5}]' >>"$EVID/run.log" 2>&1
k -n oracle-kargo get freight -o name > "$EVID/freight-before-deny.txt"
k -n oracle-kargo annotate warehouse podinfo kargo.akuity.io/refresh="$(date +%s)" --overwrite >>"$EVID/run.log" 2>&1
# Freight promotion is auto (newest first) — a promote of an OLDER freight proves the path too:
OLD=$(k -n oracle-kargo get freight -o json | jq -r '[.items[] | select(.origin.name=="podinfo")] | sort_by(.metadata.creationTimestamp) | .[0].metadata.name')
echo "deny-phase promotion freight: ${OLD:-<none>}" >> "$EVID/run.log"
DENY_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for st in smoke ingester; do
  [ -n "$OLD" ] && [ "$OLD" != null ] || break
  printf 'apiVersion: kargo.akuity.io/v1alpha1\nkind: Promotion\nmetadata:\n  name: deny-phase-%s\n  namespace: oracle-kargo\nspec:\n  stage: %s\n  freight: %s\n' \
    "$st" "$st" "$OLD" > "$EVID/promotion-$st.yaml"
  k apply -f "$EVID/promotion-$st.yaml" >>"$EVID/run.log" 2>&1
done
# Kargo's webhook renames a Promotion (<stage>.<ulid>.<freight>), so match by stage + freight +
# created after the flip.
promo_ok() { kubectl --context "$CTX" -n oracle-kargo get promotions -o json \
  | jq -e --arg st "$1" --arg fr "$OLD" --arg ts "$DENY_TS" '[.items[] | select(.spec.stage==$st and .spec.freight==$fr and .metadata.creationTimestamp >= $ts and .status.phase=="Succeeded")] | length > 0'; }
wait_for deny-promotion-smoke-succeeded 300 promo_ok smoke
wait_for deny-promotion-ingester-succeeded 300 promo_ok ingester
wait_for deny-stage-smoke-verified 300 stage_verified smoke
wait_for deny-stage-ingester-verified 300 stage_verified ingester

log "settle 30s, then forbidden scan (Deny phase)"
sleep 30
collect
check no-forbidden-in-logs-deny-phase forbidden_in_logs
# Kargo's own requests must never have been refused/annotated (the probes are not in this file).
if [ -s "$EVID/policy-annotations.tsv" ]; then
  fail kargo-itself-never-refused-under-deny "$(wc -l < "$EVID/policy-annotations.tsv") annotated kargo request(s) — see policy-annotations.tsv"
else pass kargo-itself-never-refused-under-deny; fi

# ── the metric the alert reads ────────────────────────────────────────────────────────────────
k get --raw /metrics 2>/dev/null | grep '^apiserver_validating_admission_policy_check_total' > "$EVID/vap-metrics.deny-phase.txt"
deny_count=$(awk '/policy="kargo-write-guard"/ && /enforcement_action="deny"/ {s+=$NF} END {print s+0}' "$EVID/vap-metrics.deny-phase.txt")
[ "${deny_count%.*}" -gt 0 ] && pass vap-metric-deny-count "deny=$deny_count" || fail vap-metric-deny-count "deny=$deny_count"
info vap-metric-label-sets "$(sed 's/ [0-9.e+]*$//' "$EVID/vap-metrics.deny-phase.txt" | grep kargo | tr '\n' ' ' | cut -c1-900)"

[ -s "$EVID/forbidden-by-sa.tsv" ] && info audit-403s "$(wc -l < "$EVID/forbidden-by-sa.tsv") distinct (see forbidden-by-sa.tsv)"
log "done: $(grep -c ^PASS "$RESULTS") PASS, $(grep -c ^FAIL "$RESULTS") FAIL"
! grep -q ^FAIL "$RESULTS"
