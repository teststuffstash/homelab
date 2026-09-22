#!/usr/bin/env bash
# mgmt-rollout-evidence — has <node> been EXERCISED on its current install since <since>?
# The rollout policy's soak predicate (docs/management-box.md §MB4 "The rollout policy", FU-273):
# a canary stage ends when the node has carried its own kind of work on the new version, never
# when a clock runs out. Time passing on an idle node proves nothing.
#
#   scripts/mgmt-rollout-evidence.sh <node> <since-unix-ts>
#
# Exit 0 = exercised · 1 = not yet · 2 = cannot tell (a read failed — the caller treats it as
# "not yet" and asks again). ONE line on stdout: what was found, or what is still missing.
# The timeout is the CALLER's (the reconciler); this script only answers the question once.
# Read-only by construction: kubectl get, talosctl service/etcd status, Prometheus queries.
#
# THE TYPE comes from live facts, never a node list — a node can have several, and all apply:
#   cp        label node-role.kubernetes.io/control-plane
#             → its etcd service Running+healthy, its member a voter with no errors (talosctl), and
#               its kube-apiserver static pod Ready AND answering /readyz on the node's own IP
#   arc       label homelab.io/ephemeral=true (what the ARC scale set selects on) AND the node ran
#             ≥ TYPE_MIN ARC runner pods in the TYPE_LOOKBACK before <since> — a label alone does
#             not make a node carry CI (the scheduler decides), and an untested type would stall
#             → ≥1 GitHub Actions job concluded `success` on a runner POD placed on this node,
#               completed after <since> (github_ci_job_completed_timestamp{runner_name} — the
#               exporter's /jobs read — joined to kube_pod_info{node}; the runner pod itself is
#               deleted seconds after its job, so kube-state-metrics alone misses most of them)
#   ride      the node ran ≥ TYPE_MIN worker rides in the lookback — a ride is the controller-less
#             `agent-<project>-…` pod agents/agent-session.sh names (kube-state-metrics exports no
#             pod labels, so the launcher's name IS the selector). Coordinator/reviewer pods are
#             controller-less too but are not the ride tier: measured 2026-09-22, they land on the
#             regular workers, where they would make every worker wait on the agent loop's pace
#             → ≥1 ride CREATED after <since> reached phase Succeeded on this node
#   longhorn  a Longhorn replica CR is placed on the node (any state)
#             → ≥1 replica here running on a `healthy` volume AND either rebuilt since <since>
#               (spec.healthyAt) or REUSED across the reboot under an instance-manager pod of the
#               node's current boot (started ≥ min(<since>, the node's Ready lastTransitionTime))
#   garage    the node is a Garage zone (cluster_layout_node_connected{role_zone=<node>})
#             → the zone connected in EVERY peer's view for the last 10 minutes
#   worker    none of the above and not a control plane
#             → ≥1 non-DaemonSet pod scheduled here after <since> that is Ready (or Succeeded)
#
# Where it runs: ON THE MANAGEMENT BOX (repo at /var/lib/homelab, client configs in /var/lib/mgmt/)
# and in the jail — kubectl/talosctl/jq/curl on PATH (`devbox run -- bash scripts/…`).
# Env (test seams + tuning):
#   EVIDENCE_PROM          Prometheus base URL (default NM_PROM, else http://192.168.40.13:9090)
#   EVIDENCE_PROM_CMD      command run as `<cmd> <query> <eval-ts>` printing the /api/v1/query JSON
#                          (the fixture test's fake Prometheus); default curl against EVIDENCE_PROM
#   EVIDENCE_KUBECTL / EVIDENCE_TALOSCTL   the binaries (default kubectl / talosctl)
#   EVIDENCE_NOW           "now" as a unix ts (default: the clock)
#   EVIDENCE_TYPE_LOOKBACK seconds of history before <since> that decide arc/ride (default 604800 = 7 d)
#   EVIDENCE_TYPE_MIN      pods in that lookback that make the type (default 14 = two a day: a node
#                          that sees a ride every few days would hold its stage for days)
#   EVIDENCE_EXPORTER_MAX_AGE  a github-exporter whose last full poll is older (s) is a read
#                          failure for the arc type, not a "no job yet" (default 900)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$REPO/tofu/kubeconfig}"
TALOSCONFIG="${TALOSCONFIG:-$REPO/tofu/talosconfig}"
# ON THE MANAGEMENT BOX the client configs live in /var/lib/mgmt/, and `devbox run` exports
# devbox.json's KUBECONFIG/TALOSCONFIG=$PWD/tofu/* regardless — a path that does not exist there.
# So a configured path that does not exist yields to the box's copy (node-maintenance.sh's lines).
[ -f "$KUBECONFIG" ] || { [ -f /var/lib/mgmt/kubeconfig ] && export KUBECONFIG=/var/lib/mgmt/kubeconfig; }
[ -f "$TALOSCONFIG" ] || { [ -f /var/lib/mgmt/talosconfig ] && TALOSCONFIG=/var/lib/mgmt/talosconfig; }
export TALOSCONFIG

