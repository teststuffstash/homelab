#!/bin/bash
# diff-ci — run only the CI gates the current diff can affect (#518, 2026-08-31): the local
# pre-flight for agents and the seat. Same devbox tasks CI runs, scoped by a path→task map.
#
# ONE HOME: this map is the canonical statement of "which paths feed which gate".
# `.github/workflows/ci.yaml`'s changed-paths step eval-extracts PROM_PATHS/CLAUSE_PATHS from
# THIS file (the scripts/pin-only-lint.sh one-home pattern; the #518 flip landed 2026-08-31) —
# edit trigger sets here, never inline there. Since 2026-10-09 CI's PR skip map is the WHOLE MAP
# (`--ci-outputs` below), so a too-narrow row CAN merge a defect a PR run skipped — the master push
# runs every gate regardless, so the miss reds master on the next push and the fix is a wider row.
# The PR-context gates (pin-only-lint, governance-lint, the ADR-103
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
#        devbox run diff-ci -- --ci-outputs <changed-files>
#   The CI skip map (2026-10-09): one `<key>=true|false` line per MAP row for $GITHUB_OUTPUT,
#   key = ci_key(task) below. Every ci.yaml gate step reads its own key with
#   `if: steps.diff.outputs.<key> != 'false'` — absent (push / dispatch: the diff step is skipped)
#   means RUN, so master pushes run everything (the net). Fails open: an empty/unreadable list,
#   or a change to ci.yaml, prints true for every row. The three other shared inputs are read for
#   WHAT changed (2026-11-13 — ~40 % of the full runs were a one-task edit; numbers in
#   docs/spikes/ci-runtime-2026-11.md), each failing open when the base side cannot be read:
#     devbox.json   only `shell.scripts` entries changed → the rows of those tasks, of every task
#                   whose script calls one, and of every tracked file that calls one (`devbox run
#                   <task>`; prose and recorded data excluded: *.md, *.json, *.txt, fixtures/,
#                   worlds/); any other key → every row
#     devbox.lock   every row except the gateway island's (its tasks run in gateway/'s own devbox;
#                   the root closure is proven by the warm step every run pays)
#     diff-ci.sh    the rows whose task or regex differ from the base's (`--dump-map` below)
#   The base side is origin/master in a full clone, else the PR base via the API
#   (GITHUB_BASE_REF + GITHUB_REPOSITORY + GH_TOKEN, all present in ci.yaml's diff step).
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # absolute: --ci-outputs re-invokes itself after the cd
cd "$(dirname "$0")/.."

# Single-line assignments — ci.yaml `eval "$(grep -m1 '^PROM_PATHS=' scripts/diff-ci.sh)"`s
# these verbatim (the #518 flip, live 2026-08-31); keep them one line, single-quoted, eval-safe.
PROM_PATHS='^(argocd/|tofu/|scripts/prometheus-rules-lint\.sh|devbox\.(json|lock)$)'
CLAUSE_PATHS='^(agents/|devbox\.(json|lock)$)'
# The agent-gateway island's suite + everything it feeds (gateway-ci, gateway-evidence and its
# bucket publish): gateway/ plus the two JSON files outside it the tests read. ONE copy — the
# PR-close purge (gateway-specs-pr-purge.yaml) deliberately has no paths filter so it cannot drift.
GATEWAY_PATHS='^(gateway/|argocd/resources/agent-gateway/policy\.json$|argocd/resources/openrouter-proxy/model-classes\.json$)'
# #1315: the Composition, the two cluster pins it renders with (functions + provider version),
# the gate's own script/fixtures, and the devbox closure that ships the nix provider.
PUBLICROUTE_PATHS='^(argocd/resources/publicroute/|argocd/resources/crossplane/(providerconfig|functions)\.yaml$|argocd/platform/crossplane\.yaml$|scripts/publicroute-tf-validate\.sh$|scripts/xr-render-lib\.sh$|scripts/fixtures/publicroute/|devbox\.(json|lock)$)'
# xr-render (G4 class gate): every XRD/Composition + the committed XRs/claims it discovers + the two
# cluster pins it renders with + the tool itself. Claims outside these dirs are the master-push net's.
XR_RENDER_PATHS='^(argocd/resources/(agentstack|publicroute|crossplane)/|argocd/platform/crossplane\.yaml$|agents/fixer/.*agentstack\.yaml$|scripts/xr-render|scripts/fixtures/publicroute/|devbox\.(json|lock)$)'
# the management box's policy + its readers (ADR-131): the stage-1 fixtures + the fail-closed reads
MGMT_PATHS='^(policy/mgmt/|mgmt/scripts/mgmt-[a-z-]*\.sh$|mgmt/scripts/mgmt-root-env/|scripts/iac-sentinel\.sh$|scripts/maintenance-window\.sh$|devbox\.(json|lock)$)'

