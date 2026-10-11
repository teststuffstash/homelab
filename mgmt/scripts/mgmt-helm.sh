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
#                 image AND back to its old robustness before the next; the first that does not stops it.
#                 An attached volume's CONSUMER pods must also stay whole (Ready, same pod, no restart)
#                 before the next move; a 1-replica attached volume is REFUSED before anything moves
#                 (attended engine move required — the second breakage record, 2026-10-10)
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
# Per engine move: how long the box WAITS for Longhorn's own convergence (currentImage == spec.image,
# back to its old robustness) before it stops. Waiting is not acting: the box never retries, reverts or
# touches the volume again — Longhorn's controllers do their own retrying, the box only reads. The datum
# (the first substrate breakage record, docs/management-box.md §Helm release applies, 2026-10-10):
# meta-garage-2 (1 replica, attached) was patched 17:47Z; its new replica failed `bind: address already
# in use` on the volume's unix socket, Longhorn replaced it at 18:18:23Z and the volume converged by
# itself ≈31 min after the patch — the old 900 s bound stopped the box at 15 min. 3600 s ≈ 2× the datum.
HELM_ENGINE_TIMEOUT="${MGMT_HELM_ENGINE_TIMEOUT:-3600}"
HELM_ENGINE_IMAGE_TIMEOUT="${MGMT_HELM_ENGINE_IMAGE_TIMEOUT:-900}"   # the new EngineImage reaching `deployed`
# Per ATTACHED engine move, after Longhorn reads converged: the CONSUMER check (the second breakage record,
# 2026-10-10 21:03Z — meta-garage-1 read converged/healthy while its frontend served ENODATA and garage-1
# segfaulted; the box moved the rest and only noticed at the final verdict). Every pod mounting the PVC
# must stay Ready, same pod, no restart since the move began, for HELM_CONSUMER_SOAK s; a restart, a
# replaced/gone pod or a container waiting in a crash/create error is an immediate STOP, NotReady is
# waited up to HELM_CONSUMER_TIMEOUT. Reads only — like the convergence wait, waiting is not acting.
HELM_CONSUMER_TIMEOUT="${MGMT_HELM_CONSUMER_TIMEOUT:-900}"
HELM_CONSUMER_SOAK="${MGMT_HELM_CONSUMER_SOAK:-120}"
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

