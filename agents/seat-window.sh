#!/usr/bin/env bash
# seat-window — the DECLARED change window (FU-230 leg b).
#
#   bash agents/seat-window.sh open  --reason "<what you are doing>" --alerts A,B,C [--node <n>] [--hours N] [--note "<s>"] [--admit-reconciler]
#   bash agents/seat-window.sh close [--id <id>] [--node <n> [--by <who>]] [--all]
#   bash agents/seat-window.sh has --node <n> --by <who>     # exit 0 iff such a live window exists
#   bash agents/seat-window.sh list
#
# A SECOND READER, and it treats the record as a mutex (a sign on the door — not a lock: `open` is
# a blind merge patch, and a person who declares nothing is invisible). The box's node reconciler
# (scripts/mgmt-reconcile.sh) refuses to open a window while ANY live window is declared — on
# another node, seat-wide, or on its target. `--admit-reconciler` (needs `--node`) is the one
# exception: "I am watching this node, the reconciler may act on it inside my window" — the
# attended canary. Without it, a seat's hands-on work on a node is never interrupted by a sync.
#
# WHY THIS EXISTS, and why it is not a silence. FU-230 leg (a) — `node-maintenance.sh` opening
# Alertmanager silences — removed most of the maintenance-storm noise by matching on `node`,
# `instance`, the node's pod names and (on a zone node) the Garage health set. It leaks one class
# structurally, and the leak is not fixable by adding arms:
#
#   2026-09-16 08:08:46Z — an `nx-01` wipe+reinstall window silenced all four matchers, and
#   `KubeDaemonSetRolloutStuck` fired anyway. That alert is labelled by namespace + daemonset: it
#   carries NEITHER `node` NOR `instance`, and the pod that went Pending (`cilium-przdf`) was
#   MINTED AFTER the silence, so the pod-name arm held only its predecessors. Every key the
#   taxonomy can match on is absent by construction, so ANY multi-reboot window leaks it. The same
#   evening, wk-03's shutdown leaked `CiliumUnreachableNodes` ×11, `KubeDaemonSetRolloutStuck` /
#   `MisScheduled` ×8, `KubeNodeUnreachable`, `KubeletInstanceUnreachable` and `KubePodNotReady` ×4
#   — the seat silenced them by hand for 8 h.
#
# So this leg matches on the DECLARED WINDOW instead of on labels the alert does not carry
# (`docs/spikes/responder-week-audit.md` §Design read, leg 2): the seat says what it is doing and
# WHICH ALERT NAMES to expect, and the responder reads that record. Enumerating `daemonset=~…`
# arms per alert name is the losing game the 09-16 sighting demonstrates.
#
# THREE PROPERTIES, each deliberate:
#   • It is a k8s ConfigMap, not an Alertmanager silence — so it survives a monitoring restart,
#     which silences do not (FU-195: the alertmanager-db is a bare emptyDir).
#   • It scopes by ALERT NAME, never by namespace. A whole-namespace mute would have hidden the
#     REAL findings of the rf=3 rollout (garage-2 flapping, the write-probe 400s) — the operator's
#     own boundary on this leg.
#   • It does NOT silence Alertmanager. The alert still fires, still reaches Home Assistant and
#     Grafana, and an operator still sees it. What the window suppresses is the LLM TRIAGE — the
#     thing that costs a budget slot to conclude "a person did this".
#
# An alert OUTSIDE the declared set still triages, and the brief is told a window is open — the
# other half of FU-230, since 7 of the 9 confidently-wrong writes in the 09-04→11 audit had a cause
# the seat made outside the cluster's view (a maintenance window, a PVC re-cut, a belt shipped 30
# minutes earlier) and the session filled the gap with a plausible story instead of "unknown".
set -euo pipefail

