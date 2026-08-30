# COORDINATOR-CLI-FALLBACK-ONLY leg: invokes resolve-model.sh as a real subprocess through
# the coordinator-session.sh caller flag shape (line 112, the non-explicit path):
#   bash resolve-model.sh --role coordinator --class dispatch --fallback <m>
#
# This is the fallback-only path: no --model, so the route IS consulted and the
# script fail-OPENs to the literal fallback when the proxy is unreachable.
# This row pins the drop-`--fallback` regression from #861 round 1: without
# --fallback, resolve-model.sh's unconditional guard at :47 fires BEFORE the
# override branch at :50, rc=2, killing every invocation under set -euo pipefail.
CLI_FLAGS="--role coordinator --class dispatch --fallback sonnet"
STUB_CURL="ok"
CURL_RESPONSE='{"decision":"dispatch","model":"claude/sonnet"}'