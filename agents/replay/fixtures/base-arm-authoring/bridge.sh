# ── bridge ── the launcher variables the `base-declared-read` region reads, and nothing else.
# Every name here is a launcher variable the real dispatch sets (`ORG`, `PROJECT`, `ISSUE_N`,
# `BASE_REF`, `NO_ARM`, `HERE`) — a bridge that renames things pins a different clause.
#
# NOTHING is shadowed. `ib_get` is composed from the shipped script above and runs the REAL
# parser out of the checkout; the issue fetch goes through the PATH-shim `gh`, which serves this
# row's recorded body and evaluates the `--jq` for real. The only thing that leaves is the network.
HERE="$REPLAY_ROOT/agents"
ORG="teststuffstash"
PROJECT="homelab"
ISSUE_N="1460"
# The dispatch default: no `--ref` override, so a declaration is free to win.
BASE_REF="master"
NO_ARM=""
