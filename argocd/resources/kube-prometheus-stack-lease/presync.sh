#!/usr/bin/env bash
# presync — ARM the kube-prometheus-stack upgrade lease when the sync STARTS (ADR-150 (3)): the
# cluster's own clock, so ArgoCD's git-poll lag and the box's tick are both outside the window.
# Reads the Application's in-flight operation for what is being synced: `to` = the chart source's
# revision, `sha` = the git ($values) source's revision, `from` = the chart revision of the last
# successful sync in .status.history (the first sync ever has none → from = to). Then
# `upgrade-lease.sh open` — a retry of the same sync (same sha + from + to) is a no-op there, by
# contract; the same sha at another chart version is a new lease (the #2256 ordering lesson).
# Env (the Job): APP, APP_NS, SUBJECT, CHART, EXPECT_MIN, MAX_MIN.
set -euo pipefail
: "${APP:=kube-prometheus-stack}" "${APP_NS:=argocd}" "${SUBJECT:=argocd/platform/kube-prometheus-stack.yaml}"
: "${CHART:=kube-prometheus-stack}" "${EXPECT_MIN:=20}" "${MAX_MIN:=60}"

app="$(kubectl -n "$APP_NS" get application "$APP" -o json)"
IFS='|' read -r to sha from reason < <(printf '%s' "$app" | jq -r --arg chart "$CHART" '
  def rev_of($entry; pred): ($entry.sources // [] | to_entries[] | select(.value | pred) | .key) as $i | $entry.revisions[$i];
  .status.operationState.operation.sync as $op
  | [ (rev_of($op; .chart == $chart) // "")
    , (rev_of($op; .ref == "values") // "")
    , ((.status.history // []) | if length == 0 then "" else (last as $h | rev_of($h; .chart == $chart) // "") end)
    , (.status.operationState.operation.initiatedBy // {} | if .automated then "automated" else (.username // "unknown") end)
    ] | join("|")')   # `|` not tab: `read` collapses an EMPTY tab field (the first sync's `from`) and shifts the rest
# A MANUAL sync whose operation carries no revisions (a bare `operation.sync`) or a SYMBOLIC git
# revision (`master`) must not land in the record: `to` falls back to the Application spec's chart
# pin, `sha` to the resolved git revision of the last comparison (.status.sync.revisions) — and
# only a 40-hex sha is ever written (the box reverts by sha; `master` is not a commit).
[ -n "$to" ] || to="$(printf '%s' "$app" | jq -r --arg chart "$CHART" '[.spec.sources[]? | select(.chart == $chart) | .targetRevision][0] // ""')"
if ! printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$'; then
  sha="$(printf '%s' "$app" | jq -r '(.spec.sources // [] | to_entries[] | select(.value.ref == "values") | .key) as $i | .status.sync.revisions[$i] // ""')"
fi
printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$' && [ -n "$to" ] || { echo "presync: could not read the in-flight sync's revisions (to='$to' sha='$sha') — refusing to arm on bad data" >&2; exit 1; }
[ -n "$from" ] || from="$to"
echo "presync: $CHART $from → $to at ${sha:0:8} ($reason); lease expect ${EXPECT_MIN} min, cap ${MAX_MIN} min"
exec bash /scripts/upgrade-lease.sh open --subject "$SUBJECT" --chart "$CHART" --sha "$sha" --from "$from" --to "$to" \
  --expect-min "$EXPECT_MIN" --max-min "$MAX_MIN" --by "argocd-presync/$APP" --reason "sync initiated by $reason"
