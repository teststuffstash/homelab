#!/usr/bin/env bash
# listed-push — the island intake's list step says which islands TODAY's run walks: one series
# `island_intake_listed_timestamp_seconds{island="<name>"}` per listed island, every one carrying
# the same value (this list run's epoch), PUT as ONE Pushgateway group (job island_intake_list) so
# the whole group is replaced — an island that left the list keeps no series from this run.
#
#   bash islands/intake/scripts/listed-push.sh <list file: one island per line>
#
# IslandIntakeStale (argocd/resources/pushgateway/prometheusrule.yaml) fires for an island only
# while its listed timestamp equals the newest one: an island removed from the list (a facts file
# deleted, a stack dropping `repos[].intake.facts`) or never in it (a mistyped `-p island=`) is not
# reported stale. Never fatal: a push that fails leaves the previous run's list in force and says so.
set -uo pipefail
LIST="${1:-}"
[ -s "$LIST" ] || { echo "listed-push: usage: listed-push.sh <list file> (non-empty)" >&2; exit 2; }
[ -n "${PUSHGATEWAY:-}" ] || { echo "island-intake: no PUSHGATEWAY — island_intake_listed_timestamp_seconds not pushed"; exit 0; }
now="$(date +%s)"
{
  printf '# TYPE island_intake_listed_timestamp_seconds gauge\n'
  while IFS= read -r isl; do
    [ -n "$isl" ] || continue
    esc="${isl//\\/\\\\}"; esc="${esc//\"/\\\"}"
    printf 'island_intake_listed_timestamp_seconds{island="%s"} %s\n' "$esc" "$now"
  done < "$LIST"
} > "$LIST.metrics"
curl -fsS --max-time 5 -X PUT --data-binary "@$LIST.metrics" "$PUSHGATEWAY/metrics/job/island_intake_list" >/dev/null 2>&1 \
  || echo "island-intake: pushgateway unreachable — island_intake_listed_timestamp_seconds not pushed (the previous list stays in force)"
rm -f "$LIST.metrics"
exit 0
