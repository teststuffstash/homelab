# ── bridge — seams for reviewer Touches-escape computation (helpers-unavailable case).
# The PR closes an issue, but the helper fetch fails (TOUCHES_BASE points nowhere). THE belt
# property under test: the block degrades to TOUCHES-ESCAPES: unavailable + WARN and the review
# proceeds — a fetch blip must never take the review lane down (PR#473 round-5 park, step 4).

ISSUE="125"
REPO_SLUG="teststuffstash/homelab"
CHANGED=$'agents/test.sh\nargocd/test.yaml'

# A base no curl can serve — the fetch fails, the fail-open path runs.
TOUCHES_BASE="file:///nonexistent-touches-base"

# gh stub: must NOT be reached — the fetch fails before the issue body is read.
gh() {
  echo "gh: should not be called when helpers are unavailable" >&2
  return 1
}

export ISSUE REPO_SLUG CHANGED TOUCHES_BASE
export -f gh
