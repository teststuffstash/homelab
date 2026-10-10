#!/usr/bin/env bash
# mgmt-helm-test — fixture test of the box's helm bracket (mgmt/scripts/mgmt-helm.sh, FU-301):
# the preflight reads (declared-vs-live, Longhorn settings + volume health), the engine order, and
# helm_end's one decision — CONFIRM (lease deleted, window closed) vs STOP (lease kept, window kept,
# helm-stopped written, nothing reverted). The cluster seams are stubbed; every expected value below
# is derived in its comment from the inputs and the contract in mgmt-helm.sh's header.
# `devbox run mgmt-policy-test` runs it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export REPO="$HERE/../.."
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"
# shellcheck source=mgmt-helm.sh
. "$HERE/mgmt-helm.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
eq() {  # <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"
  else fail=$((fail+1)); echo "FAIL $1 — want [$2]"; echo "                 got  [$3]"; fi
}

# ── helm_drift: the state file is what the box last APPLIED ───────────────────────────────────────
# state: argocd_apps applied at revision 7, chart argocd-apps 2.0.5, user values {"a":1,"b":{"c":2}}
jq -n '{resources:[{type:"helm_release", name:"argocd_apps", instances:[{attributes:{metadata:{
  revision:7, chart:"argocd-apps", version:"2.0.5", values:"{\"b\":{\"c\":2},\"a\":1}"}}}]}]}' >"$T/state.json"
echo '[{"revision":7,"status":"deployed","chart":"argocd-apps-2.0.5"}]' >"$T/h-ok.json"
echo '{"a":1,"b":{"c":2}}' >"$T/v-ok.json"                       # same values, other key order → same hash
eq drift-none "" "$(helm_drift argocd_apps "$T/state.json" "$T/h-ok.json" "$T/v-ok.json")"
# someone ran `helm upgrade` by hand: revision 8 → one revision line
echo '[{"revision":8,"status":"deployed","chart":"argocd-apps-2.0.5"}]' >"$T/h-rev.json"
eq drift-revision "helm-live-drift	revision live 8 ≠ applied 7" "$(helm_drift argocd_apps "$T/state.json" "$T/h-rev.json" "$T/v-ok.json")"
# a failed upgrade left the release `failed` at the same revision + chart → one status line
echo '[{"revision":7,"status":"failed","chart":"argocd-apps-2.0.5"}]' >"$T/h-failed.json"
eq drift-status "helm-live-drift	status failed (want deployed)" "$(helm_drift argocd_apps "$T/state.json" "$T/h-failed.json" "$T/v-ok.json")"
# a live chart that is not the applied one → one chart line
echo '[{"revision":7,"status":"deployed","chart":"argocd-apps-2.0.6"}]' >"$T/h-chart.json"
eq drift-chart "helm-live-drift	chart live argocd-apps-2.0.6 ≠ applied argocd-apps-2.0.5" "$(helm_drift argocd_apps "$T/state.json" "$T/h-chart.json" "$T/v-ok.json")"
# hand-set values: one values line, hashes only — the value 99 must not appear
echo '{"a":99,"b":{"c":2}}' >"$T/v-hand.json"
got="$(helm_drift argocd_apps "$T/state.json" "$T/h-ok.json" "$T/v-hand.json")"
eq drift-values-rule "helm-live-drift" "$(cut -f1 <<<"$got")"
eq drift-values-no-value "0" "$(grep -c 99 <<<"$got")"
# a release the state does not hold → rc 1 (nothing to compare is never "same")
helm_drift argocd "$T/state.json" "$T/h-ok.json" "$T/v-ok.json" >/dev/null; eq drift-absent-rc 1 "$?"

# ── lh_settings_drift: declared defaultSettings vs the live Settings ──────────────────────────────
# declared: defaultReplicaCount 2, taintToleration "x", systemManagedCSIComponentsResourceLimits "L",
#           orphanResourceAutoDeletion "replica-data"
jq -n '{resources:[{type:"helm_release", name:"longhorn", instances:[{attributes:{metadata:{
  revision:14, chart:"longhorn", version:"1.12.0",
  values:({defaultSettings:{defaultReplicaCount:2, taintToleration:"x", systemManagedCSIComponentsResourceLimits:"L", orphanResourceAutoDeletion:"replica-data"}} | tojson)}}}]}]}' >"$T/lstate.json"
