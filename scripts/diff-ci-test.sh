#!/usr/bin/env bash
# diff-ci-test — drives the REAL scripts/diff-ci.sh RUN path (the local pre-flight, pr-open's
# `pr-gate`) in a throwaway repo, with `devbox`, `docker` and `curl` stubbed on PATH. Pins the
# NEEDS_ENV contract stated above that list in diff-ci.sh: a selected gate whose environment
# requirement is absent is skipped — said so, never counted as passed — runs where it is present,
# and DIFF_CI_REQUIRE_ENV=1 makes the absence a failure. `devbox run diff-ci -- --coverage-only`
# runs this after the belt (so ci.yaml's belt step does). DIFF_CI_UNDER_TEST=<path> points it at
# another copy of the script.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${DIFF_CI_UNDER_TEST:-$HERE/diff-ci.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/scripts" "$T/repo/.github/workflows" "$T/repo/gateway/specs" "$T/repo/argocd/resources/x"
# devbox stub: records every `devbox run <task…>`; a task named in $T/red exits 1.
cat >"$T/bin/devbox" <<STUB
#!/bin/sh
shift
echo "\$*" >>"$T/devbox.calls"
[ -f "$T/red" ] && grep -qxF -- "\$1" "$T/red" && exit 1
exit 0
STUB
# docker stub: a daemon that answers only while $T/docker-up exists (`docker info` exit 1 = the
# pod's "no usable daemon"; an absent binary takes the same branch of the same predicate).
cat >"$T/bin/docker" <<STUB
#!/bin/sh
[ -f "$T/docker-up" ]
STUB
# curl stub: records its arguments; the fetch succeeds only while $T/wan-up exists (else 28, curl's
# own timeout exit — the pod's "no egress").
cat >"$T/bin/curl" <<STUB
#!/bin/sh
echo "\$*" >>"$T/curl.calls"
[ -f "$T/wan-up" ] || exit 28
STUB
chmod +x "$T/bin/devbox" "$T/bin/docker" "$T/bin/curl"
cp "$SUT" "$T/repo/scripts/diff-ci.sh"
cp "$HERE/../.github/workflows/ci.yaml" "$T/repo/.github/workflows/ci.yaml"
# the chart-wan probe reads its host from component-check.sh — a fixture value, so the test can
# tell "read from the gate's script" from "restated in diff-ci.sh"
CHART_REPO=https://charts.fixture.invalid/kyv
printf '#!/bin/sh\nKYVERNO_POLICIES_CHART_REPO=%s\n' "$CHART_REPO" >"$T/repo/scripts/component-check.sh"
(
  cd "$T/repo" && git init -q -b master && git config user.email t@t && git config user.name t \
    && echo base >gateway/specs/a.md && echo 'a: 1' >argocd/resources/x/prometheusrule.yaml \
    && git add . && git commit -qm base && git tag base \
    && git checkout -qb fix/x && echo change >>gateway/specs/a.md && echo 'b: 2' >>argocd/resources/x/prometheusrule.yaml \
    && git commit -qam change
) || { echo "diff-ci-test: fixture repo setup failed" >&2; exit 1; }

pass=0; fail=0
# The fixture diff is one gateway/specs/*.md + one argocd/resources/** file. Per MAP it selects
# (among others) the two NEEDS_ENV rows and gates with no requirement:
E2E=gateway-specs-site-e2e   # needs docker
CC=component-check           # needs chart-wan
run() {  # [VAR=value …] — runs the RUN path against tag `base`; sets $out/$rc, resets the call logs
  : >"$T/devbox.calls"; : >"$T/curl.calls"
  out="$(cd "$T/repo" && env PATH="$T/bin:$PATH" "$@" bash scripts/diff-ci.sh base 2>&1)"; rc=$?
}
check() {  # <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"
  else fail=$((fail+1)); echo "FAIL $1 — want '$2', got '$3'"; printf '%s\n' "$out" | sed 's/^/     /'; fi
}
ran() { grep -cxF -- "$1" "$T/devbox.calls"; }            # times devbox was asked to run task $1
says() { printf '%s\n' "$out" | grep -cE -- "$1"; }       # output lines matching $1
world() { rm -f "$T/docker-up" "$T/wan-up" "$T/red"; for f in "$@"; do touch "$T/$f"; done; }

