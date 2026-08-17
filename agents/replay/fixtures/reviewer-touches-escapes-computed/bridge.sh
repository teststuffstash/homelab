# ── bridge — seams for reviewer Touches-escape computation.
# Sets up the issue context (ISSUE, REPO_SLUG) and stubs gh to return a Touches: line.

ISSUE="123"
REPO_SLUG="teststuffstash/homelab"
# PR diff includes governance and non-governance paths, some inside and some outside declared Touches
CHANGED=$(cat <<'EOF'
argocd/resources/test.yaml
agents/touches-check.sh
docs/test.md
agents/replay/fixtures/test/fixture.yaml
EOF
)

# HERE for touches-check.sh sourcing (must be exported for subshells)
HERE="$REPLAY_ROOT/agents"

# gh stub: return an issue body with a Touches: line when asked for issue body
gh() {
  printf 'CALL gh %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in
    *"--jq"*".body"*)
      # Issue body with Touches: line declaring only argocd/ and docs/
      printf 'This issue fixes ADR-097.\n\nTouches: argocd/**, docs/**\n'
      return 0
      ;;
    *)
      echo "gh: unexpected call" >&2
      return 1
      ;;
  esac
}

export ISSUE REPO_SLUG CHANGED HERE
export -f gh
