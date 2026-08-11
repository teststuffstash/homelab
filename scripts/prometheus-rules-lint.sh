#!/bin/bash
# prometheus-rules-lint — FU-158's CHECK half: every PrometheusRule's exprs run through
# `promtool check rules` (operator ruling 2026-08-11: promtool over per-file self-tests — the
# self-test pattern's third instance proved the shape, promtool adds real PromQL parse +
# duplicate detection none of them model). Extraction: each manifest's `spec.groups` lifted
# verbatim into a promtool rules file (a PrometheusRule's groups ARE the upstream format).
#
# This checks SYNTAX + expr parse, not behaviour. Behaviour tests (`promtool test rules`
# fixtures per rule file — `for:`/time-series semantics) are FU-158's remaining leg.
#
# Refuses to report success when it validated nothing (the manifest-lint rule: a green that
# saw nothing is the FU-125/FU-108 class).
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
files=$(grep -rl "^kind: PrometheusRule" argocd/ tofu/ 2>/dev/null | sort || true)
[ -n "$files" ] || { echo "prometheus-rules-lint: FAIL — found no PrometheusRule manifests at all" >&2; exit 2; }

checked=0; rules=0; rc=0
for f in $files; do
  # collapse all PrometheusRule docs in the file into one groups list (JSON is valid YAML)
  yq eval-all -o=json 'select(.kind=="PrometheusRule") | .spec.groups' "$f" 2>/dev/null \
    | jq -s '{groups: (map(select(type=="array")) | add // [])}' > "$tmp/r.json"
  n=$(jq '[.groups[].rules[]? | select(.alert or .record)] | length' "$tmp/r.json")
  [ "$n" -gt 0 ] || { echo "  ⚠ $f: kind matched but zero rules extracted — check the manifest shape"; rc=1; continue; }
  if out=$(promtool check rules "$tmp/r.json" 2>&1); then
    echo "  ok  $f ($n rule(s))"
  else
    echo "  FAIL $f:"; printf '%s\n' "$out" | sed 's/^/    /'
    rc=1
  fi
  checked=$((checked+1)); rules=$((rules+n))
done
[ "$checked" -gt 0 ] || { echo "prometheus-rules-lint: FAIL — validated nothing" >&2; exit 2; }
echo "prometheus-rules-lint: $checked file(s), $rules rule(s) checked$( [ $rc -eq 0 ] && echo ' — all parse' )"

# FU-158 behaviour half (PR#310's deferred codeowner hook): run every promtool BEHAVIOUR fixture.
# Fixture pairs live beside their PrometheusRule as <name>.promtool-{rules,test} (deliberately not
# *.yaml — manifest-lint kubeconforms every yaml under argocd/resources/). `promtool test rules`
# resolves rule_files relative to the test file's directory, so run each in place.
tests=0
while IFS= read -r tf; do
  [ -n "$tf" ] || continue
  if out=$(cd "$(dirname "$tf")" && promtool test rules "$(basename "$tf")" 2>&1); then
    echo "  ok  $tf (behaviour)"
  else
    echo "  FAIL $tf:"; printf '%s\n' "$out" | sed 's/^/    /'
    rc=1
  fi
  tests=$((tests+1))
done << EOF
$(find argocd -name '*.promtool-test' 2>/dev/null | sort)
EOF
[ "$tests" -gt 0 ] && echo "prometheus-rules-lint: $tests behaviour fixture(s) run"
exit $rc
