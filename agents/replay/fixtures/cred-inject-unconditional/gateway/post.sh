# ── observation point ── not launcher code. The block's whole output is three pod-env fragments:
# whether the pod gets an opaque REF or a real key, whether the git broker URL is set, and
# whether the opencode injection marker fired. Normalized to one line each so the assertion
# reads as the contract rather than as YAML.
case "$OR_KEY_ENV" in
  "")            echo "OR_KEY: none (subscription tier — no OpenRouter key at all)";;
  *secretKeyRef*) echo "OR_KEY: REAL (secretKeyRef)";;
  *ref:*)        echo "OR_KEY: ref ($(printf '%s' "$OR_KEY_ENV" | sed -n 's/.*value: "\(ref:[^"]*\)".*/\1/p'))";;
  *)             echo "OR_KEY: ? ($OR_KEY_ENV)";;
esac
if [ -n "$CRED_BROKER_ENV" ]; then echo "GIT_BROKER: set"; else echo "GIT_BROKER: unset"; fi
echo "OC_INJECT: ${OC_INJECT:-unset}"
