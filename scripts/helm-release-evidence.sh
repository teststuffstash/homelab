#!/usr/bin/env bash
# helm-release-evidence — record what a `helm_release` apply in the main root actually did to the
# cluster: a per-release snapshot before, a timeline while it settles, a snapshot after, and the
# maintenance-window health compare around it. REPORT-ONLY — it never reverts, retries or halts.
#
#   bash scripts/helm-release-evidence.sh run <plan-id> [--label <slug>]   # ATTENDED: apply + record
#   bash scripts/helm-release-evidence.sh snapshot                         # JSON on stdout
#   bash scripts/helm-release-evidence.sh watch <seconds> [<interval>]     # JSONL timeline on stdout
#   bash scripts/helm-release-evidence.sh diff <before.json> <after.json>  # human summary
#
# WHY DATA, NOT A GATE (operator, 2026-10-02): the box's helm releases are the cluster's network,
# storage and GitOps layers (Cilium, Longhorn, ArgoCD); a bad upgrade there has no clean rollback
# (Longhorn refuses downgrades, a provider-major state rewrite does not revert) and no prod canary
# for the cluster-wide half. A box or responder acting on such a failure would be wrong more often
# than right on today's data, so nothing acts on it yet: every apply is recorded so the failures
# that do happen become the evidence a later detector is tuned on. The first ATTENDED run (#2046,
# the helm provider 2.x → 3.x migration) is the one that writes this verb for the box, the same
# way the box-run Talos rollout began as attended bumps (docs/management-box.md §MB4).
#
# Reads only the Kubernetes API (the Talos-owned control-plane VIP) and `kubectl exec` into the
# cilium agents (kubelet, not the pod network) — none of it depends on Prometheus, which rides a
# Cilium BGP VIP. The maintenance-window snapshot/compare it brackets the apply with DOES read
# Prometheus; an unreadable probe there is reported as such, never as "fine".
#
# `run` applies through `mgmt/scripts/mgmt-tf.sh apply <plan-id>` with MGMT_YES=1 — plan it first
# and read it (`devbox run mgmt-tf -- plan`): passing the id to `run` is the confirmation, and the
# evidence is only as meaningful as the plan you approved.
# Run it inside a declared window (`devbox run maint -- open --reason …`).
#
# Evidence lands in $HELM_EVIDENCE_DIR (default ~/.claude/helm-evidence)/<utc>-<label>/:
#   before.json after.json timeline.jsonl health-before.json health-compare.txt apply.log summary.txt
# Env: HELM_RELEASES ("<release>:<namespace> …"), WATCH_SECS (900), WATCH_INTERVAL (20), KUBECONFIG.
set -euo pipefail

