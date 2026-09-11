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

# ── the replay-tree exemption (ADR-097 addendum, 2026-08-18) ──────────────────────────────────
# agents/replay/** entries are stripped before intersection: replay-only footprints hold nothing
# and are held by nothing — including against the legacy `*` sentinel. Path-boundary aware:
# agents/replay-foo is a sibling name, NOT exempt.
expect 1 "replay vs replay never conflicts"           "agents/replay/**"      "agents/replay/**"
expect 1 "replay entry vs broad agents glob"          "agents/replay/fixtures/x/**" "agents/**"
expect 1 "replay-only vs the legacy sentinel"         "agents/replay/**"      "*"
expect 1 "bare agents/replay (no glob) is exempt"     "agents/replay"         "agents/replay/run.sh"
expect 0 "replay-ADJACENT name is not exempt"         "agents/replay-foo/**"  "agents/replay-foo/x.sh"
# ── the compelled-counterpart widening (homelab#601, 2026-08-19): suite pins + FSM models ──────
# Expected values from the contract (footprint.sh's three-class comment), not from running the
# code: a top-level suite script and an fsm model/view are compelled counterparts (exempt); a
# NESTED *-test.sh, a non-fsm doc, and the checker's own file are ordinary surfaces (not exempt).
expect 1 "top-level suite pin is exempt (state-fp)"    "agents/state-fp-replay.sh" "agents/state-fp-replay.sh"
expect 1 "top-level suite pin is exempt (-test.sh)"    "agents/board-test.sh"      "agents/board-test.sh"
expect 1 "FSM model yaml is exempt"                    "docs/agents/merge-path-fsm.yaml" "docs/agents/merge-path-fsm.yaml"
expect 1 "FSM generated view is exempt"                "docs/agents/iac-lane-fsm.md"     "docs/agents/iac-lane-fsm.md"
expect 0 "NESTED -test.sh is NOT exempt (depth guard)" "agents/coordinator/responder-behaviour-test.sh" "agents/coordinator/responder-behaviour-test.sh"
expect 0 "non-fsm agents doc is NOT exempt"            "docs/agents/workflow.md"   "docs/agents/workflow.md"
expect 0 "footprint.sh itself is NOT exempt"           "agents/footprint.sh"       "agents/footprint.sh"
expect 0 "mixed list: non-replay half still holds"    "agents/replay/**, agents/coordinator-scan.sh" "agents/coordinator-scan.sh"
expect 1 "mixed list: replay half holds nothing"      "agents/replay/**, docs/**" "agents/replay/fixtures/y/**"

# fp_conflict_strict — the GUARDED-check variant (PR#557 reviewer catch): NO replay exemption.
# The pin-only pre-dispatch check must read a declared replay footprint as touching a guarded
# file under agents/replay/ the day one exists there — exempting it would fail OPEN.
expect_strict() { # expect_strict <0|1> <desc> <listA> <listB>
  fp_conflict_strict "$3" "$4"; got=$?
  if [ "$got" -ne "$1" ]; then
    echo "FAIL: $2 (strict A='$3' B='$4' want=$1 got=$got)"; fails=$((fails + 1))
  fi
}
expect_strict 0 "strict: replay vs replay STILL conflicts"   "agents/replay/**" "agents/replay/run.sh"
expect_strict 0 "strict: sentinel vs replay conflicts"       "*"                "agents/replay/x"
expect_strict 1 "strict: disjoint stays disjoint"            "agents/replay/**" "docs/adr.md"

# ── the goal exemption (homelab#822) ──────────────────────────────────────────────────────────
# fp_goal_exempt returns 0 for "goal" class and 1 for every other class.
expect_goal_exempt() { # expect_goal_exempt <0|1> <desc> <class>
  fp_goal_exempt "$3"; got=$?
  if [ "$got" -ne "$1" ]; then
    echo "FAIL: $2 (class='$3' want=$1 got=$got)"; fails=$((fails + 1))
  fi
}
expect_goal_exempt 0 "goal class is exempt"                   "goal"
expect_goal_exempt 1 "fix class is not exempt"                "fix"
expect_goal_exempt 1 "doc class is not exempt"                "doc"
expect_goal_exempt 1 "empty class is not exempt"              ""
expect_goal_exempt 1 "arbitrary string is not exempt"         "anything-else"
# The ADR-097 footprint hold for goal-class items is skipped entirely (homelab#822), so
# fp_conflict/fp_conflict_multi don't need to strip goal entries — the scan's queued-dispatch
# loop checks fp_goal_exempt BEFORE calling fp_conflict_multi. Verify the invariant: a
# goal-issued `*` (no Touches line) still conflicts under fp_conflict (it is a different
# predicate for a different reader).
expect 0 "goal's star STILL conflicts under fp_conflict"       "*"                     "*"

# ── classify_touches — the platform lane tier table (homelab#1151) ──────────────────────────
# classify_touches <footprint> → "machine-merge" | "codeowner-merge" | "codeowner-author"
expect_classify() { # expect_classify <expected> <desc> <footprint>
  local result
  result="$(CLASSIFY_CODEOWNERS="$HERE/../CODEOWNERS" classify_touches "$3" 2>/dev/null || true)"
  if [ "$result" != "$1" ]; then
    echo "FAIL: classify_touches $2 (footprint='$3' want=$1 got=$result)"; fails=$((fails + 1))
  fi
}

