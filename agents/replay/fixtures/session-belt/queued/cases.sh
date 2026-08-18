# ── the queued units ── `repo|issue|title`, one per line: the three loop variables the
# session-belt-queued block reads (`repo`, `qnum`, `qtitle`). #153 carries a RUNNING
# `coordinator-homelab-issue-153` session pod in this world — it must HOLD. #70 and #201 carry
# none — they must dispatch. (The `session-belt` probe above already ran once and built
# `sess_busy`; this loop reuses it, like the shipped per-repo iteration does.)
CASES="homelab|153|monitoring: marker memory limits for kube-prometheus-stack
homelab|70|scan: the janitor tick drops its exit code
homelab|201|ci: add the required ci workflow to this repo"
while IFS='|' read -r repo qnum qtitle; do
  [ -n "$qnum" ] || continue
