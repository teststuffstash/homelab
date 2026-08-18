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
[ "$checked" -gt 0 ] && echo "prometheus-rules-lint: $checked file(s), $rules rule(s) checked$( [ $rc -eq 0 ] && echo ' — all parse' )"

# LEG 2 — Helm-VALUES-defined alerts (homelab#504): the values-defined exprs (18 at fix time) in chart VALUES files
# (argocd/platform/values/kube-prometheus-stack.yaml's additionalPrometheusRulesMap: cilium, cnpg,
# longhorn, node-health, office-plants, ...) were invisible to leg 1's `^kind: PrometheusRule` grep
# and got ZERO parse protection. The chart inlines each additionalPrometheusRulesMap entry's content
# VERBATIM as a PrometheusRule's spec.groups, so extracting the map with yq and promtool-checking
# the extracted groups validates byte-identical content — hermetic, NO `helm template`, NO network
# (a chart pull per CI run is FU-130's WAN class and blows the operator's 2-minute-CI target). The
# annotations legitimately carry raw Prometheus templating (`{{ $labels.instance }}` etc.) — promtool
# accepts these natively; nothing here helm-evaluates them.
vfiles=$(grep -rl "additionalPrometheusRulesMap" argocd/ 2>/dev/null | sort || true)
vchecked=0; vgroups=0; valerts=0
for f in $vfiles; do
  # each top-level key under additionalPrometheusRulesMap is a `groups:`-shaped document
  if ! entries=$(yq -o=json '.additionalPrometheusRulesMap' "$f" 2>/dev/null | jq -r 'if type=="object" then keys[] else empty end'); then
    echo "  FAIL $f: yq could not parse additionalPrometheusRulesMap — check the values file YAML" >&2
    rc=1; continue
  fi
  [ -n "$entries" ] || { echo "  FAIL $f: additionalPrometheusRulesMap present but zero entries extracted — must be a non-empty map" >&2; rc=1; continue; }
  fg=0; fa=0; file_rc=0
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    out="$tmp/$(printf '%s' "$(basename "$f" .yaml)-$e" | tr -c 'A-Za-z0-9._-' '_').json"
    if ! yq -o=json ".additionalPrometheusRulesMap[\"$e\"]" "$f" > "$out" 2>/dev/null; then
      echo "  FAIL $f (entry '$e'): yq could not parse — check the values file YAML" >&2
      rc=1; file_rc=1; continue
    fi
    g=$(jq '[.groups[]?] | length' "$out" 2>/dev/null || echo 0)
    a=$(jq '[.groups[].rules[]? | select(.alert or .record)] | length' "$out" 2>/dev/null || echo 0)
    fg=$((fg+g)); fa=$((fa+a))
    if [ "$g" -eq 0 ] || [ "$a" -eq 0 ]; then
      echo "  FAIL $f (entry '$e'): yielded $g group(s), $a alert(s) — must be ≥1 of each (validated nothing)" >&2
      rc=1; file_rc=1; continue
    fi
    if pout=$(promtool check rules "$out" 2>&1); then
      echo "  ok  $f (values '$e': $a alert(s))"
    else
      echo "  FAIL $f (entry '$e'):"; printf '%s\n' "$pout" | sed 's/^/    /'
      rc=1; file_rc=1
    fi
  done <<EOF
$entries
EOF
  if [ "$file_rc" -eq 0 ] && [ "$fg" -eq 0 ]; then
    echo "  FAIL $f: additionalPrometheusRulesMap extracted $fg group(s), $fa alert(s) — validated nothing" >&2
    rc=1; continue
  fi
  [ "$file_rc" -eq 0 ] || continue
  vchecked=$((vchecked+1)); vgroups=$((vgroups+fg)); valerts=$((valerts+fa))
done
[ "$vchecked" -gt 0 ] && echo "prometheus-rules-lint: values-defined rules: $vchecked file(s), $vgroups group(s), $valerts alert(s) checked"
[ "$checked" -gt 0 ] || [ "$vchecked" -gt 0 ] || { echo "prometheus-rules-lint: FAIL — validated nothing" >&2; exit 2; }

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

