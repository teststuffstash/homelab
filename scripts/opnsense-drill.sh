#!/usr/bin/env bash
# The OPNsense REBUILD DRILL (FU-297): build a router from nothing, converge ALL router code,
# score its config.xml against prod's, destroy it. docs/opnsense-test-vm.md §The rebuild drill.
#
#   bash scripts/opnsense-drill.sh [--ref <rev>] [--keep]     # jail: wallet creds; box: env file
#
# Stages (each timed; the report + metrics say which one failed):
#   preflight  nx-02 thin pool + free memory read, BEFORE anything writes (a stale drill VM from a
#              crashed run is destroyed first — by name, never anything else)
#   build      scripts/opnsense-test-vm-bootstrap.sh create + bootstrap: the tofu-shaped VM by qm,
#              first boot through the config importer, firmware to prod's series, the three
#              config plugins, snapshot `baseline` — with a THROWAWAY root password + API pair
#              minted here, in memory, dying with the VM
#   converge   scripts/opnsense-test-vm.sh --ref <rev> --steps "1 all": every ansible/opnsense-*
#              play + opnsense/dnsmasq-dhcp.py + opnsense/tuya-egress.py, at <rev>, through the
#              harness's guard/inventory/overrides (+ ansible/test-vm/drill-overrides.yml)
#   probe      BEHAVIOUR, from a throwaway Debian LXC on the drill's LAN (made after the build, so
#              its packages come through the fresh router's NAT before any router code runs):
#              DHCP leases (a reserved MAC → its pinned address, a random MAC → the pool), a
#              DNS override answering, HAProxy answering TLS on a VIP, and a REAL BGP session
#              from a fake ASN-64513 peer (FRR) whose /32 the router must learn
#   compare    GET both config.xml (prod: GET /api/core/backup/download/this — the ONLY call this
#              script makes to 192.168.2.1), opnsense/drill/config-compare.py → the realism score
#   destroy    always (trap), unless --keep; the pool must return to its preflight reading
#
# SECRETS: prod's config.xml holds private keys and hashes. Both documents live in a 0700 dir
# under the workdir, mode 0600, and are deleted when compare returns; nothing prints a value.
# Prod creds: OPN_API_KEY/OPN_API_SECRET if set (the box's env file), else the wallet
# (opnsense-api-key/-secret). They are read into a curl config and UNSET before anything else
# runs, so no play or script below can inherit them.
#
# Environment: OPN_DRILL_VMID (9199), OPN_DRILL_HOST (192.168.2.68 — machines.yaml),
# OPN_DRILL_LAN_BRIDGE (vmbr2), OPN_TEST_PVE (192.168.2.59), OPN_TEST_PVE_KEY (the pve seed key),
# OPN_DRILL_WORKDIR (mktemp), OPN_DRILL_POOL_MAX (70 — refuse above this nvme-thin data %),
# OPN_DRILL_MEM_MIN_MB (4096 — refuse below this MemAvailable on nx-02),
# OPN_DRILL_TEXTFILE (unset — the box sets its node_exporter textfile: mgmt_opnsense_drill_*),
# OPN_DRILL_STATE (unset — the box keeps the previous run's score there, for "score regressed").
# Exit: 0 drill passed, 1 a stage failed (report says which), 2 refused / environment.
set -euo pipefail

REF=HEAD; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) sed -n '2,30p' "$0" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
ROOT="$PWD"
export NIX_CONFIG="experimental-features = nix-command flakes"
eval "$(devbox shellenv)"   # python3/yq/jq/ssh from the pinned toolchain — the box has no bare python
T0=$(date +%s)
VMID="${OPN_DRILL_VMID:-9199}"
VMNAME=opnsense-drill
HOST="${OPN_DRILL_HOST:-192.168.2.68}"
LAN_BRIDGE="${OPN_DRILL_LAN_BRIDGE:-vmbr2}"
PVE="${OPN_TEST_PVE:-192.168.2.59}"
PVE_KEY="${OPN_TEST_PVE_KEY:-$HOME/.claude/homelab-pve-ssh/id_ed25519}"
POOL_MAX="${OPN_DRILL_POOL_MAX:-70}"
MEM_MIN_MB="${OPN_DRILL_MEM_MIN_MB:-4096}"
PROD=192.168.2.1

