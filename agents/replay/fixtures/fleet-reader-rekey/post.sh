# ── observation point ── not scan code. The clause accumulates into `orphans` as \n-joined
# strings; %b expands them so each emitted action lands as its own line and `diff` stays
# line-oriented. The three branch accumulators are printed too: they are the reader's own answer
# to "which branch did this class land in", and every downstream write keys off them.
printf 'PROVIDER-LATCHES %s\n' "${fleet_provider_latches:-<empty>}"
printf 'MODEL-NOMINATIONS %s\n' "${fleet_model_nominations:-<empty>}"
printf 'US-CASE %s\n' "${fleet_strike_issues:-<empty>}"
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"