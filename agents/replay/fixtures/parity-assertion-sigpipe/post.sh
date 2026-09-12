# ── observation point ── not scan code. Print the parity assertion result.
# The block sets PARITY_ISSUES; we print it to verify the block ran without
# crashing (exit 0, not SIGPIPE exit 141).
if [ -n "$PARITY_ISSUES" ]; then
  printf 'PARITY_ISSUES %s' "$PARITY_ISSUES"
else
  echo "PARITY_ISSUES (empty)"
fi
echo "REACHED: end"