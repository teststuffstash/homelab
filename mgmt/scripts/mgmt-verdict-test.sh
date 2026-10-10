#!/usr/bin/env bash
# mgmt-verdict-test — the box verdict (mgmt/scripts/mgmt-verdict.sh, FU-302) against FAKE kubectl,
# talosctl and curl on PATH: the real script, its real sourcing of maintenance-window.sh's probes 3–4,
# no cluster. Every expectation below is derived from the rule table in mgmt-verdict.sh's header
# (worst wins; unreadable counts as degraded; prometheus/alertmanager never worse than degraded; a
# kube-dependent read is `skip` while kube-api is down; pods never judged).
#   devbox run mgmt-policy-test   (or: bash mgmt/scripts/mgmt-verdict-test.sh)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/mgmt-verdict.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
: >"$T/kubeconfig"; : >"$T/talosconfig"
fails=0 n=0

# Three control planes + two workers; one machine without `reconcile` (not a Talos node: never probed).
cat >"$T/machines.json" <<'EOF'
{"machines":[
 {"name":"opnsense","ip":"192.168.2.1","role":"router"},
 {"name":"cp-01","ip":"10.0.0.1","role":"k8s control plane","reconcile":"auto"},
 {"name":"cp-02","ip":"10.0.0.2","role":"k8s control plane (ADR-133)","reconcile":"auto"},
 {"name":"cp-03","ip":"10.0.0.3","role":"k8s worker","controlplane":true,"reconcile":"auto"},
 {"name":"wk-01","ip":"10.0.0.11","role":"k8s worker","reconcile":"auto"},
 {"name":"wk-02","ip":"10.0.0.12","role":"k8s worker","reconcile":"auto"}]}
EOF

# FAKE kubectl. Knobs: FAKE_KUBE=down (every API call refused), FAKE_NOTREADY=<node>, FAKE_BGP=partial|none,
# FAKE_BACKEND=missing (one agent lacks 10.96.0.1:443), FAKE_APP=degraded, FAKE_PODS=bad.
cat >"$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
a="$*"
case "$a" in *"config view"*) echo "https://10.0.0.50:6443"; exit 0 ;; esac
[ "${FAKE_KUBE:-up}" = down ] && { echo "dial tcp 10.0.0.50:6443: connect: connection refused" >&2; exit 1; }
case "$a" in
  *"get --raw /readyz"*) echo ok ;;
  *"get nodes -o json"*)
    jq -nc --arg bad "${FAKE_NOTREADY:-}" '{items: [("cp-01","cp-02","cp-03","wk-01","wk-02") as $n
      | {metadata:{name:$n}, status:{conditions:[{type:"Ready", status:(if $n == $bad then "False" else "True" end)}]}}]}' ;;
  *"get pods -A --no-headers"*)
    echo "kube-system cilium-a 1/1 Running 0 1d"
    [ "${FAKE_PODS:-}" = bad ] && echo "cnpg-system pg-backup-1 0/1 Error 0 2d"; : ;;
  *"get pod -l k8s-app=cilium -o name"*) printf 'pod/cilium-a\npod/cilium-b\n' ;;
  *"get pod -l k8s-app=cilium -o jsonpath"*) printf 'cilium-a\twk-01\ncilium-b\twk-02\n' ;;
  *"exec"*"cilium-dbg service list"*)
    if [ "${FAKE_BACKEND:-}" = missing ] && [[ "$a" == *cilium-b* ]]; then echo "1 10.96.0.1:443/TCP ClusterIP"
    else echo "1 10.96.0.1:443/TCP ClusterIP 1 => 10.0.0.1:6443/TCP (active)"; fi ;;
  *"exec"*"bgp peers -o json"*)
    s1=established; s2=established
    [ "${FAKE_BGP:-}" = partial ] && [[ "$a" == *cilium-b* ]] && s2=active
    [ "${FAKE_BGP:-}" = none ] && { s1=active; s2=idle; }
    jq -nc --arg a "$s1" --arg b "$s2" '[{"peer-address":"10.0.0.70","session-state":$a},{"peer-address":"10.0.0.71","session-state":$b}]' ;;
  *"get svc -A -l bgp=advertise -o json"*)
    jq -nc '{items:[
      {metadata:{namespace:"monitoring",name:"prom"},spec:{type:"LoadBalancer",ports:[{port:9090,protocol:"TCP"}]},status:{loadBalancer:{ingress:[{ip:"10.40.0.13"}]}}},
      {metadata:{namespace:"unifi",name:"unifi"},spec:{type:"LoadBalancer",ports:[{port:3478,protocol:"UDP"},{port:8443,protocol:"TCP"}]},status:{loadBalancer:{ingress:[{ip:"10.40.0.12"}]}}},
      {metadata:{namespace:"x",name:"udp-only"},spec:{type:"LoadBalancer",ports:[{port:53,protocol:"UDP"}]},status:{loadBalancer:{ingress:[{ip:"10.40.0.99"}]}}}]}' ;;
  *"get applications.argoproj.io -A -o json"*)
    jq -nc --arg d "${FAKE_APP:-}" '{items:[{metadata:{name:"cilium"},status:{health:{status:"Healthy"}}},
      {metadata:{name:"stack"},status:{health:{status:(if $d == "degraded" then "Degraded" else "Progressing" end)}}}]}' ;;
  *) echo "fake kubectl: unhandled: $a" >&2; exit 1 ;;
