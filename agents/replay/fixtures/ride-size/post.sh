set -u
AVX2=$'  affinity:\n    nodeAffinity:\n      requiredDuringSchedulingIgnoredDuringExecution:\n        nodeSelectorTerms:\n          - matchExpressions:\n              - { key: homelab.io/cpu-avx2, operator: In, values: ["true"] }'
for row in ":" "1:" ":standard" "1:standard" ":large" "1:large" "1:xl" ":Large"; do
  DOCKER="${row%%:*}"; RIDE_SIZE="${row#*:}"
  AGENT_REQUESTS=""; AGENT_LIMITS=""; DIND_REQUESTS=""; DIND_LIMITS=""; AFFINITY=""
  ride_size_envelope 2>&1
  printf 'row docker=%s in=%s → size=%s agent=%s/%s dind=%s/%s\n' "${DOCKER:-0}" "${row#*:}" "$RIDE_SIZE" \
    "$AGENT_REQUESTS" "$AGENT_LIMITS" "$DIND_REQUESTS" "$DIND_LIMITS"
  printf 'affinity: [%s]\n' "$AFFINITY"
done
# large composes with an existing (opencode AVX2) pin: one term, both expressions ANDed
DOCKER=""; RIDE_SIZE=large; AFFINITY="$AVX2"; ride_size_envelope >/dev/null 2>&1
printf 'composed: [%s]\n' "$AFFINITY"
