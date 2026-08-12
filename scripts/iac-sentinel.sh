#!/usr/bin/env bash
# iac-sentinel — the IAC-G04 tamper-proof policy evaluation (docs/agents/iac-lane.md L0b),
# v1 SHADOW MODE: evaluates -iac PR heads against homelab-owned rules and REPORTS (logs +
# pushgateway metrics) — posts nothing to GitHub, blocks nothing. The enforcement flip
# (statuses:write on the homelab-reviewer App + required-check) comes after the shadow soak,
# the router-rollout pattern. Engines (operator ruling 2026-08-03: Kyverno is THE rule engine —
# CLI seat now, admission seat later; no engine sprawl):
#   path-rule  — bash/gh: worker-authored PRs must not touch .github/workflows/** (the
#                sleep-iac#28 self-merge hole; belt-of-belt for the planned push ruleset)
#   kyverno    — policy/iac/*.yaml against every k8s doc in the PR TREE (raw-YAML pass; the
#                hostile PR content is never EXECUTED — no helm, no hooks, tarball extract only)
#   gitleaks   — secret VALUES in the tree (fleet-standard scanner)
# Per-engine wall time is measured on every run (iac_sentinel_engine_seconds) — the data for
# the "when do parallel CI steps pay" question.
#
#   bash scripts/iac-sentinel.sh                      # scan open PRs of $SENTINEL_REPOS
#   bash scripts/iac-sentinel.sh --tree <repo> <ref>  # evaluate one ref (bench/manual)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ORG="${ORG:-teststuffstash}"
SENTINEL_REPOS="${SENTINEL_REPOS:-sleep-iac oracle-iac circles-iac homelab}"  # circles-iac added 2026-08-12 (A0 gap); homelab added same day (A5 leg 1: shadow the platform tier-1 lane BEFORE the CODEOWNERS scaffold drops — argocd/resources is -iac-shaped and the tier-1 line's own removal condition is "when IAC-G04 enforces for homelab")
WORKER_AUTHOR="${WORKER_AUTHOR:-app/homelab-agents-1234}"
PUSHGATEWAY="${PUSHGATEWAY:-}"   # e.g. http://prometheus-pushgateway.monitoring.svc:9091 — empty = log-only
POLICY_DIR="${POLICY_DIR:-${HERE}/../policy/iac}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
now_ms() { date +%s%3N; }

METRICS=""
metric() { METRICS="${METRICS}$1\n"; }

push_metrics() {
  [ -n "$PUSHGATEWAY" ] || return 0
  printf '%b' "$METRICS" | curl -fsS --max-time 10 --data-binary @- \
    "${PUSHGATEWAY}/metrics/job/iac-sentinel" >/dev/null 2>&1 \
    || log "pushgateway push failed (metrics stay in logs)"
}

