# ── bridge (homelab#1910) ── the per-STACK variables the deterministic noop-rerun pass reads
# (`SPAWN`, `name`, `repos`, `mainrepo`, `wipmap`, `LOOP_NS`, `HERE`), plus two seams:
#   scan_phase — the wedge-alert phase gauge (pushgateway I/O), a no-op here;
#   bash       — the ONE spawn the pass makes. Intercepted only for coordinator-session.sh and
#                printed as a LAUNCH line, so the action stream shows the exact argv the scan hands
#                the pod (the agent-session.sh call it carries); anything else runs for real.
SPAWN=1
name="${IN_STACK:-oracle}"
repos="${IN_REPO} "
mainrepo="${IN_REPO}"
LOOP_NS="${IN_LOOP_NS:-}"
wipmap="${IN_REPO} 2\n"
HERE="$REPLAY_ROOT/agents"
scan_phase() { :; }
bash() {
  if [ "${1:-}" = "${HERE}/coordinator-session.sh" ]; then
    shift; printf 'LAUNCH coordinator-session.sh'; printf ' %s' "$@"; printf '\n'
    return "${STUB_LAUNCH_RC:-0}"
  fi
  command bash "$@"
}
