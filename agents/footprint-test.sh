#!/usr/bin/env bash
# footprint-test.sh — the ADR-097 double-dispatch belt: synthetic tests over the EXACT predicate
# the scan sources (agents/footprint.sh). The miscount class has bitten twice (#55 races,
# issue-96 null-strip); with WIP>1 a predicate bug double-dispatches into a lane instead of
# deferring — so every rule here is a regression fence, run in ci (devbox run footprint-test).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/footprint.sh"

fails=0
expect() { # expect <0|1> <desc> <listA> <listB>
  fp_conflict "$3" "$4"; got=$?
  if [ "$got" -ne "$1" ]; then
    echo "FAIL: $2 (A='$3' B='$4' want=$1 got=$got)"; fails=$((fails + 1))
  fi
}

# overlap holds
expect 0 "identical entries conflict"                 "chassis/**"            "chassis/**"
expect 0 "glob contains file"                         "chassis/**"            "chassis/api.py"
expect 0 "file inside glob (order flipped)"           "chassis/api.py"        "chassis/**"
expect 0 "deep nesting conflicts"                     "mcps/x/ingest/**"      "mcps/**"
expect 0 "one overlapping entry among disjoint ones"  "docs/**, pyproject.toml" "scripts/**, pyproject.toml"
expect 0 "undeclared sentinel conflicts with anything" "*"                    "docs/readme.md"
expect 0 "sentinel on either side"                    "chart/**"              "*"
expect 0 "leading-glob entry is conservative"         "**/conftest.py"        "tests/unit/**"
expect 0 "bare directory vs its file"                 "chart"                 "chart/values.yaml"

# disjoint dispatches
expect 1 "sibling dirs are disjoint"                  "chassis/**"            "gateway/**"
expect 1 "path-boundary: chassis vs chassis-x"        "chassis/**"            "chassis-x/**"
expect 1 "distinct files are disjoint"                "pyproject.toml"        "uv.lock"
expect 1 "multi-entry fully disjoint"                 "docs/**, chart/**"     "scripts/**, src/**"
expect 1 "empty list never conflicts"                 ""                      "chassis/**"
expect 1 "prefix-similar files are disjoint"          "chart/values.yaml"     "chart/values.schema.json"

# fp_conflict_multi: any line holds; no lines never holds
multi_busy="$(printf 'chassis/**\ndocs/**')"
if ! fp_conflict_multi "docs/adr.md" "$multi_busy"; then
  echo "FAIL: multi — second line should hold"; fails=$((fails + 1))
fi
if fp_conflict_multi "gateway/**" "$multi_busy"; then
  echo "FAIL: multi — disjoint from every line must not hold"; fails=$((fails + 1))
fi
if fp_conflict_multi "*" ""; then
  echo "FAIL: multi — empty busy set must never hold (idle repo dispatches)"; fails=$((fails + 1))
fi

# the migration invariant: undeclared (*) vs undeclared (*) conflicts — two legacy issues can
# never run in parallel, which IS the old WIP=1 behavior.
expect 0 "legacy vs legacy stays serial"              "*"                     "*"

if [ "$fails" -gt 0 ]; then
  echo "footprint-test: ${fails} FAILED"
  exit 1
fi
echo "footprint-test: all rules hold"
