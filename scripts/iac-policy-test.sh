#!/usr/bin/env bash
# iac-policy-test — fixture expectations for policy/iac (run by `devbox run sentinel-smoke`).
#
# Each fixture is ONE k8s document named <case>.<expect>.fixture, expect ∈ pass|fail|warn: the
# verdict `kyverno apply policy/iac --audit-warn` (the sentinel's exact invocation) must give it.
# The `.fixture` extension is deliberate: the sentinel collects every *.yaml/*.yml in the
# homelab tree, so a deliberately-failing fixture with a yaml extension would red homelab's own
# `iac-sentinel` status.
#   fail = ≥1 fail (an Enforce rule fired) · warn = 0 fail, ≥1 warn (Audit only) · pass = neither
set -uo pipefail
cd "$(dirname "$0")/.."
POLICY_DIR="${POLICY_DIR:-policy/iac}"
FIX="scripts/fixtures/iac-policy"
bad=0; n=0
for f in "$FIX"/*.fixture; do
  [ -e "$f" ] || { echo "iac-policy-test: no fixtures in $FIX — a test with no input is not a pass"; exit 1; }
  n=$((n + 1))
  base="$(basename "$f" .fixture)"; want="${base##*.}"
  out="$(kyverno apply "$POLICY_DIR" --resource "$f" --audit-warn 2>&1)"
  sum="$(grep -oE 'pass: [0-9]+, fail: [0-9]+, warn: [0-9]+, error: [0-9]+' <<<"$out" | head -1)"
  if [ -z "$sum" ]; then
    echo "iac-policy-test: TOOL ERROR on $f (no summary line):"; head -5 <<<"$out" | sed 's/^/    /'; bad=$((bad + 1)); continue
  fi
  fail="$(sed -E 's/.*fail: ([0-9]+).*/\1/' <<<"$sum")"; warn="$(sed -E 's/.*warn: ([0-9]+).*/\1/' <<<"$sum")"
  err="$(sed -E 's/.*error: ([0-9]+).*/\1/' <<<"$sum")"
  if [ "$err" -gt 0 ]; then got=error
  elif [ "$fail" -gt 0 ]; then got=fail
  elif [ "$warn" -gt 0 ]; then got=warn
  else got=pass; fi
  if [ "$got" = "$want" ]; then echo "ok   $base ($sum)"
  else echo "FAIL $base: want $want, got $got ($sum)"; grep -E 'failed|^[0-9]+ - ' <<<"$out" | sed 's/^/    /'; bad=$((bad + 1)); fi
done
[ "$bad" -eq 0 ] || { echo "iac-policy-test: $bad of $n fixture(s) off expectation"; exit 1; }
echo "iac-policy-test: OK — $n fixture(s)"
