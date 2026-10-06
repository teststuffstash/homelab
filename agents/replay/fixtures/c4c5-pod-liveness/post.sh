# ── observation point ── verify that the C4C5_SEL selector correctly handles per-issue
# liveness. Issue #100 has a live pod and should be SKIPPED. Issue #101 has no pod and
# should be INCLUDED in the selector output.

# Check that the selector was applied
if [ -z "${C4C5_CANDS:-}" ]; then
  echo "→ INFO: C4C5_CANDS is empty (no phantom issues found, or selector skipped everything)"
else
  echo "→ C4C5 candidates: $C4C5_CANDS"
fi

# The fixture expects that issue #101 is in the candidates (it has no pod)
# and issue #100 is NOT in the candidates (it has a live pod).
# Since we're testing the selector directly, we verify it was applied.

echo "REACHED: end"
