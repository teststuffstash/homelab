# ── observation point ── not launcher code. Reads the PROMPT the block just composed and reports
# how its governance sentence is worded (homelab#1794, PR#2391): the sentence must DEFER to the
# rubric's author test, never restate a flat "BLOCKING" verdict (which falsely blocked a
# codeowner-authored PR). One home per fact: the test itself lives in .agents/review.md.
case "$PROMPT" in
  *"marked [GOVERNANCE] — apply .agents/review.md §BLOCKING's governance rule INCLUDING its author test"*) echo "GOV-SENTENCE: defers-to-author-test" ;;
  *) echo "GOV-SENTENCE: missing-author-deferral" ;;
esac
case "$PROMPT" in
  *"the diff is BLOCKING per .agents/review.md"*) echo "GOV-FLAT-VERDICT: present" ;;
  *) echo "GOV-FLAT-VERDICT: absent" ;;
esac
