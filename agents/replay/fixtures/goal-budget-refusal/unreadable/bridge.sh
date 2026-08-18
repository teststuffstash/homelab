# ── bridge ── same invocation again. The world here is not a recording at all: `STUB_GH=fail`
# (declared in fixture.yaml) makes the PATH-shim answer the read with a non-zero exit, the shape a
# 403/404/network failure takes, which is why this directory carries no world/ file.
. "$REPLAY_ROOT/agents/machine-comment.sh"

ORG=teststuffstash
PROJECT=circles
GOAL_PARENT=29
GB_SUM=1.75
GB_BUDGET=1
GB_ROWS='    #35 → $0.75 (actual spend, ledger)\n    #36 → $1.00 (cap reservation, live key)\n'
