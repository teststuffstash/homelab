# The control: every field exists in the pinned gh — served from world/gh/pr-list.json.
gh pr list --repo teststuffstash/homelab --state open --json number,reviewDecision
# The #2333 call shape: lastEditedAt is not a gh field. Must fail like gh, never be served.
rc=0
gh pr list --repo teststuffstash/homelab --state open --json number,reviewDecision,lastEditedAt || rc=$?
echo "rc=$rc"
