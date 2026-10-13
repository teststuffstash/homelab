# deploy-revert-preexisting — the Prometheus seam. `curl` is shadowed: the call is recorded, and the
# body served is the RECORDED query_range reply for the query asked (world/prom/degraded.json for the
# `health_status="Degraded"` series, world/prom/all.json for the app's unfiltered series). CURL_FAIL=1
# makes every call fail (exit 7, no body) — the unreadable arm. Nothing here reaches the network.
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  [ "${CURL_FAIL:-0}" = 1 ] && return 7
  local q=""; local prev=""
  for a in "$@"; do [ "$prev" = "--data-urlencode" ] && case "$a" in query=*) q="${a#query=}";; esac; prev="$a"; done
  case "$q" in
    *health_status=\"Degraded\"*) cat "$REPLAY_WORLD/prom/degraded.json" ;;
    *) cat "$REPLAY_WORLD/prom/all.json" ;;
  esac
}
