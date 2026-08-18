# ── bridge ── the per-repo loop state the session-belt block reads. `repo` is set BEFORE the
# probe block runs (the parts order composes this file first); the probe goes through the
# PATH-shim kubectl so the recorded pod read lands in the action stream.
repo="homelab"
slug="teststuffstash/homelab"
dispatchable=1
orphans=""
# Default loop ns (global scan): the ns the recorded session pods live in. `LOOP_NS` empty here
# exercises the `${LOOP_NS:-agent-coordinator}` default in the shipped probe.
LOOP_NS=""
KUBECTL="kubectl"
KUBE=""
