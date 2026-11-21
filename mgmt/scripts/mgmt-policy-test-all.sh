#!/usr/bin/env bash
# mgmt-policy-test-all — `devbox run mgmt-policy-test`: every mgmt fixture script, run CONCURRENTLY.
# The fixtures are independent (each owns a mktemp dir, none touches the tree or the network), so
# running them one after another was pure wall-clock — the slowest serial step on master pushes.
#
# Gate semantics are unchanged: every fixture runs to completion, any non-zero exit fails the task.
# Each fixture's output is buffered to its own file (no interleaving); a failing fixture's log is
# printed in full, the passing ones as a one-line list. MGMT_TEST_VERBOSE=1 prints every log.
#
# Concurrency: min(nproc, 4), override MGMT_TEST_JOBS. nproc on an ARC runner pod is the HOST's
# core count (the pods set no CPU limit — argocd/platform/arc-runners.yaml), so a 40-core node and
# a 4-thread laptop runner both report "all of mine"; 4 keeps the step from crowding the other
# runners sharing the node. Memory is no constraint (each fixture is bash + jq, tens of MB, against
# the 3Gi job budget). Above 4 the wall clock is bound by the longest fixture anyway.
#
# No nested `devbox run`: this runs inside the task's env (or a `devbox shellenv` snapshot), and
# the children inherit it — a `devbox run` per child would re-evaluate the env and race on
# .devbox/gen/scripts ("text file busy", #1139).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Every mgmt/scripts/mgmt-*-test.sh (discovered, so a new fixture can never be left out). The slow
# ones are named first so none starts last (measured: reconcile's rollout part and policy ~40 s,
# ansible ~30 s, helm ~23 s; the rest ≤15 s). mgmt-reconcile-test runs as its four parts
# (MGMT_RECONCILE_PART) — whole, at ~75 s, it was the critical path on its own.
JOBS_LIST="reconcile:rollout policy reconcile:hold ansible helm reconcile:legacy reconcile:verify"
for f in "$HERE"/mgmt-*-test.sh; do
  s="${f##*/mgmt-}"; s="${s%-test.sh}"
  case " $JOBS_LIST " in *" $s "*|*" $s:"*) ;; *) JOBS_LIST="$JOBS_LIST $s" ;; esac
done
max="${MGMT_TEST_JOBS:-$(n="$(nproc 2>/dev/null || echo 2)"; [ "$n" -gt 4 ] && n=4; echo "$n")}"
case "$max" in ""|0|*[!0-9]*) echo "mgmt-policy-test: MGMT_TEST_JOBS must be a positive integer (got '$max')"; exit 2 ;; esac
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT

run_one() {  # <name[:part]>
  local s="${1%%:*}" p=""; [ "$s" != "$1" ] && p="${1#*:}"
  local start=$SECONDS
  MGMT_RECONCILE_PART="$p" bash "$HERE/mgmt-$s-test.sh" >"$D/$1.log" 2>&1
  echo "$? $((SECONDS - start))" >"$D/$1.rc"
}

running=0
for j in $JOBS_LIST; do
  if [ "$running" -ge "$max" ]; then wait -n; running=$((running - 1)); fi
  run_one "$j" & running=$((running + 1))
done
wait

label() { case "$1" in *:*) echo "mgmt-${1%%:*}-test[${1#*:}]" ;; *) echo "mgmt-$1-test" ;; esac; }
rc=0; passed=""
for j in $JOBS_LIST; do
  l="$(label "$j")"
  read -r r t <"$D/$j.rc" 2>/dev/null || { r=missing; t='?'; }
  if [ "$r" = 0 ]; then
    passed="$passed $l(${t}s)"
    [ -n "${MGMT_TEST_VERBOSE:-}" ] && { echo "── $l ──"; cat "$D/$j.log"; }
  else
    rc=1
    echo "══ FAILED $l (exit $r, ${t}s) — full output ══"
    cat "$D/$j.log" 2>/dev/null
    echo "══ end $l ══"
  fi
done
echo "mgmt-policy-test (jobs=$max): passed:${passed:- none}"
[ "$rc" = 0 ] || echo "mgmt-policy-test: FAILED — see the full logs above"
exit "$rc"