log() { printf '[opnsense-drill] %s\n' "$*" >&2; }
die() { log "REFUSED: $*"; exit 2; }
pve() { ssh -i "$PVE_KEY" -o BatchMode=yes -o ConnectTimeout=10 "root@$PVE" "$@"; }

[ "$VMID" != 9110 ] || die "vmid 9110 is the PR-validation VM"
[ "$HOST" != "$PROD" ] && [ "$HOST" != 192.168.2.67 ] || die "OPN_DRILL_HOST=$HOST is not the drill's address"

SHA="$(git rev-parse --verify "$REF^{commit}")"
WORK="${OPN_DRILL_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/opnsense-drill.XXXXXX")}"
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
SEC="$WORK/secret"; ( umask 077; mkdir -p "$SEC" ); chmod 700 "$SEC"
REPORT="$WORK/report.md"; : > "$REPORT"
rep() { printf '%s\n' "$*" >> "$REPORT"; }

# ---- prod creds → a 0600 curl config, then out of the environment ----------------------------
_pk="${OPN_API_KEY:-}"; _ps="${OPN_API_SECRET:-}"
if [ -z "$_pk" ] || [ -z "$_ps" ]; then
  _kp() { DEVBOX_QUIET=1 devbox run --quiet -- keepassxc-cli show -q --no-password \
            -k "$HOME/.claude/homelab-keepass/homelab.keyx" -a Password "$HOME/.claude/homelab-keepass/homelab.kdbx" "$1" 2>/dev/null; }
  _pk="$(_kp opnsense-api-key || true)"; _ps="$(_kp opnsense-api-secret || true)"
fi
[ -n "$_pk" ] && [ -n "$_ps" ] || die "no prod API pair (OPN_API_KEY/SECRET or the wallet) — the compare stage needs it"
( umask 077; printf 'user = "%s:%s"\n' "$_pk" "$_ps" > "$SEC/prod.curl" )
unset _pk _ps OPN_API_KEY OPN_API_SECRET ACME_CF_TOKEN

# ---- a throwaway credential set for the drill VM (never stored; dies with the VM) -------------
OPN_TEST_ROOT_PASSWORD="$(openssl rand -base64 24)"
OPN_TEST_API_KEY="$(openssl rand -base64 60 | tr -d '\n')"
OPN_TEST_API_SECRET="$(openssl rand -base64 60 | tr -d '\n')"
export OPN_TEST_ROOT_PASSWORD OPN_TEST_API_KEY OPN_TEST_API_SECRET
( umask 077; printf 'user = "%s:%s"\n' "$OPN_TEST_API_KEY" "$OPN_TEST_API_SECRET" > "$SEC/drill.curl" )
export OPN_TEST_VMID="$VMID" OPN_TEST_HOST="$HOST" OPN_TEST_VM_NAME="$VMNAME" \
       OPN_TEST_LAN_BRIDGE="$LAN_BRIDGE" OPN_TEST_PVE="$PVE" OPN_TEST_PVE_KEY="$PVE_KEY" \
       OPN_TEST_SNAPSHOT=baseline