esac
EOF
# FAKE talosctl: FAKE_TALOS_DOWN = space-separated IPs that do not answer.
cat >"$T/bin/talosctl" <<'EOF'
#!/usr/bin/env bash
ip=""; while [ $# -gt 0 ]; do [ "$1" = -n ] && ip="$2"; shift; done
echo "Client:"; echo "Talos v1.14.1"; echo "Server:"
case " ${FAKE_TALOS_DOWN:-} " in *" $ip "*) echo "error getting version from node $ip: connect: no route to host" >&2; exit 1 ;; esac
printf '\tNODE:        %s\n\tTag:         v1.14.1\n' "$ip"
EOF
# FAKE curl: /-/ready answers 200 unless FAKE_PROM=down (connect refused: 000, exit 7); a VIP connect
# exits 0 unless FAKE_VIPS=down|one (7 = connection refused, the "unreachable" exit).
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  */-/ready)
    if [ "${FAKE_PROM:-up}" = down ]; then printf '000'; exit 7; fi; printf '200'; exit 0 ;;
  http://10.40.0.*)
    [ "${FAKE_VIPS:-}" = down ] && exit 7
    [ "${FAKE_VIPS:-}" = one ] && [[ "$url" == *10.40.0.12* ]] && exit 28
    exit 0 ;;
esac
exit 7
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" KUBECONFIG="$T/kubeconfig" TALOSCONFIG="$T/talosconfig"
export VERDICT_MACHINES_JSON="$T/machines.json" VERDICT_STATE_DIR="$T/state" VERDICT_TIMEOUT=2

run() { OUT="$(bash "$SUT" "$@" 2>"$T/err")"; RC=$?; }
st() { jq -r --arg c "$1" '.checks[] | select(.check == $c) | "\(.status) \(.reason)"' <<<"$OUT"; }
expect() {  # <name> <got> <want>
  n=$((n+1))
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$3', got '$2'"; fails=$((fails+1)); fi
}

# 1. Healthy: every read ok, pods info → ok, exit 0. The UDP-only Service has no TCP port: not probed.
run
expect healthy-verdict "$(jq -r .verdict <<<"$OUT") $RC" "ok 0"
expect healthy-talos-nonTalos-skipped "$(jq -r '.checks[] | select(.check=="talos") | .detail' <<<"$OUT")" "5/5 nodes answer the Talos API (v1.14.1×5)"
expect healthy-vips-tcp-only "$(jq -r '.checks[] | select(.check=="vips") | .detail' <<<"$OUT")" "2/2 BGP VIPs answer from the LAN (list: kube)"
expect healthy-pods-info "$(st pods)" "info ok"
expect healthy-vip-cache-written "$(jq -r 'length' "$T/state/vips.json")" "2"

