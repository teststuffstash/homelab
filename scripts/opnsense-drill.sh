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
fail() { FAILED="${FAILED:+$FAILED }$STAGE"; STAGE_OK[$STAGE]=0; rep "- **FAIL** ($STAGE): $*"; log "FAIL ($STAGE): $*"; }
pool_pct() { pve "lvs --noheadings -o data_percent nvme-thin/data" | tr -d ' '; }
bootstrap() { bash "$ROOT/scripts/opnsense-test-vm-bootstrap.sh" "$@"; }

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
    for s in preflight build converge probe compare destroy; do
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
    echo "- stages: $(for s in preflight build converge compare destroy; do [ -n "${STAGE_S[$s]:-}" ] && printf '%s %ss · ' "$s" "${STAGE_S[$s]}"; done)"
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
if pve "qm config $VMID" >/dev/null 2>&1; then
  log "vmid $VMID exists (a crashed run?) — destroying it by name first"
  bootstrap destroy >&2
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