# ---- stage bookkeeping -------------------------------------------------------------------------
declare -A STAGE_S STAGE_OK
STAGE=''; STAGE_T=0; FAILED=''
stage() { # stage <name> — closes the previous one
  local now; now=$(date +%s)
  [ -z "$STAGE" ] || STAGE_S[$STAGE]=$((now - STAGE_T))
  STAGE="$1"; STAGE_T=$now; log "stage: $1"
}
fail() { case " $FAILED " in *" $STAGE "*) ;; *) FAILED="${FAILED:+$FAILED }$STAGE" ;; esac; STAGE_OK[$STAGE]=0; rep "- **FAIL** ($STAGE): $*"; log "FAIL ($STAGE): $*"; }
pool_pct() { pve "lvs --noheadings -o data_percent nvme-thin/data" | tr -d ' '; }
bootstrap() { bash "$ROOT/scripts/opnsense-test-vm-bootstrap.sh" "$@"; }
CTID=$((VMID - 1)); CTNAME=opnsense-drill-probe
PEER_ROUTE=192.168.40.254/32      # the fake node's "LoadBalancer" route; exists only inside the drill
# A value out of opnsense/dnsmasq-dhcp.py's data (HOSTS / RANGE), remapped onto the drill's LAN
# prefix exactly as the converge applied it: `dhcp_data "HOSTS[0]['ip']"` (a python subscript of
# the module's globals).
dhcp_data() {
  OPN_API_KEY=x OPN_API_SECRET=x OPN_HOST="$HOST" OPN_DHCP_REMAP="192.168.2.=192.168.1." python3 -c \
    "import runpy; g = runpy.run_path('$ROOT/opnsense/dnsmasq-dhcp.py', run_name='drill'); print(eval(\"$1\", {}, g))"
}
vm_ssh() { ssh -i "$PVE_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$HOST" "$@"; }
# ================================================================ probe container ===============
# A Debian 12 LXC on the drill's LAN (template: tofu/opnsense-test.tf), made and destroyed per
# run. eth0 = 192.168.1.2 static — the fake cluster node (ansible/test-vm/drill-overrides.yml's
# BGP neighbour); eth1 carries a reserved MAC from opnsense/dnsmasq-dhcp.py (expects its pinned
# address), eth2 a random one (expects a pool address). Packages come through the drill VM's own
# NAT BEFORE the router code runs, so a converge that breaks egress cannot fail the setup.
probe_ct() { pve "pct exec $CTID -- $*"; }
probe_create() {
  local res_mac tmpl=local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst
  res_mac="$(dhcp_data "HOSTS[0]['hwaddr']")"
  pve "pct create $CTID $tmpl --hostname $CTNAME --tags 'opnsense;drill' --cores 1 --memory 512 --swap 0 \
        --rootfs nvme-thin:2 --unprivileged 1 --features nesting=1 --onboot 0 \
        --net0 name=eth0,bridge=$LAN_BRIDGE,ip=192.168.1.2/24,gw=192.168.1.1 \
        --net1 name=eth1,bridge=$LAN_BRIDGE,ip=manual,hwaddr=$res_mac \
        --net2 name=eth2,bridge=$LAN_BRIDGE,ip=manual \
        --nameserver 192.168.1.1 --start 1 >/dev/null"
  probe_ct "bash -c 'for i in \$(seq 1 30); do getent hosts deb.debian.org >/dev/null && break; sleep 2; done'"
  probe_ct "env LC_ALL=C.UTF-8 LANG=C.UTF-8 bash -c 'DEBIAN_FRONTEND=noninteractive apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends frr isc-dhcp-client dnsutils curl openssl ca-certificates >/dev/null'"
  # The fake peer: cluster ASN, the router as its neighbour, one LB-shaped /32 announced.
  # `no bgp network import-check`: announce without a RIB route; `no bgp ebgp-requires-policy`:
  # the peer side needs no route-map (the ROUTER's side keeps prod's CILIUM-ALLOW-ALL).
  pve "pct exec $CTID -- bash -c 'sed -i s/^bgpd=no/bgpd=yes/ /etc/frr/daemons && cat > /etc/frr/frr.conf'" <<FRR
frr defaults traditional
hostname $CTNAME
router bgp 64513
 bgp router-id 192.168.1.2
 no bgp ebgp-requires-policy
 no bgp network import-check
 neighbor 192.168.1.1 remote-as 64512
 address-family ipv4 unicast
  network $PEER_ROUTE
 exit-address-family
FRR
  probe_ct "systemctl restart frr"
}
probe_destroy() {
  local h
  h="$(pve "if pct config $CTID >/dev/null 2>&1; then pct config $CTID | sed -n 's/^hostname: //p'; fi")"
  [ -n "$h" ] || return 0
  [ "$h" = "$CTNAME" ] || { log "REFUSING to destroy ct $CTID: hostname '$h'"; return 1; }
  pve "pct stop $CTID >/dev/null 2>&1 || true; pct destroy $CTID --purge 1"
}