# ❌ operator-author set — NEVER agent-authored
expect_classify "codeowner-author" "dot-github"              ".github/workflows/ci.yaml"
expect_classify "codeowner-author" "dot-agents"              ".agents/fix.yaml"
expect_classify "codeowner-author" "devbox.json"             "devbox.json"
expect_classify "codeowner-author" "devbox.lock"             "devbox.lock"
expect_classify "codeowner-author" "scripts"                 "scripts/governance-lint.sh"
expect_classify "codeowner-author" "scripts-dir"             "scripts/"

# Tier 1 — machine-merge (CI gate, unowned)
expect_classify "machine-merge"    "argocd-resources"        "argocd/resources/loki/"
expect_classify "machine-merge"    "argocd-resources-file"   "argocd/resources/loki/values.yaml"

# Tier 2 — codeowner-merge (applied out-of-band)
# ⚖ ADR-128 TRIAL WEEK 2026-09-11 → 09-18: docs/, tofu/ root, ansible/, opnsense/, machines/ and
# tofu/cloudflare/ are UNOWNED in CODEOWNERS for the week, so the classifier reads them
# machine-merge. The rows below pin the TRIAL shape; the revert (un-commenting the CODEOWNERS
# lines) flips these six expectations back to codeowner-merge in the same commit.
expect_classify "machine-merge"    "docs"                    "docs/agents/iac-lane.md"
expect_classify "machine-merge"    "argocd-platform"         "argocd/platform/arc-runners.yaml"
expect_classify "machine-merge"    "tofu-root"               "tofu/main.tf"
expect_classify "machine-merge"    "ansible"                 "ansible/playbook.yaml"
expect_classify "machine-merge"    "opnsense"                "opnsense/config.xml"
expect_classify "machine-merge"    "machines"                "machines/wk-01.yaml"

# Tier 3 — codeowner-merge (loop's own machinery)
expect_classify "codeowner-merge"  "agents"                  "agents/coordinator-scan.sh"
expect_classify "codeowner-merge"  "policy"                  "policy/iac/rule.yaml"
expect_classify "codeowner-merge"  "tofu-github"             "tofu/github/main.tf"
expect_classify "machine-merge"    "tofu-cloudflare"         "tofu/cloudflare/dns.tf"

# Carve-outs (unowned in CODEOWNERS — machine-merge)
expect_classify "machine-merge"    "images-env"              "agents/images.env"
expect_classify "machine-merge"    "kustomization"           "agents/coordinator/kustomization.yaml"

# Mixed footprint — highest tier wins
expect_classify "codeowner-author" "mixed-author-wins"       "docs/agents/, .github/workflows/"
expect_classify "codeowner-merge"  "mixed-merge-wins"        "argocd/resources/, agents/coordinator-scan.sh"

# Undeclared / sentinel — empty footprint returns machine-merge (no paths to classify)
expect_classify "machine-merge"    "empty-footprint"         ""
expect_classify "machine-merge"    "star-sentinel"           "*"

# ── THEME predicates (ADR-126 v1.3.1, homelab#1423 leg A) ─────────────────────────────────────
# fp_theme_groups: stdin `<n>|<touches>` lines → `<surface>|<members>` lines for every connected
# component (edges = fp_conflict) of size ≥ 2. Expected values are computed in the comments FROM
# the inputs and the contract (footprint.sh's header for the two predicates), never by running
# the code.
expect_groups() { # expect_groups <desc> <expected-output> <input-lines>
  local got
  got="$(printf '%b' "$3" | fp_theme_groups)"
  if [ "$got" != "$2" ]; then
    echo "FAIL: groups — $1"; echo "  want: $(printf '%s' "$2" | tr '\n' ';')"; echo "  got:  $(printf '%s' "$got" | tr '\n' ';')"; fails=$((fails + 1))
  fi
}
# positive: #302 (agents/coordinator/**, docs/x.md) ∩ #301 (agents/coordinator/scan.sh) — the
# file is under the glob → one edge → one group. Surface: candidates by prefix length are
# `docs/x.md` (9, conflicts with #302 only), `agents/coordinator` (18, conflicts with both),
# `agents/coordinator/scan.sh` (26) → the shortest conflicting-with-all is `agents/coordinator`.
# Members ascending numeric: input order 302,301 → output "301 302".
expect_groups "two sprouts sharing a prefix → one group, shortest common surface, members sorted" \
  "agents/coordinator|301 302" \
  '302|agents/coordinator/**, docs/x.md\n301|agents/coordinator/scan.sh\n'