# 2. THE POINT: Prometheus and Alertmanager unreachable → degraded (never down), and every direct
#    read still answers for itself.
FAKE_PROM=down run
expect prom-down-verdict "$(jq -r .verdict <<<"$OUT") $RC" "degraded 2"
expect prom-down-prom "$(st prometheus)" "degraded unreachable"
expect prom-down-am "$(st alertmanager)" "degraded unreachable"
expect prom-down-direct-reads "$(jq -r '[.checks[] | select(.check != "prometheus" and .check != "alertmanager" and .check != "pods") | .status] | unique | join(",")' <<<"$OUT")" "ok"
expect prom-down-reasons "$(jq -r '.reasons | length' <<<"$OUT")" "2"
# the same through the CLI flag the live proof uses
run --prom http://127.0.0.1:1
expect prom-flag-source "$(jq -r .sources.prometheus <<<"$OUT")" "http://127.0.0.1:1"

# 3. The kube API down → down. Talos still read directly; the kube-dependent reads skip (counted once);
#    the VIP list comes from the cache case 1 wrote.
FAKE_KUBE=down run
expect kube-down-verdict "$(jq -r .verdict <<<"$OUT") $RC" "down 3"
expect kube-down-kube "$(st kube-api)" "down unreachable"
expect kube-down-talos-direct "$(st talos)" "ok ok"
expect kube-down-nodes-skip "$(st nodes)" "skip kube-api-down"
expect kube-down-bgp-skip "$(st bgp)" "skip kube-api-down"
expect kube-down-vips-cache "$(st vips) $(jq -r '.checks[] | select(.check=="vips") | .detail | test("list: cache")' <<<"$OUT")" "ok ok true"
rm -f "$T/state/vips.json"
FAKE_KUBE=down run
expect kube-down-no-cache "$(st vips)" "unreadable unreadable"

# 4. Talos: one worker silent → degraded; two of three control planes silent (1*2 ≤ 3) → down;
#    one of three silent (2*2 > 3) is still only degraded.
FAKE_TALOS_DOWN="10.0.0.12" run
expect talos-worker "$(st talos) $RC" "degraded unreachable 2"
FAKE_TALOS_DOWN="10.0.0.1 10.0.0.3" run
expect talos-quorum "$(st talos) $RC" "down quorum-lost 3"
FAKE_TALOS_DOWN="10.0.0.2" run
expect talos-one-cp "$(st talos)" "degraded unreachable"

# 5. Nodes, cilium backend (probe 3), Argo health → each degraded.
FAKE_NOTREADY=wk-02 run
expect node-notready "$(st nodes) $RC" "degraded notready 2"
FAKE_BACKEND=missing run
expect cilium-backend-missing "$(st cilium-backend)" "degraded missing-backend"
FAKE_APP=degraded run
expect argocd-degraded "$(st argocd) $(jq -r '.checks[] | select(.check=="argocd") | .items[0]' <<<"$OUT")" "degraded unhealthy stack (Degraded)"

# 6. BGP: one session down → degraded; none established anywhere → down.
FAKE_BGP=partial run
expect bgp-partial "$(st bgp) $(jq -r '.checks[] | select(.check=="bgp") | .items[0]' <<<"$OUT")" "degraded peer-down wk-02→10.0.0.71 (active)"
FAKE_BGP=none run
expect bgp-none "$(st bgp) $RC" "down no-session 3"

# 7. VIPs: one silent → degraded; all silent → down.
FAKE_VIPS=one run
expect vips-one "$(st vips)" "degraded unreachable"
FAKE_VIPS=down run
expect vips-all "$(st vips) $RC" "down unreachable 3"

# 8. Pods hard-failed: reported, never judged.
FAKE_PODS=bad run
expect pods-not-judged "$(jq -r .verdict <<<"$OUT") $(st pods)" "ok info hard-failed"

# 9. --skip is reported as itself; text format; no kubeconfig = the verdict could not run (1).
run --skip "vips argocd"
expect skip-requested "$(st vips) $(st argocd) $(jq -r .verdict <<<"$OUT")" "skip requested skip requested ok"
run --format text
expect text-format "$(head -1 <<<"$OUT" | cut -d' ' -f1-3)" "box verdict: OK"
KUBECONFIG="$T/nope" run
expect no-kubeconfig "$RC" "1"
run --bogus
expect usage "$RC" "64"

echo "mgmt-verdict-test: $((n - fails))/$n passed"
[ "$fails" -eq 0 ]