PROM="${EVIDENCE_PROM:-${NM_PROM:-http://192.168.40.13:9090}}"
KUBECTL="${EVIDENCE_KUBECTL:-kubectl}"
TALOSCTL="${EVIDENCE_TALOSCTL:-talosctl}"
NOW="${EVIDENCE_NOW:-$(date +%s)}"
TYPE_LOOKBACK="${EVIDENCE_TYPE_LOOKBACK:-604800}"
TYPE_MIN="${EVIDENCE_TYPE_MIN:-14}"
EXPORTER_MAX_AGE="${EVIDENCE_EXPORTER_MAX_AGE:-900}"

NODE="${1:-}"; SINCE="${2:-}"
if [ -z "$NODE" ] || ! [[ "$SINCE" =~ ^[0-9]+$ ]] || [ "$SINCE" -gt "$NOW" ]; then
  echo "usage: mgmt-rollout-evidence.sh <node> <since-unix-ts> (since must not be in the future) — got '${NODE}' '${SINCE}'"
  exit 2
fi
# The evidence window, as a PromQL range: <since> → now, plus a scrape of slack.
RANGE="$(( NOW - SINCE + 120 ))s"

# ── readers: each prints its payload, returns non-zero on ANY read failure (never an empty "0") ──
prom() {  # <query> [eval-ts] → the .data.result array
  local out
  if [ -n "${EVIDENCE_PROM_CMD:-}" ]; then out="$($EVIDENCE_PROM_CMD "$1" "${2:-$NOW}")" || return 1
  else out="$(curl -sS --max-time 20 --data-urlencode "query=$1" --data-urlencode "time=${2:-$NOW}" \
                   "$PROM/api/v1/query")" || return 1; fi
  jq -ce 'select(.status == "success") | .data.result' <<<"$out" 2>/dev/null
}
prom_count() {  # <query> [ts] → the scalar of a count(...) query; an empty result is 0
  local r; r="$(prom "$@")" || return 1
  jq -r '(.[0].value[1] // "0") | tonumber | floor' <<<"$r"
}

ERR=0; MISS=0; NOTES=()
have() { NOTES+=("$1: $2"); }
miss() { NOTES+=("$1: NOT YET — $2"); MISS=1; }
cant() { NOTES+=("$1: CANNOT TELL — $2"); ERR=1; }
finish() {
  local verdict rc
  if [ "$ERR" = 1 ]; then verdict="CANNOT TELL"; rc=2
  elif [ "$MISS" = 1 ]; then verdict="NOT YET"; rc=1
  else verdict="EXERCISED"; rc=0; fi
  local IFS=';'
  echo "$NODE ${verdict} since $(date -u -d "@$SINCE" +%FT%TZ) [${TYPES:-?}] — ${NOTES[*]}" | sed 's/;/; /g'
  exit "$rc"
}

# ── the node ────────────────────────────────────────────────────────────────────────────────────
nj="$($KUBECTL get node "$NODE" -o json 2>/dev/null)" && jq -e '.kind == "Node"' >/dev/null 2>&1 <<<"$nj" \
  || { cant node "kubectl get node $NODE failed (unregistered, or the API unreachable)"; finish; }
