#!/usr/bin/env bash
# upgrade-lease-reader — read every ⚓ upgrade lease (ADR-150) standing in `agent-coordinator` and
# push it to the Pushgateway as ONE fixed group (job upgrade_lease_probe, PUT = replace), so a lease
# the hooks confirm (delete) leaves the group on the next run and a lease nobody confirms keeps a
# name in Prometheus with or without the management box. The record's contract is
# argocd/resources/kube-prometheus-stack-lease/upgrade-lease.sh's header: name upgrade-lease-<slug>,
# label homelab.teststuff.net/upgrade-lease=true, creationTimestamp = started, data subject / chart /
# sha / from / to / expected-end / max-end (RFC3339 UTC) / by / reason.
#
# Series (docs/patterns/observability.md §Batch jobs push — every HELP/TYPE byte-identical on every
# push, zeros pushed, a freshness gauge in the group):
#   upgrade_lease_info{lease,subject,by,chart,sha,from,to} 1           the upgrade in flight
#   upgrade_lease_started_timestamp_seconds{lease,subject}             creationTimestamp
#   upgrade_lease_expected_end_timestamp_seconds{lease,subject}        the one decisive field
#   upgrade_lease_max_end_timestamp_seconds{lease,subject}             the cap renewals never pass
#   upgrade_lease_standing                                                leases standing (0 = nothing in flight)
#   upgrade_lease_malformed                                            leases whose timestamps did not parse
#   upgrade_lease_probe_generated_timestamp_seconds                    freshness
# `reason` is free text and stays in the record (never a label). Cardinality: a handful of leases
# ever stand at once; a lease's identity (sha/from/to) is a label on purpose — the whole point is to
# name WHICH upgrade is in flight when several PRs merged close together.
#
# FAILURE SHAPE: a read that fails exits non-zero and pushes NOTHING — "no leases" is never
# inferred from an error. The freshness gauge then ages (UpgradeLeaseProbeStale) and the Job fails
# (CronJobNotSucceeding). Detector only: this script holds no write verb and acts on nothing.
set -euo pipefail

NS="${LEASE_NS:-agent-coordinator}"
LABEL="homelab.teststuff.net/upgrade-lease"
PG="${PUSHGATEWAY_URL:-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
JOB="${PUSH_JOB:-upgrade_lease_probe}"
OUT="${OUT:-/tmp/upgrade-lease.prom}"

esc() { printf '%s' "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g'; }   # label value escaping
epoch() { date -u -d "$1" +%s 2>/dev/null; }                              # rfc3339 → seconds, or fails

raw="$(kubectl -n "$NS" get configmap -l "$LABEL=true" -o json)"
count="$(printf '%s' "$raw" | jq '.items | length')"
now="$(date -u +%s)"
malformed=0

{
  echo "# HELP upgrade_lease_info One series per upgrade lease standing in agent-coordinator (ADR-150): the upgrade in flight."
  echo "# TYPE upgrade_lease_info gauge"
  echo "# HELP upgrade_lease_started_timestamp_seconds The lease record's creationTimestamp (= started)."
  echo "# TYPE upgrade_lease_started_timestamp_seconds gauge"
  echo "# HELP upgrade_lease_expected_end_timestamp_seconds The lease's expected-end, the one decisive field; a renewal moves it."
  echo "# TYPE upgrade_lease_expected_end_timestamp_seconds gauge"
  echo "# HELP upgrade_lease_max_end_timestamp_seconds The lease's max-end, the cap renewals never pass."
  echo "# TYPE upgrade_lease_max_end_timestamp_seconds gauge"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    lease="$(esc "$(printf '%s' "$item" | jq -r '.metadata.name')")"
    subject="$(esc "$(printf '%s' "$item" | jq -r '.data.subject // ""')")"
    by="$(esc "$(printf '%s' "$item" | jq -r '.data.by // ""')")"
    chart="$(esc "$(printf '%s' "$item" | jq -r '.data.chart // ""')")"
    sha="$(esc "$(printf '%s' "$item" | jq -r '.data.sha // ""')")"
    from="$(esc "$(printf '%s' "$item" | jq -r '.data.from // ""')")"
    to="$(esc "$(printf '%s' "$item" | jq -r '.data.to // ""')")"
    echo "upgrade_lease_info{lease=\"$lease\",subject=\"$subject\",by=\"$by\",chart=\"$chart\",sha=\"$sha\",from=\"$from\",to=\"$to\"} 1"
    started="$(epoch "$(printf '%s' "$item" | jq -r '.metadata.creationTimestamp // ""')")" || started=""
    ee="$(epoch "$(printf '%s' "$item" | jq -r '.data["expected-end"] // ""')")" || ee=""
    me="$(epoch "$(printf '%s' "$item" | jq -r '.data["max-end"] // ""')")" || me=""
    if [ -n "$started" ] && [ -n "$ee" ] && [ -n "$me" ]; then
      echo "upgrade_lease_started_timestamp_seconds{lease=\"$lease\",subject=\"$subject\"} $started"
      echo "upgrade_lease_expected_end_timestamp_seconds{lease=\"$lease\",subject=\"$subject\"} $ee"
      echo "upgrade_lease_max_end_timestamp_seconds{lease=\"$lease\",subject=\"$subject\"} $me"
    else
      malformed=$((malformed + 1))
      echo "upgrade-lease-reader: $lease has an unparsable timestamp (started='$started' expected-end='$ee' max-end='$me') — info only" >&2
    fi
  done < <(printf '%s' "$raw" | jq -c '.items[]')
  echo "# HELP upgrade_lease_standing Upgrade leases standing at the last read (0 = nothing in flight)."
  echo "# TYPE upgrade_lease_standing gauge"
  echo "upgrade_lease_standing $count"
  echo "# HELP upgrade_lease_malformed Leases whose expected-end/max-end/creationTimestamp did not parse as RFC3339 (upgrade_lease_info only)."
  echo "# TYPE upgrade_lease_malformed gauge"
  echo "upgrade_lease_malformed $malformed"
  echo "# HELP upgrade_lease_probe_generated_timestamp_seconds When the reader last read the leases and pushed this group (freshness)."
  echo "# TYPE upgrade_lease_probe_generated_timestamp_seconds gauge"
  echo "upgrade_lease_probe_generated_timestamp_seconds $now"
} > "$OUT"

# PUT replaces the whole group: a confirmed (deleted) lease's series vanish with this push.
curl -fsS --max-time 10 -X PUT --data-binary "@$OUT" "$PG/metrics/job/$JOB" >/dev/null
echo "upgrade-lease-reader: pushed $count lease(s) ($malformed malformed) to $JOB"