# task:trigger-regex (first `:` splits; task may carry args and is word-split at run time).
# Buckets are deliberately COARSE (agents/ runs the whole agents suite, ~10 quick tasks) —
# precision is only worth chasing on the expensive rows (the two heavies + the self-tests
# scoped to their deployment dir).
MAP=(
  "argocd-validate-pins:^(argocd/|scripts/(argocd-validate-pins|vendor-garage-chart)\\.sh$)"
  # report-only workload standards over every Application's RENDERED manifests (charts included —
  # iac-lane.md L0b's render pass, standing alone): the vendored+local policies, the checker, and
  # everything the ArgoCD layer applies. Exit 0 in --report mode; no ci.yaml step yet (operator-direct).
  "component-check:^(argocd/|policy/component/|scripts/(component-check|vendor-kyverno-policies|vendor-garage-chart)\.sh$)"
  "manifest-lint:^argocd/"
  "agentstack-rbac-lint:^argocd/resources/(agentstack|crossplane)/"
  "sentinel-smoke:^(policy/iac/|scripts/iac-sentinel\.sh|scripts/iac-policy-test\.sh|scripts/fixtures/iac-policy/|devbox\.(json|lock)$)"
  "mgmt-policy-test:$MGMT_PATHS"
  "prometheus-rules-lint:$PROM_PATHS"
  "exporter-self-test:^argocd/resources/github-exporter/"
  "edge-probe-self-test:^argocd/resources/cloudflare-exporter/"
  "spend-probe-self-test:^argocd/resources/cloudflare-exporter/"
  # the version-set probe's parsers + exposition (homelab#2014), scoped to its deployment dir like the sibling probes.
  # Its ci.yaml step lands operator-direct (ci.yaml is pin-only-guarded); the row is ready for it.
  "version-sets-selftest:^argocd/resources/version-sets/"
  "publicroute-tf-validate:$PUBLICROUTE_PATHS"
  # ci.yaml runs it PR-only as `xr-render -- --diff <base>` (base↔head render diff); locally the
  # row renders every input at the worktree. Its ci.yaml step lands operator-direct (pin-only-guarded).
  "xr-render:$XR_RENDER_PATHS"
  "argo-lint:^agents/coordinator/"
  "router-self-test:^argocd/resources/openrouter-proxy/"
  "proxy-self-test:^argocd/resources/openrouter-proxy/"
  # The gateway island's ONE gate (gateway/scripts/ci.sh via its own devbox: uv sync, ruff, pytest
  # + evidence, spec gate) — ADR-139 / context-and-autonomy.md P2. Scoped to the island dir plus
  # the deployed policy the suite loads (test_model_resolve / test_codex_oauth read
  # argocd/resources/agent-gateway/policy.json, and test_model_resolve checks every id against
  # openrouter-proxy/model-classes.json — an edit to either must run the rows that check it).
  "gateway-ci:$GATEWAY_PATHS"
  # The island's specs-site publish (gateway/scripts/specs-publish.sh — mkdocs build + mirror to the
  # gateway-specs bucket; soft-skips without GATEWAY_SPECS_S3_* creds, so locally it is the dogfood
  # build). Same trigger as the gate it rides behind in ci.yaml. WAN-bound (uv fetches the mkdocs
  # pins) → PUSH_HEAVY below keeps it off the pre-push hook.
  "gateway-specs-publish:^gateway/"
  # ADR-156 step 4: the reviewer's evidence pack from the gateway suite's raw Allure results; it
  # rides the gateway-ci step's skip key in ci.yaml (no suite run, no results). WAN-bound (uv fetches
  # the pinned snippets wheel) → PUSH_HEAVY. Same trigger as gateway-ci (the suite it packs).
  "gateway-evidence:$GATEWAY_PATHS"
  # …and its upload to the gateway-specs bucket (gateway/scripts/evidence-publish.sh; ci.yaml keys it
  # off the gateway-evidence step's outcome). Soft-skips without creds; WAN/LAN-bound → PUSH_HEAVY.
  "gateway-evidence-publish:$GATEWAY_PATHS"
  # The island's rendered-browser specs-site leg (gateway/scripts/e2e-specs-site.sh → playwright image
  # via docker: every spec page's Mermaid diagrams render, every flowchart node link lands on its
  # requirement heading — the oracle-fleet e2e-specs-site shape). Inputs: the site config, the
  # staged renderer init, any spec page, the build and the leg itself. Docker pull + WAN → PUSH_HEAVY.
  "gateway-specs-site-e2e:^gateway/(mkdocs\.yml$|site-assets/|specs/.*\.md$|scripts/(specs-build|e2e-specs-site)\.sh$|scripts/e2e/test_specs_site\.py$)"
  "responder-behaviour-test:^agents/"
  # the retro collector/pipeline contract tests: their only inputs are the two modules + the two tests (FU-058)
  "retro-test:^agents/retro[_-](activity|pipeline)"
  # + the island intake selector: intake is the dig's consumer and its harness runs in this gate (FU-320)
  "deep-dig-test:^(agents/|gateway/scripts/intake-select)"
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
  # ShellCheck -S warning over the same tracked shell, ratcheted by its baseline (ADR-113, FU-185);
  # ~50s on 8 cores (the 7k-line clause files dominate). Its ci.yaml step lands operator-direct
  # (ci.yaml is pin-only-guarded); the row is ready for it.
  "shellcheck-lint:(\.(sh|bash)$|^scripts/shellcheck-(lint\.py|baseline\.txt)$|^githooks/)"
  "shim-self-test:^scripts/claude-model-shim\.py"
  # the self-test's only inputs are scripts/pin-only-lint.sh + scripts/pin-only-lint-test.sh (#2072)
  "pin-only-lint-test:^scripts/pin-only-lint"
  # the self-test's inputs: the CLI + its test, and the vendored hook copy it asserts byte-identical (ADR-150)
  "upgrade-lease-test:^(agents/upgrade-lease|argocd/resources/kube-prometheus-stack-lease/upgrade-lease\.sh)"
  "devbox-update-test:^scripts/devbox-update|^scripts/lock-cache-check|^scripts/fixtures/devbox-update/"
  # the self-test's only inputs are scripts/governance-lint.sh + scripts/governance-lint-test.sh (FU-296)
  "governance-lint-test:^scripts/governance-lint"
  # the keep-set's selection rule; its only input is the script itself (FU-274)
  "registry-keep-set-test:^scripts/registry-keep-set"
  # the belt's own CI invocation, covered by the belt: ci.yaml's `devbox run diff-ci -- --coverage-only`
  # is extracted below as task `diff-ci` and matches this row's first word. Locally this is one
  # level of recursion (a belt-only run, no git base) that exits in well under a second.
  "diff-ci -- --coverage-only:^(scripts/diff-ci(-test)?\.sh|\.github/workflows/ci\.yaml)$"
  "machines-lint:^(machines/|mgmt/nixos/hosts/mgmt/bmc\.json$)"
  "maint-self-test:^(scripts/(maintenance-window|node-maintenance\.sh$|host-maintenance\.sh$)|agents/seat-window\.sh$)"
  # the self-test drives the verb against stubs; mgmt-tf's `summary` line format is its plan-scope input.
  # Its ci.yaml step lands operator-direct (ci.yaml is pin-only-guarded); the row is ready for it.
  "runner-maint-self-test:^(scripts/runner-maintenance|mgmt/scripts/mgmt-tf\.sh$|tofu/ci-runner\.tf$|machines/machines\.yaml$)"
  # the self-test's only inputs are scripts/pr-wait.sh + scripts/pr-wait-test.sh (2026-10-04)
  "pr-wait-test:^scripts/pr-wait"
  # bash -n + the jq predicates of the specs reviewer's tick on fixtures (ADR-155); its only input
  # is the script. Its ci.yaml step lands operator-direct (ci.yaml is pin-only-guarded); the row is ready for it.
  "specs-review-self-test:^agents/specs-reviewer-session\.sh$"
  # pr-open's refusals, stamp and base against a throwaway repo + stubbed devbox/gh (workflow.md
  # §Gate A); its only input is the script. Its ci.yaml step lands operator-direct, like the row above.
  "pr-open-self-test:^agents/pr-open\.sh$"
  "-- tofu fmt -check -recursive tofu/:^tofu/"
  "follow-ups-lint:^docs/"
  # docs-graph-lint's INPUTS are wider than .md: checks #4/#4b read §-code refs out of
  # *.md/*.sh/*.py/*.yaml/*.yml (code comments included) and resolve them against living .md,
  # so a YAML comment can red it. The .md-only row let exactly that through on #2575 — a
  # sigiled code in prometheusrule.yaml, no .md in the diff, PR run SKIPPED the gate, master
  # push ran it and redded every open PR (#2576). Row widened to the gate's real input set;
  # ~7s, so the wider trigger is cheap. Keep this row and scripts/docs-graph-lint.sh's greps
  # in step — that disagreement is the defect class, not the one comment.
  # Widened again to EVERY path (2026-10-31): check #5 scans all tracked text files for committed
  # merge-conflict markers (#2946's sat on master until #3071), so any changed file is an input.
  "docs-graph-lint:."
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

# Rows that githooks/pre-push's push-time gate (--push-gates below) must NEVER select, even
# when their path matches — too slow or network-dependent for a hook that runs on every direct
# master push, from anywhere, in well under the ~2 minute budget. CI is unaffected: these still
# run there under the ordinary skip map above. Keyed to the FIRST WORD of a MAP task (matches
# the coverage-belt's own convention below); re-measure before adding a row — this is a cutoff
# call, not a guess. Measured 2026-10-10 in a jail clone, warm .devbox, no docker daemon, LAN
# reachable:
#   argocd-validate-pins    `helm pull` straight from ghcr.io — real WAN on every run.
#   manifest-lint           kubeconform's `default` schema-location falls back to a network
#                           fetch for any CRD this repo hasn't vendored a schema for (the FU-197
#                           flake class) — a WAN risk, not a timing call (it was 1-2s here).
#   mgmt-policy-test        >40s locally with no network at all — just too slow for this gate
#                           (its own fixture suite; mgmt/ changes are rare on the direct lane).
#   prometheus-rules-lint   33s here, 112-126s in ci.yaml's own wall-time accounting — the exact
#                           class CI backgrounds instead of running inline (#518).
#   publicroute-tf-validate  \
#   xr-render                } both pull pinned Crossplane/Cilium function binaries through the
#                           ADR-091 LAN pull-through mirror (192.168.40.21/.20) by digest — fast
#                           and WAN-free when it hits (3-8s measured), but curl's own worst case
#                           (`--connect-timeout 10 -m 300`) is a 5-MINUTE hang per blob on a dead
#                           mirror or an off-LAN push, which blows the budget and the "works from
#                           anywhere" requirement outright.
#   gateway-specs-publish   `uv run --no-project --with mkdocs…` resolves three pins from PyPI on a
#                           cold cache — real WAN on the first run (measured 2026-10-16: ~40s cold).
#   gateway-specs-site-e2e  the same mkdocs build, then a docker pull of the playwright image (LAN
#                           mirror) and `pip install playwright` inside it — minutes, never on a hook.
#   component-check         `helm template` pulls every third-party chart pin (ghcr.io, jetstack,
#                           prometheus-community, cloudsmith, …) — real WAN on every run, ~2 min
#                           wall measured 2026-10-25 in a jail clone (69 Applications, ~860 docs).
PUSH_HEAVY="argocd-validate-pins component-check manifest-lint mgmt-policy-test prometheus-rules-lint publicroute-tf-validate xr-render gateway-specs-publish gateway-evidence gateway-evidence-publish gateway-specs-site-e2e"

# --coverage-only: run the belt and stop (the CI form — see the header). Parsed before the
# base-ref positional so `devbox run diff-ci -- --coverage-only` needs no origin/master.
COVERAGE_ONLY=false
if [ "${1:-}" = "--coverage-only" ]; then COVERAGE_ONLY=true; shift; fi
# ci_key <task> — the GITHUB_OUTPUT key for a MAP row's task: non-alnum runs → '-', trimmed
# (`mgmt-policy-test` → itself, `estimate-budget -- --self-test` → `estimate-budget-self-test`).
ci_key() { printf '%s' "$1" | tr -cs 'a-zA-Z0-9' '-' | sed -e 's/^-*//' -e 's/-*$//'; }
# --dump-map: one `task<TAB>regex` line per MAP row — what --ci-outputs diffs a base copy of this
# script against when the PR edits the MAP.
if [ "${1:-}" = "--dump-map" ]; then
  for entry in "${MAP[@]}"; do printf '%s\t%s\n' "${entry%%:*}" "${entry#*:}"; done
  exit 0
fi
# base_file <path> — the base side's copy on stdout; non-zero when it cannot be read (→ fail open).
base_file() {
  local ref="${DIFF_CI_BASE_GIT_REF:-origin/master}"
  if git cat-file -e "$ref:$1" 2>/dev/null; then git show "$ref:$1"; return; fi
  [ -n "${GITHUB_BASE_REF:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || return 1
  gh api -H 'Accept: application/vnd.github.raw' "repos/$GITHUB_REPOSITORY/contents/$1?ref=$GITHUB_BASE_REF"
}
# devbox_changed_tasks <base devbox.json> — the changed script names + every task whose script calls
# one, transitively; exit 3 when anything outside shell.scripts differs (→ every row).
devbox_changed_tasks() {
  python3 - "$1" devbox.json <<'PY'
import json, re, sys
base, head = (json.load(open(p)) for p in sys.argv[1:3])
def rest(d):
    d = json.loads(json.dumps(d)); d.get("shell", {}).pop("scripts", None); return d
if rest(base) != rest(head):
    sys.exit(3)
bs, hs = base.get("shell", {}).get("scripts", {}), head.get("shell", {}).get("scripts", {})
changed = {k for k in set(bs) | set(hs) if bs.get(k) != hs.get(k)}
text = {k: json.dumps(v) for k, v in hs.items()}
grew = True
while grew:
    grew = False
    for k, t in text.items():
        if k not in changed and any(re.search(r"devbox run (-- )?%s\b" % re.escape(c), t) for c in changed):
            changed.add(k); grew = True
print("\n".join(sorted(changed)))
PY
}
if [ "${1:-}" = "--ci-outputs" ]; then
  list="${2:-}"; all=false; lock=false; tasks=""; maprows=""
  match=$(mktemp); trap 'rm -f "$match" "$match".*' EXIT
  if [ -z "$list" ] || [ ! -s "$list" ]; then all=true
  elif grep -qE '^\.github/workflows/ci\.yaml$' "$list"; then all=true
  else
    grep -vE '^devbox\.json$' "$list" >"$match" || true
    grep -qE '^devbox\.lock$' "$list" && lock=true
    if grep -qE '^devbox\.json$' "$list"; then
      if base_file devbox.json >"$match.dj" 2>/dev/null && tasks=$(devbox_changed_tasks "$match.dj"); then
        # a tracked file that calls a changed task counts as changed (the mgmt fixtures' nested
        # `devbox run yq` class); prose and recorded data (markdown, JSON/text captures, replay
        # fixtures and worlds) mention task names without running them
        for t in $tasks; do
          git grep -lE "devbox run (-- )?$t([^a-zA-Z0-9-]|\$)" -- ':!*.md' ':!*.json' ':!*.txt' \
            ':!**/fixtures/**' ':!**/worlds/**' >>"$match" 2>/dev/null || true
        done
      else all=true; fi
    fi
    if ! $all && grep -qE '^scripts/diff-ci\.sh$' "$list"; then
      if base_file scripts/diff-ci.sh >scripts/.diff-ci-base.sh 2>/dev/null \
         && maprows=$(bash scripts/.diff-ci-base.sh --dump-map 2>/dev/null) && [ -n "$maprows" ]; then
        maprows=$(comm -13 <(printf '%s\n' "$maprows" | sort) <(bash "$SELF" --dump-map | sort) | cut -f1)
      else all=true; fi
      rm -f scripts/.diff-ci-base.sh
    fi
  fi
  for entry in "${MAP[@]}"; do
    task="${entry%%:*}"; regex="${entry#*:}"; v=false
    if $all || grep -qE "$regex" "$match" \
       || grep -qxF -- "${task%% *}" <<<"$tasks" || grep -qxF -- "$task" <<<"$maprows"; then v=true
    elif $lock && ! jq -e --arg t "${task%% *}" '.shell.scripts[$t] | tostring | test("cd gateway && exec devbox run")' devbox.json >/dev/null 2>&1; then v=true
    fi
    echo "$(ci_key "$task")=$v"
  done
  exit 0
fi
# --push-gates <changed-files-file>: prints the MAP tasks (one per line) whose path regex
# matches the given changed-file list, MINUS PUSH_HEAVY above — the set githooks/pre-push's
# generic step runs on a direct master push. Same fail-open rule as --ci-outputs for a MISSING
# or UNREADABLE list (selects every non-heavy row); an EMPTY-but-present list (e.g. the hook's
# own bookkeeping-file filter dropped everything) selects NOTHING instead — the hook, not this
# script, decides what "nothing left to check" means for its own budget. ONE HOME: a path that
# feeds a CI gate feeds the push gate too unless it's named in PUSH_HEAVY above — the hook
# itself carries no path regex of its own.
if [ "${1:-}" = "--push-gates" ]; then
  list="${2:-}"; all=false
  if [ -z "$list" ] || [ ! -e "$list" ]; then all=true
  elif [ -s "$list" ] && grep -qE '^(devbox\.(json|lock)|\.github/workflows/ci\.yaml|scripts/diff-ci\.sh)$' "$list"; then all=true; fi
  if ! $all && [ ! -s "$list" ]; then exit 0; fi
  for entry in "${MAP[@]}"; do
    task="${entry%%:*}"; regex="${entry#*:}"
    case " $PUSH_HEAVY " in *" ${task%% *} "*) continue ;; esac
    if $all || grep -qE "$regex" "$list"; then printf '%s\n' "$task"; fi
  done
  exit 0
fi

# ── coverage belt: every `devbox run <task>` in ci.yaml must appear in MAP or PR_ONLY, so a
# new CI step cannot silently rot this map (the unexecuted-gate class, ADR-103's lesson).
# Runs in CI too since #2072 (`devbox run diff-ci -- --coverage-only`), so the map cannot rot
# past the PR that adds the step.
ci_tasks=$(grep -vE '^\s*#' .github/workflows/ci.yaml | grep -oE 'devbox run [a-z][a-z0-9-]*' | awk '{print $3}' | sort -u)
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
# ── skip-if belt (2026-10-09): the diff optimization is the STANDARD, not opt-in — every ci.yaml
# step that runs a MAP task must gate on that task's own key (`if: steps.diff.outputs.<key> !=
# 'false'`, key = ci_key), so a new step cannot silently run on every PR. PR_ONLY gates and the
# utility invocations (`-- gh …`, `-- true`, the `--ci-outputs` producer itself) are exempt.
while IFS=$'\t' read -r sname sif srun; do
  while IFS= read -r inv; do
    [ -n "$inv" ] || continue
    case "$inv" in "-- gh "*|"-- true"|"diff-ci -- --ci-outputs"*) continue;; esac
    task=""
    for entry in "${MAP[@]}"; do
      t="${entry%%:*}"
      if [ "$inv" = "$t" ] || [ "${inv%% *}" = "$t" ]; then task="$t"; break; fi
    done
    [ -n "$task" ] || continue   # unknown tasks are the coverage belt's job above
    for p in $PR_ONLY; do [ "$p" = "$task" ] && task=""; done
    [ -n "$task" ] || continue
    k=$(ci_key "$task")
    case "$sif" in *"steps.diff.outputs.$k "*) ;; *)
      echo "diff-ci: FAIL — ci.yaml step '$sname' runs '$task' without \`if: steps.diff.outputs.$k != 'false'\` (the skip map is standard — add it)" >&2; exit 2;;
    esac
  done <<EOF_INV