# live: replica count per data engine (both "2" — matches a scalar 2), taint-toleration "x", the CSI
# limits "L" (the acronym's kebab name), orphan-resource-auto-deletion CHANGED by hand to "none"
jq -n '{items:[
  {metadata:{name:"default-replica-count"}, value:"{\"v1\":\"2\",\"v2\":\"2\"}"},
  {metadata:{name:"taint-toleration"}, value:"x"},
  {metadata:{name:"system-managed-csi-components-resource-limits"}, value:"L"},
  {metadata:{name:"orphan-resource-auto-deletion"}, value:"none"}]}' >"$T/ls.json"
eq lh-settings-one-drift "lh-settings-drift	orphan-resource-auto-deletion" "$(lh_settings_drift longhorn "$T/lstate.json" "$T/ls.json")"
# a per-engine value that DIFFERS on one engine is a drift; a declared key with no live Setting is too
jq '.items[0].value = "{\"v1\":\"2\",\"v2\":\"3\"}" | .items[3].value = "replica-data" | del(.items[1])' "$T/ls.json" >"$T/ls2.json"
eq lh-settings-engine-and-absent "lh-settings-drift	default-replica-count
lh-settings-drift	taint-toleration" "$(lh_settings_drift longhorn "$T/lstate.json" "$T/ls2.json" | sort)"

# ── lh_unhealthy ──────────────────────────────────────────────────────────────────────────────────
# a: attached healthy (ok) · b: detached unknown (ok — detached reads unknown) · c: attached degraded
# · d: detached faulted · e: attached unknown (an attached volume must read healthy)
jq -n '{items:[
  {metadata:{name:"a"}, status:{state:"attached", robustness:"healthy"}},
  {metadata:{name:"b"}, status:{state:"detached", robustness:"unknown"}},
  {metadata:{name:"c"}, status:{state:"attached", robustness:"degraded"}},
  {metadata:{name:"d"}, status:{state:"detached", robustness:"faulted"}},
  {metadata:{name:"e"}, status:{state:"attached", robustness:"unknown"}}]}' >"$T/vol.json"
eq lh-unhealthy "lh-volume-unhealthy	c attached/degraded
lh-volume-unhealthy	d detached/faulted
lh-volume-unhealthy	e attached/unknown" "$(lh_unhealthy "$T/vol.json")"

# ── lh_engine_plan: least valuable class first, std last, unknown classes after everything named ───
# order fast,none,bulk,std. Volumes: s1 std, b1 bulk, n1 no selector (= none), f1 fast, x1 "weird"
# (unnamed → rank 999, last), s0 std already on NEW (skipped), v2 a v2-engine volume (skipped).
# Expected: f1 (0), n1 (1), b1 (2), s1 (3), x1 (999).
jq -n '{items:[
  {metadata:{name:"s1"}, spec:{diskSelector:["std"]},  status:{currentImage:"OLD", state:"attached"}},
  {metadata:{name:"b1"}, spec:{diskSelector:["bulk"]}, status:{currentImage:"OLD", state:"attached"}},
  {metadata:{name:"n1"}, spec:{diskSelector:[]},       status:{currentImage:"OLD", state:"detached"}},
  {metadata:{name:"f1"}, spec:{diskSelector:["fast"]}, status:{currentImage:"OLD", state:"attached"}},
  {metadata:{name:"x1"}, spec:{diskSelector:["weird"]},status:{currentImage:"OLD", state:"attached"}},
  {metadata:{name:"s0"}, spec:{diskSelector:["std"]},  status:{currentImage:"NEW", state:"attached"}},
  {metadata:{name:"v2"}, spec:{dataEngine:"v2", diskSelector:["fast"]}, status:{currentImage:"OLD", state:"attached"}}]}' >"$T/ev.json"
eq lh-engine-order "f1 n1 b1 s1 x1" "$(lh_engine_plan "$T/ev.json" NEW fast,none,bulk,std | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
jq -n '{spec:{template:{spec:{containers:[{command:["longhorn-manager","-d","daemon","--engine-image","docker.io/longhornio/longhorn-engine:v1.12.1","--instance-manager-image","im"]}]}}}}' >"$T/ds.json"
eq lh-engine-image "docker.io/longhornio/longhorn-engine:v1.12.1" "$(lh_engine_image "$T/ds.json")"

