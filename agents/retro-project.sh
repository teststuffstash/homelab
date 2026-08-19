# retro-project.sh — the ONE stack→(PROJECT, MAIN_REPO) map for the retro lane (homelab#588,
# the platform-series rename). `agents/retro-session.sh` (the launcher, which mints the cell's
# OpenRouterKey IN this namespace) and `agents/coordinator/retro-argo.yaml`'s guard (the busy
# probe, which now checks ONLY this namespace — WIP-slot locality, see the guard's own comment)
# both source this instead of carrying their own copy of the case map — the shape that let the
# two drift the way `agents/stacks.json`'s per-stack repo lists already do for other purposes.
#
# Usage:
#   . agents/retro-project.sh
#   retro_project "$STACK" || exit 1   # sets PROJECT + MAIN_REPO, or returns non-zero on an
#                                        # unknown stack (message on stderr) — the caller decides
#                                        # whether that is fatal.
retro_project() {
  case "$1" in
    oracle)
      PROJECT=oracle-fleet
      MAIN_REPO=teststuffstash/oracle-fleet
      ;;
    sleep)
      PROJECT=sleep-tracking
      MAIN_REPO=teststuffstash/sleep-tracking
      ;;
    platform)
      # openrouter-operator is the platform stack's FIXER namespace (agents/stacks.json:
      # mainRepo=homelab, repos=[agent-runtime, agent-coordinator, homelab,
      # openrouter-operator]) — the retro pod rides here, so this is the one namespace whose
      # WIP slot it can actually contend for.
      PROJECT=openrouter-operator
      MAIN_REPO=teststuffstash/homelab
      ;;
    *)
      echo "retro_project: unknown stack '$1' (add its project/main-repo mapping here)" >&2
      return 1
      ;;
  esac
}
