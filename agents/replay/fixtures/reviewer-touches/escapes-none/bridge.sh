# ── bridge — seams for reviewer Touches-escape computation (no escapes case).

ISSUE="124"
REPO_SLUG="teststuffstash/homelab"
PR_NUMBER="123"
# PR diff includes only paths covered by declared Touches
CHANGED=$(cat <<'EOF'
argocd/resources/app1.yaml
argocd/resources/app2.yaml
argocd/platform/test.yaml
EOF
)

TOUCHES_BASE="file://$REPLAY_ROOT/agents"

# gh stub: return an issue body with a Touches: line
gh() {
  printf 'CALL gh %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in
    *"--jq"*".body"*)
      # Issue body with Touches: line covering argocd
      printf 'Fix deployment issue.\n\nTouches: argocd/**\n'
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
