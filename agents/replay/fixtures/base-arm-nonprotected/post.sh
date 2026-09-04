# ── observation point ── verify NO_ARM is set (un-armed).
if [ "${NO_ARM:-}" = "1" ]; then
  echo "→ VERIFIED: NO_ARM=1 — PR will NOT be armed (expected for non-protected base)"
else
  echo "→ VERIFIED: NO_ARM is not set — PR will be ARMED (unexpected for non-protected base)"
fi
echo "REACHED: end"