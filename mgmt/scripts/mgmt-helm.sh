#!/usr/bin/env bash
# mgmt-helm — the management box's bracket around an UNATTENDED `helm_release` apply (FU-301,
# docs/management-box.md §MB3 "Helm release applies"). SOURCED by mgmt/scripts/mgmt-apply.sh after
# mgmt-lib.sh, never run on its own; the fixture test (mgmt-helm-test.sh) sources it and stubs the seams.
#
# The operator's rulings it implements:
#   2026-10-02  no box action, revert or agent autonomy on a Cilium/Longhorn/ArgoCD failure until breakage
#               data exists — every helm apply is RECORDED (scripts/helm-release-evidence.sh)
#   2026-10-10  ("for now") the box MAY APPLY a reviewed helm bump: forward only, evidence-bracketed,
#               STOP + ALERT on a bad verdict, never revert / retry / remediate. Cilium stays class 6
#               (attended) — it is simply not in the policy's `apply_helm` list.
#
# One apply, in order (mgmt-apply.sh drives it; every step is a function below):
#   1 preflight   refusals BEFORE anything changes — the apply never starts on a cluster that already
#                 disagrees with git:
#                   helm-live-drift     the live release is not what the box last applied (status not
#                                       `deployed`, revision / chart / user values ≠ the state file's)
#                   lh-settings-drift   longhorn: a declared `defaultSettings` value ≠ the live Setting
#                   lh-volume-unhealthy longhorn: a volume faulted/degraded, or attached and not healthy
#                   lh-backup           longhorn: the fresh restore point failed (below)
#                 longhorn's fresh restore point: Longhorn refuses downgrades, so restore IS its rollback
#                 (docs/longhorn-backup.md) — an on-demand Backup of every daily-class volume to the
#                 backup Garage, plus `scripts/pg-backup.sh now` (every CNPG cluster rides Longhorn)
#   2 begin       a declared window (agents/seat-window.sh, by mgmt-apply — the reconciler waits it out),
#                 the ⚓ upgrade lease (ADR-150 — the box is the ACTOR here: it arms, verifies, deletes),
#                 the health baseline (maintenance-window snapshot) and the evidence `before` + timeline
#   3 (the apply — mgmt-apply.sh's own `tofu apply <plan>`)
#   4 engines     longhorn only: `concurrent-automatic-engine-upgrade-per-node-limit` is 0 here, so a
#                 chart upgrade leaves every volume on the old engine. The box moves them ONE AT A TIME,
#                 least valuable disk class first (the policy row's `engine_order`), each waited to the new
#                 image AND back to its old robustness before the next; the first that does not stops it
#   5 end         settle, `after`, the VERDICT (the evidence verdict + the box verdict, FU-302), the health
#                 compare; the record goes to the backup Garage. Good → the lease is deleted (confirmed)
#                 and the window closed. Bad → STOP: the lease STAYS (the lease loop reads a `tofu/` subject
#                 as `forward_only` — never a revert PR), the window stays open (it holds the apply loop
#                 and the reconciler until it lapses), and $ADIR/helm-stopped refuses every later helm
#                 apply until a human removes it → mgmt_apply_helm_stopped → MgmtHelmApplyStopped.
#
# Never: a revert, a retry, a rollback of the chart, a remediation. A bad verdict is data plus a stop.

HELM_EVIDENCE_ROOT="${MGMT_HELM_EVIDENCE_DIR:-/var/lib/mgmt/helm-evidence}"
HELM_LEASE_NS="${MGMT_LEASE_NS:-agent-coordinator}"
HELM_LEASE_LABEL="${MGMT_LEASE_LABEL:-homelab.teststuff.net/upgrade-lease}"
HELM_SETTLE="${MGMT_HELM_SETTLE:-600}"          # after the apply (and the engine moves) before `after` is read
HELM_ENGINE_TIMEOUT="${MGMT_HELM_ENGINE_TIMEOUT:-900}"   # per volume
HELM_BACKUP_TIMEOUT="${MGMT_HELM_BACKUP_TIMEOUT:-1800}"  # the Longhorn on-demand backups, all together
# The names a helm roll of these releases structurally produces (the window graces them, silences nothing).
HELM_DECLARED_ALERTS="${MGMT_HELM_DECLARED_ALERTS:-KubePodNotReady,KubeDeploymentReplicasMismatch,KubeDeploymentRolloutStuck,KubeDaemonSetRolloutStuck,KubeStatefulSetReplicasMismatch,KubeStatefulSetUpdateNotRolledOut,ArgoCDAppDegraded,ArgoCDAppOutOfSync,LonghornVolumeDegraded,TargetDown}"

