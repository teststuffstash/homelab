#!/usr/bin/env bash
# devbox-update-test — the lock-diff gate of scripts/devbox-update.sh (`lock_moves`, loaded through
# its DEVBOX_UPDATE_LIB seam — no clone, no push, no gh) over the RECORDED #2260 lock diff
# (scripts/fixtures/devbox-update/, gap register G17) plus two synthetic locks. Every expectation is
# derived from the rule in the script's header, never from running it:
#   majors     = exactly argo-workflows (3.6.10 → 4.0.5 — the leading integer moved; the other 17 did not)
#   downgrades = exactly openssl (3.6.0 → 3.5.8 — numerically lower, same major)
#   lines      = exactly python3 3.12→3.14, opentofu 1.12→1.13, kubectl 1.36→1.37 (LINE_PACKAGES whose
#                major.minor moved; openssl is in the set but its minor move is reported ONCE, as the
#                downgrade — a line-move row for it would double-count the same fact)
#   a no-move lock → all three empty and the body section prints "none" twice
#   an unparseable version pair (a hash) → majors (changed + unparseable), never downgrades
#   devbox run devbox-update-test
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v jq >/dev/null || { echo "FAIL: jq not on PATH — run via \`devbox run devbox-update-test\`"; exit 1; }
# shellcheck source=devbox-update.sh
DEVBOX_UPDATE_LIB=1 . "$HERE/devbox-update.sh" || { echo "FAIL: could not load lock_moves from devbox-update.sh"; exit 1; }
F="$HERE/fixtures/devbox-update"
fails=0; n=0
check() {  # check <name> <want> <got>
  n=$((n+1))
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  want: $2"; echo "  got:  $3"; fails=$((fails+1)); fi
}

moves="$(lock_moves "$(cat "$F/pr2260-old.lock")" "$(cat "$F/pr2260-new.lock")")" || { echo "FAIL: lock_moves errored on the #2260 fixture"; exit 1; }
check "2260: one major, argo-workflows"      "argo-workflows: 3.6.10 → 4.0.5" "$(jq -r '.majors | join(";")' <<<"$moves")"
check "2260: one downgrade, openssl"         "openssl: 3.6.0 → 3.5.8"         "$(jq -r '.downgrades | join(";")' <<<"$moves")"
check "2260: line moves python3/opentofu/kubectl" "kubectl: 1.36.3 → 1.37.1;opentofu: 1.12.5 → 1.13.1;python3: 3.12.8 → 3.14.7" \
      "$(jq -r '.lines | sort | join(";")' <<<"$moves")"
check "2260: 18 packages moved in the fixture (the recorded diff is intact)" 18 \
      "$(jq -rn --argjson o "$(cat "$F/pr2260-old.lock")" --argjson n "$(cat "$F/pr2260-new.lock")" '[$n.packages | to_entries[] | select($o.packages[.key].version != .value.version)] | length')"

# the body section renders one bullet per item under the two labelled lists
sec="$(lock_moves_section "$(jq -r '.downgrades[]' <<<"$moves")" "$(jq -r '.lines[]' <<<"$moves")")"
check "2260: section names the downgrade"    1 "$(grep -c -- '^- openssl: 3.6.0 → 3.5.8$' <<<"$sec")"
check "2260: section names the three lines"  3 "$(grep -cE -- '^- (python3|opentofu|kubectl): ' <<<"$sec")"
check "2260: section heading is the G17 one" 1 "$(grep -c '^### Downgrades and compatibility-line moves' <<<"$sec")"

# no move at all → empty lists, "none" twice
same='{"packages":{"jq@latest":{"version":"1.8.1"},"python3@latest":{"version":"3.14.7"}}}'
moves="$(lock_moves "$same" "$same")"
check "no-move: all three lists empty"       "0 0 0" "$(jq -r '"\(.majors|length) \(.downgrades|length) \(.lines|length)"' <<<"$moves")"
check "no-move: section says none twice"     2 "$(lock_moves_section "" "" | grep -c -- '^- none$')"

# synthetic edge cases: a pin change keyed by base name; an unparseable pair; a pre-release component
old='{"packages":{"kubernetes-helm@3":{"version":"3.18.0"},"foo@latest":{"version":"abc123"},"bar@latest":{"version":"2.4.0"},"opentofu@latest":{"version":"1.12.5"},"kubectl@latest":{"version":"1.36.3"}}}'
new='{"packages":{"kubernetes-helm@latest":{"version":"4.0.1"},"foo@latest":{"version":"def456"},"bar@latest":{"version":"2.4.0-rc1"},"opentofu@latest":{"version":"1.12.9"},"kubectl@latest":{"version":"1.35.0"}}}'
moves="$(lock_moves "$old" "$new")"
check "edge: pin change still a major (base-name keyed) + unparseable pair is a major" \
      "foo: abc123 → def456;kubernetes-helm: 3.18.0 → 4.0.1" "$(jq -r '.majors | sort | join(";")' <<<"$moves")"
check "edge: unparseable pair never a downgrade; rc suffix compares on leading digits (equal → not a downgrade); kubectl 1.36 → 1.35 IS one" \
      "kubectl: 1.36.3 → 1.35.0" "$(jq -r '.downgrades | join(";")' <<<"$moves")"
check "edge: opentofu patch move is no line move; kubectl's downward minor move is the downgrade row only" \
      "" "$(jq -r '.lines | join(";")' <<<"$moves")"

echo "devbox-update-test: $n check(s), $fails failure(s)"
[ "$fails" -eq 0 ]
