# ── bridge ── the LINTED repo's governance (homelab#1897). classify_touches_repo applies the ❌
# platform set only for a homelab slug; for any other slug it classifies against that repo's
# CODEOWNERS, fetched with `gh api` (the stub serves the recorded world). SLUG and FOOTPRINT come
# from the row's env. The REAL function from the shipped agents/footprint.sh is called — never a
# copy of the tier logic.
. "$REPLAY_ROOT/agents/footprint.sh"
RESULT="$(classify_touches_repo "$SLUG" "$FOOTPRINT")"
printf 'classify: %s\n' "$RESULT"