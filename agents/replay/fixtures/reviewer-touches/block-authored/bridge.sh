# ── bridge — seams for the BLOCK-AUTHORED footprint read (homelab#1460 leg 5).
# Byte-for-byte ../multiline-union/bridge.sh except the issue body: the footprint is declared
# in the `---` MACHINE BLOCK rather than in two line-anchored `Touches:` paragraphs.

ISSUE="123"
REPO_SLUG="teststuffstash/homelab"
PR_NUMBER="123"
# The same two paths the legacy twin changes — one per glob in the declared footprint, so the
# verdict turns on the footprint being read at all, not on one glob doing all the work.
CHANGED=$(cat <<'EOF'
argocd/resources/test.yaml
docs/test.md
EOF
)

# The block fetches the helper pair via curl from TOUCHES_BASE — point it at the repo checkout
# (file:// keeps the fixture hermetic and exercises the real fetch path, no shim).
TOUCHES_BASE="file://$REPLAY_ROOT/agents"

# gh stub: the SAME footprint as the legacy twin, declared in the machine block at the top of
# the body. The prose below it is deliberately identical in shape to the twin's, and carries no
# machine line — the writer owns those (coordinator/README §Authoring an issue body).
gh() {
  printf 'CALL gh %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in
    *"--jq"*".body"*)
      printf -- '---\nTouches: argocd/**, docs/**\n---\n\nOriginal scope.\n\nSecond consumer widens the footprint.\n'
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