# ── helm_end: the ONE decision. Stubs record every cluster write in $T/calls. ──────────────────────
ADIR="$T/adir"; mkdir -p "$ADIR"
HELM_SETTLE=0; export MGMT_POSTCHECK_TIMEOUT=0   # the polled compare reads once, no wall-clock wait
_hsleep() { :; }
_hk() { echo "k $*" >>"$T/calls"; case "$*" in *"get cm upgrade-lease-"*) echo "Error from server (NotFound): configmaps not found"; return 1 ;; esac; return 0; }
_hwin() { echo "win $*" >>"$T/calls"; [ "$1" = open ] && echo '✓ window w-test open until x — r'; return 0; }
VERDICT_RC=0; BOXV_RC=0   # BOXV_RC: what mgmt_verdict (FU-302) answers AFTER the apply; the baseline is in the record
_hev() {
  case "$1" in
    snapshot) echo '{"releases":{}}' ;;
    diff) echo "diff" ;;
    upload) echo "upload $2" >>"$T/calls" ;;
    verdict) if [ "$VERDICT_RC" = 0 ]; then echo '{"ok":true,"findings":[]}'; else echo '{"ok":false,"findings":["bgp: established 13 → 12"]}'; return 2; fi ;;
  esac
}
mgmt_verdict() { echo '{"verdict":"x","reasons":["bgp: 2 sessions down"]}'; return "$BOXV_RC"; }
mkd() {  # a begun bracket's dir
  local d="$T/rec-$1"; mkdir -p "$d"
  printf 'argocd_apps\targocd-apps\targocd\tabc123\t2.0.5\t2.0.6\n' >"$d/meta.tsv"
  printf 'seat-1-1' >"$d/window-id"; printf 'upgrade-lease-tofu-helm-argocd-apps' >"$d/lease-name"; printf 0 >"$d/box-verdict-before.rc"
  printf '%s' "$d"
}
# (1) clean apply + clean verdict + clean compare → rc 0; the lease DELETED, the window CLOSED, no marker
: >"$T/calls"; rm -f "$ADIR/helm-stopped"; d="$(mkd ok)"
helm_end "$d" 0 "" >/dev/null 2>&1; eq end-confirm-rc 0 "$?"
eq end-confirm-lease-deleted 1 "$(grep -c '^k -n agent-coordinator delete cm upgrade-lease-tofu-helm-argocd-apps' "$T/calls")"
eq end-confirm-window-closed 1 "$(grep -c '^win close --id seat-1-1' "$T/calls")"
eq end-confirm-uploaded 1 "$(grep -c "^upload $d" "$T/calls")"
eq end-confirm-no-marker "" "$(cat "$ADIR/helm-stopped" 2>/dev/null)"
# (2) bad evidence verdict → rc 2 STOP: no lease delete, no window close, marker names the release
: >"$T/calls"; d="$(mkd bad)"; VERDICT_RC=2
helm_end "$d" 0 "" >/dev/null 2>&1; eq end-stop-rc 2 "$?"
eq end-stop-lease-kept 0 "$(grep -c 'delete cm' "$T/calls")"
eq end-stop-window-kept 0 "$(grep -c '^win close' "$T/calls")"
eq end-stop-marker "helm_release.argocd_apps|2.0.5→2.0.6" "$(cut -f2,3 "$ADIR/helm-stopped" | tr '\t' '|')"
eq end-stop-finding 1 "$(grep -c 'bgp: established 13 → 12' "$ADIR/helm-stopped")"
eq end-stop-still-uploaded 1 "$(grep -c "^upload $d" "$T/calls")"
# nothing that could be a revert: no helm/tofu call, no write beyond the lease/window reads above
eq end-stop-no-revert 0 "$(grep -ciE 'rollback|revert|apply|patch' "$T/calls")"
# (3) clean evidence, the BOX VERDICT worse than its baseline (ok → degraded, rc 2) → STOP — the box
#     verdict is the other half (FU-302; it replaced the maintenance-window compare 2026-10-10)
: >"$T/calls"; rm -f "$ADIR/helm-stopped"; d="$(mkd health)"; VERDICT_RC=0; BOXV_RC=2
helm_end "$d" 0 "" >/dev/null 2>&1; eq end-health-stop-rc 2 "$?"
eq end-health-finding "box: box verdict worse than its baseline: ok → degraded — bgp: 2 sessions down" "$(cat "$d/verdict.txt")"
# (3b) a baseline that was ALREADY degraded and stays degraded is no worse → CONFIRM (never the apply's fault)
: >"$T/calls"; rm -f "$ADIR/helm-stopped"; d="$(mkd degraded-base)"; printf 2 >"$d/box-verdict-before.rc"
helm_end "$d" 0 "" >/dev/null 2>&1; eq end-degraded-baseline-confirms 0 "$?"
# (4) an apply that ERRORED is a STOP even when the cluster reads clean (never a retry)
: >"$T/calls"; rm -f "$ADIR/helm-stopped"; d="$(mkd applyerr)"; BOXV_RC=0
helm_end "$d" 1 "" >/dev/null 2>&1; eq end-apply-error-rc 2 "$?"
eq end-apply-error-line 1 "$(grep -c '^apply: tofu apply exited 1' "$d/verdict.txt")"

