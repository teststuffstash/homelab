#!/usr/bin/env bash
# upgrade-lease — the ACTOR side of the ⚓ upgrade lease (ADR-150, glossary; design in
# docs/dependency-upgrades.md §Worked case): commit-confirm for an upgrade whose dependency cone
# holds its own detector (kube-prometheus-stack IS Prometheus + Alertmanager; a node-by-node
# substrate rollout). The actor DECLARES the upgrade with a deadline, VERIFIES and DELETES the
# declaration; the management box (mgmt/scripts/mgmt-lease.sh) REVERTS whatever is still declared
# past its deadline — a pin-only revert PR through the reflex lane, never a diagnosis.
#
#   upgrade-lease.sh open    --subject <file> --chart <name> --sha <git sha> --from <v> --to <v>
#                            --expect-min <N> --max-min <M> [--by <who>] [--reason <text>]
#   upgrade-lease.sh renew   --subject <file> --expect-min <N>
#   upgrade-lease.sh confirm --subject <file>
#   upgrade-lease.sh list                                 # one JSON line per lease (the box's read)
#   common: [--kubeconfig <path>] [--namespace <ns>]      # default: in-cluster SA, agent-coordinator
#
# THE RECORD (pinned contract — the box's reader implements exactly this):
#   one ConfigMap per in-flight upgrade in ns `agent-coordinator` (the `responder-window`
#   ConfigMap's namespace: a SIBLING record on the read path the apply loop already uses, FU-300 —
#   never a window: a window HOLDS the apply loop and arms nothing; a lease expiring ACTS);
#   name `upgrade-lease-<subject-slug>` (slug = the subject file's basename without `.yaml`);
#   label `homelab.teststuff.net/upgrade-lease: "true"`; `metadata.creationTimestamp` IS `started`;
#   data: subject (the Application file path) · chart · sha (the homelab revision being synced) ·
#   from / to (chart versions) · expected-end · max-end (RFC3339 UTC) · by · reason.
#   ONE decisive field: `expected-end`. `max-end` = started + the per-subject cap renewals never pass.
#
# THE RETRY RULE: `open` on a subject whose lease already carries the SAME IDENTITY — sha AND
# from AND to — is a NO-OP (prints the existing record, exit 0). ArgoCD re-runs PreSync on every
# sync retry (retry.limit 5 on the Application) and on every self-heal of the same revision —
# without this rule each retry would push the deadline forward and a wedged sync could renew
# itself forever. ANY other identity replaces the record (delete + create → a new `started`): a
# newer commit is a new upgrade, and so is the SAME commit synced at a different chart version —
# the kps 91.8.0 merge (#2256, 2026-10-06 23:13Z) moved the hooks source and the pin in ONE commit,
# ArgoCD synced the git source first (chart still 86.3.2, the app-of-apps had not bumped the
# Application yet), and a sha-only rule kept that `86.3.2 → 86.3.2` record, with its deadline,
# through the real 91.8.0 sync.
#
# CALLERS: the kube-prometheus-stack PreSync / PostSync hook Jobs
# (argocd/resources/kube-prometheus-stack-lease/ — the vendored copy there must stay byte-identical,
# agents/upgrade-lease-test.sh asserts it); later the node reconciler (`renew` per node, ADR-150 (3)).
# Tools: kubectl + jq + GNU date only (the agent-coordinator image, the box's closure, the jail).
set -euo pipefail

LABEL="homelab.teststuff.net/upgrade-lease"
NS="${LEASE_NS:-agent-coordinator}"
KUBE=()
NOW_CMD="${LEASE_NOW_CMD:-date -u +%Y-%m-%dT%H:%M:%SZ}"   # test seam: a fixed clock

die() { printf 'upgrade-lease: %s\n' "$*" >&2; exit 2; }
now() { $NOW_CMD; }
plus_min() { date -u -d "$1 + $2 min" +%Y-%m-%dT%H:%M:%SZ; }   # <rfc3339> <N> → rfc3339
slug() { local b; b="$(basename "$1")"; printf '%s' "${b%.yaml}"; }
kc() { kubectl "${KUBE[@]}" -n "$NS" "$@"; }

