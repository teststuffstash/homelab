#!/usr/bin/env bash
# mgmt-verdict — the management box's OWN read of cluster health, one that does not ride Prometheus
# (FU-302; docs/management-box.md §"The box verdict"; the glossary's "⚓ box verdict"). Prometheus is
# in-cluster and its reads ride a Cilium BGP VIP that the router carries, so every gate that asks it
# goes blind exactly when the cluster or the router has a bad day. The operator's ruling (2026-10-02):
# no out-of-band human notification — the box needs its own verdict for its OWN gates.
#
# The reads, and what each one may say (worst wins; `unreadable` is never `ok`):
#   kube-api        GET /readyz through the kubeconfig's server — the CP VIP (L2, not the router)   down
#   talos           `talosctl version` against every Talos node machines.yaml declares (a `reconcile`
#                   key — every Talos node carries one since FU-273); L2, no kube needed. Control
#                   planes answering ≤ half of those declared → down (quorum-lost); any node silent → degraded
#   nodes           Node Ready from the kube API; a NotReady node → degraded
#   cilium-backend  maintenance-window.sh probe 3 (cilium_backends + cilium_verdict, SOURCED — one home):
#                   an agent missing the 10.96.0.1:443 backend, or no agent answering → degraded
#   bgp             `kubectl exec` into every cilium agent: `cilium-dbg bgp peers -o json`. Some session
#                   not established → degraded; NO session established anywhere → down (the VIPs are gone)
#   vips            LAN HTTP to every BGP-advertised LoadBalancer (label bgp=advertise) — one TCP port per
#                   VIP, a connect is the answer (curl exit 7/28 = unreachable; any other = something
#                   answered). The list comes from the kube API and is CACHED, so it still runs with the
#                   API down. Some silent → degraded; ALL silent → down (rides the router: this is the
#                   only read here that does)
#   prometheus      GET <prom>/-/ready     — not ready → degraded, NEVER down: the observability plane is
#   alertmanager    GET <am>/-/ready         not the cluster, and this verdict exists to outlive it
#   argocd          the Application health summary (applications.argoproj.io, kube API); Degraded or
#                   Missing → degraded; Progressing/Suspended/Unknown are counted, never judged
#   pods            maintenance-window.sh probe 4 (hard-failed pods) — status `info`, NEVER moves the
#                   verdict: an absolute count is steady-state noise (a failed CronJob pod sits in Error
#                   for days); the delta is the bracket's job — diff `.checks[] | select(.check=="pods")`
# A read that needs the kube API is `skip` (reason kube-api-down) while kube-api is down — the cause is
# already counted once. `--skip <check>` is the operator's knob and is reported as `skip requested`.
#
# Output: one JSON object on stdout (default) — {verdict, at, reasons[], checks[{check, status, reason,
# detail, items[]}], sources{}} — or `--format text`. EXIT: 0 ok · 2 degraded · 3 down · 1 the verdict
# itself could not run (no kubeconfig/talosconfig, bad env) · 64 usage. Callers treat 1 as a no.
# Read-only by construction: get/exec of read-only cilium-dbg verbs/version/GET only.
#
# Callers (docs/management-box.md §"The box verdict" says replace-or-AND for each):
#   mgmt-apply.sh     a DOWN verdict defers the apply (ANDed with the window gate); the Talos bracket's
#                     post-check also requires the verdict no worse than its baseline (ANDed with compare)
#   mgmt-reconcile.sh a DOWN (or unrunnable) verdict refuses the sync (ANDed with MgmtRolloutDifferential)
#   FU-301            brackets a helm apply: verdict before, verdict after, worse = stop
#
# Usage:
#   devbox run mgmt-verdict                                   # JSON
#   devbox run mgmt-verdict -- --format text
#   devbox run mgmt-verdict -- --prom http://127.0.0.1:1      # Prometheus "unreachable", the rest direct
#   devbox run mgmt-verdict -- --skip "vips argocd"
# Env: KUBECONFIG/TALOSCONFIG (box: /var/lib/mgmt/*; the fallback lives in maintenance-window.sh),
#   VERDICT_PROM / VERDICT_AM (defaults: the Prometheus / Alertmanager LoadBalancer VIPs),
#   VERDICT_STATE_DIR (the VIP list cache; default /var/lib/mgmt/verdict, else ~/.cache/mgmt-verdict),
#   VERDICT_MACHINES_JSON (test seam: machines.yaml as JSON), VERDICT_TIMEOUT (per read, s; default 10).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
V_PROM="${VERDICT_PROM:-http://192.168.40.13:9090}"
V_AM="${VERDICT_AM:-http://192.168.40.14:9093}"
V_TO="${VERDICT_TIMEOUT:-10}"
FORMAT=json; V_SKIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prom)   [ -n "${2:-}" ] || { echo "--prom needs a URL" >&2; exit 64; }; V_PROM="$2"; shift 2 ;;
    --am)     [ -n "${2:-}" ] || { echo "--am needs a URL" >&2; exit 64; }; V_AM="$2"; shift 2 ;;
    --format) case "${2:-}" in json|text) FORMAT="$2" ;; *) echo "--format json|text" >&2; exit 64 ;; esac; shift 2 ;;
    --skip)   V_SKIP="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "usage: mgmt-verdict.sh [--prom URL] [--am URL] [--format json|text] [--skip \"<check> …\"]" >&2; exit 64 ;;
  esac
done

# Probes 3–4 and the kubeconfig/talosconfig resolution: SOURCED from their one home. The script returns
# before its verb dispatch when sourced; it sets -e, which this read-everything script must not run under.
# A missing kubeconfig exits it with 1 — the verdict's own "could not run".
# shellcheck source=../../scripts/maintenance-window.sh
. "$REPO/scripts/maintenance-window.sh" || exit 1
set +e
# `devbox run` hands a nix-shell environment down, and nix EXPORTS `$out` — so a node or Application
# list assigned to `out` rode the environment of every later exec and hit the kernel's per-string limit
# ("Argument list too long", found on the first live run). Un-export it before any read.
export -n out 2>/dev/null; unset out

V_STATE="${VERDICT_STATE_DIR:-/var/lib/mgmt/verdict}"
mkdir -p "$V_STATE" 2>/dev/null && [ -w "$V_STATE" ] || { V_STATE="${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/mgmt-verdict"; mkdir -p "$V_STATE" || exit 1; }
W="$(mktemp -d)" || exit 1
trap 'rm -rf "$W"' EXIT
KC=(--kubeconfig "$KUBECONFIG" --request-timeout="${V_TO}s")

CHECKS=()   # one compact JSON object per check
add() {  # <check> <status> <reason> <detail> [items-json]
  CHECKS+=("$(jq -nc --arg c "$1" --arg s "$2" --arg r "$3" --arg d "$4" --argjson i "${5:-[]}" \
    '{check:$c, status:$s, reason:$r, detail:$d, items:$i}')")
}
skipping() { case " $V_SKIP " in *" $1 "*) add "$1" skip requested "skip requested"; return 0 ;; esac; return 1; }
KUBE_UP=false
kube_skip() { add "$1" skip kube-api-down "not read: the kube API is down (counted once, under kube-api)"; }

