# ── bridge — seams for the multi-line Touches union read (S6 sprout, #716).
# Same shape as ../escapes-computed/bridge.sh; the delta is the issue body carrying TWO
# Touches: lines and a diff whose coverage needs their UNION.

ISSUE="123"
REPO_SLUG="teststuffstash/homelab"
# One path per declared line: argocd/ is covered by the FIRST line only, docs/ by the SECOND
# only. Under a first-line-only read, docs/test.md escapes — the false-escape class this
# fixture red-cases.
CHANGED=$(cat <<'EOF'
argocd/resources/test.yaml
docs/test.md
EOF
)

# The block fetches the helper pair via curl from TOUCHES_BASE — point it at the repo checkout
# (file:// keeps the fixture hermetic and exercises the real fetch path, no shim).
TOUCHES_BASE="file://$REPLAY_ROOT/agents"

# gh stub: an issue body with TWO Touches: lines — original footprint + a later superseding
# paragraph (the multi-consumer shape).
gh() {
  printf 'CALL gh %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in
    *"--jq"*".body"*)
      printf 'Original scope.\n\nTouches: argocd/**\n\nSecond consumer widens the footprint:\nTouches: docs/**\n'
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
