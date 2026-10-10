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
_hk() { echo "k $*" >>"$T/calls"; return 0; }
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

echo "mgmt-helm-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