ROOT="${DEVBOX_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export KUBECONFIG="${KUBECONFIG:-$ROOT/tofu/kubeconfig}"
# Same fallback as maintenance-window.sh / node-maintenance.sh: on the management box the client
# config lives in /var/lib/mgmt/, and devbox exports the checkout path regardless.
[ -f "$KUBECONFIG" ] || { [ -f /var/lib/mgmt/kubeconfig ] && export KUBECONFIG=/var/lib/mgmt/kubeconfig; }
[ -f "$KUBECONFIG" ] || { echo "helm-release-evidence: no kubeconfig at $KUBECONFIG" >&2; exit 1; }
RELEASES="${HELM_RELEASES:-cilium:kube-system longhorn:longhorn-system argocd:argocd argocd-apps:argocd}"
# stderr goes to $EVIDENCE_ERRLOG (default: discarded), never into a captured JSON read — kubectl
# warnings on stderr would otherwise be parsed as the object.
K() { kubectl --request-timeout=20s "$@" 2>>"${EVIDENCE_ERRLOG:-/dev/null}"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── reads ────────────────────────────────────────────────────────────────────────────────────────
# Every read writes JSON to a FILE; a failed read writes {"error": "..."} in its place, never an
# empty value a later diff would read as "nothing there". Files, not shell variables, because a
# namespace's Secret list is far past the 128 KiB a single exec argument may carry (`jq --argjson`
# with it died E2BIG on the first live run) — every combine below is `--slurpfile`/stdin.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { jq -nc --arg e "$1" '{error:$e}'; }

get_ns() { # <ns> <kinds> <tag> → $T/ns-<ns>-<tag>.json, one read per namespace per snapshot, shared
  # by every release in it. Secrets are their own read: helm keeps its release history as Secrets,
  # megabytes per namespace, which the 20 s timeline has no use for.
  [ -s "$T/ns-$1-$3.json" ] && return 0
  K get "$2" -n "$1" -o json > "$T/ns-$1-$3.json" || { fail "read failed: get $2 -n $1" > "$T/ns-$1-$3.json"; return 1; }
}

helm_state() { # <rel> <ns>
  local m
  helm history "$1" -n "$2" --max 1 -o json > "$T/h.json" 2>>"${EVIDENCE_ERRLOG:-/dev/null}" \
    || { fail "read failed: helm history $1"; return; }
  m="$(helm get manifest "$1" -n "$2" 2>/dev/null | sha256sum | cut -c1-16)"
  jq -c --arg m "$m" '.[-1] | {revision, status, chart, app_version, updated, manifest_sha:$m}' "$T/h.json"
}

workloads() { # <rel> <ns> — the release's DaemonSets/Deployments/StatefulSets with their roll state
  get_ns "$2" ds,deploy,sts wl || { cat "$T/ns-$2-wl.json"; return; }
  jq -c --arg r "$1" '[.items[] | select(.metadata.annotations["meta.helm.sh/release-name"] == $r) | {
      kind, name: .metadata.name, generation: .metadata.generation,
      observed: .status.observedGeneration,
      desired:   (.status.desiredNumberScheduled // .spec.replicas // 0),
      ready:     (.status.numberReady // .status.readyReplicas // 0),
      updated:   (.status.updatedNumberScheduled // .status.updatedReplicas // 0),
      available: (.status.numberAvailable // .status.availableReplicas // 0),
      selector:  .spec.selector.matchLabels }]' "$T/ns-$2-wl.json"
}

pods() { # <ns> <workloads-file> — every pod behind the release's workloads
  local sel
  : > "$T/pods.jsonl"
  while IFS= read -r sel; do
    [ -n "$sel" ] || continue
    K get pods -n "$1" -l "$sel" -o json > "$T/p.json" || { fail "read failed: pods -l $sel"; return; }
    jq -c '[.items[] | {
        name: .metadata.name, uid: .metadata.uid, node: .spec.nodeName, phase: .status.phase,
        started: .status.startTime,
        ready: ([.status.containerStatuses[]?.ready] | all),
        restarts: ([.status.containerStatuses[]?.restartCount] | add // 0),
        images: ([.spec.containers[].image] | unique) }]' "$T/p.json" >> "$T/pods.jsonl"
  done < <(jq -r 'if type == "array" then .[] | .selector // {} | to_entries | map("\(.key)=\(.value)") | join(",") else empty end' "$2")
  jq -sc 'add // [] | unique_by(.uid)' "$T/pods.jsonl"
}

secrets() { # <rel> <ns> — chart-owned Secrets: did the upgrade rotate them? (a hash, never a value)
  local n sha
  get_ns "$2" secrets sec || { cat "$T/ns-$2-sec.json"; return; }
  jq -r --arg r "$1" '.items[] | select(.metadata.annotations["meta.helm.sh/release-name"] == $r) | .metadata.name' "$T/ns-$2-sec.json" |
    while IFS= read -r n; do
      sha="$(jq -cS --arg n "$n" '.items[] | select(.metadata.name == $n) | .data // {}' "$T/ns-$2-sec.json" | sha256sum | cut -c1-16)"
      jq -c --arg n "$n" --arg sha "$sha" '.items[] | select(.metadata.name == $n)
          | {name: $n, rv: .metadata.resourceVersion, data_sha: $sha}' "$T/ns-$2-sec.json"
    done | jq -sc '.'
}

# ── component-specific reads (what "broken" looks like for each layer) ───────────────────────────
cilium_bgp() { # per agent: its BGP sessions — the layer the router peers with
  local p
  : > "$T/bgp.jsonl"
  for p in $(K get pods -n kube-system -l k8s-app=cilium -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.nodeName}{"\n"}{end}'); do
    if K exec -n kube-system "${p%%:*}" -c cilium-agent -- cilium-dbg bgp peers -o json > "$T/b.json"; then
      jq -c --arg node "${p##*:}" '[.[]? | {node:$node, peer:."peer-address", state:."session-state",
          uptime_s:((."uptime-nanoseconds" // 0) / 1e9 | floor)}]' "$T/b.json" >> "$T/bgp.jsonl"
    else
      jq -nc --arg node "${p##*:}" '[{node:$node, error:"exec failed"}]' >> "$T/bgp.jsonl"
    fi
  done
  jq -sc 'add // []' "$T/bgp.jsonl"
}

longhorn_state() {
  K get settings.longhorn.io -n longhorn-system -o json > "$T/ls.json" || { fail "read failed: longhorn settings"; return; }
  K get volumes.longhorn.io -n longhorn-system -o json > "$T/lv.json" || { fail "read failed: longhorn volumes"; return; }
  jq -nc --slurpfile s "$T/ls.json" --slurpfile v "$T/lv.json" '{
      settings: [$s[0].items[] | {name: .metadata.name, value, applied: .status.applied}],
      volumes:  [$v[0].items[] | {name: .metadata.name, state: .status.state,
                 robustness: .status.robustness, engine: .status.currentImage, node: .status.currentNodeID}]}'
}

argocd_apps() {
  K get applications.argoproj.io -n argocd -o json > "$T/a.json" || { fail "read failed: argocd applications"; return; }
  jq -c '[.items[] | {name: .metadata.name, health: (.status.health.status // "?"), sync: (.status.sync.status // "?")}]' "$T/a.json"
}

# ── verbs ────────────────────────────────────────────────────────────────────────────────────────
cmd_snapshot() {
  local rel ns
  rm -f "$T"/ns-*.json; : > "$T/rel.jsonl"
  for r in $RELEASES; do
    rel="${r%%:*}"; ns="${r##*:}"
    helm_state "$rel" "$ns" > "$T/rh.json"; workloads "$rel" "$ns" > "$T/rw.json"
    pods "$ns" "$T/rw.json" > "$T/rp.json"; secrets "$rel" "$ns" > "$T/rs.json"
    jq -nc --arg rel "$rel" --arg ns "$ns" --slurpfile h "$T/rh.json" --slurpfile w "$T/rw.json" \
      --slurpfile p "$T/rp.json" --slurpfile s "$T/rs.json" \
      '{($rel): {namespace:$ns, helm:$h[0], workloads:$w[0], pods:$p[0], secrets:$s[0]}}' >> "$T/rel.jsonl"
  done
  cilium_bgp > "$T/sb.json"; longhorn_state > "$T/sl.json"; argocd_apps > "$T/sa.json"
  jq -nc --arg at "$(now)" --slurpfile rel "$T/rel.jsonl" --slurpfile bgp "$T/sb.json" \
    --slurpfile lh "$T/sl.json" --slurpfile argo "$T/sa.json" \
    '{at:$at, releases:($rel | add), cilium_bgp:$bgp[0], longhorn:$lh[0], argocd:$argo[0]}'
}

# One compact line per tick: the signals that move during a roll. Cheap enough at 20 s.
tick() {
  local rel ns
  rm -f "$T"/ns-*.json; : > "$T/trel.jsonl"
  for r in $RELEASES; do
    rel="${r%%:*}"; ns="${r##*:}"
    workloads "$rel" "$ns" > "$T/tw.json"; pods "$ns" "$T/tw.json" > "$T/tp.json"
    jq -nc --arg rel "$rel" --slurpfile w "$T/tw.json" --slurpfile p "$T/tp.json" '{($rel): {
        workloads: ($w[0] | if type == "array" then map({(.name): "\(.ready)/\(.desired) upd=\(.updated) gen=\(.observed)/\(.generation)"}) | add else . end),
        restarts: ($p[0] | if type == "array" then map(.restarts) | add // 0 else . end),
        not_ready: ($p[0] | if type == "array" then map(select(.ready | not) | .name) else . end)}}' >> "$T/trel.jsonl"
  done
  cilium_bgp > "$T/tb.json"; longhorn_state > "$T/tl.json"; argocd_apps > "$T/ta.json"
  jq -nc --arg at "$(now)" --slurpfile rel "$T/trel.jsonl" --slurpfile bgp "$T/tb.json" \
    --slurpfile lh "$T/tl.json" --slurpfile argo "$T/ta.json" '{at:$at, releases:($rel | add),
      bgp_established: ($bgp[0] | if type == "array" then map(select(.state == "established")) | length else . end),
      bgp_total: ($bgp[0] | if type == "array" then length else . end),
      longhorn_robustness: ($lh[0].volumes // [] | group_by(.robustness) | map({(.[0].robustness // "?"): length}) | add),
      argocd: ($argo[0] | if type == "array" then group_by("\(.health)/\(.sync)") | map({("\(.[0].health)/\(.[0].sync)"): length}) | add else . end)}'
}

cmd_watch() {
  local secs="${1:-${WATCH_SECS:-900}}" step="${2:-${WATCH_INTERVAL:-20}}" end
  end=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$end" ]; do tick; sleep "$step"; done
}

cmd_diff() { # <before> <after>
  jq -rn --slurpfile a "$1" --slurpfile b "$2" '
    ($a[0]) as $A | ($b[0]) as $B |
    "before \($A.at)  after \($B.at)",
    ( $B.releases | keys[] as $r |
      ($A.releases[$r]) as $x | ($B.releases[$r]) as $y |
      "== \($r): revision \($x.helm.revision) → \($y.helm.revision) (\($y.helm.status)), chart \($x.helm.chart) → \($y.helm.chart), manifest \(if $x.helm.manifest_sha == $y.helm.manifest_sha then "UNCHANGED" else "CHANGED \($x.helm.manifest_sha) → \($y.helm.manifest_sha)" end)",
      ( [$y.workloads[]? | . as $w | ($x.workloads[]? | select(.name == $w.name)) as $o
          | select($o.generation != $w.generation) | "   rolled: \($w.kind)/\($w.name) gen \($o.generation) → \($w.generation), ready \($w.ready)/\($w.desired)"] | .[] ),
      ( ([$x.pods[]?.uid]) as $old | [$y.pods[]? | select(.uid as $u | $old | index($u) | not)] | length |
          "   pods replaced: \(.) of \($y.pods | length)" ),
      ( (([$y.pods[]?.restarts] | add // 0) - ([$x.pods[]?.restarts] | add // 0)) | "   container restarts during: \(.)" ),
      ( [$y.secrets[]? | . as $s | ($x.secrets[]? | select(.name == $s.name)) as $o
          | select($o.data_sha != $s.data_sha) | "   secret rotated: \($s.name)"] | .[] ) ),
    "== cilium BGP: \([$A.cilium_bgp[] | select(.state == "established")] | length)/\($A.cilium_bgp | length) → \([$B.cilium_bgp[] | select(.state == "established")] | length)/\($B.cilium_bgp | length) established; sessions reset: \([$B.cilium_bgp[] | . as $s | ($A.cilium_bgp[] | select(.node == $s.node and .peer == $s.peer)) as $o | select(($s.uptime_s // 0) < ($o.uptime_s // 0))] | length)",
    "== longhorn: settings changed \([$B.longhorn.settings[]? | . as $s | ($A.longhorn.settings[]? | select(.name == $s.name)) as $o | select($o.value != $s.value or $o.applied != $s.applied) | "\($s.name)=\($o.value)→\($s.value) applied=\($s.applied)"])",
    "   robustness \($A.longhorn.volumes | group_by(.robustness) | map({(.[0].robustness // "?"): length}) | add) → \($B.longhorn.volumes | group_by(.robustness) | map({(.[0].robustness // "?"): length}) | add)",
    "== argocd: \($A.argocd | group_by("\(.health)/\(.sync)") | map({("\(.[0].health)/\(.[0].sync)"): length}) | add) → \($B.argocd | group_by("\(.health)/\(.sync)") | map({("\(.[0].health)/\(.[0].sync)"): length}) | add)"'
}

cmd_run() { # <plan-id> [--label <slug>]
  local plan="${1:-}" label="helm-apply"; shift || true
  [ -n "$plan" ] || { echo "run: <plan-id> required (devbox run mgmt-tf -- plan prints it)" >&2; exit 64; }
  [ "${1:-}" = "--label" ] && label="$2"
  local dir="${HELM_EVIDENCE_DIR:-$HOME/.claude/helm-evidence}/$(date -u +%Y%m%dT%H%M%SZ)-$label"
  mkdir -p "$dir"
  echo "evidence → $dir"
  bash "$ROOT/scripts/maintenance-window.sh" snapshot > "$dir/health-before.json" \
    || echo "  ⚠ health baseline has unread probes (kept as-is; see the compare)"
  cmd_snapshot > "$dir/before.json"
  echo "  before: $(jq -r '[.releases | to_entries[] | "\(.key)@\(.value.helm.revision)"] | join(" ")' "$dir/before.json")"
  # The timeline starts BEFORE the apply so the roll's first seconds are on it.
  cmd_watch "$(( ${WATCH_SECS:-900} + 600 ))" "${WATCH_INTERVAL:-20}" > "$dir/timeline.jsonl" & local wpid=$!
  local t0 t1 rc=0; t0="$(now)"
  # MGMT_YES=1: invoking `run` with a plan id IS the confirmation — mgmt-tf's own prompt would sit
  # unseen behind the log redirect. The apply output is still on the terminal (tee).
  MGMT_YES=1 bash "$ROOT/mgmt/scripts/mgmt-tf.sh" apply "$plan" 2>&1 | tee "$dir/apply.log" || rc=${PIPESTATUS[0]}
  t1="$(now)"
  echo "  apply rc=$rc ($t0 → $t1); settling ${WATCH_SECS:-900}s"
  sleep "${WATCH_SECS:-900}"; kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  cmd_snapshot > "$dir/after.json"
  bash "$ROOT/scripts/maintenance-window.sh" compare "$dir/health-before.json" > "$dir/health-compare.txt" 2>&1 || true
  { echo "plan $plan  apply rc=$rc  $t0 → $t1"; cmd_diff "$dir/before.json" "$dir/after.json"
    echo "== health compare (maintenance-window probes)"; cat "$dir/health-compare.txt"; } > "$dir/summary.txt"
  cat "$dir/summary.txt"
  return "$rc"
}

case "${1:-}" in
  snapshot) shift; cmd_snapshot ;;
  watch)    shift; cmd_watch "$@" ;;
  diff)     shift; cmd_diff "$@" ;;
  run)      shift; cmd_run "$@" ;;
  *) echo "usage: helm-release-evidence.sh run <plan-id> [--label s] | snapshot | watch <secs> [<interval>] | diff <before> <after>" >&2; exit 64 ;;
esac
