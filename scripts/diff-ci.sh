#!/bin/bash
# diff-ci — run only the CI gates the current diff can affect (#518, 2026-08-31): the local
# pre-flight for agents and the seat. Same devbox tasks CI runs, scoped by a path→task map.
#
# ONE HOME: this map is the canonical statement of "which paths feed which gate".
# `.github/workflows/ci.yaml`'s changed-paths step eval-extracts PROM_PATHS/CLAUSE_PATHS from
# THIS file (the scripts/pin-only-lint.sh one-home pattern; the #518 flip landed 2026-08-31) —
# edit trigger sets here, never inline there. CI stays AUTHORITATIVE: a too-narrow mapping here
# costs a surprise red in CI,
# never a merged defect (CI's skip map only covers the two heavy suites; everything else
# always runs there). The PR-context gates (pin-only-lint, governance-lint, the ADR-103
# ratchet) need the PR's base/author and do not run here.
#
# Usage: devbox run diff-ci [base-ref]
#   Compares merge-base(base-ref, HEAD)..worktree (staged + unstaged + untracked included);
#   base-ref defaults to origin/master.
#        devbox run diff-ci -- --coverage-only
#   Runs ONLY the coverage belt below (no git base needed) and exits 0/2. This is the CI
#   form (#2072): the belt was local-only and rotted the first time a ci.yaml step landed
#   without a MAP row (#2026's pin-only-lint-test — every worker's pre-flight went red on
#   pristine master). With ci.yaml running it, a new step without a row reds the PR that
#   adds the step, not the next person's pre-flight.
set -euo pipefail
cd "$(dirname "$0")/.."

# Single-line assignments — ci.yaml `eval "$(grep -m1 '^PROM_PATHS=' scripts/diff-ci.sh)"`s
# these verbatim (the #518 flip, live 2026-08-31); keep them one line, single-quoted, eval-safe.
PROM_PATHS='^(argocd/|tofu/|scripts/prometheus-rules-lint\.sh|devbox\.(json|lock)$)'
CLAUSE_PATHS='^(agents/|devbox\.(json|lock)$)'
# #1315: the Composition, the two cluster pins it renders with (functions + provider version),
# the gate's own script/fixtures, and the devbox closure that ships the nix provider.
PUBLICROUTE_PATHS='^(argocd/resources/publicroute/|argocd/resources/crossplane/(providerconfig|functions)\.yaml$|argocd/platform/crossplane\.yaml$|scripts/publicroute-tf-validate\.sh$|scripts/fixtures/publicroute/|devbox\.(json|lock)$)'
# the management box's policy + its readers (ADR-131): the stage-1 fixtures + the fail-closed reads
MGMT_PATHS='^(policy/mgmt/|mgmt/scripts/mgmt-[a-z-]*\.sh$|mgmt/scripts/mgmt-root-env/|scripts/iac-sentinel\.sh$|devbox\.(json|lock)$)'