# evaluate <repo> <ref/sha> <pr-number-or-'-'> <author-or-'-'> → violations counted in $VIOLATIONS
evaluate() {
  repo="$1"; ref="$2"; pr="$3"; author="$4"
  VIOLATIONS=0
  tree="$WORK/${repo}-${ref}"
  t0=$(now_ms)
  mkdir -p "$tree"
  # Tarball fetch, never a clone: no hooks, no submodules — hostile PR content is data here.
  if ! gh api "repos/${ORG}/${repo}/tarball/${ref}" > "$tree.tgz" 2>/dev/null \
     || ! tar -xzf "$tree.tgz" -C "$tree" --strip-components=1 2>/dev/null; then
    log "[$repo#$pr@$ref] FETCH FAILED — skipping (rule #6: loud, not silently green)"
    metric "iac_sentinel_probe_failed{repo=\"$repo\"} 1"
    return 1
  fi
  t_fetch=$(( $(now_ms) - t0 ))

  # ── path rule (worker-authored PRs only) ─────────────────────────────────────────────
  t0=$(now_ms)
  if [ "$pr" != "-" ] && [ "$author" = "$WORKER_AUTHOR" ]; then
    touched="$(gh api "repos/${ORG}/${repo}/pulls/${pr}/files" --paginate \
                 --jq '.[].filename' 2>/dev/null | grep -E '^\.github/workflows/|^scripts/ci' || true)"
    if [ -n "$touched" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      log "[$repo#$pr] VIOLATION path-rule: worker PR touches CI-gate files:"
      printf '%s\n' "$touched" | sed 's/^/    /'
      metric "iac_sentinel_violations{repo=\"$repo\",pr=\"$pr\",rule=\"workflow-touch\"} 1"
    fi
  fi
  t_path=$(( $(now_ms) - t0 ))

  # ── collect k8s docs (apiVersion+kind) from the tree into one resource file ──────────
  t0=$(now_ms)
  : > "$tree/.sentinel-resources.yaml"
  while IFS= read -r f; do
    # yq (go) parses what it can; unparseable helm-template yaml is skipped here — the raw pass
    # covers plain manifests, the render pass (v2) will cover templated ones.
    docs="$(yq eval-all 'select(tag == "!!map" and .apiVersion != null and .kind != null)' "$f" 2>/dev/null || true)"
    [ -n "$docs" ] && [ "$docs" != "null" ] \
      && printf -- '---\n%s\n' "$docs" >> "$tree/.sentinel-resources.yaml"
  done < <(find "$tree" \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/.github/*' -not -name '.sentinel-resources.yaml')
  n_docs="$(grep -c '^kind:' "$tree/.sentinel-resources.yaml" 2>/dev/null)"
  case "${n_docs:-}" in ''|*[!0-9]*) n_docs=0;; esac
  t_collect=$(( $(now_ms) - t0 ))

  # ── kyverno (THE rule engine) ────────────────────────────────────────────────────────
  t0=$(now_ms)
  if [ "$n_docs" -gt 0 ]; then
    kout="$(kyverno apply "$POLICY_DIR" --resource "$tree/.sentinel-resources.yaml" 2>&1)"
    krc=$?
    if [ $krc -ne 0 ]; then
      nfail="$(printf '%s' "$kout" | grep -oE 'fail: [0-9]+' | grep -oE '[0-9]+' | head -1)"
      VIOLATIONS=$((VIOLATIONS + ${nfail:-1}))
      log "[$repo#$pr@$ref] VIOLATION kyverno (${nfail:-?} failing):"
      printf '%s\n' "$kout" | grep -E "fail|→|message" | head -20 | sed 's/^/    /'
      metric "iac_sentinel_violations{repo=\"$repo\",pr=\"$pr\",rule=\"kyverno\"} ${nfail:-1}"
    fi
  fi
  t_kyverno=$(( $(now_ms) - t0 ))

  # ── gitleaks (secret values) ─────────────────────────────────────────────────────────
  t0=$(now_ms)
  if ! gitleaks detect --no-git --source "$tree" --no-banner --exit-code 9 >/dev/null 2>&1; then
    # exit 9 = leaks found (set explicitly so tool errors ≠ findings)
    VIOLATIONS=$((VIOLATIONS + 1))
    log "[$repo#$pr@$ref] VIOLATION gitleaks: secret material in the tree (details withheld from logs)"
    metric "iac_sentinel_violations{repo=\"$repo\",pr=\"$pr\",rule=\"gitleaks\"} 1"
  fi
  t_gitleaks=$(( $(now_ms) - t0 ))

  total=$(( t_fetch + t_path + t_collect + t_kyverno + t_gitleaks ))
  log "[$repo#$pr@$ref] engines(ms): fetch=$t_fetch path=$t_path collect=$t_collect(docs=$n_docs) kyverno=$t_kyverno gitleaks=$t_gitleaks total=$total violations=$VIOLATIONS"
  for e in fetch:$t_fetch path:$t_path collect:$t_collect kyverno:$t_kyverno gitleaks:$t_gitleaks; do
    metric "iac_sentinel_engine_seconds{engine=\"${e%%:*}\",repo=\"$repo\"} $(python3 -c "print(${e##*:}/1000)")"
  done
  return 0
}

if [ "${1:-}" = "--tree" ]; then
  evaluate "$2" "$3" "-" "-"
  push_metrics
  exit 0
fi

for repo in $SENTINEL_REPOS; do
  prs="$(gh pr list --repo "${ORG}/${repo}" --state open --json number,headRefOid,author \
           --jq '.[] | "\(.number) \(.headRefOid) \(.author.login)"' 2>/dev/null)" || {
    log "[$repo] PR list PROBE FAILED — skipped"; continue; }
  [ -n "$prs" ] || { log "[$repo] no open PRs"; continue; }
  while read -r num sha author; do
    [ -n "$num" ] && evaluate "$repo" "$sha" "$num" "$author"
  done <<EOF2
$prs
EOF2
done
push_metrics