# (5) helm_begin refuses when the box verdict BEFORE is down (rc 3) or cannot run (rc 1): nothing applied,
#     the lease it just armed deleted, the window closed (management-box.md §The box verdict)
for vr in 3 1; do
  : >"$T/calls"; BOXV_RC=$vr
  helm_begin "$T/rec-begin-$vr" argocd_apps argocd-apps argocd abc 2.0.5 2.0.6 60 >/dev/null 2>&1; eq "begin-refuses-verdict-rc$vr" 1 "$?"
  eq "begin-refuses-lease-deleted-rc$vr" 1 "$(grep -c '^k -n agent-coordinator delete cm upgrade-lease-tofu-helm-argocd-apps' "$T/calls")"
  eq "begin-refuses-window-closed-rc$vr" 1 "$(grep -c '^win close --id' "$T/calls")"
done
BOXV_RC=0

# (6) the ENGINE WAIT — a replay of the first substrate breakage record (meta-garage-2, longhorn 1.12.1,
#     2026-10-10): patched to v1.12.1, the volume reads v1.12.0/healthy while its new replica fails, then
#     Longhorn converges by itself (~31 min). Fake clock: every _hsleep advances it; reads come from a
#     sequence file (one line per read, the last line repeats). Contract (mgmt-helm.sh, HELM_ENGINE_TIMEOUT):
#     converged inside the bound → `ok` and the next volume moves; never converged → FAIL, rc 2, the rest
#     untouched; ONE patch per volume, never a second (waiting is not retrying).
CLOCK="$T/clock"
_hnow() { cat "$CLOCK"; }
_hsleep() { echo $(( $(cat "$CLOCK") + $1 )) >"$CLOCK"; }
jq -n '{spec:{template:{spec:{containers:[{command:["longhorn-manager","--engine-image","longhornio/longhorn-engine:v1.12.1"]}]}}}}' >"$T/eng-ds.json"
jq -n '{items:[{metadata:{name:"meta-garage-2"}, spec:{diskSelector:[]}, status:{currentImage:"longhornio/longhorn-engine:v1.12.0", state:"attached", robustness:"healthy"}},
               {metadata:{name:"std-1"}, spec:{diskSelector:["std"]}, status:{currentImage:"longhornio/longhorn-engine:v1.12.0", state:"attached", robustness:"healthy"}}]}' >"$T/eng-vols.json"