# task:trigger-regex (first `:` splits; task may carry args and is word-split at run time).
# Buckets are deliberately COARSE (agents/ runs the whole agents suite, ~10 quick tasks) —
# precision is only worth chasing on the expensive rows (the two heavies + the self-tests
# scoped to their deployment dir).
MAP=(
  "argocd-validate-pins:^argocd/"
  "manifest-lint:^argocd/"
  "agentstack-rbac-lint:^argocd/resources/(agentstack|crossplane)/"
  "sentinel-smoke:^(policy/iac/|scripts/iac-sentinel\.sh|devbox\.(json|lock)$)"
  "mgmt-policy-test:$MGMT_PATHS"
  "prometheus-rules-lint:$PROM_PATHS"
  "exporter-self-test:^argocd/resources/github-exporter/"
  "edge-probe-self-test:^argocd/resources/cloudflare-exporter/"
  "spend-probe-self-test:^argocd/resources/cloudflare-exporter/"
  "publicroute-tf-validate:$PUBLICROUTE_PATHS"
  "argo-lint:^agents/coordinator/"
  "router-self-test:^argocd/resources/openrouter-proxy/"
  "proxy-self-test:^argocd/resources/openrouter-proxy/"
  "responder-behaviour-test:^agents/"
  "deep-dig-test:^agents/"
  "estimate-budget -- --self-test:^agents/"
  "rail-degrade-replay:^agents/"
  "state-fp-replay:^agents/"
  "clause-replay:$CLAUSE_PATHS"
  "goal-findings-self-test:^agents/"
  "footprint-test:^agents/"
  "touches-check-test:^agents/"
  "model-id-test:^(agents/|argocd/resources/openrouter-proxy/)"
  "merge-path-lint:^(agents/|scripts/merge-path-lint\.py|docs/agents/)"
  "agents-registration-lint:^(agents/|tofu/github/)"
  "github-apps-lint:^(agents/|scripts/|docs/github-apps)"
  "prompt-transport-lint:^(agents/|argocd/|scripts/)"
  "py-compile-lint:\.py$"
  # every tracked shell file + the lint itself (the replay suite also runs it, fixtures/sigpipe-lint/)
  "sigpipe-lint:(\.(sh|bash)$|^scripts/sigpipe-lint\.py$|^githooks/|^agents/replay/stubs/)"
  "shim-self-test:^scripts/claude-model-shim\.py"
  # the self-test's only inputs are scripts/pin-only-lint.sh + scripts/pin-only-lint-test.sh (#2072)
  "pin-only-lint-test:^scripts/pin-only-lint"
  # the self-test's inputs: the CLI + its test, and the vendored hook copy it asserts byte-identical (ADR-150)
  "upgrade-lease-test:^(agents/upgrade-lease|argocd/resources/kube-prometheus-stack-lease/upgrade-lease\.sh)"
  "devbox-update-test:^scripts/devbox-update|^scripts/fixtures/devbox-update/"
  # the self-test's only inputs are scripts/governance-lint.sh + scripts/governance-lint-test.sh (FU-296)
  "governance-lint-test:^scripts/governance-lint"
  # the belt's own CI invocation, covered by the belt: ci.yaml's `devbox run diff-ci -- --coverage-only`
  # is extracted below as task `diff-ci` and matches this row's first word. Locally this is one
  # level of recursion (a belt-only run, no git base) that exits in well under a second.
  "diff-ci -- --coverage-only:^(scripts/diff-ci\.sh|\.github/workflows/ci\.yaml)$"
  "machines-lint:^machines/"
  "maint-self-test:^scripts/maintenance-window"
  # the self-test drives the verb against stubs; mgmt-tf's `summary` line format is its plan-scope input
  "runner-maint-self-test:^(scripts/runner-maintenance|mgmt/scripts/mgmt-tf\.sh$|tofu/ci-runner\.tf$|machines/machines\.yaml$)"
  # the self-test's only inputs are scripts/pr-wait.sh + scripts/pr-wait-test.sh (2026-10-04)
  "pr-wait-test:^scripts/pr-wait"
  "-- tofu fmt -check -recursive tofu/:^tofu/"
  "follow-ups-lint:^docs/"
  "docs-graph-lint:\.md$"
  "mermaid-lint:(\.md$|^scripts/mermaid-lint)"
  "lock-intake-lint-test:^scripts/lock-intake-lint"
  # request-flow-self-test renders docs/patterns/request-flow/{platform,example-*}.yaml with
  # scripts/request-flow-render.py and byte-compares the committed example-*-rendered.md — those
  # are its only inputs (#1390; the round-5 worker on PR#1386 proposed an `agents/` arm too, which
  # nothing in the self-test reads).
  "request-flow-self-test:^(scripts/request-flow-render\.py|docs/patterns/request-flow/|devbox\.(json|lock)$)"
)
# Gates that exist in ci.yaml but are PR-context-only (base/author) — exempt from the
# coverage belt below, with the reason on the record.
PR_ONLY="pin-only-lint governance-lint lock-intake-lint"

# --coverage-only: run the belt and stop (the CI form — see the header). Parsed before the
# base-ref positional so `devbox run diff-ci -- --coverage-only` needs no origin/master.
COVERAGE_ONLY=false
if [ "${1:-}" = "--coverage-only" ]; then COVERAGE_ONLY=true; shift; fi