POOL_BEFORE=''; POOL_AFTER=''; SCORE=''
TEXTFILE="${OPN_DRILL_TEXTFILE:-}"; STATE="${OPN_DRILL_STATE:-}"

# The metrics (the box's textfile; argocd/resources/mgmt-metrics/opnsense-drill.yaml reads them).
# Written atomically on EVERY finished run, pass or fail; a preflight refusal writes nothing (the
# stale belt then speaks). The previous run's score comes from $STATE, so "regressed" compares
# run to run.
emit_metrics() {
  local ok="$1" P=mgmt_opnsense_drill prev='' s tmp
  [ -n "$TEXTFILE" ] || return 0
  if [ -n "$STATE" ]; then
    mkdir -p "$STATE"
    [ -f "$STATE/last-score" ] && prev="$(cat "$STATE/last-score")"
    [ -z "$SCORE" ] || printf '%s' "$SCORE" > "$STATE/last-score"
  fi
  tmp="$TEXTFILE.$$"
  {
    echo "# HELP ${P}_success 1 if the last drill passed every stage (FU-297)."
    echo "# TYPE ${P}_success gauge"; echo "${P}_success $ok"
    echo "# TYPE ${P}_last_run_timestamp_seconds gauge"; echo "${P}_last_run_timestamp_seconds $(date +%s)"
    echo "# TYPE ${P}_duration_seconds gauge"; echo "${P}_duration_seconds $DURATION"
    echo "# TYPE ${P}_stage_seconds gauge"
    for s in "${!STAGE_S[@]}"; do echo "${P}_stage_seconds{stage=\"$s\"} ${STAGE_S[$s]}"; done
    echo "# TYPE ${P}_stage_failed gauge"
    for s in preflight build probe-setup converge probe compare destroy; do
      case " $FAILED " in *" $s "*) echo "${P}_stage_failed{stage=\"$s\"} 1" ;; *) echo "${P}_stage_failed{stage=\"$s\"} 0" ;; esac
    done
    for s in "${!PROBE_OK[@]}"; do echo "${P}_probe_success{probe=\"$s\"} ${PROBE_OK[$s]}"; done
    if [ -n "$SCORE" ]; then
      grep -v '^#' "$WORK/compare.prom" 2>/dev/null || true
      [ -z "$prev" ] || echo "${P}_realism_score_previous $prev"
    fi
  } > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$TEXTFILE"
}
declare -A PROBE_OK
finish() {
  local rc=$? now; now=$(date +%s)
  [ -z "$STAGE" ] || STAGE_S[$STAGE]=$((now - STAGE_T))
  rm -f "$SEC"/*.xml
  if [ "$KEEP" -eq 0 ]; then
    STAGE=destroy; STAGE_T=$(date +%s); log "stage: destroy"
    probe_destroy >&2 || fail "destroy of probe container $CTID failed — clean up by hand (pct destroy $CTID)"
    bootstrap destroy >&2 || fail "destroy of vm $VMID failed — clean up by hand (qm destroy $VMID)"
    POOL_AFTER="$(pool_pct 2>/dev/null || echo '?')"
    STAGE_S[destroy]=$(( $(date +%s) - STAGE_T ))
  else
    log "--keep: vm $VMID left running at $HOST; its throwaway API pair: $SEC/drill.curl (0600)"
  fi
  rm -f "$SEC/prod.curl"; [ "$KEEP" -eq 1 ] || rm -rf "$SEC"
  DURATION=$(( $(date +%s) - T0 ))
  if [ -n "$POOL_AFTER" ] && [ "$POOL_AFTER" != '?' ] \
     && awk -v a="$POOL_AFTER" -v b="$POOL_BEFORE" 'BEGIN { exit !(a - b > 1.0) }'; then
    rep "- ⚠ nvme-thin rose ${POOL_BEFORE}% → ${POOL_AFTER}% across the run (> 1 point; the other VMs on nx-02 write too — check the pool)"
  fi
  emit_metrics "$([ -z "$FAILED" ] && [ "$rc" -eq 0 ] && echo 1 || echo 0)"
  {
    echo "## OPNsense rebuild drill (FU-297) — $(date -u +%FT%TZ)"
    echo
    echo "- rev \`$SHA\`, vm $VMID on $PVE, WAN $HOST, LAN $LAN_BRIDGE; duration **${DURATION}s**"
    echo "- stages: $(for s in preflight build probe-setup converge probe compare destroy; do [ -n "${STAGE_S[$s]:-}" ] && printf '%s %ss · ' "$s" "${STAGE_S[$s]}"; done)"
    echo "- nvme-thin data%: before $POOL_BEFORE → after ${POOL_AFTER:-kept}"
    echo "- verdict: **$([ -z "$FAILED" ] && [ "$rc" -eq 0 ] && echo PASS || echo "FAIL (${FAILED:-exit $rc})")**"
    echo
    cat "$REPORT"
  } > "$WORK/drill.md"
  cat "$WORK/drill.md"
  [ -z "$FAILED" ] && [ "$rc" -eq 0 ] || exit 1
}
trap finish EXIT

# ================================================================ preflight =====================
stage preflight
POOL_BEFORE="$(pool_pct)"
mem_mb="$(pve "awk '/MemAvailable/ {print int(\$2/1024)}' /proc/meminfo")"
log "nx-02: nvme-thin data ${POOL_BEFORE}%, MemAvailable ${mem_mb} MiB"
awk -v p="$POOL_BEFORE" -v m="$POOL_MAX" 'BEGIN { exit !(p + 0 < m + 0) }' \
  || { trap - EXIT; rm -rf "$SEC"; die "nvme-thin at ${POOL_BEFORE}% ≥ ${POOL_MAX}% — not writing a VM into it"; }
[ "$mem_mb" -ge "$MEM_MIN_MB" ] \
  || { trap - EXIT; rm -rf "$SEC"; die "nx-02 MemAvailable ${mem_mb} MiB < ${MEM_MIN_MB} (FU-289's NUMA pressure)"; }
if pve "qm config $VMID" >/dev/null 2>&1 || pve "pct config $CTID" >/dev/null 2>&1; then
  log "vm $VMID / ct $CTID exists (a crashed run?) — destroying by name first"
  bootstrap destroy >&2; probe_destroy >&2
  POOL_BEFORE="$(pool_pct)"
fi

# ================================================================ build =========================
stage build
if bootstrap create >&2 && bootstrap bootstrap > "$WORK/bootstrap.log" 2>&1; then
  rep "- build: $(grep -E '^(version|plugin):' "$WORK/bootstrap.log" | tr '\n' ' ')"
else
  tail -30 "$WORK/bootstrap.log" >&2 || true
  fail "the VM did not build (bootstrap log tail above)"; exit 1
fi

# ================================================================ probe setup ===================
stage probe-setup
probe_create > "$WORK/probe-setup.log" 2>&1 || { tail -20 "$WORK/probe-setup.log" >&2; fail "the probe container did not come up"; exit 1; }
rep "- probe container $CTID on $LAN_BRIDGE: $(probe_ct "sh -c '. /etc/os-release; echo \$PRETTY_NAME, frr \$(dpkg-query -W frr | cut -f2)'" | tr '\n' ' ')"

# ================================================================ converge ======================
stage converge
set +e
OPN_TEST_WORKDIR="$WORK/harness" OPN_TEST_EXTRA_VARS="$ROOT/ansible/test-vm/drill-overrides.yml" \
OPN_DHCP_REMAP="192.168.2.=192.168.1." \
  bash "$ROOT/scripts/opnsense-test-vm.sh" --ref "$SHA" --steps "1 all" > "$WORK/converge.log" 2>&1
hrc=$?
set -e
if [ "$hrc" -eq 0 ]; then rep "- converge: every router-code unit applied (harness PASS)"
else
  fail "harness rc=$hrc — $(grep -E '^FAIL' "$WORK/converge.log" | head -5 | tr '\n' ';')"
  [ "$hrc" -eq 1 ] || exit 1      # 2 = guard/environment: nothing converged, nothing to score
fi
sed -n '/^### all\./,/^### /p' "$WORK/harness/report.md" 2>/dev/null | sed '$d' >> "$REPORT" || true

# ================================================================ probe =========================
# Behaviour, not saved config. Expected values are read from the code under test (the
# reservation in dnsmasq-dhcp.py, the first unbound_hosts / haproxy_proxied_services entries in
# group_vars), never restated here. A failing probe fails the drill; each has its own metric.
stage probe
GV="$ROOT/ansible/group_vars/opnsense.yml"
probe() { # probe <name> <ok 0|1> <detail>
  PROBE_OK[$1]=$2
  rep "| \`$1\` | $([ "$2" = 1 ] && echo pass || echo **FAIL**) | $3 |"
  [ "$2" = 1 ] || fail "probe $1: $3"
}
rep ''; rep '### Behaviour probes (from the LAN side)'; rep ''; rep '| probe | result | evidence |'; rep '|---|---|---|'
lease() { # lease <iface> → the address the router's DHCP bound it to (-sf /bin/true: configure nothing)
  pve "pct exec $CTID -- sh -s $1" <<'SH' | tail -1
i=$1; rm -f /tmp/$i.lease
timeout 60 dhclient -1 -v -sf /bin/true -lf /tmp/$i.lease -pf /tmp/$i.pid $i 2>&1 | sed -n 's/^bound to \([0-9.]*\).*/\1/p'
dhclient -x -pf /tmp/$i.pid $i >/dev/null 2>&1 || true
SH
}
want="$(dhcp_data "HOSTS[0]['ip']")"; got="$(lease eth1 || true)"
probe dhcp_reservation "$([ -n "$got" ] && [ "$got" = "$want" ] && echo 1 || echo 0)" "reserved MAC → \`${got:-no lease}\` (want \`$want\`, dnsmasq-dhcp.py HOSTS[0] remapped)"
got="$(lease eth2 || true)"
lo="$(dhcp_data "RANGE['start_addr']")"; hi="$(dhcp_data "RANGE['end_addr']")"
inpool="$(python3 -c "import ipaddress as i, sys; a = sys.argv[1:]; print(int(bool(a[0]) and i.ip_address(a[1]) <= i.ip_address(a[0]) <= i.ip_address(a[2])))" "${got:-}" "$lo" "$hi" 2>/dev/null || echo 0)"
probe dhcp_pool "$inpool" "random MAC → \`${got:-no lease}\` (want $lo–$hi, dnsmasq-dhcp.py RANGE remapped)"
dn="$(yq -r '.unbound_hosts[0] | .hostname + "." + .domain' "$GV")"; dv="$(yq -r '.unbound_hosts[0].value' "$GV")"
got="$(probe_ct "dig +short +time=3 +tries=2 @192.168.1.1 $dn A" | tail -1 || true)"
probe dns_override "$([ "$got" = "$dv" ] && echo 1 || echo 0)" "\`$dn\` → \`${got:-no answer}\` (want \`$dv\`, unbound_hosts[0])"
hv="$(yq -r '.haproxy_proxied_services[0].vip' "$GV")"; hn="$(yq -r '.haproxy_proxied_services[0].cert_domain' "$GV")"
got="$(probe_ct "sh -c 'echo | timeout 15 openssl s_client -connect $hv:443 -servername $hn 2>/dev/null | grep -E \"^ *(Protocol|New, )\" | head -1'" || true)"
probe haproxy_tls "$([ -n "$got" ] && echo 1 || echo 0)" "TLS handshake on VIP \`$hv:443\` (SNI \`$hn\`): \`$(echo "${got:-none}" | tr -s ' ' | cut -c1-60)\`"
# BGP: the session from the PEER's side, and the route in the ROUTER's kernel table (what FRR
# installs is what the LAN would forward by). Poll: the router's FRR reloads late in the converge.
st=''; rt=''
for i in $(seq 1 36); do
  st="$(probe_ct "vtysh -c 'show bgp neighbors 192.168.1.1 json'" 2>/dev/null | jq -r '.["192.168.1.1"].bgpState // empty' 2>/dev/null || true)"
  rt="$(vm_ssh "route -n get ${PEER_ROUTE%/32} 2>/dev/null | awk '/gateway:/ {print \$2}'" 2>/dev/null || true)"
  [ "$st" = Established ] && [ "$rt" = 192.168.1.2 ] && break
  sleep 5
