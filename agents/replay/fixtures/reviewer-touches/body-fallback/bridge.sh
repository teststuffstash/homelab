# ── bridge — seams for reviewer Touches-escape computation (body-fallback path, #1189).
# Simulates a PR whose base is NOT the default branch: closingIssuesReferences is empty, but the
# PR body contains "Fixes #N". The PREP heredoc falls back to parsing the body and sets ISSUE.
# This fixture tests the downstream reviewer-touches-check block with ISSUE set from that path.

ISSUE="1189"
REPO_SLUG="teststuffstash/homelab"
PR_NUMBER="123"
# PR diff includes only paths covered by declared Touches
CHANGED=$(cat <<'EOF'
argocd/resources/app1.yaml
argocd/resources/app2.yaml
EOF
)

TOUCHES_BASE="file://$REPLAY_ROOT/agents"

# gh stub: return an issue body with a Touches: line when asked for issue body
gh() {
  printf 'CALL gh %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in
    *"--jq"*".body"*)
      # Issue body with Touches: line covering argocd
      printf 'Fix goal-lane Touches footprint.\n\nTouches: argocd/**\n'
      return 0
      ;;
    *"pr diff"*)
      # #944: the sentinel-only classifier fetches the PR diff; this fixture's condition has
      # no sentinel-only files, so an empty diff keeps the pinned behaviour unchanged.
      return 0
      ;;
    *)
      echo "gh: unexpected call" >&2
      return 1
      ;;
  esac
}

export ISSUE REPO_SLUG CHANGED TOUCHES_BASE
export -f gh