# ── coverage belt: every `devbox run <task>` in ci.yaml must appear in MAP or PR_ONLY, so a
# new CI step cannot silently rot this map (the unexecuted-gate class, ADR-103's lesson).
# Runs in CI too since #2072 (`devbox run diff-ci -- --coverage-only`), so the map cannot rot
# past the PR that adds the step.
ci_tasks=$(grep -vE '^\s*#' .github/workflows/ci.yaml | grep -oE 'devbox run [a-z][a-z-]*' | awk '{print $3}' | sort -u)
for t in $ci_tasks; do
  hit=false
  for entry in "${MAP[@]}"; do [ "${entry%%:*}" = "$t" ] || [ "${entry%% *}" = "$t" ] && { hit=true; break; }; done
  for p in $PR_ONLY; do [ "$p" = "$t" ] && hit=true; done
  $hit || { echo "diff-ci: FAIL — ci.yaml runs '$t' but the map here doesn't know it; add a row (one home)" >&2; exit 2; }
done
# `devbox run -- <cmd …>` lines start with `-`, invisible to the extraction above (#1147 review
# follow-up). Match the full remainder against the MAP keys. Utility invocations that are not
# gates are exempt by FIRST TOKEN (`gh` = PR-data fetches inside PR-context steps, `true` = the
# devbox warm-up) — a new `-- <tool>` gate reds here until it gets a MAP row or a conscious
# exemption, which is the belt doing its job.
while IFS= read -r dd; do
  [ -n "$dd" ] || continue
  case "${dd#-- }" in gh\ *|true) continue;; esac
  hit=false
  for entry in "${MAP[@]}"; do [ "${entry%%:*}" = "$dd" ] && { hit=true; break; }; done
  $hit || { echo "diff-ci: FAIL — ci.yaml runs 'devbox run $dd' but the map here doesn't know it; add a row (one home)" >&2; exit 2; }
done <<EOF_DDBELT
$(grep -vE '^\s*#' .github/workflows/ci.yaml | grep -oE 'devbox run -- .*' | sed -e 's/^devbox run //' -e 's/[[:space:]]*$//' | sort -u)
EOF_DDBELT
belt_n=$(( $(printf '%s\n' $ci_tasks | grep -c .) + $(grep -vE '^\s*#' .github/workflows/ci.yaml | grep -oE 'devbox run -- .*' | sed -e 's/^devbox run //' -e 's/[[:space:]]*$//' | sort -u | grep -c .) ))
if $COVERAGE_ONLY; then
  echo "diff-ci: coverage belt ok (every ci.yaml devbox task — $belt_n distinct — has a MAP row or a PR_ONLY exemption)"
  exit 0
fi

BASE="${1:-origin/master}"
base=$(git merge-base "$BASE" HEAD) || { echo "diff-ci: cannot find merge-base with $BASE (fetch it first?)" >&2; exit 2; }
changed=$( { git diff --name-only "$base"; git diff --name-only --cached; git status --porcelain | awk '{print $NF}'; } | sort -u | grep . || true)
[ -n "$changed" ] || { echo "diff-ci: no changes vs $BASE — nothing to run"; exit 0; }
echo "diff-ci: $(printf '%s\n' "$changed" | grep -c .) changed file(s) vs $BASE"

run=0; skipped=0; failed=""
if grep -qE '^devbox\.(json|lock)$' <<< "$changed"; then
  echo "diff-ci: devbox pins changed — running EVERYTHING"
  match_all=true
else
  match_all=false
fi
for entry in "${MAP[@]}"; do
  task="${entry%%:*}"; regex="${entry#*:}"
  if ! $match_all && ! grep -qE "$regex" <<< "$changed"; then
    skipped=$((skipped+1)); continue
  fi
  echo "── devbox run $task"
  t0=$SECONDS
  # shellcheck disable=SC2086 — task strings intentionally word-split (args ride along)
  if devbox run $task; then
    echo "   ok (${task%% *}, $((SECONDS-t0))s)"
  else
    echo "   FAIL (${task%% *}, $((SECONDS-t0))s)"
    failed="$failed ${task%% *}"
  fi
  run=$((run+1))
done
echo "diff-ci: $run task(s) run, $skipped skipped (PR-context gates run only in CI)"
[ -z "$failed" ] || { echo "diff-ci: FAILED:$failed" >&2; exit 1; }