IP="$(jq -r '[.status.addresses[]? | select(.type == "InternalIP") | .address][0] // ""' <<<"$nj")"
label() { jq -r --arg k "$1" '.metadata.labels[$k] // empty' <<<"$nj"; }
is_cp=0;  jq -e '.metadata.labels | has("node-role.kubernetes.io/control-plane")' >/dev/null <<<"$nj" && is_cp=1

# Longhorn replicas are read once: they classify AND evidence the longhorn type. The dumps are
# megabytes — they go through FILES, never argv ("Argument list too long", node-maintenance.sh).
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
$KUBECTL -n longhorn-system get replicas.longhorn.io -o json >"$TMP/reps.json" 2>/dev/null \
  && jq -e '.items | type == "array"' "$TMP/reps.json" >/dev/null 2>&1 \
  || { cant longhorn "cannot list Longhorn replicas"; echo '{"items":[]}' >"$TMP/reps.json"; }
lh_here="$(jq --arg n "$NODE" '[.items[] | select(.spec.nodeID == $n)] | length' "$TMP/reps.json")"

TYPES_A=()
[ "$is_cp" = 1 ] && TYPES_A+=(cp)
if [ "$(label homelab.io/ephemeral)" = true ]; then
  if h="$(prom_count "count(max by (uid) (max_over_time(kube_pod_info{namespace=\"arc-runners\",created_by_kind=\"EphemeralRunner\",node=\"$NODE\"}[${TYPE_LOOKBACK}s])))" "$SINCE")"; then
    [ "$h" -ge "$TYPE_MIN" ] && TYPES_A+=(arc)
  else cant arc "cannot read the ARC history (Prometheus at $PROM)"; fi
fi
if h="$(prom_count "count(max by (uid) (max_over_time(kube_pod_info{created_by_kind=\"\",pod=~\"agent-.+\",node=\"$NODE\"}[${TYPE_LOOKBACK}s])))" "$SINCE")"; then
  [ "$h" -ge "$TYPE_MIN" ] && TYPES_A+=(ride)
else cant ride "cannot read the ride history (Prometheus at $PROM)"; fi
[ "$lh_here" -gt 0 ] && TYPES_A+=(longhorn)
if z="$(prom_count "count(cluster_layout_node_connected{role_zone=\"$NODE\"})")"; then
  [ "$z" -gt 0 ] && TYPES_A+=(garage)
else cant garage "cannot read the Garage layout (Prometheus at $PROM)"; fi
[ "${#TYPES_A[@]}" -eq 0 ] && TYPES_A+=(worker)
TYPES="$(IFS=,; echo "${TYPES_A[*]}")"
has_type() { [[ ",$TYPES," == *",$1,"* ]]; }

# ── cp: etcd member healthy + apiserver serving ─────────────────────────────────────────────────
if has_type cp; then
  if [ -z "$IP" ]; then cant cp "no InternalIP on the node"
  elif ! svc="$($TALOSCTL -n "$IP" service etcd 2>/dev/null)"; then cant cp "talosctl service etcd on $IP failed"
  elif ! st="$($TALOSCTL -n "$IP" etcd status 2>/dev/null)"; then cant cp "talosctl etcd status on $IP failed"
  else
    state="$(awk '$1 == "STATE" {print $2}' <<<"$svc")"; health="$(awk '$1 == "HEALTH" {print $2}' <<<"$svc")"
    # Columns by HEADER POSITION — values contain spaces ("97 MB (34.02%)"), and ERRORS is the
    # last column, empty when healthy.
    read -r learner errors < <(awk 'NR == 1 {l = index($0, "LEARNER"); e = index($0, "ERRORS"); next}
      NR == 2 {le = substr($0, l); split(le, a, " "); er = substr($0, e); gsub(/^ +| +$/, "", er);
               print a[1], (er == "" ? "-" : er); exit}' <<<"$st")
    rp="$($KUBECTL -n kube-system get pod "kube-apiserver-$NODE" -o json 2>/dev/null \
          | jq -r '[.status.conditions[]? | select(.type == "Ready")][0].status // "absent"')"
    rz="$($KUBECTL --server "https://$IP:6443" get --raw /readyz 2>/dev/null)"
    if [ "$state" != Running ] || [ "$health" != OK ]; then miss cp "etcd service $state/$health"
    elif [ "$learner" != false ]; then miss cp "etcd member is a learner or absent (LEARNER=${learner:-?})"
    elif [ "$errors" != - ]; then miss cp "etcd reports errors: $errors"
    elif [ "$rp" != True ]; then miss cp "kube-apiserver-$NODE Ready=$rp"
    elif [ "$rz" != ok ]; then miss cp "apiserver on $IP:6443 /readyz answered '${rz:-nothing}'"
    else have cp "etcd voter healthy, apiserver Ready and /readyz ok on $IP"; fi
  fi
fi

# ── arc: a successful job on a runner pod placed here ───────────────────────────────────────────
# The join runs IN Prometheus (runner_name == the runner pod's name), so only the jobs that ran
# here come back.
if has_type arc; then
  here="label_replace(max by (pod) (max_over_time(kube_pod_info{namespace=\"arc-runners\",created_by_kind=\"EphemeralRunner\",node=\"$NODE\"}[$RANGE])), \"runner_name\", \"\$1\", \"pod\", \"(.*)\")"
  if ! fresh="$(prom "time() - max(github_exporter_last_success_timestamp)")" \
     || ! fam="$(prom_count "count(max_over_time(github_ci_job_completed_timestamp[1d]))")" \
     || ! jobs="$(prom "(max by (runner_name, repo, job, run_id) (max_over_time(github_ci_job_completed_timestamp{conclusion=\"success\"}[$RANGE])) >= $SINCE) and on (runner_name) $here")" \
     || ! npods="$(prom_count "count($here)")"; then
    cant arc "Prometheus at $PROM unreadable"
  elif ! age="$(jq -er '.[0].value[1] | tonumber | floor' <<<"$fresh" 2>/dev/null)" || [ "$fam" -eq 0 ]; then
    cant arc "no github-exporter job-completion series (exporter down, or older than FU-273) — no job read is possible"
  else
    hit="$(jq -r 'sort_by(.value[1] | tonumber)
      | if length == 0 then "" else "\(length) job(s), latest \(.[-1].metric.repo)/\(.[-1].metric.job) run \(.[-1].metric.run_id) on \(.[-1].metric.runner_name)" end' <<<"$jobs")"
    if [ -n "$hit" ]; then have arc "$hit succeeded"
    # A stale exporter cannot say "no job" — its absence of evidence is a read failure.
    elif [ "$age" -ge "$EXPORTER_MAX_AGE" ]; then cant arc "github-exporter last full poll ${age}s ago — no job seen, but it may just not have been read"
    else miss arc "no successful GitHub Actions job on a runner pod here since then ($npods runner pod(s) placed here)"; fi
  fi
fi

# ── ride: a ride created after <since> finished Succeeded here ──────────────────────────────────
if has_type ride; then
  if r="$(prom "max by (namespace, pod) (
        max by (uid, namespace, pod) (max_over_time(kube_pod_info{created_by_kind=\"\",pod=~\"agent-.+\",node=\"$NODE\"}[$RANGE]))
        and on (uid) (max by (uid) (max_over_time(kube_pod_status_phase{phase=\"Succeeded\"}[$RANGE])) == 1)
        and on (uid) (max by (uid) (max_over_time(kube_pod_created[$RANGE])) >= $SINCE))")"; then
    n="$(jq length <<<"$r")"
    if [ "$n" -gt 0 ]; then have ride "$n ride(s) Succeeded, e.g. $(jq -r '.[0].metric | "\(.namespace)/\(.pod)"' <<<"$r")"
    else miss ride "no ride created since then has Succeeded here"; fi
  else cant ride "Prometheus at $PROM unreadable"; fi
fi

# ── longhorn: a replica here serving on the new install, its volume healthy ─────────────────────
# Two ways a replica proves the node's storage path works on the new install: it was REBUILT since
# <since> (healthyAt), or Longhorn REUSED it across the reboot — then healthyAt keeps its old date
# (wk-metal-04, 2026-09-22: 6 healthy replicas, healthyAt 09-09/09-16) — and it runs under an
# instance-manager pod of the node's CURRENT boot. The caller asks only about a node it verified on
# the target, so the current boot IS the new install; but <since> is the sync's END and the upgrade
# verb waits for Longhorn before ending, so that instance-manager always starts BEFORE <since>. The
# boot marker is the node's Ready lastTransitionTime: threshold = min(<since>, that). An unreadable
# instance-manager list falls back to the rebuilt-only rule (never a success-shaped 0).
if has_type longhorn; then
  im_new=false
  boot="$(jq -r '[.status.conditions[]? | select(.type == "Ready") | .lastTransitionTime // empty | fromdateiso8601][0] // empty' <<<"$nj" 2>/dev/null)"
  imfloor="$SINCE"; [ -n "$boot" ] && [ "$boot" -lt "$SINCE" ] && imfloor="$boot"
  if $KUBECTL -n longhorn-system get pods -l longhorn.io/component=instance-manager \
       --field-selector "spec.nodeName=$NODE" -o json >"$TMP/im.json" 2>/dev/null; then
    im_new="$(jq -r --argjson s "$imfloor" '[.items[]? | .status.startTime // empty | fromdateiso8601 | select(. >= $s)] | length > 0' "$TMP/im.json" 2>/dev/null || echo false)"
  fi
  if $KUBECTL -n longhorn-system get volumes.longhorn.io -o json >"$TMP/vols.json" 2>/dev/null \
     && jq -e '.items | type == "array"' "$TMP/vols.json" >/dev/null 2>&1; then
    ok="$(jq -rn --slurpfile R "$TMP/reps.json" --slurpfile V "$TMP/vols.json" --arg n "$NODE" --argjson s "$SINCE" --argjson imnew "$im_new" '
      ($R[0]) as $r | ($V[0]) as $v
      | ($v.items | map({key: .metadata.name, value: (.status.robustness // "")}) | from_entries) as $rob
      | [$r.items[] | select(.spec.nodeID == $n and .status.currentState == "running"
          and $rob[.spec.volumeName] == "healthy"
          and ($imnew or (((.spec.healthyAt // "") != "") and ((.spec.healthyAt | fromdateiso8601) >= $s))))
          | .spec.volumeName]
      | if length == 0 then "" elif $imnew then "\(length) replica(s) healthy under the instance-manager of the current boot, e.g. \(.[0])"
        else "\(length) replica(s) rebuilt/healthy, e.g. \(.[0])" end')"
    if [ -n "$ok" ]; then have longhorn "$ok"
    else miss longhorn "none of the $lh_here replica(s) here is running+healthy since then on a healthy volume"; fi
  else cant longhorn "cannot list Longhorn volumes"; fi
fi

# ── garage: the zone connected in every peer's view, for the last 10 minutes ────────────────────
if has_type garage; then
  if g="$(prom "min(min_over_time(cluster_layout_node_connected{role_zone=\"$NODE\"}[10m]))")"; then
    v="$(jq -r '.[0].value[1] // "absent"' <<<"$g")"
    if [ "$v" = 1 ]; then have garage "zone $NODE connected (every peer, 10 min)"
    else miss garage "zone $NODE not connected in every peer's view for 10 min (min=$v)"; fi
  else cant garage "Prometheus at $PROM unreadable"; fi
fi

# ── worker: a non-DaemonSet pod scheduled after <since> reached Ready ──────────────────────────
if has_type worker; then
  if pj="$($KUBECTL get pods -A --field-selector "spec.nodeName=$NODE" -o json 2>/dev/null)"; then
    w="$(jq -r --argjson s "$SINCE" '
      [.items[] | select(((.metadata.ownerReferences // [])[0].kind // "") | IN("DaemonSet", "Node") | not)
        | select(([.status.conditions[]? | select(.type == "PodScheduled")][0].lastTransitionTime // .metadata.creationTimestamp
                  | fromdateiso8601) >= $s)
        | select(.status.phase == "Succeeded"
                 or ([.status.conditions[]? | select(.type == "Ready")][0].status == "True"))
        | "\(.metadata.namespace)/\(.metadata.name)"]
      | if length == 0 then "" else "\(length) pod(s), e.g. \(.[0])" end' <<<"$pj")"
    if [ -n "$w" ]; then have worker "$w scheduled since then and Ready"
    else miss worker "no non-DaemonSet pod scheduled here since then has reached Ready"; fi
  else cant worker "cannot list the pods on $NODE"; fi
fi

finish