$(printf '%s\n' "$srun" | grep -oE 'devbox run [^;|&]*' | sed -e 's/^devbox run //' -e 's/[[:space:]]*$//' || true)
EOF_INV
done <<EOF_STEPS
$(yq -o=json '.jobs.ci.steps' .github/workflows/ci.yaml | jq -r '.[] | [(.name // .uses // "?"), ((.if // "") + " "), ((.run // "") | gsub("\n"; " ; "))] | @tsv')
EOF_STEPS
belt_n=$(( $(printf '%s\n' $ci_tasks | grep -c .) + $(grep -vE '^\s*#' .github/workflows/ci.yaml | grep -oE 'devbox run -- .*' | sed -e 's/^devbox run //' -e 's/[[:space:]]*$//' | sort -u | grep -c .) ))
if $COVERAGE_ONLY; then
  echo "diff-ci: coverage belt ok (every ci.yaml devbox task — $belt_n distinct — has a MAP row or a PR_ONLY exemption, and every MAP step gates on its own skip key)"
  # The --ci-outputs selection's pinned cases ride this invocation: CI already runs it, and its
  # row matches both files, so a selection edit can never skip its own test.
  bash scripts/diff-ci-test.sh
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
  # shellcheck disable=SC2086  # task strings intentionally word-split (args ride along)
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
