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

# DRIFT PIN (homelab#337, operator-lane): every *.promtool-rules file is a HAND COPY of its CR's
# groups, and a stale copy makes the behaviour fixtures pass vacuously. For each directory with a
# rules copy: extract every alert from every PrometheusRule doc in that dir's *.yaml (eval-all —
# blackbox.yaml is MULTI-DOC), and for each alert name present in BOTH the CR and the copy, assert
# expr+for equality. Witness groups (Pre335, MaxDirection, …) exist only copy-side, so the
# intersection skips them with no name convention needed; annotations are legitimately deleted by
# some recipes, so only expr+for are pinned.
pins=0
for rf in $(find argocd -name '*.promtool-rules' | sort); do
  d=$(dirname "$rf")
  crs=$(find "$d" -maxdepth 1 -name '*.yaml' | sort)
  [ -n "$crs" ] || continue
  cr_json="$tmp/cr-alerts.json"; cp_json="$tmp/cp-alerts.json"
  # shellcheck disable=SC2086
  yq eval-all -o=json '[.] | map(select(.kind == "PrometheusRule")) | map(.spec.groups[].rules[]) | flatten | map(select(.alert)) | map({"alert": .alert, "expr": .expr, "for": .for})' $crs 2>/dev/null | jq -s 'flatten | unique_by(.alert)' > "$cr_json" || continue
  yq -o=json '[.groups[].rules[] | select(.alert)] | map({"alert": .alert, "expr": .expr, "for": .for})' "$rf" 2>/dev/null > "$cp_json" || continue
  # ANY-match per alert name: the copy may carry extra same-named variants (probes' hand-rendered
  # SLO group) and witness groups; the pin asserts the CR's exact (expr, for) appears among the
  # copy's entries for every alert name both sides share.
  drift=$(jq -n --slurpfile cr "$cr_json" --slurpfile cp "$cp_json" '
    ($cp[0] | map(.alert) | unique) as $names
    | $cr[0] | map(select(.alert as $a | $names | index($a)))
    | map(select(. as $want | $cp[0] | map(select(. == $want)) | length == 0) | .alert)
    | unique | join(" ")')
  drift=$(printf '%s' "$drift" | tr -d '"')
  if [ -n "$drift" ]; then
    echo "  DRIFT $rf: alert(s) [$drift] differ from the CR in $d — re-run the header's yq recipe"
    rc=1
  fi
  pins=$((pins+1))
done
[ "$pins" -gt 0 ] && echo "prometheus-rules-lint: $pins hand-copy file(s) drift-pinned against their CRs"
exit $rc