VERB="${1:-}"; [ -n "$VERB" ] || die "usage: open|renew|confirm|list (see header)"
shift
SUBJECT="" CHART="" SHA="" FROM="" TO="" EXPECT="" MAX="" BY="" REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --subject) SUBJECT="$2"; shift ;;
    --chart) CHART="$2"; shift ;;
    --sha) SHA="$2"; shift ;;
    --from) FROM="$2"; shift ;;
    --to) TO="$2"; shift ;;
    --expect-min) EXPECT="$2"; shift ;;
    --max-min) MAX="$2"; shift ;;
    --by) BY="$2"; shift ;;
    --reason) REASON="$2"; shift ;;
    --kubeconfig) KUBE+=(--kubeconfig "$2"); shift ;;
    --namespace) NS="$2"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

need() {  # need VAR=flag … → die naming the missing flag
  local pair v
  for pair in "$@"; do v="${pair%%=*}"; [ -n "${!v}" ] || die "$VERB needs --${pair#*=}"; done
}
get_lease() {  # <name> → JSON on stdout, rc 1 if absent
  kc get configmap "$1" -o json 2>/dev/null
}
print_lease() {  # one JSON line, the `list` shape
  jq -c --arg now "$(now)" '{name: .metadata.name, subject: .data.subject, chart: .data.chart, sha: .data.sha,
    from: .data.from, to: .data.to, started: .metadata.creationTimestamp,
    "expected-end": .data["expected-end"], "max-end": .data["max-end"], by: .data.by, reason: .data.reason,
    expired: (.data["expected-end"] < $now)}'
}

case "$VERB" in
  open)
    need SUBJECT=subject CHART=chart SHA=sha FROM=from TO=to EXPECT=expect-min MAX=max-min
    name="upgrade-lease-$(slug "$SUBJECT")"
    if existing="$(get_lease "$name")"; then
      if [ "$(printf '%s' "$existing" | jq -r '[.data.sha, .data.from, .data.to] | join(" ")')" = "$SHA $FROM $TO" ]; then
        printf 'upgrade-lease: %s already open for %s %s → %s — no-op (a sync retry never moves the deadline)\n' "$name" "${SHA:0:8}" "$FROM" "$TO" >&2
        printf '%s' "$existing" | print_lease; exit 0
      fi
      printf 'upgrade-lease: %s held %s, replacing with %s %s → %s\n' "$name" "$(printf '%s' "$existing" | jq -r '"\(.data.sha[0:8]) \(.data.from) → \(.data.to)"')" "${SHA:0:8}" "$FROM" "$TO" >&2
      kc delete configmap "$name" --ignore-not-found >/dev/null
    fi
    start="$(now)"
    doc="$(jq -nc --arg name "$name" --arg lbl "$LABEL" --arg ns "$NS" \
      --arg subject "$SUBJECT" --arg chart "$CHART" --arg sha "$SHA" --arg from "$FROM" --arg to "$TO" \
      --arg ee "$(plus_min "$start" "$EXPECT")" --arg me "$(plus_min "$start" "$MAX")" \
      --arg by "${BY:-upgrade-lease.sh}" --arg reason "$REASON" '
      {apiVersion: "v1", kind: "ConfigMap",
       metadata: {name: $name, namespace: $ns, labels: {($lbl): "true"}},
       data: {subject: $subject, chart: $chart, sha: $sha, from: $from, to: $to,
              "expected-end": $ee, "max-end": $me, by: $by, reason: $reason}}')"
    printf '%s' "$doc" | kc create -f - >/dev/null      # create, never apply: an existing record is the guard above
    get_lease "$name" | print_lease
    ;;
  renew)
    need SUBJECT=subject EXPECT=expect-min
    name="upgrade-lease-$(slug "$SUBJECT")"
    existing="$(get_lease "$name")" || die "no lease $name to renew"
    max="$(printf '%s' "$existing" | jq -r '.data["max-end"]')"
    want="$(plus_min "$(now)" "$EXPECT")"
    [ "$want" \< "$max" ] || want="$max"                  # never past max-end (RFC3339 UTC sorts lexically)
    kc patch configmap "$name" --type merge -p "$(jq -nc --arg ee "$want" '{data: {"expected-end": $ee}}')" >/dev/null
    get_lease "$name" | print_lease
    ;;
  confirm)
    need SUBJECT=subject
    name="upgrade-lease-$(slug "$SUBJECT")"
    kc delete configmap "$name" --ignore-not-found >/dev/null
    printf 'upgrade-lease: %s confirmed (record deleted; missing is fine)\n' "$name" >&2
    ;;
  list)
    kc get configmap -l "$LABEL=true" -o json | jq -c '.items[]' | while IFS= read -r item; do printf '%s' "$item" | print_lease; done
    ;;
  *) die "unknown verb: $VERB (open|renew|confirm|list)" ;;
esac