# ── seams (mgmt-helm-test.sh overrides these) ───────────────────────────────────────────────────
_hkc() { local kc="${KUBECONFIG:-}"; [ -f "$kc" ] || kc=/var/lib/mgmt/kubeconfig; printf '%s' "$kc"; }
# Tools (FU-305, mgmt-tools.sh): kubectl from the box's closure, helm as master's devbox.lock pins it
# (mgmt_tree_path in mgmt-apply.sh) — never `devbox run`, which a bad lock on master wedges.
_hk()    { ( cd "$REPO" && mgmt_x kubectl --kubeconfig "$(_hkc)" --request-timeout=30s "$@" ); }
_hhelm() { ( cd "$REPO" && mgmt_x helm --kubeconfig "$(_hkc)" "$@" ); }
# the evidence verbs run from the TRUSTED tree (master, like maintenance-window.sh); their own fallback
# finds /var/lib/mgmt/kubeconfig when KUBECONFIG names an absent file
_hev()   { ( cd "$REPO" && bash "$REPO/scripts/helm-release-evidence.sh" "$@" ); }
# seat-window.sh finds kubectl on PATH (the box closure) on its own (agents/seat-window.sh header)
_hwin()  { KUBECONFIG="$(_hkc)" SEAT_WINDOW_BY=mgmt-apply bash "$REPO/agents/seat-window.sh" "$@"; }
_hpg()   { ( cd "$REPO" && KUBECONFIG="$(_hkc)" bash "$REPO/scripts/pg-backup.sh" now ); }
_hnow()  { date +%s; }
# the timeline watcher is a subshell → bash → kubectl: kill the whole tree (no procps on the
# box's unit path — /proc is)
_hkilltree() { local c; for c in $(cat /proc/"$1"/task/*/children 2>/dev/null); do _hkilltree "$c"; done; kill "$1" 2>/dev/null || true; }
_hsleep() { sleep "$1"; }
_hstate() { printf '%s' "${MGMT_STATE_DIR:-/var/lib/mgmt/state}/main/terraform.tfstate"; }

# ── pure reads (no cluster; the test feeds them files) ───────────────────────────────────────────
# helm_drift <tf-name> <state-file> <live-history.json> <live-values.json> → one "helm-live-drift<TAB>…"
# line per mismatch between what the box last APPLIED (the state file — never the refreshed plan, whose
# `before` already reads live) and the running release. Values are compared as a canonical hash, never
# printed. rc 1 = the state has no such release (the caller refuses: nothing to compare is not "same").
helm_drift() {
  local name="$1" st="$2" hist="$3" vals="$4" m sv lv
  m="$(jq -c --arg n "$name" '.resources[]? | select(.type == "helm_release" and .name == $n) | .instances[0].attributes.metadata' "$st" 2>/dev/null)"
  [ -n "$m" ] && [ "$m" != null ] || return 1
  jq -r --argjson m "$m" '.[-1] // {} |
      (if (.status // "") != "deployed" then "helm-live-drift\tstatus \(.status // "unreadable") (want deployed)" else empty end),
      (if (.revision // -1) != $m.revision then "helm-live-drift\trevision live \(.revision // "?") ≠ applied \($m.revision)" else empty end),
      (if (.chart // "") != "\($m.chart)-\($m.version)" then "helm-live-drift\tchart live \(.chart // "?") ≠ applied \($m.chart)-\($m.version)" else empty end)' "$hist" 2>/dev/null \
    || printf 'helm-live-drift\tlive history unreadable\n'
  sv="$(jq -r '.values // "{}"' <<<"$m" | jq -cS . 2>/dev/null | sha256sum | cut -c1-16)"
  lv="$(jq -cS 'if . == null then {} else . end' "$vals" 2>/dev/null | sha256sum | cut -c1-16)"
  [ "$sv" = "$lv" ] || printf 'helm-live-drift\tuser values live %s ≠ applied %s (hashes)\n' "$lv" "$sv"
  return 0
}
# lh_settings_drift <tf-name> <state-file> <settings.json> → "lh-settings-drift<TAB><setting>" per
# declared `defaultSettings` key whose live Setting differs. camelCase → kebab name (Longhorn's own
# mapping: systemManagedCSIComponentsResourceLimits → system-managed-csi-components-resource-limits).
# A per-data-engine live value ({"v1":"2","v2":"2"}) matches a scalar declaration when every engine
# carries it. A declared key with no live Setting is a drift too (a renamed setting must be read).
lh_settings_drift() {
  local name="$1" st="$2" ls="$3" k v n lv
  jq -r --arg n "$name" '.resources[]? | select(.type == "helm_release" and .name == $n) | .instances[0].attributes.metadata.values // "{}"
      | fromjson | .defaultSettings // {} | to_entries[] | "\(.key)\t\(.value | tostring)"' "$st" 2>/dev/null |
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    n="$(sed -E 's/([A-Z]+)([A-Z][a-z])/\1-\2/g; s/([a-z0-9])([A-Z])/\1-\2/g' <<<"$k" | tr 'A-Z' 'a-z')"
    lv="$(jq -r --arg n "$n" '[.items[]? | select(.metadata.name == $n) | .value][0] // "__absent__"' "$ls")"
    [ "$lv" = "$v" ] && continue
    jq -e --arg v "$v" 'type == "object" and length > 0 and all(.[]; tostring == $v)' <<<"$lv" >/dev/null 2>&1 && continue
    printf 'lh-settings-drift\t%s\n' "$n"
  done
}
# lh_unhealthy <volumes.json> → "lh-volume-unhealthy<TAB><vol> <state>/<robustness>" per volume that is
# faulted or degraded, or attached and not healthy. A detached volume reads robustness `unknown`.
lh_unhealthy() {
  jq -r '.items[]? | select(.status.robustness == "faulted" or .status.robustness == "degraded"
           or (.status.state == "attached" and .status.robustness != "healthy"))
         | "lh-volume-unhealthy\t\(.metadata.name) \(.status.state)/\(.status.robustness)"' "$1"
}
# lh_engine_plan <volumes.json> <new-image> <order csv> → "<vol><TAB><class><TAB><state>" for every
# v1 volume not yet on <new-image>, least valuable class first: a volume's class is the first of its
# diskSelector tags found in <order> (`none` = no selector); a class <order> does not name goes LAST,
# after everything it does name. Stable inside a class (by name), so a rerun walks the same order.
lh_engine_plan() {
  jq -r --arg img "$2" --arg order "$3" '($order | split(",")) as $o |
    [.items[]? | select((.spec.dataEngine // "v1") == "v1" and (.status.currentImage // "") != $img)
     | ((.spec.diskSelector // []) | if length == 0 then ["none"] else . end) as $tags
     | ([$tags[] | . as $t | $o | index($t) | select(. != null)] | min // 999) as $rank
     | {n: .metadata.name, rank: $rank, cls: ($tags | join("+")), st: (.status.state // "?")}]
    | sort_by(.rank, .n)[] | "\(.n)\t\(.cls)\t\(.st)"' "$1"
}
# lh_engine_image <manager-ds.json> → the `--engine-image` the longhorn-manager DaemonSet runs with
lh_engine_image() {
  jq -r '.spec.template.spec.containers[0] | (.command // []) + (.args // []) | . as $c
         | [range(0; length) | select($c[.] == "--engine-image") | $c[. + 1]][0] // empty' "$1"
}

# ── 1 preflight ──────────────────────────────────────────────────────────────────────────────────
# helm_preflight <tf-name> <release> <ns> <workdir> → refusal lines on stdout ("rule<TAB>detail"),
# rc 0 = it may apply, rc 2 = refused (lines say why), rc 1 = a read failed (the caller refuses too —
# "we could not look" is never a pass).
helm_preflight() {
  local name="$1" rel="$2" ns="$3" w="$4" out=""
  mkdir -p "$w"
  _hhelm history "$rel" -n "$ns" --max 1 -o json >"$w/live-history.json" 2>"$w/err" || { echo "live helm history unreadable: $(tail -c 200 "$w/err")"; return 1; }
  _hhelm get values "$rel" -n "$ns" -o json >"$w/live-values.json" 2>"$w/err" || { echo "live helm values unreadable: $(tail -c 200 "$w/err")"; return 1; }
  out="$(helm_drift "$name" "$(_hstate)" "$w/live-history.json" "$w/live-values.json")" || { echo "helm_release.$name absent from the box's state"; return 1; }
  if [ "$rel" = longhorn ]; then
    _hk -n "$ns" get settings.longhorn.io -o json >"$w/settings.json" 2>"$w/err" || { echo "longhorn settings unreadable"; return 1; }
    _hk -n "$ns" get volumes.longhorn.io -o json >"$w/volumes.json" 2>"$w/err" || { echo "longhorn volumes unreadable"; return 1; }
    out="$(printf '%s\n%s\n%s' "$out" "$(lh_settings_drift "$name" "$(_hstate)" "$w/settings.json")" "$(lh_unhealthy "$w/volumes.json")" | grep . || true)"
    # the restore point only when everything else passed — a backup of a cluster the box will not
    # touch is a wasted half hour, and a failed backup refuses the apply on its own
    [ -z "$out" ] && out="$(lh_fresh_backup "$ns" "$w")"
  fi
  out="$(printf '%s\n' "$out" | grep . || true)"
  [ -z "$out" ] && return 0
  printf '%s\n' "$out"; return 2
}
# lh_fresh_backup <ns> <workdir> → "" when every daily-class volume has a NEW completed Backup and every
# CNPG cluster a new base backup; else one "lh-backup<TAB>…" line per failure. The drill recipe of
# docs/longhorn-backup.md §Restore (Snapshot → Backup with the backup-volume label); the Snapshot CR is
# deleted once its Backup completes (the backup is independent of it; on-demand snapshots are not
# auto-cleaned here). Backups carry `homelab.io/restore-point: fu301` so a person can find them.
lh_fresh_backup() {
  local ns="$1" w="$2" tag v t0 st pending
  tag="fu301-$(date -u +%Y%m%d%H%M%S)"
  _hk -n "$ns" get volumes.longhorn.io -l recurring-job-group.longhorn.io/daily-backup=enabled -o json >"$w/daily.json" 2>/dev/null \
    || { printf 'lh-backup\tdaily-class volumes unreadable\n'; return 0; }
  jq -r '.items[].metadata.name' "$w/daily.json" >"$w/daily.list"
  [ -s "$w/daily.list" ] || { printf 'lh-backup\tno daily-class volume found — the restore point would be empty\n'; return 0; }
  while read -r v; do
    jq -n --arg n "$tag-${v:4:8}" --arg ns "$ns" --arg v "$v" \
      '{apiVersion:"longhorn.io/v1beta2", kind:"Snapshot", metadata:{name:$n, namespace:$ns, labels:{"homelab.io/restore-point":"fu301"}}, spec:{volume:$v, createSnapshot:true}}' \
      | _hk create -f - >/dev/null 2>&1 || printf 'lh-backup\tsnapshot of %s could not be created\n' "$v"
  done <"$w/daily.list"
  t0="$(_hnow)"; pending="$(cat "$w/daily.list")"
  while [ -n "$pending" ] && [ $(( $(_hnow) - t0 )) -lt "$HELM_BACKUP_TIMEOUT" ]; do
    local left=""
    while read -r v; do
      [ -n "$v" ] || continue
      st="$(_hk -n "$ns" get snapshots.longhorn.io "$tag-${v:4:8}" -o jsonpath='{.status.readyToUse}' 2>/dev/null)"
      if [ "$st" = true ]; then
        if ! _hk -n "$ns" get backups.longhorn.io "$tag-${v:4:8}" >/dev/null 2>&1; then
          jq -n --arg n "$tag-${v:4:8}" --arg ns "$ns" --arg v "$v" \
            '{apiVersion:"longhorn.io/v1beta2", kind:"Backup", metadata:{name:$n, namespace:$ns, labels:{"backup-volume":$v, "homelab.io/restore-point":"fu301"}}, spec:{snapshotName:$n}}' \
            | _hk create -f - >/dev/null 2>&1 || true
        fi
        st="$(_hk -n "$ns" get backups.longhorn.io "$tag-${v:4:8}" -o jsonpath='{.status.state}' 2>/dev/null)"
        case "$st" in
          Completed) _hk -n "$ns" delete snapshots.longhorn.io "$tag-${v:4:8}" --wait=false >/dev/null 2>&1 || true; continue ;;
          Error) printf 'lh-backup\tbackup of %s ended in Error\n' "$v"; continue ;;
        esac
      fi
      left="$left$v"$'\n'
    done <<<"$pending"
    pending="$(printf '%s' "$left" | grep . || true)"
    [ -n "$pending" ] && _hsleep 20
  done
  [ -n "$pending" ] && printf '%s\n' "$pending" | sed 's/^/lh-backup\tbackup not Completed within the timeout: /'
  _hpg >"$w/pg-backup.log" 2>&1 || printf 'lh-backup\tCNPG base backups (pg-backup.sh now) did not all complete — %s\n' "$(tail -1 "$w/pg-backup.log")"
  return 0
}

# ── 2 begin ──────────────────────────────────────────────────────────────────────────────────────
# helm_begin <dir> <tf-name> <release> <ns> <sha> <from> <to> <cap-min> → the window, the lease, the
# baseline, `before` and the timeline. rc≠0 = not begun (the caller does NOT apply; what was opened is
# closed again here). Writes $dir/{window-id,lease-name,watch.pid}.
helm_begin() {
  local d="$1" name="$2" rel="$3" ns="$4" sha="$5" from="$6" to="$7" cap="$8" wid lease now_ end
  mkdir -p "$d"
  _hwin open --reason "box helm apply: helm_release.$name $from → $to (${sha:0:8}) — mgmt/scripts/mgmt-helm.sh, FU-301" \
    --alerts "$HELM_DECLARED_ALERTS" --minutes "$(( cap + 30 ))" \
    --note "forward only: a bad verdict STOPS the box (lease kept, window kept, MgmtHelmApplyStopped) — nothing reverts" \
    >"$d/window-open.log" 2>&1 || { log "helm: window did not open"; return 1; }
  wid="$(sed -n 's/^✓ window \([^ ]*\) open .*/\1/p' "$d/window-open.log" | head -1)"
  [ -n "$wid" ] || { log "helm: window id unreadable"; return 1; }
  printf '%s' "$wid" >"$d/window-id"
  lease="upgrade-lease-tofu-helm-$rel"
  now_="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; end="$(date -u -d "+${cap} minutes" +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg n "$lease" --arg ns "$HELM_LEASE_NS" --arg l "$HELM_LEASE_LABEL" --arg subj "tofu/helm_release.$name" \
        --arg chart "$rel" --arg sha "$sha" --arg from "$from" --arg to "$to" --arg end "$end" --arg w "$wid" \
    '{apiVersion:"v1", kind:"ConfigMap", metadata:{name:$n, namespace:$ns, labels:{($l):"true"}},
      data:{subject:$subj, chart:$chart, sha:$sha, from:$from, to:$to, "expected-end":$end, "max-end":$end,
            by:"mgmt-apply", reason:("box helm apply under window " + $w + " — forward only (FU-301): an expired lease here is a STOP, never a revert")}}' \
    >"$d/lease.json"
  if ! _hk create -f "$d/lease.json" >/dev/null 2>"$d/lease.err"; then
    log "helm: lease $lease not created ($(tail -c 200 "$d/lease.err")) — closing the window, not applying"
    _hwin close --id "$wid" --tail-min 0 >/dev/null 2>&1 || true; return 1
  fi
  printf '%s' "$lease" >"$d/lease-name"
  # the box verdict's baseline (FU-302, management-box.md §The box verdict): DOWN or unrunnable = no apply
  local vbase=0; mgmt_verdict >"$d/box-verdict-before.json" 2>"$d/box-verdict-before.err" || vbase=$?
  printf '%s' "$vbase" >"$d/box-verdict-before.rc"
  if [ "$(mgmt_verdict_rank "$vbase")" -ge 2 ]; then
    log "helm: box verdict $(mgmt_verdict_name "$vbase") before the apply — not applying (lease deleted, window closed)"
    _hk -n "$HELM_LEASE_NS" delete cm "$lease" >/dev/null 2>&1 || true
    _hwin close --id "$wid" --tail-min 0 >/dev/null 2>&1 || true; return 1
  fi
  _hev snapshot >"$d/before.json" 2>"$d/before.err" || log "helm: WARN before snapshot partial ($(tail -c 160 "$d/before.err"))"
  ( _hev watch "$(( HELM_SETTLE + cap * 60 ))" 20 >"$d/timeline.jsonl" 2>/dev/null ) & printf '%s' "$!" >"$d/watch.pid"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$rel" "$ns" "$sha" "$from" "$to" >"$d/meta.tsv"
  log "helm: begun — window $wid, lease $HELM_LEASE_NS/$lease (expected-end $end), record $d"
}

# ── 4 engines (longhorn) ─────────────────────────────────────────────────────────────────────────
# helm_lh_engines <dir> <ns> <order csv> → rc 0 every v1 volume on the manager's engine image; rc 2 the
# first volume that did not come back (its line in $d/engines.log) — the rest are left where they are.
helm_lh_engines() {
  local d="$1" ns="$2" order="$3" img v cls st t0 cur rob was
  _hk -n "$ns" get ds longhorn-manager -o json >"$d/manager-ds.json" 2>/dev/null || { echo "manager DaemonSet unreadable" >>"$d/engines.log"; return 2; }
  img="$(lh_engine_image "$d/manager-ds.json")"
  [ -n "$img" ] || { echo "engine image unreadable from longhorn-manager" >>"$d/engines.log"; return 2; }
  # the new EngineImage must be deployed before a volume may move to it
  t0="$(_hnow)"
  until [ "$(_hk -n "$ns" get engineimages.longhorn.io -o json 2>/dev/null | jq -r --arg i "$img" '[.items[] | select(.spec.image == $i) | .status.state][0] // ""')" = deployed ]; do
    [ $(( $(_hnow) - t0 )) -lt "$HELM_ENGINE_TIMEOUT" ] || { echo "engine image $img not deployed within ${HELM_ENGINE_TIMEOUT}s" >>"$d/engines.log"; return 2; }
    _hsleep 15
  done
  _hk -n "$ns" get volumes.longhorn.io -o json >"$d/engines-volumes.json" 2>/dev/null || { echo "volumes unreadable" >>"$d/engines.log"; return 2; }
  lh_engine_plan "$d/engines-volumes.json" "$img" "$order" >"$d/engines.plan"
  echo "engine image $img — $(grep -c . "$d/engines.plan") volume(s) to move, order $order" >>"$d/engines.log"
  while IFS=$'\t' read -r v cls st; do
    [ -n "$v" ] || continue
    was="$(jq -r --arg v "$v" '.items[] | select(.metadata.name == $v) | .status.robustness // "?"' "$d/engines-volumes.json")"
    _hk -n "$ns" patch volumes.longhorn.io "$v" --type merge -p "{\"spec\":{\"image\":\"$img\"}}" >/dev/null 2>&1 \
      || { echo "FAIL $v ($cls, $st): patch refused" >>"$d/engines.log"; return 2; }
    t0="$(_hnow)"
    while :; do
      cur="$(_hk -n "$ns" get volumes.longhorn.io "$v" -o jsonpath='{.status.currentImage}|{.status.robustness}' 2>/dev/null)"
      rob="${cur#*|}"; cur="${cur%%|*}"
      # back where it was: on the new image, and healthy again if it was healthy (a detached volume
      # reads `unknown` before and after)
      if [ "$cur" = "$img" ] && { [ "$was" != healthy ] || [ "$rob" = healthy ]; }; then
        echo "ok   $v ($cls, $st) → $img [$was → $rob] $(( $(_hnow) - t0 ))s" >>"$d/engines.log"; break
      fi
      [ $(( $(_hnow) - t0 )) -lt "$HELM_ENGINE_TIMEOUT" ] || { echo "FAIL $v ($cls, $st): image=$cur robustness=$rob after ${HELM_ENGINE_TIMEOUT}s" >>"$d/engines.log"; return 2; }
      _hsleep 10
    done
  done <"$d/engines.plan"
  return 0
}

# ── 5 end ────────────────────────────────────────────────────────────────────────────────────────
# helm_cluster_verdict <dir> <release> → rc 0 good / 2 bad, findings in $d/verdict.txt. Two reads, both
# must pass: the evidence verdict (scripts/helm-release-evidence.sh — release-scoped: rolled, deployed,
# BGP, Longhorn robustness, ArgoCD health, before vs after) and the BOX VERDICT (FU-302,
# mgmt/scripts/mgmt-verdict.sh, docs/management-box.md §The box verdict — Talos, kube API, BGP, VIPs,
# nodes, ArgoCD, Prometheus/Alertmanager readiness) polled until it ranks no worse than its baseline
# from helm_begin. The box verdict REPLACED the maintenance-window compare (the declared FU-302 swap,
# 2026-10-10): no Prometheus alert names any more — drill 1 stopped a clean roll on GitHub's API quota.
helm_cluster_verdict() {
  local d="$1" rel="$2" rc=0 vbase line
  : >"$d/verdict.txt"
  _hev verdict "$d/before.json" "$d/after.json" "$rel" >"$d/verdict.json" 2>>"$d/verdict.txt" || rc=2
  jq -r '.findings[]?' "$d/verdict.json" 2>/dev/null | sed 's/^/evidence: /' >>"$d/verdict.txt"
  vbase="$(cat "$d/box-verdict-before.rc" 2>/dev/null)"; vbase="${vbase:-1}"
  if ! line="$(mgmt_verdict_poll "$vbase" "$d/box-verdict-after.json")"; then
    rc=2; echo "box: ${line:-box verdict poll failed without a finding}" >>"$d/verdict.txt"
  fi
  [ "$rc" = 0 ] && [ ! -s "$d/verdict.txt" ] && return 0
  return 2
}
# helm_end <dir> <apply-rc> <engine-order csv> → rc 0 confirmed / 2 STOPPED. Never reverts anything.
helm_end() {
  local d="$1" arc="$2" order="${3:-}" name rel ns sha from to wid lease erc=0 vrc=0 pid
  IFS=$'\t' read -r name rel ns sha from to <"$d/meta.tsv"
  wid="$(cat "$d/window-id")"; lease="$(cat "$d/lease-name")"
  if [ "$arc" = 0 ] && [ "$rel" = longhorn ]; then helm_lh_engines "$d" "$ns" "$order" || erc=2; fi
  _hsleep "$HELM_SETTLE"
  pid="$(cat "$d/watch.pid" 2>/dev/null)"; [ -n "$pid" ] && { _hkilltree "$pid"; wait "$pid" 2>/dev/null; }
  _hev snapshot >"$d/after.json" 2>"$d/after.err" || true
  helm_cluster_verdict "$d" "$rel" || vrc=2
  [ "$arc" = 0 ] || echo "apply: tofu apply exited $arc" >>"$d/verdict.txt"
  [ "$erc" = 0 ] || grep '^FAIL\|unreadable\|not deployed' "$d/engines.log" | sed 's/^/engines: /' >>"$d/verdict.txt"
  { echo "box helm apply helm_release.$name ($rel) $from → $to  sha $sha  apply rc=$arc  window $wid  lease $lease"
    _hev diff "$d/before.json" "$d/after.json" 2>/dev/null || echo "(diff unreadable)"
    [ -s "$d/engines.log" ] && { echo "== longhorn engines"; cat "$d/engines.log"; }
    echo "== verdict"; if [ -s "$d/verdict.txt" ]; then cat "$d/verdict.txt"; else echo "ok"; fi
    echo "== box verdict $(mgmt_verdict_name "$(cat "$d/box-verdict-before.rc" 2>/dev/null)") → $(jq -r '.verdict // "?"' "$d/box-verdict-after.json" 2>/dev/null)"
  } >"$d/summary.txt"
  _hev upload "$d" >>"$d/upload.log" 2>&1 || log "helm: WARN record not uploaded to the backup Garage — kept at $d"
  if [ "$arc" = 0 ] && [ "$erc" = 0 ] && [ "$vrc" = 0 ] && [ ! -s "$d/verdict.txt" ]; then
    _hk -n "$HELM_LEASE_NS" delete cm "$lease" >/dev/null 2>&1 || log "helm: WARN lease $lease not deleted — the lease loop will read it as forward_only at expiry"
    _hwin close --id "$wid" >/dev/null 2>&1 || log "helm: WARN window $wid not closed — it lapses at its until"
    log "helm: CONFIRMED helm_release.$name $from → $to — lease deleted, window closed"
    return 0
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$sha" "helm_release.$name" "$from→$to" "$d" "$(tr '\n' ';' <"$d/verdict.txt" | sed 's/;$//')" >"$ADIR/helm-stopped"
  log "helm: STOPPED after helm_release.$name $from → $to — lease $lease KEPT, window $wid LEFT OPEN, $ADIR/helm-stopped written; nothing reverted:"
  sed 's/^/    /' "$d/verdict.txt"
  return 2
}
