#!/usr/bin/env bash
# iac-sentinel — the IAC-G04 tamper-proof policy evaluation (docs/agents/iac-lane.md L0b).
# Evaluates PR heads against homelab-owned rules and reports to logs + pushgateway metrics.
# ENFORCEMENT (the G01 flip, 2026-08-18): when SENTINEL_STATUS_TOKEN is set (the reviewer-App
# token — never the worker's own identity, which could pass itself), each evaluated PR head
# gets an `iac-sentinel` commit status (success/failure; `error` on probe failure — fail-closed,
# the next tick heals a transient). The -iac repos' rulesets require that context. Empty token =
# the original shadow mode. Engines (operator ruling 2026-08-03: Kyverno is THE rule engine —
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
STATUS_TOKEN="${SENTINEL_STATUS_TOKEN:-}"  # reviewer-App token; empty = shadow (no GitHub writes)
SENTINEL_WAKE="${SENTINEL_WAKE:-cron}"     # cron|edge — who woke this run (homelab#650; stated per run)
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
now_ms() { date +%s%3N; }

# doorbell-collapse (homelab#938 -- ADR-106 (5), ported from coordinator-scan.sh): the
# evaluation is UNSCOPED (re-lists every open head), so N queued sibling submissions re-scan ONE
# world serially behind the mutex -- a merge-heavy evening queued 14, and the clone+tarball IO
# degraded a co-scheduled grafana for half an hour (hp-01 sda at 68% util). A STARTING evaluation
# therefore ABSORBS Pending siblings before its own listing (delete-then-list: a ring arriving
# after the delete creates a fresh Pending, which correctly survives for the next pass). Self is
# Running, not Pending; the HOSTNAME-prefix check is the belt for the no-status-yet window.
# In-cluster only (a jail/manual run has no workflow world); a failed list absorbs NOTHING --
# extra wakes just queue behind the mutex as today (rule #6).
absorb_pending_sentinel_rings() {
  [ -f /var/run/secrets/kubernetes.io/serviceaccount/namespace ] || return 0
  local ns raw names n
  ns="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
  if ! raw="$(kubectl -n "$ns" get workflows -o json 2>/dev/null)" \
     || ! jq -e . >/dev/null 2>&1 <<<"${raw:-null}"; then
    log "doorbell-collapse: workflow list PROBE-FAILED in ${ns} -- absorbing nothing (extra wakes just queue)"
    return 0
  fi
  names="$(jq -r --arg self "${HOSTNAME:-}" '.items[]?
      | (.metadata.name // "") as $n
      | select($n | startswith("iac-sentinel"))
      | select(($self | startswith($n)) | not)
      | select((.status.phase // "Pending") == "Pending")
      | $n' <<<"$raw" 2>/dev/null)" || names=""
  for n in $names; do
    if kubectl -n "$ns" delete workflow "$n" --ignore-not-found >/dev/null 2>&1; then
      log "doorbell-collapse: absorbed pending sentinel ring ${ns}/${n} -- this run's re-list covers it"
    else
      log "doorbell-collapse: could not delete ${ns}/${n} (RBAC?) -- it runs behind the mutex instead"
    fi
  done
  return 0
}
absorb_pending_sentinel_rings

METRICS=""
metric() { METRICS="${METRICS}$1\n"; }

push_metrics() {
  [ -n "$PUSHGATEWAY" ] || return 0
  # FU-176: an empty body must never reach the gateway — a push REPLACES the whole
  # job/iac-sentinel group, and a zero-PR tick's empty body used to WIPE
  # iac_sentinel_engine_seconds (2026-08-18: a clean board read as "sentinel blind" while the
  # sentinel was healthy). The cron-tick path appends the heartbeat before calling here; a
  # bench/--tree invocation must NOT (it would reset IacSentinelSilent's clock mid-outage —
  # PR#670 review), and its evaluate() always emits engine/probe rows, so nothing here can be
  # empty — the guard below is the belt for any future metric-less caller.
  [ -n "$METRICS" ] || { log "push_metrics: nothing to push (empty body would wipe the group — FU-176)"; return 0; }
  printf '%b' "$METRICS" | curl -fsS --max-time 10 --data-binary @- \
    "${PUSHGATEWAY}/metrics/job/iac-sentinel" >/dev/null 2>&1 \
    || log "pushgateway push failed (metrics stay in logs)"
}

# post_status <repo> <sha> <state> <description> — the enforcement write. A failed POST is loud
# but non-fatal: the required check simply stays pending/stale and the next tick retries.
post_status() {
  [ -n "$STATUS_TOKEN" ] || return 0
  if ! curl -fsS --max-time 10 \
       -H "Authorization: token $STATUS_TOKEN" -H "Accept: application/vnd.github+json" \
       "https://api.github.com/repos/${ORG}/$1/statuses/$2" \
       -d "{\"state\":\"$3\",\"context\":\"iac-sentinel\",\"description\":\"$4\"}" >/dev/null 2>&1; then
    log "[$1@$2] STATUS POST FAILED ($3) — check stays pending, next tick retries"
  fi
}

# evaluate <repo> <ref/sha> <pr-number-or-'-'> <author-or-'-'> → violations counted in $VIOLATIONS
evaluate() {
  repo="$1"; ref="$2"; pr="$3"; author="$4"
  VIOLATIONS=0
  GITLEAKS_TOOL_ERROR=0
  KYVERNO_TOOL_ERROR=0
  tree="$WORK/${repo}-${ref}"
  t0=$(now_ms)
  mkdir -p "$tree"
  if [ -n "${SMOKE_SRC:-}" ]; then
    # --smoke (homelab#1134 leg 3): the SAME engines over the LOCAL checkout — tracked files +
    # worktree state, never .git/.devbox (`ls-files`, not a directory walk), no GitHub. This is
    # what `ci` runs so a toolchain-lock bump that breaks an engine reds ITS OWN PR instead of
    # the whole merge path one sentinel tick after it lands (#1131: kyverno 1.19.0, 8/8 PRs).
    if ! git -C "$SMOKE_SRC" ls-files -z --cached --others --exclude-standard \
           | tar -C "$SMOKE_SRC" --null -T - -czf "$tree.tgz" 2>/dev/null \
       || ! tar -xzf "$tree.tgz" -C "$tree" 2>/dev/null; then
      log "[$repo@$ref] SMOKE TREE BUILD FAILED"
      return 1
    fi
  # Tarball fetch, never a clone: no hooks, no submodules — hostile PR content is data here.
  elif ! gh api "repos/${ORG}/${repo}/tarball/${ref}" > "$tree.tgz" 2>/dev/null \
     || ! tar -xzf "$tree.tgz" -C "$tree" --strip-components=1 2>/dev/null; then
    log "[$repo#$pr@$ref] FETCH FAILED — skipping (rule #6: loud, not silently green)"
    metric "iac_sentinel_probe_failed{repo=\"$repo\",pr=\"$pr\"} 1"
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
    # comments are STRIPPED: yq keeps a file's head comment attached to its first doc, and the
    # `---` it then emits can strand that comment as a document of its own — which kyverno
    # refuses to load ("Object 'Kind' is missing"), failing the whole resource file.
    # `kustomize.config.k8s.io/*` docs are EXCLUDED (homelab#1134): a `Kustomization` is
    # kustomize build config, not a cluster object — no policy targets the kind — and it carries
    # no metadata.name, so kyverno ≥1.19 (which indexes loaded resources by kind/ns/name)
    # PANICS on the second one (`kustomizations.kustomize.config.k8s.io "" already exists`),
    # rc=2 with no fail-summary. Verified 2026-09-01: with them dropped, 1.19.0 reproduces
    # 1.18.2's verdicts exactly over this repo's 302 remaining docs.
    docs="$(yq eval-all '(select(tag == "!!map" and .apiVersion != null and .kind != null and (.apiVersion | test("^kustomize\\.config\\.k8s\\.io/") | not))) | ... comments=""' "$f" 2>/dev/null || true)"
    [ -n "$docs" ] && [ "$docs" != "null" ] \
      && printf -- '---\n%s\n' "$docs" >> "$tree/.sentinel-resources.yaml"
  done < <(find "$tree" \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/.github/*' -not -name '.sentinel-resources.yaml')
  n_docs="$(grep -c '^kind:' "$tree/.sentinel-resources.yaml" 2>/dev/null)"
  case "${n_docs:-}" in ''|*[!0-9]*) n_docs=0;; esac
  t_collect=$(( $(now_ms) - t0 ))

  # ── kyverno (THE rule engine) ────────────────────────────────────────────────────────
  t0=$(now_ms)
  if [ "$n_docs" -gt 0 ]; then
    # Per-repo baseline exceptions (policy/iac/exceptions/<repo>.yaml) — read from the
    # sentinel's OWN master clone, never the scanned tree: a hostile PR editing its copy of
    # the exception list changes nothing here.
    exc="$POLICY_DIR/exceptions/${repo}.yaml"
    if [ -f "$exc" ]; then
      kout="$(kyverno apply "$POLICY_DIR" --resource "$tree/.sentinel-resources.yaml" --exceptions "$exc" 2>&1)"
    else
      kout="$(kyverno apply "$POLICY_DIR" --resource "$tree/.sentinel-resources.yaml" 2>&1)"
    fi
    krc=$?
    if [ $krc -ne 0 ]; then
      nfail="$(printf '%s' "$kout" | grep -oE 'fail: [0-9]+' | grep -oE '[0-9]+' | head -1)"
      if [ -z "$nfail" ]; then
        # homelab#1134 — the gitleaks discrimination, ported: kyverno exiting non-zero WITHOUT a
        # `fail: N` summary is the ENGINE erroring (a broken binary, a flag change, a loader
        # regression — the 1.19.0 bump froze 8/8 open PRs this way), not a manifest violating a
        # policy. A tool error is a PROBE failure: error status, healed next tick — never a
        # "violation" with rule `?` and no detail, which reads as a policy verdict and is
        # permanent instead of self-healing.
        log "[$repo#$pr@$ref] kyverno TOOL ERROR (rc=$krc, no fail-summary) — probe failed, not a finding:"
        printf '%s\n' "$kout" | head -8 | sed 's/^/    /'
        metric "iac_sentinel_probe_failed{repo=\"$repo\",pr=\"$pr\"} 1"
        KYVERNO_TOOL_ERROR=1
      else
        VIOLATIONS=$((VIOLATIONS + nfail))
        log "[$repo#$pr@$ref] VIOLATION kyverno (${nfail} failing):"
        printf '%s\n' "$kout" | grep -E "fail|→|message" | head -20 | sed 's/^/    /'
        metric "iac_sentinel_violations{repo=\"$repo\",pr=\"$pr\",rule=\"kyverno\"} ${nfail}"
      fi
    fi
  fi
  t_kyverno=$(( $(now_ms) - t0 ))

  # ── gitleaks (secret values) ─────────────────────────────────────────────────────────
  t0=$(now_ms)
  # --config from the sentinel's own clone: gitleaks would otherwise auto-read the SCANNED
  # tree's .gitleaks.toml, letting a hostile PR allowlist its own leak.
  gitleaks detect --no-git --source "$tree" --no-banner --exit-code 9 \
    --config "$POLICY_DIR/gitleaks.toml" >/dev/null 2>&1
  grc=$?
  # exit 9 = leaks found — set explicitly so tool errors ≠ findings, and CONSUMED as such
  # (2026-08-19: the old `if ! gitleaks` counted ANY nonzero — a missing/broken binary (127) or
  # a config error read as "secret material in the tree" and would post a failure status with a
  # bogus reason; a tool error is a PROBE failure → error status, healed next tick).
  if [ "$grc" -eq 9 ]; then
    VIOLATIONS=$((VIOLATIONS + 1))
    log "[$repo#$pr@$ref] VIOLATION gitleaks: secret material in the tree (details withheld from logs)"
    metric "iac_sentinel_violations{repo=\"$repo\",pr=\"$pr\",rule=\"gitleaks\"} 1"
  elif [ "$grc" -ne 0 ]; then
    log "[$repo#$pr@$ref] gitleaks TOOL ERROR (rc=$grc) — probe failed, not a finding"
    metric "iac_sentinel_probe_failed{repo=\"$repo\",pr=\"$pr\"} 1"
    GITLEAKS_TOOL_ERROR=1
  fi
  t_gitleaks=$(( $(now_ms) - t0 ))

  total=$(( t_fetch + t_path + t_collect + t_kyverno + t_gitleaks ))
  log "[$repo#$pr@$ref] engines(ms): fetch=$t_fetch path=$t_path collect=$t_collect(docs=$n_docs) kyverno=$t_kyverno gitleaks=$t_gitleaks total=$total violations=$VIOLATIONS"
  for e in fetch:$t_fetch path:$t_path collect:$t_collect kyverno:$t_kyverno gitleaks:$t_gitleaks; do
    # ⚠ label sets must be UNIQUE across every evaluate() of ONE tick: the pushgateway rejects a
    # body carrying duplicate-labeled samples WHOLESALE (probed live 2026-08-19: HTTP 400,
    # "collected before with the same name and label values") — without `pr` here, any tick with
    # ≥2 open PRs in one repo lost its ENTIRE push, heartbeat included (push_failure_time_seconds
    # vs push_time_seconds on the group was the tell; IacSentinelSilent's first firing was this).
    metric "iac_sentinel_engine_seconds{engine=\"${e%%:*}\",repo=\"$repo\",pr=\"$pr\"} $(python3 -c "print(${e##*:}/1000)")"
  done
  return 0
}

if [ "${1:-}" = "--tree" ]; then
  evaluate "$2" "$3" "-" "-"
  push_metrics
  exit 0
fi

# --smoke [repo-root]: run every engine over the local checkout and exit by the SAME
# discrimination the tick posts as a status — the CI gate homelab#1134 found missing. No
# metrics push (never reset IacSentinelSilent's clock from a bench run — the --tree rule).
#   2 = an ENGINE could not run (the #1131 class: a lock bump broke a required check's tool)
#   1 = a real policy/secret violation in the tree (the sentinel would red this head anyway)
#   0 = clean
if [ "${1:-}" = "--smoke" ]; then
  SMOKE_SRC="$(cd "${2:-$HERE/..}" && pwd)"
  export SMOKE_SRC
  smoke_repo="$(basename "$(git -C "$SMOKE_SRC" rev-parse --show-toplevel 2>/dev/null || echo "$SMOKE_SRC")")"
  if ! evaluate "$smoke_repo" "local" "-" "-"; then
    log "SMOKE: tree build failed"; exit 2
  fi
  if [ "${KYVERNO_TOOL_ERROR:-0}" -ne 0 ] || [ "${GITLEAKS_TOOL_ERROR:-0}" -ne 0 ]; then
    log "SMOKE FAIL: an engine could not run — this lock/toolchain would freeze the merge path at the next sentinel tick (homelab#1134)"; exit 2
  fi
  if [ "$VIOLATIONS" -ne 0 ]; then
    log "SMOKE FAIL: $VIOLATIONS violation(s) in the local tree (exceptions: $POLICY_DIR/exceptions/${smoke_repo}.yaml)"; exit 1
  fi
  log "SMOKE OK: engines ran, 0 violations (docs=$n_docs)"; exit 0
fi

for repo in $SENTINEL_REPOS; do
  prs="$(gh pr list --repo "${ORG}/${repo}" --state open --json number,headRefOid,author \
           --jq '.[] | "\(.number) \(.headRefOid) \(.author.login)"' 2>/dev/null)" || {
    log "[$repo] PR list PROBE FAILED — skipped"; continue; }
  [ -n "$prs" ] || { log "[$repo] no open PRs"; continue; }
  while read -r num sha author; do
    [ -n "$num" ] || continue
    # homelab#650 backstop accounting: a CRON tick posting the FIRST iac-sentinel status on a
    # head that is old enough for the edge to have fired = A MISSED RING, said loudly (the
    # "cron-serviced dispatch is a defect with an id" rule, transposed). This is what earns the
    # backstop its sparse cadence (hourly since 2026-08-20; operator: sensors do the heavy
    # lifting) and would earn "no cron at all" if it stays silent. Heads younger than 10min are
    # skipped — the exporter's 120s poll simply may not have fired yet.
    if [ "$SENTINEL_WAKE" = "cron" ] && [ -n "$STATUS_TOKEN" ]; then
      have="$(gh api "repos/${ORG}/${repo}/commits/${sha}/status"                 --jq '[.statuses[]|select(.context=="iac-sentinel")]|length' 2>/dev/null || echo probe-fail)"
      if [ "$have" = "0" ]; then
        age=$(( $(date +%s) - $(date -d "$(gh api "repos/${ORG}/${repo}/commits/${sha}"                 --jq '.commit.committer.date' 2>/dev/null || echo now)" +%s 2>/dev/null || date +%s) ))
        if [ "$age" -gt 600 ]; then
          log "[$repo#$num@$sha] ⚠ CRON-SERVICED — first status by the BACKSTOP on a ${age}s-old head: the edge missed this ring (homelab#650)"
          # {repo,pr} like every sibling per-PR metric — an unlabeled line duplicates when TWO
          # virgin heads hit one tick, and a duplicate label set 400s the WHOLE push (the exact
          # #682 class this file just got fixed for; caught by the PR#702 review).
          metric "iac_sentinel_cron_serviced_timestamp_seconds{repo=\"$repo\",pr=\"$num\"} $(date +%s)"
        fi
      fi
    fi
    if evaluate "$repo" "$sha" "$num" "$author"; then
      if [ "${GITLEAKS_TOOL_ERROR:-0}" -ne 0 ] || [ "${KYVERNO_TOOL_ERROR:-0}" -ne 0 ]; then
        # an engine that could not run means the verdict is INCOMPLETE — fail closed as a probe
        # error (never success, and never a "violation" with a bogus reason); next tick retries.
        post_status "$repo" "$sha" error "sentinel probe failed (engine tool error) — retries next tick"
      elif [ "$VIOLATIONS" -eq 0 ]; then
        post_status "$repo" "$sha" success "0 violations (kyverno + gitleaks + path-rule)"
      else
        post_status "$repo" "$sha" failure "$VIOLATIONS violation(s) — details in the iac-sentinel workflow logs"
      fi
    else
      # fetch/probe failure: fail CLOSED (error state), not silently green — transient
      # failures heal on the next tick, which re-evaluates every open PR head.
      post_status "$repo" "$sha" error "sentinel probe failed — retries next tick"
    fi
  done <<EOF2
$prs
EOF2
done
# FU-176: the per-tick heartbeat — CRON-TICK PATH ONLY (never --tree: a manual bench run with
# PUSHGATEWAY set would reset IacSentinelSilent's staleness clock and mask the outage being
# debugged). Appending it here also guarantees a zero-PR tick pushes a non-empty body, which is
# what stops the group wipe. Freshness keys on this metric (iac-lane.md §L0b); engine rows exist
# only for ticks that evaluated a PR.
metric "iac_sentinel_last_run_timestamp_seconds $(date +%s)"
# homelab#650: state the wake source, so "% of evaluations edge-served" is a number (the FU-144
# acceptance shape). A DISTINCT metric name per source — never a label on the heartbeat: a POST
# replaces per metric NAME within the group, so a labeled heartbeat would let an edge run erase
# the cron's series (and vice versa). changes(edge)/changes(cron+edge) is the ratio.
metric "iac_sentinel_wake_${SENTINEL_WAKE}_timestamp_seconds $(date +%s)"
log "wake=${SENTINEL_WAKE} (homelab#650 edge accounting)"
push_metrics