# 1. no docker daemon (WAN present): only the docker gate is skipped, and the exit is green
world wan-up; run DIFF_CI_REQUIRE_ENV=
check "no docker: exit 0"                                   0 "$rc"
check "no docker: the docker gate was not run"              0 "$(ran "$E2E")"
check "no docker: a requirement-free selected gate ran"     1 "$(ran gateway-ci)"
check "no docker: the chart gate (WAN present) ran"         1 "$(ran "$CC")"
# its NEEDS_ENV row is `ci` (ci.yaml has a `devbox run gateway-specs-site-e2e` step) → the CI claim
check "no docker: the SKIPPED line names the gate, docker, and that the PR's CI runs it" 1 "$(says "^ +SKIPPED \($E2E\).*needs docker.* — the PR's CI runs it\$")"
check "no docker: the gate is not reported ok"              0 "$(says "^ +ok \($E2E,")"
check "no docker: the final summary lists it as skipped"    1 "$(says "^diff-ci: SKIPPED for the environment.*: $E2E\$")"
n_run="$(wc -l <"$T/devbox.calls" | tr -d ' ')"
check "no docker: the run count excludes the skipped gate"  1 "$(says "^diff-ci: $n_run task\(s\) run,")"

# 2. no WAN to the chart host (docker present): only the chart gate is skipped
world docker-up; run DIFF_CI_REQUIRE_ENV=
check "no WAN: exit 0"                                      0 "$rc"
check "no WAN: the chart gate was not run"                  0 "$(ran "$CC")"
check "no WAN: the docker gate (daemon up) ran"             1 "$(ran "$E2E")"
check "no WAN: the other argocd/ gates still ran"           1 "$(ran prometheus-rules-lint)"
# its NEEDS_ENV row is `report-only` (ci.yaml has NO component-check step) → no CI claim at all
check "no WAN: the SKIPPED line says report-only, in no CI step, nothing runs it" 1 "$(says "^ +SKIPPED \($CC\).*needs chart-wan.* — report-only, in no CI step: nothing runs it for this PR, and it gates nothing\$")"
check "no WAN: nothing in the output claims CI runs the chart gate" 0 "$(says "CI runs (it|them)")"
check "no WAN: the gate is not reported ok"                 0 "$(says "^ +ok \($CC,")"
check "no WAN: the final summary lists it as skipped"       1 "$(says "^diff-ci: SKIPPED for the environment.*: $CC\$")"
check "no WAN: ONE probe, of the host component-check.sh names" "1 1" \
  "$(wc -l <"$T/curl.calls" | tr -d ' ') $(grep -cF -- "$CHART_REPO/index.yaml" "$T/curl.calls")"

# 3. neither: both skipped, both in the summary; a red gate that DID run is not masked
world; run DIFF_CI_REQUIRE_ENV=
check "neither: exit 0"                                     0 "$rc"
check "neither: the summary lists both"                     1 "$(says "^diff-ci: SKIPPED for the environment.*: $CC $E2E\$")"
world; echo gateway-ci >"$T/red"; run DIFF_CI_REQUIRE_ENV=
check "neither + a red run gate: exit 1"                    1 "$rc"
check "neither + a red run gate: FAILED names only it"      1 "$(says '^diff-ci: FAILED: gateway-ci$')"

# 4. the override: an absent requirement is a failure, and the gate is still not run
world; run DIFF_CI_REQUIRE_ENV=1
check "require env, neither: exit 1"                        1 "$rc"
check "require env, neither: FAILED names both gates"       1 "$(says "^diff-ci: FAILED: $CC $E2E\$")"
check "require env, neither: neither run"                   "0 0" "$(ran "$CC") $(ran "$E2E")"

# 5. both present: behaviour unchanged — both run, nothing is skipped
world docker-up wan-up; run DIFF_CI_REQUIRE_ENV=
check "both present: exit 0"                                0 "$rc"
check "both present: both gates ran"                        "1 1" "$(ran "$CC") $(ran "$E2E")"
check "both present: both reported ok"                      2 "$(says "^ +ok \(($CC|$E2E),")"
check "both present: no skip line"                          0 "$(says 'SKIPPED')"
world docker-up wan-up; echo "$CC" >"$T/red"; run DIFF_CI_REQUIRE_ENV=
check "both present + the chart gate red: exit 1"           1 "$rc"

# 6. the belt holds each row's cost field to ci.yaml (the fixture's is the real one): a row that
# claims CI for a task ci.yaml has no step for, or report-only for one it runs, exits 2
grep -q '^  "component-check:chart-wan:report-only"$' "$T/repo/scripts/diff-ci.sh" || { fail=$((fail+1)); echo "FAIL fixture: the component-check NEEDS_ENV row is not where the belt cases expect it"; }
cp "$T/repo/scripts/diff-ci.sh" "$T/sut.orig"
sed -i 's/^  "component-check:chart-wan:report-only"$/  "component-check:chart-wan:ci"/' "$T/repo/scripts/diff-ci.sh"
world docker-up wan-up; run DIFF_CI_REQUIRE_ENV=
check "a false CI claim (no ci.yaml step): exit 2"          2 "$rc"
check "…and no gate ran"                                    0 "$(wc -l <"$T/devbox.calls" | tr -d ' ')"
cp "$T/sut.orig" "$T/repo/scripts/diff-ci.sh"
sed -i 's/^  "gateway-specs-site-e2e:docker:ci"$/  "gateway-specs-site-e2e:docker:report-only"/' "$T/repo/scripts/diff-ci.sh"
world docker-up wan-up; run DIFF_CI_REQUIRE_ENV=
check "report-only on a task ci.yaml runs: exit 2"          2 "$rc"
cp "$T/sut.orig" "$T/repo/scripts/diff-ci.sh"

echo "diff-ci-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