# ── kube-api ─────────────────────────────────────────────────────────────────────────────────────
v_kube_api() {
  local server out
  server="$(kubectl --kubeconfig "$KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  skipping kube-api && { KUBE_UP=true; return; }
  if out="$(kubectl "${KC[@]}" get --raw /readyz 2>&1)" && [ "$out" = ok ]; then
    KUBE_UP=true; add kube-api ok ok "/readyz ok via ${server:-?}"
  elif grep -qiE 'refused|timeout|no route|unreachable|deadline|EOF' <<<"$out"; then
    add kube-api down unreachable "${server:-?}: $(tail -1 <<<"$out" | cut -c1-160)"
  else
    add kube-api down not-ready "${server:-?}: $(tail -1 <<<"$out" | cut -c1-160)"
  fi
}

# ── talos: every declared Talos node, in parallel ──────────────────────────────────────────────────
v_talos() {
  skipping talos && return
  local mj rows name ip cp n=0 up=0 cpn=0 cpup=0 silent=() vers ver
  if [ -n "${VERDICT_MACHINES_JSON:-}" ]; then mj="$(cat "$VERDICT_MACHINES_JSON" 2>/dev/null)"
  else mj="$(yq -o=json "$REPO/machines/machines.yaml" 2>/dev/null)"; fi
  rows="$(jq -r '.machines[] | select(.reconcile != null)
            | [.name, .ip, ((.controlplane == true) or ((.role // "") | test("^k8s control plane")))] | @tsv' <<<"$mj" 2>/dev/null)"
  [ -n "$rows" ] || { add talos unreadable unreadable "machines.yaml declares no Talos node (or did not parse)"; return; }
  while IFS=$'\t' read -r name ip cp; do
    ( timeout "$((V_TO + 5))" talosctl --talosconfig "$TALOSCONFIG" -n "$ip" version --short >"$W/talos.$name" 2>&1
      echo $? >"$W/talos.$name.rc" ) &
  done <<<"$rows"
  wait
  while IFS=$'\t' read -r name ip cp; do
    n=$((n+1)); [ "$cp" = true ] && cpn=$((cpn+1))
    ver="$(sed -n '/^Server:/,$p' "$W/talos.$name" | awk '/Tag:/{print $2; exit}')"
    if [ "$(cat "$W/talos.$name.rc" 2>/dev/null)" = 0 ] && [ -n "$ver" ]; then
      up=$((up+1)); [ "$cp" = true ] && cpup=$((cpup+1)); vers+="$ver"$'\n'
    else silent+=("$name ($ip)"); fi
  done <<<"$rows"
  local items; items="$(printf '%s\n' "${silent[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  local vs; vs="$(printf '%s' "$vers" | sort | uniq -c | awk '{printf "%s%s×%s", (NR>1?", ":""), $2, $1}')"
  if [ "$cpn" -gt 0 ] && [ $((cpup * 2)) -le "$cpn" ]; then
    add talos down quorum-lost "$cpup/$cpn control planes answer the Talos API ($up/$n nodes)" "$items"
  elif [ ${#silent[@]} -gt 0 ]; then
    add talos degraded unreachable "$up/$n nodes answer the Talos API (${vs:-none}); silent: ${silent[*]}" "$items"
  else
    add talos ok ok "$up/$n nodes answer the Talos API ($vs)"
  fi
}

# ── nodes: Ready ─────────────────────────────────────────────────────────────────────────────────
v_nodes() {
  skipping nodes && return
  $KUBE_UP || { kube_skip nodes; return; }
  local out bad n
  out="$(kubectl "${KC[@]}" get nodes -o json 2>/dev/null)" && jq -e '.items | length > 0' >/dev/null 2>&1 <<<"$out" \
    || { add nodes unreadable unreadable "kubectl get nodes failed or returned none"; return; }
  n="$(jq '.items | length' <<<"$out")"
  bad="$(jq -c '[.items[] | select(([.status.conditions[]? | select(.type == "Ready")][0].status // "Unknown") != "True") | .metadata.name]' <<<"$out")"
  if [ "$bad" != '[]' ]; then add nodes degraded notready "$(jq length <<<"$bad")/$n NotReady: $(jq -r 'join(", ")' <<<"$bad")" "$bad"
  else add nodes ok ok "$n/$n Ready"; fi
}

# ── cilium-backend: probe 3, its own verdict function ───────────────────────────────────────────
v_cilium_backend() {
  skipping cilium-backend && return
  $KUBE_UP || { kube_skip cilium-backend; return; }
  local cil ok=true msg rc
  cil="$(cilium_backends)" || { cil="0 0 0"; ok=false; }
  # shellcheck disable=SC2086
  msg="$(cilium_verdict "$ok" $cil)"; rc=$?
  msg="$(sed -n '1{s/^[[:space:]]*\(⚠\|ok\)[[:space:]]*//;p}' <<<"$msg")"
  case "$rc" in
    0) add cilium-backend ok ok "$msg" ;;
    2) add cilium-backend degraded missing-backend "$msg" ;;
    *) add cilium-backend unreadable unreadable "$msg" ;;
  esac
}

# ── bgp: every cilium agent's peers, in parallel ──────────────────────────────────────────────────
v_bgp() {
  skipping bgp && return
  $KUBE_UP || { kube_skip bgp; return; }
  local pods p node sess=0 est=0 unk=0 agents=0 down=() f
  pods="$(kubectl "${KC[@]}" -n kube-system get pod -l k8s-app=cilium -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null)"
  [ -n "$pods" ] || { add bgp unreadable unreadable "could not list the cilium agents"; return; }
  while IFS=$'\t' read -r p node; do
    [ -n "$p" ] || continue
    ( timeout "$((V_TO + 10))" kubectl "${KC[@]}" -n kube-system exec "$p" -c cilium-agent -- cilium-dbg bgp peers -o json \
        >"$W/bgp.$p" 2>/dev/null || : >"$W/bgp.$p" ) &
  done <<<"$pods"
  wait
  while IFS=$'\t' read -r p node; do
    [ -n "$p" ] || continue; agents=$((agents+1)); f="$W/bgp.$p"
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <"$f"; then unk=$((unk+1)); continue; fi
    sess=$((sess + $(jq length <"$f"))); est=$((est + $(jq '[.[] | select(."session-state" == "established")] | length' <"$f")))
    while read -r a; do [ -n "$a" ] && down+=("$node→$a"); done < <(jq -r '.[] | select(."session-state" != "established") | "\(."peer-address") (\(."session-state"))"' <"$f")
  done <<<"$pods"
  local items; items="$(printf '%s\n' "${down[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  local d="$est/$sess sessions established on $((agents - unk))/$agents agents"; [ "$unk" -gt 0 ] && d+=" ($unk agent(s) did not answer)"
  if [ "$unk" -eq "$agents" ]; then add bgp unreadable unreadable "no cilium agent answered \`cilium-dbg bgp peers\` ($agents tried)"
  elif [ "$sess" -gt 0 ] && [ "$est" -eq 0 ]; then add bgp down no-session "$d — no BGP session up anywhere: the LoadBalancer VIPs are not advertised" "$items"
  elif [ "$sess" -eq 0 ]; then add bgp down no-session "$d — no agent has a BGP peer configured" "$items"
  elif [ ${#down[@]} -gt 0 ]; then add bgp degraded peer-down "$d; not established: ${down[*]}" "$items"
  elif [ "$unk" -gt 0 ]; then add bgp degraded unreadable "$d"
  else add bgp ok ok "$d"; fi
}

# ── vips: LAN HTTP to the BGP VIPs (the list from the kube API, cached for when it is down) ────────
v_vips() {
  skipping vips && return
  local list="" src=kube age cache="$V_STATE/vips.json" ip port name rc reach=0 n=0 silent=()
  if $KUBE_UP && list="$(kubectl "${KC[@]}" get svc -A -l bgp=advertise -o json 2>/dev/null | jq -c '
        [.items[] | select(.spec.type == "LoadBalancer") | . as $s
         | ([.spec.ports[] | select(.protocol == "TCP") | .port][0]) as $p | select($p != null)
         | .status.loadBalancer.ingress[]? | select(.ip) | {ip, port: $p, name: "\($s.metadata.namespace)/\($s.metadata.name)"}]
        | unique_by(.ip)' 2>/dev/null)" && [ "$list" != '[]' ] && [ -n "$list" ]; then
    printf '%s\n' "$list" >"$cache.tmp" && mv -f "$cache.tmp" "$cache"
  elif [ -s "$cache" ] && list="$(jq -c . "$cache" 2>/dev/null)"; then
    age=$(( $(date +%s) - $(stat -c %Y "$cache") )); src="cache, ${age}s old"
  else
    add vips unreadable unreadable "no VIP list: the kube API read failed and no cached list exists at $cache"; return
  fi
  while IFS=$'\t' read -r ip port name; do
    ( curl -s -o /dev/null --connect-timeout 3 --max-time 5 "http://$ip:$port/" ; echo $? >"$W/vip.$ip" ) &
  done < <(jq -r '.[] | [.ip, .port, .name] | @tsv' <<<"$list")
  wait
  while IFS=$'\t' read -r ip port name; do
    n=$((n+1)); rc="$(cat "$W/vip.$ip" 2>/dev/null)"
    case "$rc" in 7|28|"") silent+=("$name $ip:$port") ;; *) reach=$((reach+1)) ;; esac
  done < <(jq -r '.[] | [.ip, .port, .name] | @tsv' <<<"$list")
  local items; items="$(printf '%s\n' "${silent[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  if [ "$reach" -eq 0 ]; then add vips down unreachable "0/$n BGP VIPs answer from the LAN (list: $src)" "$items"
  elif [ ${#silent[@]} -gt 0 ]; then add vips degraded unreachable "$reach/$n BGP VIPs answer (list: $src); silent: ${silent[*]}" "$items"
  else add vips ok ok "$reach/$n BGP VIPs answer from the LAN (list: $src)"; fi
}

# ── prometheus / alertmanager: /-/ready — degraded at worst, never down ────────────────────────────
v_ready() {  # <check> <base-url>
  skipping "$1" && return
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time "$V_TO" "$2/-/ready")"
  case "$code" in
    200) add "$1" ok ok "$2/-/ready 200" ;;
    000) add "$1" degraded unreachable "$2/-/ready did not answer" ;;
    *)   add "$1" degraded not-ready "$2/-/ready answered $code" ;;
  esac
}

# ── argocd: the Application health summary through the kube API ───────────────────────────────────
v_argocd() {
  skipping argocd && return
  $KUBE_UP || { kube_skip argocd; return; }
  local out sum bad
  out="$(kubectl "${KC[@]}" get applications.argoproj.io -A -o json 2>/dev/null)" && jq -e '.items | type == "array"' >/dev/null 2>&1 <<<"$out" \
    || { add argocd unreadable unreadable "kubectl get applications failed"; return; }
  sum="$(jq -r '[.items[] | .status.health.status // "Unknown"] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' <<<"$out")"
  bad="$(jq -c '[.items[] | select((.status.health.status // "Unknown") as $h | $h == "Degraded" or $h == "Missing")
                | "\(.metadata.name) (\(.status.health.status))"]' <<<"$out")"
  if [ "$bad" != '[]' ]; then add argocd degraded unhealthy "$sum; $(jq -r 'join(", ")' <<<"$bad")" "$bad"
  else add argocd ok ok "${sum:-no Applications}"; fi
}

# ── pods: probe 4, reported only ────────────────────────────────────────────────────────────────
v_pods() {
  skipping pods && return
  $KUBE_UP || { kube_skip pods; return; }
  local out items
  if ! out="$(pods_bad_list)"; then add pods unreadable unreadable "kubectl get pods failed"; return; fi
  items="$(printf '%s\n' "$out" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  add pods info "$([ "$items" = '[]' ] && echo ok || echo hard-failed)" "$(jq length <<<"$items") hard-failed pod(s) — reported, never judged (diff two verdicts for a delta)" "$items"
}

v_kube_api; v_talos; v_nodes; v_cilium_backend; v_bgp; v_vips
v_ready prometheus "$V_PROM"; v_ready alertmanager "$V_AM"
v_argocd; v_pods

# ── the verdict: worst wins; `unreadable` counts as degraded ("could not look" is never ok) ─────────
SERVER="$(kubectl --kubeconfig "$KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
OUT="$(printf '%s\n' "${CHECKS[@]}" | jq -sc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg prom "$V_PROM" --arg am "$V_AM" --arg kube "$SERVER" --arg tc "$TALOSCONFIG" '
  (map(select(.status == "down")) | length) as $down
  | (map(select(.status == "degraded" or .status == "unreadable")) | length) as $deg
  | {verdict: (if $down > 0 then "down" elif $deg > 0 then "degraded" else "ok" end),
     at: $at,
     reasons: [.[] | select(.status == "down" or .status == "degraded" or .status == "unreadable")
               | "\(.check): \(.reason) — \(.detail)"],
     checks: .,
     sources: {kube: $kube, talosconfig: $tc, prometheus: $prom, alertmanager: $am}}')" || exit 1
if [ "$FORMAT" = text ]; then
  jq -r '"box verdict: \(.verdict | ascii_upcase)  (\(.at))",
         (.checks[] | "  \(.status | . + (" " * (10 - length)))\(.check | . + (" " * (15 - length)))\(.detail)")' <<<"$OUT"
else
  printf '%s\n' "$OUT"
fi
case "$(jq -r .verdict <<<"$OUT")" in ok) exit 0 ;; degraded) exit 2 ;; down) exit 3 ;; *) exit 1 ;; esac
