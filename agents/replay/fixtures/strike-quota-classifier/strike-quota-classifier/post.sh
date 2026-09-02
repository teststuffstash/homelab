# ── post.sh ── assert the emit gate's outcome and echo it for the action-stream assertion.
# An empty STRIKE_LINE is a real outcome since homelab#866 (a PR-present ride outside the
# harness-death classes must not strike); the row's expected/ file pins which side it is on.
# FU-202 (homelab#1233): KEY_RETRY_LINE is set for key-class errors (budget-403-key,
# budget-exhausted-key) — a marker, not a strike.
if [ -n "${KEY_RETRY_LINE:-}" ]; then
  printf '→ key-class failure — %s\n' "$KEY_RETRY_LINE"
  exit 0
fi
if [ -z "${STRIKE_LINE:-}" ]; then
  printf '→ no strike emitted — error_class=[%s]\n' "${ERR_CLASS:-}"
  exit 0
fi
if [ -n "${PR_URL:-}" ]; then
  printf '→ harness death with PR — %s\n' "$STRIKE_LINE"
else
  printf '→ no PR opened — %s\n' "$STRIKE_LINE"
fi