_hk() {
  echo "k $*" >>"$T/calls"
  case "$*" in
    *"get ds longhorn-manager"*) cat "$T/eng-ds.json" ;;
    *"get engineimages.longhorn.io"*) echo '{"items":[{"spec":{"image":"longhornio/longhorn-engine:v1.12.1"},"status":{"state":"deployed"}}]}' ;;
    *"get volumes.longhorn.io -o json"*) cat "$T/eng-vols.json" ;;
    *"patch volumes.longhorn.io"*|*"patch cm upgrade-lease-"*) return 0 ;;
    *"get volumes.longhorn.io "*" -o jsonpath"*)
      local v; v="$(awk '{for(i=1;i<=NF;i++) if($i=="volumes.longhorn.io") print $(i+1)}' <<<"$*")"
      local f="$T/seq-$v"; local line; line="$(head -1 "$f")"; [ "$(wc -l <"$f")" -gt 1 ] && sed -i 1d "$f"; echo -n "$line" ;;
  esac
}
OLD="longhornio/longhorn-engine:v1.12.0|healthy"; NEW="longhornio/longhorn-engine:v1.12.1|healthy"
eng_case() {  # <name> <want-rc> <meta-garage-2 seq: N old reads then NEW|never> <want ok/FAIL lines>
  local d="$T/eng-$1"; mkdir -p "$d"; : >"$T/calls"; echo 0 >"$CLOCK"
  printf 'upgrade-lease-tofu-helm-longhorn' >"$d/lease-name"; printf 'w-eng' >"$d/window-id"; printf '%s' "${MAXEND:-1970-01-02T00:00:00Z}" >"$d/max-end"
  { for _ in $(seq 1 "$3"); do echo "$OLD"; done; [ "$4" = never ] || echo "$NEW"; } >"$T/seq-meta-garage-2"
  [ "$4" = never ] && echo "$OLD" >>"$T/seq-meta-garage-2"
  echo "$NEW" >"$T/seq-std-1"
  helm_lh_engines "$d" longhorn-system fast,none,bulk,std; eq "engines-$1-rc" "$2" "$?"
  eq "engines-$1-lines" "$5" "$(grep -oE '^(ok  |FAIL) [a-z0-9-]+' "$d/engines.log" | tr -s ' ' | tr '\n' ';')"
  eq "engines-$1-one-patch-each" "$6" "$(grep -c 'patch volumes.longhorn.io meta-garage-2' "$T/calls")"
}
# the fake clock's dates (epoch + the clock), for the lease arithmetic
_hdate() { case "$1" in now) date -u -d "@$(cat "$CLOCK")" +%Y-%m-%dT%H:%M:%SZ ;; *) date -u -d "@$(( $(cat "$CLOCK") + $(sed 's/^+\([0-9]*\) seconds$/\1/' <<<"$1") ))" +%Y-%m-%dT%H:%M:%SZ ;; esac; }
renewals() { grep 'patch cm upgrade-lease-tofu-helm-longhorn' "$T/calls" | grep -oE '[0-9]{4}-[0-9-]+T[0-9:]+Z' | tr '\n' ' ' | sed 's/ $//'; }
# 186 old reads × 10 s ≈ 31 min (the datum) then converged: inside the 3600 s bound → ok, std-1 moves next
eng_case datum-converges 0 186 converge "ok meta-garage-2;ok std-1;" 1
# never converges: FAIL after the bound, std-1 never patched (the rest left where they are)
eng_case never-converges 2 0 never "FAIL meta-garage-2;" 1
eq engines-never-std-untouched 0 "$(grep -c 'patch volumes.longhorn.io std-1' "$T/calls")"
eq engines-datum-wait-recorded 1 "$(grep -c 'converged by itself after: v1.12.0/healthy' "$T/eng-datum-converges/engines.log")"
# the default bound is the datum's ≈2× (contract value, stated in mgmt-helm.sh)
eq engine-timeout-default 3600 "$HELM_ENGINE_TIMEOUT"

# (7) RENEW ON PROGRESS (operator 2026-10-10). Budget = HELM_ENGINE_TIMEOUT + HELM_TAIL; in this test
#     HELM_SETTLE=0 and MGMT_POSTCHECK_TIMEOUT=0 → HELM_TAIL = 0 + 0 + 300 → budget 3900 s.
#     datum case: meta-garage-2 converges at clock 186×10 = 1860 s → renew to 1860+3900 = 5760 s
#     (01:36:00); std-1 converges at its first read, clock still 1860 → renew 5760 again. max-end
#     1970-01-02 (86400 s) does not clamp.
HELM_TAIL=300
eq budget 3900 "$(helm_move_budget)"
eq renew-on-progress "1970-01-01T01:36:00Z 1970-01-01T01:36:00Z" "$(MAXEND=1970-01-02T00:00:00Z eng_case renew-datum 0 186 converge "ok meta-garage-2;ok std-1;" 1 >/dev/null; renewals)"
#     the cap: max-end 01:00:00 (3600 s) < 5760 → both renewals clamp to max-end, never past it
eq renew-capped-at-max-end "1970-01-01T01:00:00Z 1970-01-01T01:00:00Z" "$(MAXEND=1970-01-01T01:00:00Z eng_case renew-cap 0 186 converge "ok meta-garage-2;ok std-1;" 1 >/dev/null; renewals)"
#     a HUNG move (never converges) renews NOTHING → the lease runs out on its own (the dead-man)
eq hung-no-renewal "" "$(eng_case renew-hung 2 0 never "FAIL meta-garage-2;" 1 >/dev/null; renewals)"
eq renew-moves-window 2 "$(MAXEND=1970-01-02T00:00:00Z eng_case renew-win 0 0 converge "ok meta-garage-2;ok std-1;" 1 >/dev/null; grep -c '^win renew --id w-eng' "$T/calls")"