# negative: disjoint footprints → no edge → no component of size ≥ 2 → empty output.
expect_groups "disjoint sprouts never group" "" '1|chassis/**\n2|gateway/**\n'
# sentinel + empty: `*` conflicts with everything (ADR-097) and would swallow both groups; an
# undeclared line is EXCLUDED before grouping, so #6 (`*`) and #8 (empty) appear in no group.
# #7 (gateway) is a singleton → excluded. Three-member group: #1 chassis/** ∩ #2 chassis/api.py
# ∩ #3 (chassis/**, docs/**) → all pairwise conflict → {1,2,3}; surface candidates by length:
# `docs` (4, conflicts with #3 only), `chassis` (7, conflicts with all three) → `chassis`.
# Second group: #5 src/a/** ∩ #4 src/a/x.py → {4,5}, surface `src/a` (5, shortest, conflicts
# with both). Groups sorted by surface: "chassis" < "src/a" (C collation).
expect_groups "three-member group + a disjoint pair; sentinel/empty/singleton lines excluded" \
  "$(printf 'chassis|1 2 3\nsrc/a|4 5')" \
  '5|src/a/**\n1|chassis/**\n2|chassis/api.py\n3|chassis/**, docs/**\n4|src/a/x.py\n6|*\n7|gateway/**\n8|\n'
# exempt-only lists: fp_conflict strips agents/replay/** before pairing, so two replay-only
# sprouts share no edge → no group (the pin surface is an allowance, never a theme).
expect_groups "replay-exempt-only lists never group" "" '1|agents/replay/**\n2|agents/replay/fixtures/x/**\n'
# no candidate conflicts with EVERY member (a chain: 1∩2 via chassis, 2∩3 via docs, 1∥3):
# the component is {1,2,3} but no single prefix conflicts with all → the shortest non-exempt
# entry in the group: `docs` (4) < `chassis` (7) < `chassis/api.py` (14) → `docs`.
expect_groups "chained component with no common surface falls back to the shortest entry" \
  "docs|1 2 3" \
  '1|chassis/**\n2|chassis/api.py, docs/**\n3|docs/adr.md\n'
# determinism: the same input twice → byte-identical output (the replay diffs the report line).
g1="$(printf '9|a/**\n3|a/b.py\n7|z/**\n8|z/q\n' | fp_theme_groups)"
g2="$(printf '9|a/**\n3|a/b.py\n7|z/**\n8|z/q\n' | fp_theme_groups)"
[ "$g1" = "$g2" ] && [ "$g1" = "$(printf 'a|3 9\nz|7 8')" ] || { echo "FAIL: groups — determinism / two groups (got: $(printf '%s' "$g1" | tr '\n' ';'))"; fails=$((fails + 1)); }

# fp_theme_member <touches> <fix-surface> → 0 iff every non-exempt entry is under some surface
# entry (path boundary); exempt entries skipped; empty / `*` → 1.
expect_member() { # expect_member <0|1> <desc> <touches> <surface>
  fp_theme_member "$3" "$4"; got=$?
  if [ "$got" -ne "$1" ]; then
    echo "FAIL: member — $2 (touches='$3' surface='$4' want=$1 got=$got)"; fails=$((fails + 1))
  fi
}
# positive: agents/coordinator/scan.sh is under agents/coordinator (path boundary); the replay
# entry is exempt (the pin-surface allowance) and skipped → every non-exempt entry covered → 0.
expect_member 0 "file under the surface + a pin entry"          "agents/coordinator/scan.sh, agents/replay/**" "agents/coordinator/**"
expect_member 0 "identical entry is a member"                   "chassis/**"                "chassis/**"
expect_member 0 "two surfaces, each entry under one"            "docs/a.md, src/x/y.py"     "docs/**, src/**"
# negative: agents/coordinator-scan.sh shares the string prefix but NOT the path boundary
# (chassis vs chassis-x) → not under agents/coordinator → 1.
expect_member 1 "path-boundary: sibling name escapes"           "agents/coordinator-scan.sh" "agents/coordinator/**"
expect_member 1 "one entry escapes → the whole list escapes"    "docs/a.md, scripts/x.sh"   "docs/**"
expect_member 1 "surface narrower than the entry escapes"       "agents/**"                 "agents/coordinator/**"
# sentinel / empty: undeclared is exclusive, never a member.
expect_member 1 "star sentinel is never a member"               "*"                         "agents/**"
expect_member 1 "empty list is never a member"                  ""                          "agents/**"
expect_member 1 "empty surface covers nothing"                  "docs/a.md"                 ""
# exempt-only list: every entry is skipped, the universal quantifier is vacuously true → 0
# (a pin-only sprout fits any theme — delta 2's implicit allowance).
expect_member 0 "exempt-only list is a member of any surface"   "agents/replay/**, agents/footprint-test.sh" "docs/**"
# a leading-glob entry has no prefix — it is under nothing → 1; a leading-glob SURFACE entry
# covers nothing (it is not a surface) → ignored, so the entry escapes → 1.
expect_member 1 "leading-glob entry is under nothing"           "**/conftest.py"            "tests/**"
expect_member 1 "leading-glob surface covers nothing"           "tests/unit/a.py"           "**/unit/**"

if [ "$fails" -gt 0 ]; then
  echo "footprint-test: ${fails} FAILED"
  exit 1
fi
echo "footprint-test: all rules hold"