# DRIFT PIN (homelab#337, operator-lane; made BIDIRECTIONAL in #375): every *.promtool-rules file is
# a HAND COPY of its CR's groups, and a stale copy makes the behaviour fixtures pass vacuously. For
# each directory with a rules copy: extract every alert from every PrometheusRule doc in that dir's
# *.yaml (eval-all — blackbox.yaml is MULTI-DOC).
#
# CR→copy (unchanged from #337): for each alert name present in BOTH the CR and the copy, assert
# expr+for equality. ANY-match per alert name: the copy may carry extra same-named variants (probes'
# hand-rendered SLO group) and witness groups; the pin asserts the CR's exact (expr, for) appears
# among the copy's entries for every shared name. Annotations are legitimately deleted by some
# recipes, so only expr+for are pinned.
#
# copy→CR (#375's reverse walk): an alert name present in the COPY but absent from the CR is a stale
# entry — a renamed/deleted CR alert would otherwise sit unexamined (exactly #337's own failure
# class). Every copy-only name must be EXPLICITLY DECLARED witness-only via a marker comment in the
# copy file: `# witness-only: <AlertName>[, <AlertName>…]` for a per-name declaration, or
# `# witness-only: all` for a file whose every alert is witness-only. An undeclared copy-only name
# is a DRIFT. A file whose copy-side names are all witness-only (zero CR intersection) counts as
# "witness-only", not "drift-pinned" — the pin counter says how many files carry real pins.
pins=0; witness_only=0
name_lines() { printf '%s' "$1" | tr ' ' '\n' | sed '/^$/d' | sort -u; }
for rf in $(find argocd -name '*.promtool-rules' | sort); do
  d=$(dirname "$rf")
  crs=$(find "$d" -maxdepth 1 -name '*.yaml' | sort)
  [ -n "$crs" ] || continue
  cr_json="$tmp/cr-alerts.json"; cp_json="$tmp/cp-alerts.json"
  # shellcheck disable=SC2086
  yq eval-all -o=json '[.] | map(select(.kind == "PrometheusRule")) | map(.spec.groups[].rules[]) | flatten | map(select(.alert)) | map({"alert": .alert, "expr": .expr, "for": .for})' $crs 2>/dev/null | jq -s 'flatten | unique_by(.alert)' > "$cr_json" || continue
  yq -o=json '[.groups[].rules[] | select(.alert)] | map({"alert": .alert, "expr": .expr, "for": .for})' "$rf" 2>/dev/null > "$cp_json" || continue
  # CR→copy: the #337 assertion, unchanged.
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
  # copy→CR reverse walk: every copy-side name absent from the CR must be declared witness-only.
  copy_only=$(comm -13 <(jq -r '.[].alert' "$cr_json" | sort -u) <(jq -r '.[].alert' "$cp_json" | sort -u) | tr '\n' ' ')
  undeclared=""
  if [ -n "$copy_only" ]; then
    declared=""
    while IFS= read -r line; do
      body=$(printf '%s' "${line#*witness-only:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      if [ "$body" = "all" ]; then
        declared=$(jq -r '.[].alert' "$cp_json" | sort -u | tr '\n' ' ')
        break
      fi
      declared="$declared $(printf '%s' "$body" | tr ',' ' ')"
    done < <(grep -E '^# witness-only:' "$rf" || true)
    undeclared=$(comm -23 <(name_lines "$copy_only") <(name_lines "$declared") | tr '\n' ' ')
    if [ -n "$undeclared" ]; then
      crs_msg=$(printf '%s' "$crs" | tr '\n' ' ')
      echo "  DRIFT $rf: alert(s) [$undeclared] exist only in this copy and are not declared witness-only (CR: $crs_msg) — delete/rename them CR-side or add a 'witness-only:' declaration to the copy"
      rc=1
    fi
  fi
  # Counting: files with ≥1 CR-shared alert name carry a real pin; files with zero shared alerts but
  # ≥1 declared copy-only (witness) alert are witness-only (the "2 of 13 assert nothing" class, now
  # named as what they are). A file with no alert rules at all (recording-only copies such as
  # agent-goals, pinned by exporter-self-test instead) is neither.
  if [ -n "$(comm -12 <(jq -r '.[].alert' "$cr_json" | sort -u) <(jq -r '.[].alert' "$cp_json" | sort -u))" ]; then
    pins=$((pins+1))
  elif [ -n "$copy_only" ] && [ -z "$undeclared" ]; then
    witness_only=$((witness_only+1))
  fi
done
[ "$pins" -gt 0 ] && echo "prometheus-rules-lint: $pins hand-copy file(s) drift-pinned against their CRs"
[ "$witness_only" -gt 0 ] && echo "prometheus-rules-lint: $witness_only witness-only copy file(s) (no CR counterpart, fully declared)"
other=$(( $(find argocd -name "*.promtool-rules" | wc -l) - pins - witness_only ))
[ "$other" -gt 0 ] && echo "prometheus-rules-lint: $other copy file(s) with no alert rules (recording-only — pinned elsewhere, e.g. exporter-self-test)"
exit $rc
