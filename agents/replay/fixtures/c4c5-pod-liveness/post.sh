# ── observation point ── verify the C4C5_CANDS output (selector execution per-issue liveness).
# Extract candidate issue numbers (before the pipe separator) from the selector run.
if [ -n "${c4c5_cands:-}" ]; then
  printf 'CANDIDATES: %s\n' "$(printf '%s\n' "$c4c5_cands" | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//')"
else
  printf 'CANDIDATES: (empty)\n'
fi
if [ -n "${orphans:-}" ]; then
  printf 'ORPHANS: %b\n' "$orphans"
fi
echo "REACHED: end"
