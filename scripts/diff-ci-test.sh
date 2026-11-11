#!/usr/bin/env bash
# diff-ci-test — drives the REAL scripts/diff-ci.sh RUN path (the local pre-flight, pr-open's
# `pr-gate`) in a throwaway repo, with `devbox` and `docker` stubbed on PATH. Pins the NEEDS_DOCKER
# contract stated above that list in diff-ci.sh: a selected gate that needs docker is skipped —
# said so, never counted as passed — where no docker daemon answers, runs where one does, and
# DIFF_CI_REQUIRE_DOCKER=1 makes the absence a failure. `devbox run diff-ci -- --coverage-only`
# runs this after the belt (so ci.yaml's belt step does). DIFF_CI_UNDER_TEST=<path> points it at
# another copy of the script.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${DIFF_CI_UNDER_TEST:-$HERE/diff-ci.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/scripts" "$T/repo/.github/workflows" "$T/repo/gateway/specs"
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
chmod +x "$T/bin/devbox" "$T/bin/docker"
cp "$SUT" "$T/repo/scripts/diff-ci.sh"
cp "$HERE/../.github/workflows/ci.yaml" "$T/repo/.github/workflows/ci.yaml"
(
  cd "$T/repo" && git init -q -b master && git config user.email t@t && git config user.name t \
    && echo base >gateway/specs/a.md && git add . && git commit -qm base && git tag base \
    && git checkout -qb fix/x && echo change >>gateway/specs/a.md && git commit -qam spec
) || { echo "diff-ci-test: fixture repo setup failed" >&2; exit 1; }

pass=0; fail=0
E2E=gateway-specs-site-e2e   # the docker-needing row a gateway/specs/*.md change selects (MAP)
run() {  # [VAR=value …] — runs the RUN path against tag `base`; sets $out/$rc, resets the call log
  rm -f "$T/devbox.calls"; : >"$T/devbox.calls"
  out="$(cd "$T/repo" && env PATH="$T/bin:$PATH" "$@" bash scripts/diff-ci.sh base 2>&1)"; rc=$?
}
check() {  # <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"
  else fail=$((fail+1)); echo "FAIL $1 — want '$2', got '$3'"; printf '%s\n' "$out" | sed 's/^/     /'; fi
}
ran() { grep -cxF -- "$1" "$T/devbox.calls"; }            # times devbox was asked to run task $1
says() { printf '%s\n' "$out" | grep -cE -- "$1"; }       # output lines matching $1

# 1. no daemon: the docker gate is not run, every other selected gate is, and the exit is green
rm -f "$T/docker-up" "$T/red"; run DIFF_CI_REQUIRE_DOCKER=
check "no docker: exit 0"                                   0 "$rc"
check "no docker: the docker gate was not run"              0 "$(ran "$E2E")"
check "no docker: a docker-free selected gate still ran"    1 "$(ran gateway-ci)"
check "no docker: a SKIPPED line names the gate, docker and CI" 1 "$(says "^ +SKIPPED \($E2E\).*docker.*CI runs it")"
check "no docker: the gate is not reported ok"              0 "$(says "^ +ok \($E2E,")"
check "no docker: the final summary lists it as skipped"    1 "$(says "^diff-ci: SKIPPED for the environment.*: $E2E\$")"
n_run="$(wc -l <"$T/devbox.calls" | tr -d ' ')"
check "no docker: the run count excludes the skipped gate"  1 "$(says "^diff-ci: $n_run task\(s\) run,")"

# 2. no daemon does not mask a red gate that DID run
echo gateway-ci >"$T/red"; run DIFF_CI_REQUIRE_DOCKER=
check "no docker + a red run gate: exit 1"                  1 "$rc"
check "no docker + a red run gate: FAILED names it"         1 "$(says '^diff-ci: FAILED: gateway-ci$')"
rm -f "$T/red"

# 3. the override: absence is a failure, and the gate is still not run
run DIFF_CI_REQUIRE_DOCKER=1
check "require docker, none: exit 1"                        1 "$rc"
check "require docker, none: FAILED names the gate"         1 "$(says "^diff-ci: FAILED: $E2E\$")"
check "require docker, none: not run"                       0 "$(ran "$E2E")"

# 4. a daemon answers: behaviour unchanged — the gate runs and nothing is skipped
touch "$T/docker-up"; run DIFF_CI_REQUIRE_DOCKER=
check "docker up: exit 0"                                   0 "$rc"
check "docker up: the docker gate ran"                      1 "$(ran "$E2E")"
check "docker up: reported ok"                              1 "$(says "^ +ok \($E2E,")"
check "docker up: no skip line"                             0 "$(says 'SKIPPED')"
echo "$E2E" >"$T/red"; run DIFF_CI_REQUIRE_DOCKER=
check "docker up + the gate red: exit 1"                    1 "$rc"

echo "diff-ci-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
