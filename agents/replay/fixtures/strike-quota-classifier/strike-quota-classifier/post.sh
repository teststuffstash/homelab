# ── post.sh ── assert STRIKE_LINE is set and echo it for the action-stream assertion.
# The expected template matches the full line including error_class.
if [ -z "${STRIKE_LINE:-}" ]; then
  printf 'FAIL: STRIKE_LINE not set by strike-line-format block\n' >&2
  exit 1
fi
printf '→ no PR opened — %s\n' "$STRIKE_LINE"