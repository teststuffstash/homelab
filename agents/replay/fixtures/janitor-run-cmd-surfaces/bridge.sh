# ── bridge ── the RUN_CMD's input: the janitor's brief. The SHIPPED brief is the default; a row
# may point BRIEF_NAME at a world copy to exercise a declaration the shipped brief does not carry.
# The BASE_RUN_CMD file (worlds/base/base-run-cmd.txt) carries the pre-#2286 RUN_CMD text — the
# contrast row overrides RUN_CMD with it so the guard is proven to detect the defect it fixes.
BRIEF="${REPLAY_ROOT}/agents/coordinator/README.md"
[ -n "${BRIEF_NAME:-}" ] && BRIEF="${REPLAY_WORLD}/${BRIEF_NAME}"
if [ -f "${REPLAY_WORLD}/base-run-cmd.txt" ]; then
  RUN_CMD="$(cat "${REPLAY_WORLD}/base-run-cmd.txt")"
fi