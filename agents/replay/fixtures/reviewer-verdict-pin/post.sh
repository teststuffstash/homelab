# ── observation point ── the call the reviewing LLM makes, chosen per row by VP_FORM (the prompt's
# STEP FINAL forms; body-file and stdin forms included), then the two values the exit contract
# reads afterwards: the shim's exit code and the drop record.
printf 'BLOCKING: the fix misses a sibling.\n' > "$VP_STATE/rc-body.md"
vp_rc=0
case "${VP_FORM:-approve}" in
  approve)          verdict_pin_gh pr review 3444 --approve --body "LGTM at the reviewed head" || vp_rc=$? ;;
  request-changes)  verdict_pin_gh pr review 3444 --request-changes --body-file "$VP_STATE/rc-body.md" || vp_rc=$? ;;
  stdin-default-pr) printf 'stdin body\n' | verdict_pin_gh pr review -a -F - || vp_rc=$? ;;
  comment)          verdict_pin_gh pr review 3444 --comment -b "a note" || vp_rc=$? ;;
  other-pr)         verdict_pin_gh pr review 99 --approve -b "x" || vp_rc=$? ;;
  view)             verdict_pin_gh pr view 3444 --repo teststuffstash/homelab --json state || vp_rc=$? ;;
esac
echo "SHIM_RC: $vp_rc"
echo "DROP: $(cat "$VP_DROP_RECORD" 2>/dev/null || echo none)"
rm -rf "$VP_STATE"
