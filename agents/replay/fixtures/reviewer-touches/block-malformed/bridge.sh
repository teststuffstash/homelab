# ── bridge — seams for the MALFORMED-block degrade (homelab#1460 leg 5).
# Byte-for-byte ../block-authored/bridge.sh except for one line inside the fences: `Nope:` is not
# one of the 13 grammar keys, so the whole block is refused. The rest of the world is held
# constant on purpose — the ONLY difference between this stream and its sibling's is the damage.

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

# gh stub: the sibling's body with an unknown key added inside the fences. Note the footprint
# line itself is still perfectly readable — the refusal is of the BLOCK, not of the key, which is
# what makes "half-read the body" impossible by construction.
gh() {
  printf 'CALL gh %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in
    *"--jq"*".body"*)
      printf -- '---\nTouches: argocd/**, docs/**\nNope: 1\n---\n\nOriginal scope.\n\nSecond consumer widens the footprint.\n'
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
