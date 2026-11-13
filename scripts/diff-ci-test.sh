#!/usr/bin/env bash
# diff-ci-test — the pinned cases of `diff-ci.sh --ci-outputs` (the PR skip map). Run by
# `diff-ci -- --coverage-only`, which CI runs on every PR whose paths reach either file.
#
# The base side is injected without network: DIFF_CI_BASE_GIT_REF points at a TREE object built
# here that holds only a modified base copy of devbox.json or diff-ci.sh. The head side is the
# working tree, so the cases hold on any checkout, shallow CI included. GITHUB_BASE_REF and
# GITHUB_REPOSITORY are unset so a missing base can never fall through to the real API.
set -euo pipefail
cd "$(dirname "$0")/.."
unset GITHUB_BASE_REF GITHUB_REPOSITORY

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; n=0

# tree_with <path> <file>: a tree object holding only <path> = <file>'s content.
tree_with() {
  local blob; blob=$(git hash-object -w "$2")
  GIT_INDEX_FILE="$T/idx" git update-index --add --cacheinfo "100644,$blob,$1"
  local tree; tree=$(GIT_INDEX_FILE="$T/idx" git write-tree); rm -f "$T/idx"
  printf '%s\n' "$tree"
}
# sel <base-ref> <changed-path>... : run the selection, leave key=bool lines in $T/out
sel() {
  local ref="$1"; shift
  printf '%s\n' "$@" | grep . >"$T/list" || : >"$T/list"
  DIFF_CI_BASE_GIT_REF="$ref" bash scripts/diff-ci.sh --ci-outputs "$T/list" >"$T/out"
}
is()  { n=$((n+1)); grep -qx "$2=$3" "$T/out" || { echo "diff-ci-test: FAIL [$1] expected $2=$3" >&2; fail=1; }; }
all() { n=$((n+1)); ! grep -q '=false$' "$T/out" || { echo "diff-ci-test: FAIL [$1] expected every row, skipped: $(grep '=false$' "$T/out" | cut -d= -f1 | tr '\n' ' ')" >&2; fail=1; }; }

# 1. devbox.json, a scripts-only edit to one task → that task + its callers, nothing unrelated
jq '.shell.scripts["maint-self-test"] += ["true"]' devbox.json >"$T/dj"
sel "$(tree_with devbox.json "$T/dj")" devbox.json
is scripts-only maint-self-test true
is scripts-only mgmt-policy-test true     # mgmt/scripts/mgmt-policy-test.sh calls it
is scripts-only xr-render false
is scripts-only gateway-ci false

# 2. devbox.json, any key outside shell.scripts → every row
jq '.packages += {"diff-ci-test-pkg": "latest"}' devbox.json >"$T/dj"
sel "$(tree_with devbox.json "$T/dj")" devbox.json
all package-edit

# 3. devbox.lock alone → every row except the gateway island's own-devbox tasks
sel nope devbox.lock
for g in gateway-ci gateway-evidence gateway-evidence-publish gateway-specs-publish gateway-specs-site-e2e; do
  is lock-only "$g" false
done
n=$((n+1)); [ "$(grep -c '=false$' "$T/out")" -eq 5 ] || { echo "diff-ci-test: FAIL [lock-only] expected exactly the 5 gateway rows skipped, got: $(grep '=false$' "$T/out" | cut -d= -f1 | tr '\n' ' ')" >&2; fail=1; }

# 4. diff-ci.sh, one MAP regex edited against a base that has --dump-map → that row, not others
sed 's#"machines-lint:^(machines/#"machines-lint:^(machines-base-only/|machines/#' scripts/diff-ci.sh >"$T/dc"
cmp -s "$T/dc" scripts/diff-ci.sh && { echo "diff-ci-test: FAIL [map-edit] fixture sed matched nothing — re-aim it at a live row" >&2; exit 1; }
sel "$(tree_with scripts/diff-ci.sh "$T/dc")" scripts/diff-ci.sh
is map-edit machines-lint true
is map-edit xr-render false
is map-edit diff-ci-coverage-only true    # its regex matches the script path

# 5. fail-open cases → every row
printf '#!/bin/sh\nexit 2\n' >"$T/old"
sel "$(tree_with scripts/diff-ci.sh "$T/old")" scripts/diff-ci.sh; all base-without-dump-map
sel nope devbox.json;                                              all unreadable-base
sel nope .github/workflows/ci.yaml;                                all ci-yaml
sel nope;                                                          all empty-list

# 6. a docs-only change stays narrow (the selection is not "every row" by accident)
sel nope docs/ci.md
is docs-only xr-render false
is docs-only follow-ups-lint true

[ "$fail" -eq 0 ] || exit 1
echo "diff-ci-test: ok ($n assertions over the --ci-outputs selection)"
