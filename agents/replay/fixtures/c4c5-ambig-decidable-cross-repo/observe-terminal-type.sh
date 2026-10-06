# ── observation point ── the c4c5-decidable loop resolves $ad_term_type from the repo-qualified
# $ambig_terminal_type keys; this part makes that resolution observable in the action stream, so
# the assertion lives in the fixture instead of in the live dispatch loop.
ad_n="${uitem#issue-}"
ad_qualified="${urepo}#${ad_n}"
ad_term_type="$(printf '%s' "$ambig_terminal_type" | grep "^${ad_qualified}=" | cut -d= -f2 || true)"
ad_term_type="${ad_term_type:-AGENT_STRIKE}"
printf '  TERM_TYPE: %s#%s \xE2\x86\x92 %s\n' "$urepo" "$ad_n" "$ad_term_type"