NS="${SEAT_WINDOW_NS:-agent-coordinator}"
CM="${SEAT_WINDOW_CM:-responder-window}"
HOURS="${SEAT_WINDOW_HOURS:-3}"
BY="${SEAT_WINDOW_BY:-${USER:-seat}}"

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${HERE}/../tofu/kubeconfig" ]; then KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"; else KUBE=""; fi
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"
kubectl() { "$KUBECTL" $KUBE "$@"; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 64; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# The live set: every entry whose `until` is still in the future. ISO-8601 with a Z suffix sorts
# lexicographically, so the comparison needs no date parsing in jq.
live_windows() {
  kubectl -n "$NS" get cm "$CM" -o json 2>/dev/null \
    | jq -c --arg now "$(now_iso)" '[ (.data // {}) | to_entries[] | (.value | fromjson?) // empty
                                      | select((.until // "") > $now) ]' 2>/dev/null \
    || printf '[]'
}

cmd_open() {
  local reason="" alerts="" node="" note="" hours="$HOURS" admit=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --admit-reconciler) admit=true; shift ;;
      --reason) reason="${2:-}"; shift 2 ;;
      --alerts) alerts="${2:-}"; shift 2 ;;
      --node)   node="${2:-}";   shift 2 ;;
      --note)   note="${2:-}";   shift 2 ;;
      --hours)  hours="${2:-}";  shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$reason" ] || die "--reason is required: the window record exists to tell a triage session what a person is doing"
  [ -n "$alerts" ] || die "--alerts is required: a window with no declared alert names suppresses nothing (and a namespace-wide mute is deliberately not offered)"
  [ "$admit" = false ] || [ -n "$node" ] || die "--admit-reconciler needs --node: it admits the reconciler to ONE node, never the fleet"
  local id until_ body
  # The suffix: two opens in one second must not share a key — the merge patch would silently
  # overwrite the first record (a seat window and node-maintenance.sh's, 2026-09-22).
  id="${node:-seat}-$(date -u +%s)-$((RANDOM % 10000))"
  until_="$(date -u -d "+${hours} hours" +%Y-%m-%dT%H:%M:%SZ)"
  body="$(jq -cn --arg id "$id" --arg by "$BY" --arg opened "$(now_iso)" --arg until "$until_" \
                 --arg reason "$reason" --arg node "$node" --arg note "$note" --arg alerts "$alerts" \
                 --argjson admit "$admit" \
    '{id:$id, by:$by, opened_at:$opened, until:$until, reason:$reason, node:$node, note:$note,
      admit_reconciler:$admit,
      alerts:($alerts | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0)))}')"
  kubectl -n "$NS" get cm "$CM" >/dev/null 2>&1 || kubectl -n "$NS" create cm "$CM" >/dev/null
  kubectl -n "$NS" patch cm "$CM" --type merge -p "$(jq -cn --arg k "w-$id" --arg v "$body" '{data:{($k):$v}}')" >/dev/null
  printf '✓ window %s open until %s — %s\n' "$id" "$until_" "$reason"
  printf '  alerts: %s%s\n' "$(printf '%s' "$body" | jq -r '.alerts | join(", ")')" "${node:+  (node $node)}"
  [ "$admit" = true ] && printf '  the box reconciler MAY sync %s inside this window (--admit-reconciler)\n' "$node"
  printf '  the responder skips a triage for those names while it is open; everything else still triages, with the window named in its brief.\n'
}

cmd_close() {
  local id="" node="" by="" all=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id="${2:-}"; shift 2 ;;
      --node) node="${2:-}"; shift 2 ;;
      --by) by="${2:-}"; shift 2 ;;
      --all) all=1; shift ;;
      *) usage ;;
    esac
  done
  # --by narrows a --node close to ONE writer's records: a tool closes what it opened, never a
  # seat's window on the same node (node-maintenance.sh, 2026-09-22: it removed the seat's
  # admitting window at the end of every sync).
  local keys
  keys="$(kubectl -n "$NS" get cm "$CM" -o json 2>/dev/null \
    | jq -r --arg id "$id" --arg node "$node" --arg by "$by" --argjson all "$all" '
        (.data // {}) | to_entries[]
        | . as $e | ($e.value | fromjson?) // empty
        | select($all == 1 or ($id != "" and .id == $id)
                 or ($node != "" and .node == $node and ($by == "" or .by == $by)))
        | $e.key' 2>/dev/null || true)"
  [ -n "$keys" ] || { printf 'no matching window to close\n'; return 0; }
  local k n=0
  for k in $keys; do
    # A closed window is REMOVED, not expired-in-place: the record's only readers ask "is a window
    # open now", and a graveyard of closed entries would grow the ConfigMap without a reader.
    kubectl -n "$NS" patch cm "$CM" --type json -p "$(jq -cn --arg p "/data/$k" '[{op:"remove", path:$p}]')" >/dev/null 2>&1 \
      && n=$((n+1)) || printf '⚠ could not remove %s (it self-expires at its `until`)\n' "$k"
  done
  printf '✓ closed %d window(s)\n' "$n"
}

cmd_has() {
  local node="" by=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --node) node="${2:-}"; shift 2 ;;
      --by) by="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$node" ] && [ -n "$by" ] || die "has needs --node and --by"
  live_windows | jq -e --arg n "$node" --arg b "$by" 'any(.[]; .node == $n and .by == $b)' >/dev/null
}

cmd_list() {
  local live
  live="$(live_windows)"
  [ "$(printf '%s' "$live" | jq 'length')" -gt 0 ] || { printf 'no live seat window\n'; return 0; }
  printf '%s' "$live" | jq -r '.[] | "\(.id)  until \(.until)  by \(.by)\n  reason: \(.reason)\n  alerts: \(.alerts | join(", "))\(if .node != "" then "\n  node:   " + .node else "" end)\(if .note != "" then "\n  note:   " + .note else "" end)"'
}

case "${1:-}" in
  open)  shift; cmd_open "$@" ;;
  close) shift; cmd_close "$@" ;;
  has)   shift; cmd_has "$@" ;;
  list)  shift; cmd_list "$@" ;;
  *) usage ;;
esac
