set -u
for row in ":" "1:" ":standard" "1:standard" ":large" "1:large" "1:xl" ":Large"; do
  DOCKER="${row%%:*}"; RIDE_SIZE="${row#*:}"
  AGENT_REQUESTS=""; AGENT_LIMITS=""; DIND_REQUESTS=""; DIND_LIMITS=""
  ride_size_envelope 2>&1
  printf 'row docker=%s in=%s → size=%s agent=%s/%s dind=%s/%s\n' "${DOCKER:-0}" "${row#*:}" "$RIDE_SIZE" \
    "$AGENT_REQUESTS" "$AGENT_LIMITS" "$DIND_REQUESTS" "$DIND_LIMITS"
done