# (8) a KILLED run, then resume: the dead run's lease is still there. helm_lease_check: NotFound → 0;
#     live (expected-end ahead of the clock) → 1, no marker; PAST DUE → 2, the STOP marker names it —
#     never a quiet refusal every tick. Clock 7200 s = 02:00:00.
LEASE_JSON=""
_hk() { echo "k $*" >>"$T/calls"; case "$*" in *"get cm upgrade-lease-"*) [ -n "$LEASE_JSON" ] || { echo "(NotFound)"; return 1; }; echo "$LEASE_JSON" ;; esac; return 0; }
echo 7200 >"$CLOCK"; rm -f "$ADIR/helm-stopped"
helm_lease_check longhorn >/dev/null; eq lease-none 0 "$?"
LEASE_JSON='{"data":{"expected-end":"1970-01-01T02:30:00Z","max-end":"1970-01-01T09:00:00Z","by":"mgmt-helm-engines","sha":"abc","subject":"tofu/helm_release.longhorn","from":"1.12.1","to":"1.12.1"}}'
helm_lease_check longhorn >/dev/null; eq lease-live 1 "$?"
eq lease-live-no-marker "" "$(cat "$ADIR/helm-stopped" 2>/dev/null)"
LEASE_JSON='{"data":{"expected-end":"1970-01-01T01:30:00Z","max-end":"1970-01-01T09:00:00Z","by":"mgmt-apply","sha":"abc","subject":"tofu/helm_release.longhorn","from":"1.12.0","to":"1.12.1"}}'
helm_lease_check longhorn >/dev/null; eq lease-stale-stop 2 "$?"
eq lease-stale-marker 1 "$(grep -c 'stale lease upgrade-lease-tofu-helm-longhorn by mgmt-apply, expected-end 1970-01-01T01:30:00Z passed' "$ADIR/helm-stopped")"
#     expected-end past max-end reads as max-end (ADR-150 (2)): renewed to 10:00 but max-end 01:00 → stale
rm -f "$ADIR/helm-stopped"
LEASE_JSON='{"data":{"expected-end":"1970-01-01T10:00:00Z","max-end":"1970-01-01T01:00:00Z","by":"mgmt-helm-engines"}}'
helm_lease_check longhorn >/dev/null; eq lease-maxend-caps 2 "$?"
#     and the resume path itself: a stale lease → helm_lh_engines_run returns 2 (STOP), opens no window
rm -f "$ADIR/helm-stopped"; : >"$T/calls"
helm_lh_drift() { printf '41\tlonghorn-system\t1.12.1\tfast,none,bulk,std\t240\n'; }
helm_lh_engines_run /dev/null main abc >/dev/null 2>&1; eq resume-stale-stops 2 "$?"
eq resume-stale-no-window 0 "$(grep -c '^win open' "$T/calls")"
#     with the marker standing, the next start does nothing at all (no reads beyond the marker)
: >"$T/calls"; helm_lh_engines_run /dev/null main abc >/dev/null 2>&1; eq resume-marker-shut 0 "$?"
eq resume-marker-no-calls 0 "$(grep -c . "$T/calls")"
# (9) engines-mode begin: max-end fixed up front = now + moves × HELM_ENGINE_TIMEOUT + HELM_TAIL;
#     expected-end = now + one budget. Clock 0, 41 moves → 41×3600+300 = 147900 s = 1970-01-02T17:05:00Z;
#     expected-end 3900 s = 01:05:00.
rm -f "$ADIR/helm-stopped"; LEASE_JSON=""; echo 0 >"$CLOCK"; : >"$T/calls"
helm_begin "$T/rec-eng-begin" longhorn longhorn longhorn-system abc 1.12.1 1.12.1 240 engines 41 >/dev/null 2>&1; eq begin-engines-rc 0 "$?"
eq begin-engines-max-end "1970-01-02T17:05:00Z" "$(cat "$T/rec-eng-begin/max-end")"
eq begin-engines-lease "1970-01-01T01:05:00Z|1970-01-02T17:05:00Z|mgmt-helm-engines" "$(jq -r '.data | "\(.["expected-end"])|\(.["max-end"])|\(.by)"' "$T/rec-eng-begin/lease.json")"
eq begin-engines-mode engines "$(cut -f7 "$T/rec-eng-begin/meta.tsv")"
_hkilltree "$(cat "$T/rec-eng-begin/watch.pid")" 2>/dev/null

echo "mgmt-helm-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
