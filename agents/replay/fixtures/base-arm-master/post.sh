# ── observation point ── verify NO_ARM is still empty (armed).
if [ -z "${NO_ARM:-}" ]; then
  echo "→ VERIFIED: NO_ARM is empty — PR will be ARMED"
else
  echo "→ VERIFIED: NO_ARM is set — PR will NOT be armed (unexpected)"
fi
echo "REACHED: end"