_hdate() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }   # the test stubs it with its fake clock
# ── the lease, on the engine moves (operator 2026-10-10: "renew on PROGRESS") ──────────────────────
# One move budget = HELM_ENGINE_TIMEOUT (the per-volume convergence bound) + HELM_TAIL (the settle + the
# verdict poll after the last move). The lease RENEWS only when a volume CONVERGED: expected-end = now +
# one budget, never past the max-end fixed at begin. A hung actor stops renewing → the lease expires
# within one budget → the lease loop's `forward_only` → MgmtHelmApplyStopped (the dead-man, unchanged).
HELM_TAIL="${MGMT_HELM_TAIL:-$(( ${MGMT_HELM_SETTLE:-600} + ${MGMT_POSTCHECK_TIMEOUT:-900} + 300 ))}"
helm_move_budget() { echo $(( HELM_ENGINE_TIMEOUT + HELM_TAIL )); }
# helm_lease_renew <dir> → patches expected-end = min(now + budget, max-end); rc≠0 logged by the caller
helm_lease_renew() {
  local d="$1" lease new max
  lease="$(cat "$d/lease-name" 2>/dev/null)"; max="$(cat "$d/max-end" 2>/dev/null)"
  [ -n "$lease" ] && [ -n "$max" ] || return 1
  new="$(_hdate "+$(helm_move_budget) seconds")"; [ "$new" \> "$max" ] && new="$max"
  _hk -n "$HELM_LEASE_NS" patch cm "$lease" --type merge -p "{\"data\":{\"expected-end\":\"$new\"}}" >/dev/null 2>&1 || return 1
  echo "renew $(date -u +%H:%M:%SZ) expected-end $new" >>"$d/lease-renewals.log"
  # the window rides the same progress: a dead actor's window lapses within one budget too
  _hwin renew --id "$(cat "$d/window-id")" --minutes "$(( $(helm_move_budget) / 60 + 30 ))" >/dev/null 2>&1 || true
}
# helm_lease_check <release> → rc 0 no lease of this release; rc 1 a LIVE one (in flight — the caller
# does not begin); rc 2 one PAST DUE (expected-end, capped at max-end, in the past): its actor died or
# stopped without confirming → write the STOP marker (→ MgmtHelmApplyStopped) and name it. Never a quiet
# refusal on every tick (operator 2026-10-10); a human clears the marker + the lease, once. rc 3 = unreadable.
helm_lease_check() {
  local rel="$1" j e m now_
  j="$(_hk -n "$HELM_LEASE_NS" get cm "upgrade-lease-tofu-helm-$rel" -o json 2>&1)" || { grep -q NotFound <<<"$j" && return 0; return 3; }
  e="$(jq -r '.data["expected-end"] // ""' <<<"$j")"; m="$(jq -r '.data["max-end"] // ""' <<<"$j")"
  [ -n "$m" ] && [ "$e" \> "$m" ] && e="$m"
  now_="$(_hdate now)"
  [ -n "$e" ] && [ "$e" \> "$now_" ] && return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$(jq -r '.data.sha // "?"' <<<"$j")" "$(jq -r '.data.subject // "?"' <<<"$j")" \
    "$(jq -r '"\(.data.from // "?")→\(.data.to // "?")"' <<<"$j")" "-" \
    "stale lease upgrade-lease-tofu-helm-$rel by $(jq -r '.data.by // "?"' <<<"$j"), expected-end $e passed with no confirm — its actor died or stopped; read the record, then clear (marker + lease)" >"$ADIR/helm-stopped"
  log "helm: STOP — lease upgrade-lease-tofu-helm-$rel is past due ($e) with no actor confirming it; $ADIR/helm-stopped written"
  return 2
}

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
# lh_engine_refusals <volumes.json> <new-image> → "<vol><TAB><why>" for every v1 volume still to move that
# is ATTACHED with one replica (or an unreadable replica count): the box refuses a LIVE engine move of it —
# a 1-replica attached volume has no second replica to carry its frontend through the move, and the
# second breakage record (meta-garage-1, 2026-10-10) is exactly that shape. Attended path only (offline:
# detach, move, reattach). A DETACHED 1-replica volume moves offline and is not refused.
lh_engine_refusals() {
  jq -r --arg img "$2" '.items[]? | select((.spec.dataEngine // "v1") == "v1" and (.status.currentImage // "") != $img
         and (.status.state // "") == "attached" and ((.spec.numberOfReplicas // 0) | tonumber? // 0) < 2)
       | "\(.metadata.name)\t\(if (.spec.numberOfReplicas // null) == null then "replica count unreadable" else "1-replica" end) attached: attended engine move required"' "$1"
}
# lh_consumers <pods.json> <pvc> → "<pod><TAB><uid><TAB><phase><TAB>ready|notready<TAB><restarts><TAB><waiting reasons|->"
# for every pod whose spec mounts <pvc>. Restarts = the sum over its containers.
lh_consumers() {
  jq -r --arg c "$2" '.items[]? | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName? == $c))
    | [.metadata.name, (.metadata.uid // "?"), (.status.phase // "?"),
       (if any(.status.conditions[]?; .type == "Ready" and .status == "True") then "ready" else "notready" end),
       ([.status.containerStatuses[]?.restartCount // 0] | add // 0 | tostring),
       ([.status.containerStatuses[]?.state.waiting.reason? // empty] | join(",") | if . == "" then "-" else . end)] | @tsv' "$1"
}
# lh_consumer_verdict <base.tsv> <now.tsv> → rc 0 every consumer whole; rc 1 "wait<TAB>…" (a pod Ready before
# is NotReady now — waited, bounded); rc 2 "bad<TAB>…" (immediate STOP): a baseline pod gone or replaced
# (uid), restarted, Failed, or any consumer container waiting in a crash/create error. A pod already
# NotReady at baseline is not required to turn Ready (the move did not cause that), only to not get worse.
lh_consumer_verdict() {
  awk -F'\t' '
    function badreason(r,  n, a, i) { n = split(r, a, ","); for (i = 1; i <= n; i++) if (a[i] ~ /^(CreateContainerError|CreateContainerConfigError|CrashLoopBackOff|RunContainerError|Error)$/) return a[i]; return "" }
    FNR == NR { bu[$1] = $2; br[$1] = $5; bready[$1] = $4; next }
    { seen[$1] = 1; r = badreason($6)
      if (r != "") { bad = bad "pod " $1 " container waiting " r "; "; next }
      if ($3 == "Failed") { bad = bad "pod " $1 " Failed; "; next }
      if ($1 in bu) {
        if ($2 != bu[$1]) { bad = bad "pod " $1 " replaced (uid changed); "; next }
        if ($5 + 0 > br[$1] + 0) { bad = bad "pod " $1 " restarted (" br[$1] " → " $5 "); "; next }
        if ($3 == "Succeeded") next
        if (bready[$1] == "ready" && $4 != "ready") wait = wait "pod " $1 " not Ready; "
      } else if ($4 != "ready" && $3 != "Succeeded") wait = wait "pod " $1 " (new) not Ready; "
    }
    END {
      for (p in bu) if (!(p in seen)) bad = bad "pod " p " gone; "
      if (bad != "") { sub(/; $/, "", bad); print "bad\t" bad; exit 2 }
      if (wait != "") { sub(/; $/, "", wait); print "wait\t" wait; exit 1 }
    }' "$1" "$2"
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
# helm_begin <dir> <tf-name> <release> <ns> <sha> <from> <to> <cap-min> [<mode> <moves>] → the window,
# the lease, the baseline, `before` and the timeline. rc≠0 = not begun (the caller does NOT apply; what
# was opened is closed again here). Writes $dir/{window-id,lease-name,watch.pid,meta.tsv}.
# mode `apply` (default): the chart bracket in the mgmt-apply tick — lease expected-end = max-end = start
#   + cap_min. mode `engines`: the longhorn engine moves in their own unit (mgmt-helm-engines.sh) — the
#   lease RENEWS ON PROGRESS (§The lease, below): expected-end = start + one move budget + the tail;
#   max-end = start + <moves> × the move budget + the tail, fixed up front; the window likewise renews.
helm_begin() {
  local d="$1" name="$2" rel="$3" ns="$4" sha="$5" from="$6" to="$7" cap="$8" mode="${9:-apply}" moves="${10:-0}" wid lease now_ end maxend wmin by
  mkdir -p "$d"
  if [ "$mode" = engines ]; then
    end="$(_hdate "+$(helm_move_budget) seconds")"; maxend="$(_hdate "+$(( moves * HELM_ENGINE_TIMEOUT + HELM_TAIL )) seconds")"
    wmin="$(( $(helm_move_budget) / 60 + 30 ))"; by=mgmt-helm-engines
  else
    end="$(_hdate "+${cap} minutes")"; maxend="$end"; wmin="$(( cap + 30 ))"; by=mgmt-apply
  fi
  # (3) a lease of this release still standing — the previous actor's: live = in flight (not begun);
  # past due = its actor died or STOPPED unconfirmed → a STOP, never a silent refusal every tick
  helm_lease_check "$rel"; case $? in 1) log "helm: lease of $rel still in flight — not begun"; return 1 ;; 2) return 1 ;; esac
  _hwin open --reason "box helm $mode: helm_release.$name $from → $to (${sha:0:8}) — mgmt/scripts/mgmt-helm.sh, FU-301" \
    --alerts "$HELM_DECLARED_ALERTS" --minutes "$wmin" \
    --note "forward only: a bad verdict STOPS the box (lease kept, window kept, MgmtHelmApplyStopped) — nothing reverts" \
    >"$d/window-open.log" 2>&1 || { log "helm: window did not open"; return 1; }
  wid="$(sed -n 's/^✓ window \([^ ]*\) open .*/\1/p' "$d/window-open.log" | head -1)"
  [ -n "$wid" ] || { log "helm: window id unreadable"; return 1; }
  printf '%s' "$wid" >"$d/window-id"
  lease="upgrade-lease-tofu-helm-$rel"
  jq -n --arg n "$lease" --arg ns "$HELM_LEASE_NS" --arg l "$HELM_LEASE_LABEL" --arg subj "tofu/helm_release.$name" \
        --arg chart "$rel" --arg sha "$sha" --arg from "$from" --arg to "$to" --arg end "$end" --arg max "$maxend" --arg w "$wid" --arg by "$by" \
    '{apiVersion:"v1", kind:"ConfigMap", metadata:{name:$n, namespace:$ns, labels:{($l):"true"}},
      data:{subject:$subj, chart:$chart, sha:$sha, from:$from, to:$to, "expected-end":$end, "max-end":$max,
            by:$by, reason:("box helm bracket under window " + $w + " — forward only (FU-301): an expired lease here is a STOP, never a revert")}}' \
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$rel" "$ns" "$sha" "$from" "$to" "$mode" >"$d/meta.tsv"
  printf '%s' "$maxend" >"$d/max-end"
  log "helm: begun ($mode) — window $wid, lease $HELM_LEASE_NS/$lease (expected-end $end, max-end $maxend), record $d"
}

# ── 4 engines (longhorn) ─────────────────────────────────────────────────────────────────────────
# helm_lh_engines <dir> <ns> <order csv> → rc 0 every v1 volume on the manager's engine image; rc 2 the
# first volume that did not come back within HELM_ENGINE_TIMEOUT, or whose CONSUMER did not stay whole
# (helm_lh_consumer_wait), or a REFUSE before any move (lh_engine_refusals: a 1-replica attached volume
# wants the attended path) — its line in $d/engines.log; the rest are left where they are. One patch per
# volume, then READS only: a transient failure Longhorn recovers from inside the bound is a pass (logged
# with its wait), never a second patch.
helm_lh_engines() {
  local d="$1" ns="$2" order="$3" img v cls st t0 cur rob was seen pvc pns ref
  _hk -n "$ns" get ds longhorn-manager -o json >"$d/manager-ds.json" 2>/dev/null || { echo "manager DaemonSet unreadable" >>"$d/engines.log"; return 2; }
  img="$(lh_engine_image "$d/manager-ds.json")"
  [ -n "$img" ] || { echo "engine image unreadable from longhorn-manager" >>"$d/engines.log"; return 2; }
  # the new EngineImage must be deployed before a volume may move to it
  t0="$(_hnow)"
  until [ "$(_hk -n "$ns" get engineimages.longhorn.io -o json 2>/dev/null | jq -r --arg i "$img" '[.items[] | select(.spec.image == $i) | .status.state][0] // ""')" = deployed ]; do
    [ $(( $(_hnow) - t0 )) -lt "$HELM_ENGINE_IMAGE_TIMEOUT" ] || { echo "engine image $img not deployed within ${HELM_ENGINE_IMAGE_TIMEOUT}s" >>"$d/engines.log"; return 2; }
    _hsleep 15
  done
  _hk -n "$ns" get volumes.longhorn.io -o json >"$d/engines-volumes.json" 2>/dev/null || { echo "volumes unreadable" >>"$d/engines.log"; return 2; }
  lh_engine_plan "$d/engines-volumes.json" "$img" "$order" >"$d/engines.plan"
  echo "engine image $img — $(grep -c . "$d/engines.plan") volume(s) to move, order $order" >>"$d/engines.log"
  # the refusal comes BEFORE the first patch: nothing moves while the set holds a volume the box may not
  # move live — the operator decides the whole run (the conservative reading of the 2026-10-02 ruling)
  ref="$(lh_engine_refusals "$d/engines-volumes.json" "$img")"
  if [ -n "$ref" ]; then
    printf '%s\n' "$ref" | sed -E 's/^([^\t]*)\t/REFUSE \1: /' >>"$d/engines.log"
    echo "nothing moved — move the refused volume(s) attended (offline), then clear the stop" >>"$d/engines.log"
    return 2
  fi
  while IFS=$'\t' read -r v cls st; do
    [ -n "$v" ] || continue
    was="$(jq -r --arg v "$v" '.items[] | select(.metadata.name == $v) | .status.robustness // "?"' "$d/engines-volumes.json")"
    # the consumer's baseline BEFORE the patch (attached volumes only — a detached one has no consumer):
    # Longhorn's own record of the PVC, then the pods mounting it, read from the kube API
    pvc=""; pns=""; rm -f "$d/consumers-$v.base"
    if [ "$st" = attached ]; then
      IFS=$'\t' read -r pns pvc < <(jq -r --arg v "$v" '.items[] | select(.metadata.name == $v) | .status.kubernetesStatus // {} | "\(.namespace // "")\t\(.pvcName // "")"' "$d/engines-volumes.json")
      if [ -n "$pvc" ] && [ -n "$pns" ]; then
        _hk -n "$pns" get pods -o json >"$d/consumers-$v.json" 2>/dev/null \
          || { echo "FAIL $v ($cls, $st): consumer pods of $pns/$pvc unreadable before the move — not moved" >>"$d/engines.log"; return 2; }
        lh_consumers "$d/consumers-$v.json" "$pvc" | awk -F'\t' '$3 != "Succeeded" && $3 != "Failed"' >"$d/consumers-$v.base"
      else
        echo "note $v: attached, no PVC on Longhorn's record — consumer not checked" >>"$d/engines.log"
      fi
    fi
    _hk -n "$ns" patch volumes.longhorn.io "$v" --type merge -p "{\"spec\":{\"image\":\"$img\"}}" >/dev/null 2>&1 \
      || { echo "FAIL $v ($cls, $st): patch refused" >>"$d/engines.log"; return 2; }
    t0="$(_hnow)"; seen=""
    while :; do
      cur="$(_hk -n "$ns" get volumes.longhorn.io "$v" -o jsonpath='{.status.currentImage}|{.status.robustness}' 2>/dev/null)"
      rob="${cur#*|}"; cur="${cur%%|*}"
      # a read that is not yet there is recorded once per distinct shape (the breakage data), never acted on
      case " $seen " in *" ${cur##*:}/${rob:-?} "*) ;; *) [ "$cur" = "$img" ] && [ "$rob" = healthy ] || seen="${seen:+$seen }${cur##*:}/${rob:-?}" ;; esac
      # back where it was: on the new image, and healthy again if it was healthy (a detached volume
      # reads `unknown` before and after)
      if [ "$cur" = "$img" ] && { [ "$was" != healthy ] || [ "$rob" = healthy ]; }; then
        echo "ok   $v ($cls, $st) → $img [$was → $rob] $(( $(_hnow) - t0 ))s${seen:+ (converged by itself after: $seen)}" >>"$d/engines.log"
        helm_lease_renew "$d" || echo "WARN lease renewal after $v failed — the lease may expire (a STOP, the safe side)" >>"$d/engines.log"
        if [ -s "$d/consumers-$v.base" ]; then helm_lh_consumer_wait "$d" "$v" "$cls" "$st" "$pns" "$pvc" || return 2; fi
        break
      fi
      [ $(( $(_hnow) - t0 )) -lt "$HELM_ENGINE_TIMEOUT" ] || { echo "FAIL $v ($cls, $st): image=$cur robustness=$rob after ${HELM_ENGINE_TIMEOUT}s" >>"$d/engines.log"; return 2; }
      _hsleep 10
    done
  done <"$d/engines.plan"
  return 0
}

# helm_lh_consumer_wait <dir> <vol> <class> <state> <pod-ns> <pvc> → rc 0 every pod that mounted <pvc> before
# the move stayed whole for HELM_CONSUMER_SOAK s; rc 2 (a FAIL line naming the volume and the pod) on the
# first bad read (restart, replaced/gone, crash/create error) or NotReady past HELM_CONSUMER_TIMEOUT.
# Reads only. An unreadable pod list is waited like NotReady (and is a FAIL at the bound).
helm_lh_consumer_wait() {
  local d="$1" v="$2" cls="$3" st="$4" pns="$5" pvc="$6" t0 out rc el
  t0="$(_hnow)"
  while :; do
    el=$(( $(_hnow) - t0 ))
    if _hk -n "$pns" get pods -o json >"$d/consumers-$v.now.json" 2>/dev/null; then
      lh_consumers "$d/consumers-$v.now.json" "$pvc" >"$d/consumers-$v.now"
      out="$(lh_consumer_verdict "$d/consumers-$v.base" "$d/consumers-$v.now")"; rc=$?
    else out="wait"$'\t'"pods of $pns unreadable"; rc=1; fi
    if [ "$rc" = 2 ]; then
      echo "FAIL $v ($cls, $st): consumer of $pns/$pvc broke after the move — ${out#*$'\t'} (Longhorn read converged; ${el}s after)" >>"$d/engines.log"; return 2
    fi
    if [ "$rc" = 0 ] && [ "$el" -ge "$HELM_CONSUMER_SOAK" ]; then
      echo "consumer-ok $v: $pns/$pvc — $(cut -f1 "$d/consumers-$v.base" | tr '\n' ' ' | sed 's/ $//') whole for ${el}s" >>"$d/engines.log"; return 0
    fi
    [ "$el" -lt "$HELM_CONSUMER_TIMEOUT" ] || { echo "FAIL $v ($cls, $st): consumer of $pns/$pvc not whole within ${HELM_CONSUMER_TIMEOUT}s — ${out#*$'\t'}" >>"$d/engines.log"; return 2; }
    _hsleep 10
  done
}

# ── the engine moves: their own unit (FU-301, operator 2026-10-10) ───────────────────────────────
# helm_lh_drift <policy> <root> → prints "<n>\t<ns>\t<chart-version>\t<order>\t<cap>" when the longhorn row
# exists and n > 0 v1 volumes are not on the manager's `--engine-image`; nothing when there is nothing to
# move; rc 1 = a read failed. Cheap enough for every apply tick (two kubectl reads).
helm_lh_drift() {
  local pol="$1" root="$2" row ns ver img n t st
  row="$(mgmt_helm_row "$pol" "$root" helm_release.longhorn)" || return 1
  [ -n "$row" ] || return 0
  st="$(_hstate)"
  ns="$(jq -r '.resources[]? | select(.type == "helm_release" and .name == "longhorn") | .instances[0].attributes.namespace // empty' "$st" 2>/dev/null)"
  ver="$(jq -r '.resources[]? | select(.type == "helm_release" and .name == "longhorn") | .instances[0].attributes.metadata.version // empty' "$st" 2>/dev/null)"
  [ -n "$ns" ] && [ -n "$ver" ] || return 1
  t="$(mktemp -d)"
  _hk -n "$ns" get ds longhorn-manager -o json >"$t/ds.json" 2>/dev/null && _hk -n "$ns" get volumes.longhorn.io -o json >"$t/v.json" 2>/dev/null \
    || { rm -rf "$t"; return 1; }
  img="$(lh_engine_image "$t/ds.json")"; [ -n "$img" ] || { rm -rf "$t"; return 1; }
  n="$(lh_engine_plan "$t/v.json" "$img" "x" | grep -c .)"; rm -rf "$t"
  [ "$n" -gt 0 ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$ns" "$ver" "$(jq -r '(.engine_order // []) | join(",")' <<<"$row")" "$(jq -r '.cap_min // 120' <<<"$row")"
}
# helm_lh_engines_run <policy> <root> <sha> → the engine bracket (mgmt-helm-engines.sh's body): rc 0 nothing
# to do or CONFIRMED; rc 2 STOPPED (marker); rc 1 not begun (a read failed, a window holds, a live lease).
# A STOP marker keeps it shut until a person removes it — the box never retries on its own.
helm_lh_engines_run() {
  local pol="$1" root="$2" sha="$3" dr n ns ver order cap d
  [ -s "$ADIR/helm-stopped" ] && { log "helm: engines — STOP marker stands; nothing moves until a human clears it"; return 0; }
  dr="$(helm_lh_drift "$pol" "$root")" || { log "helm: engines — drift read failed"; return 1; }
  [ -n "$dr" ] || return 0
  IFS=$'\t' read -r n ns ver order cap <<<"$dr"
  d="$HELM_EVIDENCE_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-box-longhorn-engines-$ver"
  log "helm: engines — $n v1 volume(s) not on the manager's engine under longhorn $ver; moves only, no apply"
  helm_begin "$d" longhorn longhorn "$ns" "$sha" "$ver" "$ver" "$cap" engines "$n" || { [ -s "$ADIR/helm-stopped" ] && return 2; return 1; }
  helm_end "$d" 0 "$order"
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
  local mode
  IFS=$'\t' read -r name rel ns sha from to mode <"$d/meta.tsv"
  wid="$(cat "$d/window-id")"; lease="$(cat "$d/lease-name")"
  # the engine moves run in their OWN bracket and unit (mgmt-helm-engines.sh), never inside the apply tick
  if [ "$arc" = 0 ] && [ "${mode:-apply}" = engines ]; then helm_lh_engines "$d" "$ns" "$order" || erc=2; fi
  _hsleep "$HELM_SETTLE"
  pid="$(cat "$d/watch.pid" 2>/dev/null)"; [ -n "$pid" ] && { _hkilltree "$pid"; wait "$pid" 2>/dev/null; }
  _hev snapshot >"$d/after.json" 2>"$d/after.err" || true
  helm_cluster_verdict "$d" "$rel" || vrc=2
  [ "$arc" = 0 ] || echo "apply: tofu apply exited $arc" >>"$d/verdict.txt"
  [ "$erc" = 0 ] || grep '^FAIL\|^REFUSE\|unreadable\|not deployed' "$d/engines.log" | sed 's/^/engines: /' >>"$d/verdict.txt"
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