done
bgpd="$(vm_ssh 'pgrep -x bgpd >/dev/null && echo running || echo "NOT running (FU-298)"' 2>/dev/null || echo '?')"
probe bgp_session "$([ "$st" = Established ] && echo 1 || echo 0)" "fake peer AS64513 @192.168.1.2 ↔ router AS64512: \`${st:-no state}\` (router bgpd: $bgpd)"
probe bgp_route "$([ "$rt" = 192.168.1.2 ] && echo 1 || echo 0)" "router kernel route \`$PEER_ROUTE\` → \`${rt:-none}\` (want the peer, 192.168.1.2)"

# ================================================================ compare =======================
stage compare
bash "$ROOT/opnsense/drill/config-compare-test.sh" > "$WORK/compare-test.log" 2>&1 \
  || { cat "$WORK/compare-test.log" >&2; fail "the scorer's self-test failed — not scoring with it"; exit 1; }
curl -sfk -K "$SEC/drill.curl" --max-time 60 -o "$SEC/drill.xml" "https://$HOST/api/core/backup/download/this" \
  || { fail "could not download the drill VM's config.xml"; exit 1; }
curl -sfk -K "$SEC/prod.curl" --max-time 60 -o "$SEC/prod.xml" "https://$PROD/api/core/backup/download/this" \
  || { fail "could not GET prod's config.xml"; exit 1; }
chmod 600 "$SEC"/*.xml
python3 "$ROOT/opnsense/drill/config-compare.py" "$SEC/prod.xml" "$SEC/drill.xml" \
  --report "$WORK/compare.md" --prom "$WORK/compare.prom" --json "$WORK/compare.json" \
  --detail "$SEC/detail.tsv" || { fail "config-compare failed"; exit 1; }
rm -f "$SEC"/*.xml
SCORE="$(jq -r .score "$WORK/compare.json")"
rep ''; rep '### Realism: prod config.xml vs the from-git build'; rep ''; cat "$WORK/compare.md" >> "$REPORT"
if [ "$KEEP" -eq 1 ]; then  # the keyed detail (paths + item names, no values) outlives the run only on request
  install -m 600 "$SEC/detail.tsv" "$WORK/detail.tsv"; log "keyed detail (no values): $WORK/detail.tsv"
fi
