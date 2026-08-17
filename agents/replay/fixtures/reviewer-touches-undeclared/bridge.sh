# ── bridge — seams for reviewer Touches-escape computation (undeclared case).
# ISSUE is empty, so the check skips to the undeclared branch.

ISSUE=""
REPO_SLUG="teststuffstash/homelab"
CHANGED=$'agents/test.sh\nargocd/test.yaml\ndocs/test.md'

# gh stub: not called in the undeclared case
gh() {
  echo "gh: should not be called in undeclared case" >&2
  return 1
}

export ISSUE REPO_SLUG CHANGED
export -f gh
