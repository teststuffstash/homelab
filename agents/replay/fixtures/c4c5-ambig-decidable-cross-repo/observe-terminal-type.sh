# ── observation point ── runs immediately after each repo's c4c5-derivations pass,
# while $ambig_decidable/$ambig_terminal_type still hold THAT repo's scratch state
# (both are re-initialized per repo inside the block, homelab#2326).
for ad_qualified in $ambig_decidable; do
  ad_term_type="$(printf '%s' "$ambig_terminal_type" | grep "^${ad_qualified}=" | cut -d= -f2 || true)"
  printf '  TERM_TYPE: %s \xE2\x86\x92 %s\n' "$ad_qualified" "$ad_term_type"
done
