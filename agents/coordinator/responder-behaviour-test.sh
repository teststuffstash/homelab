#!/usr/bin/env bash
# responder-behaviour-test — behavioural harness for responder-argo.yaml's embedded triage script.
#
#   bash agents/coordinator/responder-behaviour-test.sh
#
# WHY THIS EXISTS. The responder's decision logic is ~250 lines of POSIX-sh embedded in an Argo
# WorkflowTemplate. `manifest-lint` cannot see any of it — kubeconform has no schema for
# `argoproj.io` kinds, so both resources in that file come back SKIPPED and the gate validates
# nothing. Every defect this lane has shipped has been in that shell, and #124 shipped two in two
# rounds: a subject key that fell through to a catch-all shared by four namespaces (round 0), and
# a `source` fallback so broad it flipped an unrelated alert's subject (round 1, caught in review).
# Both are one-line changes with cluster-wide blast radius and no schema that could ever catch them.
# So the check has to be behavioural: run the real script, assert on what it decides.
#
# WHAT IT RUNS. The script under test is EXTRACTED FROM THE YAML at run time, never transcribed —
# so this file cannot drift from responder-argo.yaml. Exactly one seam is cut into it: the
# hard-coded in-pod clone path `/work/homelab` is redirected to a temp dir, so the harness needs
# no /work mount and no root. Nothing else is rewritten.
#
# THE STUBS. gh/kubectl/claude/curl/git are replaced by recorders: mutations are logged and never
# performed, reads are served from per-scenario fixtures. `claude` captures the composed brief
# instead of calling a model, which is how the routing default, SUBJ, SELF_NOTE and EGRESS_NOTE are
# asserted. The AgentStack read is deliberately DENIED so routing resolves through the real
# agents/stacks.json fallback belt — the claims under test are the live ones.
#
# WIRED INTO CI since homelab#133 (2026-08-08): `devbox run responder-behaviour-test`, a required
# `ci` step in .github/workflows/ci.yaml. (The original header said "NOT WIRED, deliberately" —
# that predated #133; the wiring was an operator-lane commit exactly because those two files are
# off-limits to the fixer lane. Stale header caught by #360.) It also runs fine by hand; a few
# seconds. See the PRs for #124 and #133.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
YAML="${YAML:-$REPO/agents/coordinator/responder-argo.yaml}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home"

command -v yq >/dev/null 2>&1 || { echo "responder-behaviour-test: needs yq (devbox run -- bash $0)"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "responder-behaviour-test: needs jq (devbox run -- bash $0)"; exit 2; }

# ── the script under test, straight out of the manifest ─────────────────────────────────────────
yq -r 'select(.kind == "WorkflowTemplate") | .spec.templates[] | select(.container != null) | .container.args[0]' \
   "$YAML" > "$TMP/respond.raw.sh"
[ -s "$TMP/respond.raw.sh" ] || { echo "responder-behaviour-test: could not extract the script from $YAML"; exit 2; }
sed "s#/work/homelab#$TMP/homelab#g" "$TMP/respond.raw.sh" > "$TMP/respond.sh"   # the one seam
bash -n "$TMP/respond.sh" || { echo "responder-behaviour-test: extracted script is not valid shell"; exit 1; }

# ── stubs ───────────────────────────────────────────────────────────────────────────────────────
cat > "$BIN/kubectl" <<'EOF'
#!/bin/bash
printf '%s\n' "kubectl $*" >> "$H/calls.log"
case "$*" in
  *agentstacks*)                     exit 1 ;;                       # denied → stacks.json belt
  *"get applications.argoproj.io"*)  printf '{"items":[]}'; exit 0 ;; # no observation window open
  *"get cm responder-seen -o json"*) printf '{"data":{}}'; exit 0 ;;  # ledger empty → budget clear
  # FU-230 leg (b): the declared-window record. ABSENT by default — an unreadable/absent record
  # must read as NO window, so every other scenario exercises that path and a window can only ever
  # silence a name a person deliberately declared.
  *"get cm responder-window -o json"*) [ -f "$H/window.json" ] && { cat "$H/window.json"; exit 0; }; exit 1 ;;
esac
exit 0
EOF
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "gh $*" >> "$H/calls.log"
_jq=""; _p=""; _prev=""
for a in "$@"; do
  [ "$_prev" = "--jq" ] && _jq="$a"
  case "$a" in repos/*) _p="$a";; esac
  _prev="$a"
done
_emit() { if [ -n "$_jq" ]; then jq -r "$_jq" 2>/dev/null || true; else cat; fi; }
case "$1 $2" in
  "search issues") { cat "$H/gh/search.json" 2>/dev/null || printf '[]'; } | _emit; exit 0 ;;
  "issue view")    [ -f "$H/gh/issue-$3.json" ] && { _emit < "$H/gh/issue-$3.json"; exit 0; }; exit 1 ;;
  "issue comment"|"issue close"|"issue edit"|"issue reopen") exit 0 ;;
esac
if [ "$1" = "api" ]; then
  case "$_p" in
    *"/issues?"*) r="${_p#repos/}"; r="${r%%/issues?*}"
                  f="$H/gh/verdict-list-$(printf '%s' "$r" | tr / _).json"
                  { [ -f "$f" ] && cat "$f" || printf '[]'; } | _emit; exit 0 ;;
    */issues/*/events)
                  # The human-close probe (#1733). Absent ⇒ exit 1, which the clause reads as
                  # "close actor unreadable" and treats as machine-closed — i.e. exactly today's
                  # reopen behaviour. The guard may only ever ADD a restore.
                  [ -f "$H/gh/events.json" ] && { _emit < "$H/gh/events.json"; exit 0; }; exit 1 ;;
    */issues/77/comments)
                  # The resolve leg's engagement probe (#1733). REST is the authority here — it is
                  # the only endpoint that types a commenter (`.user.type`), which is what the
                  # GraphQL `gh issue view --json comments` the leg used to call cannot do. An
                  # ABSENT recording exits 1 so the rule-#6 "never close on a failed read" branch
                  # stays reachable, exactly as the issue read below does.
                  [ -f "$H/gh/issue-77-comments.json" ] && { _emit < "$H/gh/issue-77-comments.json"; exit 0; }; exit 1 ;;
    */issues/77)    [ -f "$H/gh/issue-77.json" ] && { _emit < "$H/gh/issue-77.json"; exit 0; }; exit 1 ;;
    */issues/123)   { printf '{"id":"123123"}'; } | _emit; exit 0 ;;  # cause issue
    */issues/999)   { cat "$H/gh/verdict-issue.json" 2>/dev/null || printf '{}'; } | _emit; exit 0 ;;  # filed issue
    */issues/*)     { cat "$H/gh/verdict-issue.json" 2>/dev/null || printf '{}'; } | _emit; exit 0 ;;
    */sub_issues)   exit 0 ;;  # POST succeeds silently
  esac
fi
exit 0
EOF
cat > "$BIN/claude" <<'EOF'
#!/bin/bash
# Never calls a model; captures the composed brief so the routing default, SUBJ, SELF_NOTE
# and EGRESS_NOTE the real script built can be asserted on.
printf '%s\n' "claude $*" >> "$H/calls.log"
for a in "$@"; do case "$a" in -*) ;; *) printf '%s' "$a" > "$H/brief.txt"; break;; esac; done
# A real session prints its report; the §A1 capture tees that into triage.log, and an EMPTY file
# is deliberately not uploaded — so the stub must speak or the capture assertions pass vacuously.
echo "triage report (stub): diagnosis and verdict would be here"
exit 0
EOF
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "curl $*" >> "$H/calls.log"; exit 0
EOF
# §A1 capture (FU-210): the bucket write recorder. Present ALWAYS, so the difference between the
# two capture paths is the KEY, never the binary — which is the real production shape (the Secret
# is `optional: true`, the image always carries s5cmd).
cat > "$BIN/s5cmd" <<'EOF'
#!/bin/bash
printf '%s\n' "s5cmd $*" >> "$H/calls.log"; exit 0
EOF
cat > "$BIN/git" <<'EOF'
#!/bin/bash
# The script does `rm -rf <clonedir> && git clone … <clonedir>`; point that at this checkout so
# the stacks.json / latch scripts it then reads are the real ones under test.
printf '%s\n' "git $*" >> "$H/calls.log"
if [ "$1" = "clone" ]; then for a in "$@"; do t="$a"; done; ln -sfn "$REPO_UNDER_TEST" "$t"; fi
exit 0
EOF
chmod +x "$BIN"/*

# ── assertions ──────────────────────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "$2"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# /tmp/rbody.md is the script's own scratch file for a body rewrite; clear it per scenario so a
# `grep -c '^last-cleared:'` can never pass on the PREVIOUS scenario's leftovers.
scenario() { H="$TMP/run/$1"; rm -rf "$H"; mkdir -p "$H/gh"; rm -f /tmp/rbody.md; export H; }
go() {
  PAYLOAD="$1" ORG="teststuffstash" HOME="$TMP/home" REPO_UNDER_TEST="$REPO" \
  PUSHGATEWAY="" PATH="$BIN:$PATH" \
    bash "$TMP/respond.sh" > "$H/out.txt" 2> "$H/err.txt"
  OUT="$(cat "$H/out.txt")"
}
# go_ts — the same run WITH the §A1 transcripts key present. `go` deliberately leaves it unset,
# so every other scenario exercises the degrade path (`optional: true` Secret absent) and the
# capture can never be load-bearing for a triage.
go_ts() {
  AGENT_TS_ACCESS_KEY_ID=k AGENT_TS_SECRET_ACCESS_KEY=s \
  AGENT_TS_BUCKET=agent-transcripts AGENT_TS_ENDPOINT=http://garage.garage.svc:3900 \
  PAYLOAD="$1" ORG="teststuffstash" HOME="$TMP/home" REPO_UNDER_TEST="$REPO" \
  PUSHGATEWAY="" PATH="$BIN:$PATH" \
    bash "$TMP/respond.sh" > "$H/out.txt" 2> "$H/err.txt"
  OUT="$(cat "$H/out.txt")"
}
want()      { printf '%s' "$OUT" | grep -qF -- "$2" && ok "$1" || bad "$1" "stdout lacks: $2"; }
wantnot()   { printf '%s' "$OUT" | grep -qF -- "$2" && bad "$1" "stdout has: $2" || ok "$1"; }
wantbrief() { grep -qF -- "$2" "$H/brief.txt" 2>/dev/null && ok "$1" || bad "$1" "brief lacks: $2"; }
wantcall()  { grep -qF -- "$2" "$H/calls.log" 2>/dev/null && ok "$1" || bad "$1" "no call: $2"; }
wantnocall(){ grep -qF -- "$2" "$H/calls.log" 2>/dev/null && bad "$1" "unexpected call: $2" || ok "$1"; }
alert()     { printf '{"alerts":[{"status":"firing","fingerprint":"%s","labels":%s}]}' "$1" "$2"; }
resolved()  { printf '{"alerts":[{"status":"resolved","fingerprint":"%s","labels":{"alertname":"%s"}}]}' "$1" "$2"; }
searchhit() { printf '[{"repository":{"nameWithOwner":"%s"},"number":%s}]' "$1" "$2" > "$H/gh/search.json"; }
# `$2` is the REST comments payload — `[{"user":{"login":…,"type":"Bot"|"User"}}]`. The TYPE is
# what the engagement probe reads (#1733): GraphQL returns a Bot's bare login while REST returns
# both the `[bot]` suffix AND the type, and the leg used to test the suffix against the GraphQL
# endpoint, so every machine comment counted as a human for two months. Writing the type at each
# call site is deliberate — it keeps the distinction visible in the scenario rather than hidden in
# a helper.
issuebody() { jq -n --arg b "$1" '{body:$b}' > "$H/gh/issue-77.json"; printf '%s' "$2" > "$H/gh/issue-77-comments.json"; }

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "LEG 1 — AgentWorkerEgressDropped: source IS the namespace, so subject + route recover"
# The #107 story: nine oracle-fleet fires deduped onto homelab's issue because this alert
# aggregates `sum by (source)` and carries no `namespace` label at all.

scenario egress-oracle
go "$(alert f1 '{"alertname":"AgentWorkerEgressDropped","source":"oracle-fleet","severity":"warning"}')"
want      "oracle-fleet → subject ns:oracle-fleet (was the catch-all alert:<name>)" "subject=ns:oracle-fleet"
want      "oracle-fleet → route default oracle / oracle-iac" "stack=oracle repo=teststuffstash/oracle-iac"
wantbrief "oracle-fleet → the fix-payload note is attached" "EGRESS-DROP PAYLOAD"
wantbrief "oracle-fleet → payload names the claim path" "oracle-fleet/agent/agentstack.yaml in oracle-iac"
wantbrief "oracle-fleet → payload names the acceptance probe" "ACCEPTANCE PROBE"
wantbrief "oracle-fleet → STEP 1 routes by the named fix surface" "ROUTE BY THE FIX SURFACE YOU NAME"

# ── #125: the payload must name reads that WORK FROM THE POD, not the jail's `devbox run hubble` ──
# The 2026-08-08 failure was not a missing tool, it was a brief that named an absent one and then
# licensed "cannot verify". These assert the composed brief still carries both reads and, for the
# hubble fallback, its single-node caveat — the exact sentence a session must repeat if it uses it.
wantbrief "oracle-fleet → payload names the Prometheus read that works in-pod" "kube-prometheus-stack-prometheus.monitoring.svc:9090"
wantbrief "oracle-fleet → …with the POLICY_DENIED query scoped to this namespace" 'source="oracle-fleet"'
wantbrief "oracle-fleet → payload names the cilium-agent hubble fallback" "kubectl exec -n kube-system ds/cilium -- hubble observe"
wantbrief "oracle-fleet → …and states its single-node ring-buffer blind spot" "ONE node's ring buffer"
wantbrief "oracle-fleet → 'cannot name it' is gated on having actually run them" "an unrun query is not a blocked one"

scenario egress-sleep
go "$(alert f2 '{"alertname":"AgentWorkerEgressDropped","source":"sleep-tracking"}')"
want "sleep-tracking → route default sleep / sleep-iac" "stack=sleep repo=teststuffstash/sleep-iac"

scenario egress-homelab
go "$(alert f3 '{"alertname":"AgentWorkerEgressDropped","source":"homelab"}')"
want "source=homelab still files PLATFORM-side (the 2026-08-05 case stays correct)" "stack=platform repo=teststuffstash/homelab"

scenario egress-openrouter-operator
go "$(alert f4 '{"alertname":"AgentWorkerEgressDropped","source":"openrouter-operator"}')"
want "source=openrouter-operator files platform-side" "stack=platform repo=teststuffstash/homelab"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "LEG 2 — AgentDispatchCronWoken: project IS the namespace, preventing subject collision"
# homelab#707: two different fingerprints from the same alert class (different projects) with no
# namespace/pod/node/repo/workflow labels would both compute `alert:AgentDispatchCronWoken` and
# subject-dedupe would mark the second as subjdup-* without triaging. Make AgentDispatchCronWoken
# opt into a project-aware subject (like AgentWorkerEgressDropped does with source).

scenario dispatch-cron-homelab
go "$(alert dp1 '{"alertname":"AgentDispatchCronWoken","project":"homelab","severity":"warning"}')"
want      "AgentDispatchCronWoken homelab → subject ns:homelab (was the catch-all alert:<name>)" "subject=ns:homelab"
want      "AgentDispatchCronWoken homelab → routes platform" "stack=platform repo=teststuffstash/homelab"

scenario dispatch-cron-oracle
go "$(alert dp2 '{"alertname":"AgentDispatchCronWoken","project":"oracle-fleet","severity":"warning"}')"
want      "AgentDispatchCronWoken oracle-fleet → subject ns:oracle-fleet" "subject=ns:oracle-fleet"
want      "AgentDispatchCronWoken oracle-fleet → routes oracle" "stack=oracle repo=teststuffstash/oracle-iac"

# Two different fps in one payload with different projects compute different subjects, so both
# triage. This prevents the #707 collision where only one fp per subject fires per 24h.
scenario dispatch-cron-multi-project
go '{"alerts":[{"status":"firing","fingerprint":"dp3","labels":{"alertname":"AgentDispatchCronWoken","project":"homelab"}},{"status":"firing","fingerprint":"dp4","labels":{"alertname":"AgentDispatchCronWoken","project":"oracle-fleet"}}]}'
want "dispatch-cron → first fp triages with subject ns:homelab" "subject=ns:homelab"
want "dispatch-cron → second fp triages with subject ns:oracle-fleet" "subject=ns:oracle-fleet"
want "dispatch-cron multi-project → both subjects are distinct (no collision dedup)" "subject=ns:oracle-fleet"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "ROUND-2 REGRESSION — the source fallback is scoped to ONE alert"
# Round 1 read `.labels.namespace // .labels.source` for EVERY alert, justified by the claim that
# no other rule uses `source`. False: alert RouterRotationStale (in
# argocd/resources/openrouter-proxy/prometheusrule.yaml — cited by NAME, not by line: its expr has
# already moved once, homelab#342) fires on router_rotation_age_seconds with
# source="openrouter-daily-rankings" and carries no `triage: none`, so it flows through here with a
# `source` that is a FEED name. Unscoped, its subject flipped to ns:openrouter-daily-rankings — a
# marker discontinuity that files a duplicate on the next fire. What decides that is the LABEL, not
# the expr's shape: #342's restart-gap bridge aggregates with `max by (source)`, which preserves it,
# so the assertions below are unchanged by that rewrite.

scenario router-rotation-stale
go "$(alert f5 '{"alertname":"RouterRotationStale","source":"openrouter-daily-rankings","severity":"warning"}')"
want    "RouterRotationStale keeps subject alert:RouterRotationStale" "subject=alert:RouterRotationStale"
wantnot "RouterRotationStale does NOT mint ns:openrouter-daily-rankings" "ns:openrouter-daily-rankings"
want    "RouterRotationStale still routes platform-side" "stack=platform repo=teststuffstash/homelab"
wantnot "RouterRotationStale gets no egress payload note" "EGRESS-DROP PAYLOAD"

scenario future-source-alert
go "$(alert f6 '{"alertname":"SomeFutureSourceAlert","source":"not-a-namespace"}')"
want    "any future source-carrying alert keeps the catch-all subject" "subject=alert:SomeFutureSourceAlert"
wantnot "…and never mints a namespace subject from it" "ns:not-a-namespace"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "REGRESSIONS — every other subject shape is byte-identical to pre-#124"

scenario pvc-alert
go "$(alert f7 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"prom-db"}')"
want "PVC alert → pvc:monitoring/prom-db" "subject=pvc:monitoring/prom-db"
want "PVC alert → routes platform" "stack=platform repo=teststuffstash/homelab"

scenario pod-alert
go "$(alert f8 '{"alertname":"PodCrashLoop","namespace":"platform-agents","pod":"coordinator-110038"}')"
want "pod alert → generated suffix stripped" "subject=workload:platform-agents/coordinator"

scenario workflow-alert
go "$(alert f9 '{"alertname":"GithubWorkflowRunFailed","repo":"teststuffstash/oracle-iac","workflow":"ci"}')"
want "workflow alert → workflow:<repo>/<wf>" "subject=workflow:teststuffstash/oracle-iac/ci"

scenario node-alert
go "$(alert f10 '{"alertname":"NodeNotReady","node":"wk-metal-04"}')"
want "node alert → node:<node>" "subject=node:wk-metal-04"

scenario bare-alert
go "$(alert f11 '{"alertname":"SomethingVague"}')"
want "alert with no routable label → catch-all" "subject=alert:SomethingVague"

scenario triage-none
go "$(alert f12 '{"alertname":"OpenRouterKeyBudgetLow","triage":"none"}')"
want       "triage:none skipped by the rule author's declaration" "triage:none"
wantnocall "triage:none spawns no session" "claude -p"

scenario multi-alert
go '{"alerts":[{"status":"firing","fingerprint":"m1","labels":{"alertname":"AgentWorkerEgressDropped","source":"oracle-fleet"}},{"status":"firing","fingerprint":"m2","labels":{"alertname":"NodeNotReady","node":"hp-01"}}]}'
want "multi-alert payload → first alert triaged" "subject=ns:oracle-fleet"
want "multi-alert payload → SECOND alert triaged too (the </dev/null stdin belt holds)" "subject=node:hp-01"

scenario selfref
go "$(alert f13 '{"alertname":"AgentWorkerEgressDropped","source":"oracle-fleet"}')"
want "Agent* alert is self-referential — may PR, must not auto-merge" "SELF-REFERENTIAL"
want "…and the log names WHICH key matched" "alertname='AgentWorkerEgressDropped'"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "#239 — platform_machinery is the THIRD self-referential key"
# Both original keys INFER machinery from something else: a namespace in the platform set, or an
# `Agent*` name. A platform-machinery alert derived from a PUSHGATEWAY metric carries neither.
# RetroReportOverdue (retro_report_last_success_timestamp — no meaningful namespace, name not
# Agent*) went through the gate on 2026-08-11, took a `fix` verdict, was debounce-queued, and put
# a coordinator ride on the retro belt, which only the jail/operator lane can act on; it ended in
# an agent/error latch (homelab#237). The label is declared by the rule AUTHOR, where the fact is
# known — and these assertions are the reason it is testable at all.

scenario platform-machinery-label
go "$(alert f16 '{"alertname":"RetroReportOverdue","severity":"warning","platform_machinery":"true"}')"
want      "the label alone trips the gate (no namespace, no Agent* name)" "SELF-REFERENTIAL"
want      "…and the log names the label as the matching key" "platform_machinery='true'"
wantbrief "…so the brief carries the never-auto-merge cap" "NEVER enable auto-merge on it"
wantbrief "…and asks for the machine-readable marker the debouncer reads" "self-referential: true"
want      "…while triage still RUNS (the label is not triage:none)" "subject=alert:RetroReportOverdue"

# The #237 shape itself, as a witness: strip the label and this alert is dispatchable again. It
# fails if someone ever makes the gate fire on the alertname instead — which is the rot this
# issue exists to avoid, and would make the assertion above pass for the wrong reason.
scenario platform-machinery-witness
go "$(alert f17 '{"alertname":"RetroReportOverdue","severity":"warning"}')"
wantnot "unlabelled RetroReportOverdue is NOT self-referential (the #237 shape)" "SELF-REFERENTIAL"

# Exact-match on "true": anything else is not a declaration. A truthy-ish test would make a
# future `platform_machinery: "false"` mean its own opposite.
scenario platform-machinery-false
go "$(alert f18 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x","platform_machinery":"false"}')"
wantnot "platform_machinery='false' does NOT trip the gate" "SELF-REFERENTIAL"

# ── the PAIRING: the gate is only as good as the rules that stamp the label ──────────────────────
# The assertions above prove the gate reads the label; these prove the label is actually ON the
# alerts it was minted for. Read straight out of the live PrometheusRules — a rule edit that drops
# a stamp fails HERE, which is the only place it can fail (kubeconform has no opinion about labels,
# and the alert would simply become dispatchable again in silence).
section "#239 — the stamped rule set (asserted against the real PrometheusRules)"
stampval() { # <alertname> <file> → "true" | "unset" | "" (alert not found at all)
  A="$1" yq -r '.spec.groups[].rules[] | select(.alert == strenv(A)) | .labels.platform_machinery // "unset"' \
    "$REPO/$2" 2>/dev/null | head -1
}
stamped() { # <alertname> <file>
  local v; v="$(stampval "$1" "$2")"
  [ "$v" = "true" ] && ok "$1 carries platform_machinery (${2##*/resources/})" \
                    || bad "$1 stamped in $2" "got '${v:-alert not found}'"
}
stamped RetroReportOverdue              argocd/resources/pushgateway/prometheusrule.yaml
# CloudflareZoneSpendToggleEnabled left this list 2026-08-12: retired WITH the spend-probe's
# argo leg (entitlement-gated endpoint — docs/cloudflare.md §spend surface), not un-stamped.
stamped CloudflareZonePlanNotFree       argocd/resources/cloudflare-exporter/prometheusrule.yaml
stamped CloudflareSpendProbeBlind       argocd/resources/cloudflare-exporter/prometheusrule.yaml
stamped GithubAppPermissionDrift        argocd/resources/github-exporter/prometheusrule.yaml
stamped CiDispatchStalled               argocd/resources/github-exporter/prometheusrule.yaml
stamped GithubPaidUsage                 argocd/resources/github-exporter/prometheusrule.yaml
stamped GithubActionsMinutesHigh        argocd/resources/github-exporter/prometheusrule.yaml
stamped GithubStorageHeldHigh           argocd/resources/github-exporter/prometheusrule.yaml
stamped GithubRateLimitLow              argocd/resources/github-exporter/prometheusrule.yaml
# …and the counterexample, so the stamp stays LOAD-BEARING rather than decorative: an alert the
# fixer lane legitimately owns (a red master CI run in a claimed repo) must NOT be stamped.
v="$(stampval GithubWorkflowRunFailed argocd/resources/github-exporter/prometheusrule.yaml)"
[ "$v" = "unset" ] && ok "GithubWorkflowRunFailed stays dispatchable (not stamped)" \
                   || bad "GithubWorkflowRunFailed unstamped" "got '${v:-alert not found}'"

# ── THE ROUTING FILTER: what never reaches the lane at all (2026-09-17) ─────────────────────────
# Tier 0 of the three routing tiers. The responder's Alertmanager child route carries
# `severity != "info"` and `triage != "none"`, so a denied alert costs no Sensor trigger, no
# workflow, no clone. Nothing downstream can catch a regression here: the route is in a values
# file kubeconform SKIPs, and the in-pod `triage:none` belt would silently absorb a dropped
# matcher while the workflow cost came back. Two readers exist and must agree — the route and
# agents/meta-alert-crosscheck.sh, which would otherwise report every denied alert as stuck
# machinery. So: assert the matchers ARE on the route, assert the crosscheck applies the same
# two predicates, and assert the declarations on the rules the filter is FOR.
section "routing — the tier-0 filter (route matchers ⟷ the crosscheck ⟷ the rule-site labels)"
VALUES="$REPO/argocd/platform/values/kube-prometheus-stack.yaml"
RMATCH="$(yq -r '.alertmanager.config.route.routes[] | select(.receiver == "agent-responder") | .matchers[]' "$VALUES" 2>/dev/null | tr '\n' ' ')"
case "$RMATCH" in
  *'severity != "info"'*) ok "the responder route denies severity:info" ;;
  *) bad "responder route denies severity:info" "matchers are: ${RMATCH:-<none>}" ;;
esac
case "$RMATCH" in
  *'triage != "none"'*) ok "the responder route honours triage:none (tier 0, not just the in-pod belt)" ;;
  *) bad "responder route honours triage:none" "matchers are: ${RMATCH:-<none>}" ;;
esac
# The crosscheck's predicate, asserted on the SOURCE rather than by running it: its Alertmanager
# read needs the LAN and this harness is hermetic. A dropped `select` here is the loud-but-wrong
# failure (every denied alert reported UNTRIAGED), which is how a belt teaches its reader to
# ignore it — so it is worth a grep-level pin.
XCHK="$REPO/agents/meta-alert-crosscheck.sh"
grep -qF 'select((.labels.triage // "") != "none")' "$XCHK" \
  && ok "meta-alert-crosscheck excludes triage:none (reader 2 agrees with the route)" \
  || bad "crosscheck excludes triage:none" "predicate missing from $XCHK"
grep -qF 'select((.labels.severity // "") != "info")' "$XCHK" \
  && ok "meta-alert-crosscheck excludes severity:info (reader 2 agrees with the route)" \
  || bad "crosscheck excludes severity:info" "predicate missing from $XCHK"
grep -qF 'routing-denied' "$XCHK" \
  && ok "…and names the denied set once, so a denied alert is quiet but not invisible" \
  || bad "crosscheck names the denied set" "no routing-denied summary line in $XCHK"
# The same rule one level up: a PAUSED lane (FU-249's never-matching Sensor filter) is a deliberate
# stop, and without this the crosscheck reports every firing alert as stuck machinery — observed
# live during the 2026-09-17 pause. A belt that cries wolf through a planned stand-down is one its
# reader learns to skip.
grep -qF 'responder PAUSED at the Sensor' "$XCHK" \
  && ok "…and a PAUSED lane reads as a deliberate stop, not as stuck machinery" \
  || bad "crosscheck sees a paused lane" "no pause line in $XCHK"

# The rule-site declarations the filter is FOR. Same shape as the #239 stamp assertions above and
# the same reason: a rule edit that drops one makes the alert dispatchable again in silence, and
# no schema has an opinion about labels. Each entry here is an OPERATOR-QUEUE alert — its remedy
# is an act only the operator can take, so a session could only re-conclude the annotation.
triageval() { # <alertname> <file> → "none" | "unset" | "" (alert not found)
  A="$1" yq -r '.spec.groups[].rules[] | select(.alert == strenv(A)) | .labels.triage // "unset"' \
    "$REPO/$2" 2>/dev/null | head -1
}
notriage() { # <alertname> <file>
  local v; v="$(triageval "$1" "$2")"
  [ "$v" = "none" ] && ok "$1 declares triage:none (${2##*/resources/})" \
                    || bad "$1 declares triage:none in $2" "got '${v:-alert not found}'"
}
notriage CodeownerParkWaiting         argocd/resources/github-exporter/prometheusrule.yaml
notriage BlockingCodeownerParkWaiting argocd/resources/github-exporter/prometheusrule.yaml
notriage GithubVendorOutage           argocd/resources/github-exporter/prometheusrule.yaml
notriage AnthropicVendorDegraded      argocd/resources/github-exporter/prometheusrule.yaml
notriage GithubPaidUsage              argocd/resources/github-exporter/prometheusrule.yaml
notriage GithubActionsMinutesHigh     argocd/resources/github-exporter/prometheusrule.yaml
notriage GithubStorageHeldHigh        argocd/resources/github-exporter/prometheusrule.yaml
notriage AgentAttentionStanding       argocd/resources/pushgateway/prometheusrule.yaml
# …and the counterexamples, so `triage: none` stays a JUDGMENT rather than a habit. Both are
# alerts whose cause lives inside something the lane can read, so both must keep costing a
# session: a red master CI run in a claimed repo, and a rate-limit pool that a loop can drain
# (the FU-084 shape).
for pair in "GithubWorkflowRunFailed" "GithubRateLimitLow"; do
  v="$(triageval "$pair" argocd/resources/github-exporter/prometheusrule.yaml)"
  [ "$v" = "unset" ] && ok "$pair stays triage-eligible (investigable from in-cluster reads)" \
                     || bad "$pair stays triage-eligible" "got '${v:-alert not found}'"
done

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "#125 — the two brief rules that ride EVERY triage, not just egress drops"
# Both are 2026-08-08 failures with no schema that could catch them: a session that re-derived from
# scratch on a thread already carrying the answer, and an authoring path that spliced its own tool
# output into the issue body. They are unconditional text, so any alert shape must carry them.

scenario brief-universal-rules
go "$(alert f14 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"prom-db"}')"
wantbrief "dedup hit → read the prior thread before re-deriving" "READ THAT THREAD BEFORE YOU RE-DERIVE"
wantbrief "…and the --json form is named (the plain view renders empty)" "the plain view renders EMPTY under this token"
wantbrief "bodies are composed with --body-file" "gh issue create --body-file"
wantbrief "…never as an interpolated argument" "NEVER build it as an interpolated double-quoted argument"
wantbrief "the one-subject-per-thread boundary rides every triage, not just the graft-prone ones" "ONE SUBJECT PER THREAD"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "#149 — subject identity: a related-but-different subject files FRESH and links, never grafts"
# 2026-08-08, two live grafts by the same mechanism. #103 was born a wk-01 CPU-containment record
# (NodeSystemSaturation); a NodeMemoryMajorPagesFaults triage commented onto it carrying its OWN
# marker, subject:workload:monitoring/kube-prometheus-stack-prometheus-node-exporter — a subject
# with no prior issue anywhere. The dedup search greps COMMENTS, so that thread is now the org-wide
# hit for both resources, permanently (closing it does not unindex the comment). #100 took a third
# alert class the same way. The instinct was FU-133's anti-fragmentation and it was right; the
# mechanism was marker-attachment and it is drift with a mechanism.
#
# ⚠ WHAT THIS CAN AND CANNOT ASSERT. The org-wide 'subject:' search runs INSIDE the session, not in
# this shell — the harness stubs claude, so no search happens here and no fixture can stage one. The
# only lever the manifest holds is the INSTRUCTION the brief carries, so that is what is asserted:
# for an alert whose subject is exactly the grafted one, the brief must (a) compute that subject as
# its own, and (b) instruct filing fresh + linking whenever the thread found does not already carry
# it. A regression that deleted the boundary would fail here even though no issue is ever touched.

# ⚠ UPDATED 2026-09-16 (#1733, FU-232). This scenario used to send the alert WITHOUT its `job`
# label and assert `subject=workload:monitoring/kube-prometheus-stack-prometheus-node-exporter` —
# i.e. it asserted the GRAFT as correct behaviour, because the shape it sent could not reach the
# reporter discriminator. The payload below is the live one, read off Alertmanager 2026-09-16:
# `job=node-exporter` (the scrape job, which is what declares the pod a REPORTER) and
# `instance=192.168.2.182:9100` (the failing node, the only label that names the object at all).
# The #149 boundary the rest of this scenario asserts is unchanged and is the reason it still
# exists — FU-232 makes the subject name the right thing, #149 keeps one subject per thread, and
# they are independent.
scenario subject-identity-graft
go "$(alert f15 '{"alertname":"NodeMemoryMajorPagesFaults","namespace":"monitoring","pod":"kube-prometheus-stack-prometheus-node-exporter-x7k2p","job":"node-exporter","instance":"192.168.2.182:9100"}')"
want      "the reporter's pod is NOT the subject — the failing target is (FU-232)" \
          "subject=instance:192.168.2.182:9100"
wantnot   "…and the node-exporter workload key that made #103 a magnet is gone" \
          "subject=workload:monitoring/kube-prometheus-stack-prometheus-node-exporter"
wantbrief "comment ONLY where the alert's own subject marker is already on the thread" \
          "is ALREADY a marker on that thread"
wantbrief "a related-but-different subject files its OWN issue" "file your OWN issue and cross-reference by LINK"
wantbrief "…and correlates by LINK, in the 'related: #N' form" "related: #N"
wantbrief "never attach a second subject marker to someone else's thread" \
          "NEVER attach your 'subject:' marker to a thread that does not already carry it"
wantbrief "…because the dedup search greps COMMENTS (the aliasing mechanism is stated)" \
          "the dedup search greps COMMENTS"
wantbrief "grouping belongs at Alertmanager/filing, not to a comment (FU-133 leg a)" \
          "Grouping alerts together is Alertmanager's job at filing time"
wantbrief "the marker rule itself is split: FILE always carries it, a COMMENT only on a match" \
          "a COMMENT carries it ONLY on a thread that already does"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "LEG 2 — the resolve leg keys on the recorded verdict, not on the alert"

scenario resolve-fix
searchhit teststuffstash/oracle-iac 77
issuebody 'evidence
alert-fp:r1
fix-verdict: fix' '[]'
go "$(resolved r1 AgentWorkerEgressDropped)"
want       "fix-verdict: fix → stays OPEN, no comment" "OPEN, no comment"
wantnocall "fix-verdict: fix → never closed" "issue close"
wantnocall "fix-verdict: fix → never commented" "issue comment"
wantcall   "fix-verdict: fix → one guarded body edit" "issue edit"
n="$(grep -c '^last-cleared:' /tmp/rbody.md 2>/dev/null || echo 0)"
[ "$n" = "1" ] && ok "fix-verdict: fix → exactly 1 last-cleared line" || bad "last-cleared line count" "got $n"
grep -q '^fix-verdict:' /tmp/rbody.md 2>/dev/null && grep -q '^alert-fp:r1' /tmp/rbody.md 2>/dev/null \
  && ok "fix-verdict: fix → verdict + alert-fp markers survive the rewrite" \
  || bad "markers survive the rewrite" "a marker was lost"

scenario resolve-fix-second-clear
searchhit teststuffstash/oracle-iac 77
issuebody 'evidence
alert-fp:r1
fix-verdict: fix
last-cleared: 2026-08-07T23:00:00Z — AgentWorkerEgressDropped stopped firing (alert-fp:r1).' '[]'
go "$(resolved r1 AgentWorkerEgressDropped)"
n="$(grep -c '^last-cleared:' /tmp/rbody.md 2>/dev/null || echo 0)"
[ "$n" = "1" ] && ok "second clear → still exactly 1 line (N clears never accumulate)" || bad "second-clear line count" "got $n"

scenario resolve-report-only
searchhit teststuffstash/homelab 77
issuebody 'evidence
alert-fp:r2
fix-verdict: report-only' '[{"user":{"login":"homelab-agents-1234[bot]","type":"Bot"}}]'
go "$(resolved r2 PVCNearFull)"
want     "report-only, bots only → commented + CLOSED (unchanged)" "commented + CLOSED"
wantcall "report-only, bots only → the ✅ comment is still posted" "issue comment"
wantcall "report-only → close issued" "issue close"

# ── #148: the OTHER churn path. PR#129 gave the single-line treatment to 'fix' verdicts only, so
# report-only + human-engaged kept commenting every clear on a thread that never closes: 27 of the
# 80 comments homelab took on 2026-08-08 were this leg, #63 four in ~2h of PSI flapping. An open
# issue is exactly where a per-clear comment is unbounded, so it gets the body line instead.
scenario resolve-report-only-human
searchhit teststuffstash/homelab 77
issuebody 'evidence
alert-fp:r3
fix-verdict: report-only' '[{"user":{"login":"RasmusSoot","type":"User"}}]'
go "$(resolved r3 PVCNearFull)"
want       "report-only + a human → left OPEN (unchanged)" "left OPEN"
wantnocall "report-only + a human → not closed" "issue close"
wantnocall "report-only + a human → NO ✅ comment any more (#148)" "issue comment"
wantcall   "report-only + a human → one guarded body edit instead" "issue edit"
n="$(grep -c '^last-cleared:' /tmp/rbody.md 2>/dev/null || echo 0)"
[ "$n" = "1" ] && ok "report-only + a human → exactly 1 last-cleared line" || bad "open-issue last-cleared count" "got $n"
grep -q '^alert-fp:r3' /tmp/rbody.md 2>/dev/null && grep -q '^fix-verdict: report-only' /tmp/rbody.md 2>/dev/null \
  && ok "report-only + a human → markers survive the rewrite" \
  || bad "markers survive the rewrite (report-only)" "a marker was lost"

scenario resolve-report-only-human-second-clear
searchhit teststuffstash/homelab 77
issuebody 'evidence
alert-fp:r3
fix-verdict: report-only
last-cleared: 2026-08-07T23:00:00Z — PVCNearFull stopped firing (alert-fp:r3). A human is engaged.' '[{"user":{"login":"RasmusSoot","type":"User"}}]'
go "$(resolved r3 PVCNearFull)"
wantnocall "second clear on an OPEN human-engaged issue → ZERO new comments (the flap case)" "issue comment"
n="$(grep -c '^last-cleared:' /tmp/rbody.md 2>/dev/null || echo 0)"
[ "$n" = "1" ] && ok "second clear → still exactly 1 line (N flaps never accumulate)" || bad "second-clear line count (open issue)" "got $n"

scenario resolve-report-only-human-no-marker
searchhit teststuffstash/homelab 77
issuebody 'a body the search matched via a COMMENT — it carries no alert-fp line of its own' '[{"user":{"login":"RasmusSoot","type":"User"}}]'
go "$(resolved r8 PVCNearFull)"
want       "no alert-fp in the body → left untouched, never half-written" "left untouched"
wantnocall "…and still no comment (an unguarded body is not a reason to churn)" "issue comment"
wantnocall "…and still not closed" "issue close"

scenario resolve-no-verdict
searchhit teststuffstash/homelab 77
issuebody 'no verdict line here
alert-fp:r4' '[]'
go "$(resolved r4 PVCNearFull)"
want "no verdict recorded → legacy behaviour (comment + close)" "commented + CLOSED"

scenario resolve-unreadable
searchhit teststuffstash/homelab 77
go "$(resolved r5 PVCNearFull)"                 # no fixture → gh issue view exits 1
want       "unreadable issue → left alone (never close on a failed read)" "left alone"
wantnocall "unreadable issue → not closed" "issue close"
wantnocall "unreadable issue → not commented" "issue comment"

scenario resolve-partial-read
searchhit teststuffstash/homelab 77
printf '{"body":"alert-fp:r6","labels":[' > "$H/gh/issue-77.json"   # truncated, still exit 0
go "$(resolved r6 PVCNearFull)"
want       "PARTIAL read → left alone (the jq -e parse guard)" "left alone"
wantnocall "PARTIAL read → not closed" "issue close"
wantnocall "PARTIAL read → not commented" "issue comment"

scenario resolve-nothing-open
printf '[]' > "$H/gh/search.json"
go "$(resolved r7 PVCNearFull)"
want "resolved with no open issue → nothing to close" "nothing to close"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "VERDICT read-back follows a RE-ROUTED filing"
# STEP 1 can land a session on ANY claimed repo, so searching only (default, platform) would drop
# the verdict: the issue would sit unlabelled and the bell would never ring.

scenario verdict-rerouted
printf '[]' > "$H/gh/search.json"
printf '[]' > "$H/gh/verdict-list-teststuffstash_homelab.json"
jq -n '[{number:42, body:"alert-fp:v1\nfix-verdict: fix"}]' > "$H/gh/verdict-list-teststuffstash_sleep-iac.json"
jq -n '{body:"alert-fp:v1\nfix-verdict: fix"}' > "$H/gh/verdict-issue.json"
go "$(alert v1 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x"}')"
want     "verdict found on the re-routed repo and labelled agent-fix" "sleep-iac#42 labelled agent-fix"
wantcall "verdict → /fix-verdict bell rung" "/fix-verdict"

# …and APP-ward, not just -iac-ward (#154). STEP 1's own rule routes to the stack's app repo when
# the fix is that stack's application code — a workflow file in a stack repo is app-repo surface.
# Filtering the candidates to `-iac` names made those filings inert: oracle-fleet#228 carried
# 'fix-verdict: fix' and sat unlabelled for ~6h until a human hand-queued it.
scenario verdict-rerouted-app-repo
printf '[]' > "$H/gh/search.json"
printf '[]' > "$H/gh/verdict-list-teststuffstash_homelab.json"
jq -n '[{number:228, body:"alert-fp:v2\nfix-verdict: fix"}]' > "$H/gh/verdict-list-teststuffstash_oracle-fleet.json"
jq -n '{body:"alert-fp:v2\nfix-verdict: fix"}' > "$H/gh/verdict-issue.json"
go "$(alert v2 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x"}')"
want     "verdict on a claimed APP repo found and labelled agent-fix" "oracle-fleet#228 labelled agent-fix"
wantnot  "app-repo verdict → not written off as unfindable" "nothing to label"
wantcall "app-repo verdict → /fix-verdict bell rung" "/fix-verdict"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "BIND-AT-FILING — Cause: line → native sub-issue edge (ADR-094, S6)"

# When the issue body carries a line-anchored 'Cause: #<n>' marker and the cause issue exists,
# the shell POSTs the native sub-issue edge, same pattern as .agents/fix.yaml. Same repo only.

scenario cause-line-valid
printf '[]' > "$H/gh/search.json"
jq -n '[{number:999, body:"evidence\nalert-fp:c1\nCause: #123\nfix-verdict: fix", id:123999}]' > "$H/gh/verdict-list-teststuffstash_homelab.json"
jq -n '{body:"evidence\nalert-fp:c1\nCause: #123\nfix-verdict: fix", id:123999}' > "$H/gh/verdict-issue.json"
# Additional fixtures for the cause issue and API calls
jq -n '{id:123123}' > "$H/gh/cause-issue.json"
go "$(alert c1 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x"}')"
want      "cause line present → issue filed with fix-verdict: fix" "labelled agent-fix"
wantcall  "cause line valid → POST to /sub_issues endpoint" "/sub_issues"
want      "cause line valid → logged as 'linked as sub-issue'" "linked as sub-issue"

scenario cause-line-absent
printf '[]' > "$H/gh/search.json"
jq -n '[{number:999, body:"evidence\nalert-fp:c2\nfix-verdict: fix", id:123999}]' > "$H/gh/verdict-list-teststuffstash_homelab.json"
jq -n '{body:"evidence\nalert-fp:c2\nfix-verdict: fix", id:123999}' > "$H/gh/verdict-issue.json"
go "$(alert c2 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x"}')"
want       "no cause line → issue filed normally" "labelled agent-fix"
wantnocall "no cause line → no /sub_issues POST" "/sub_issues"

scenario cause-line-malformed
printf '[]' > "$H/gh/search.json"
jq -n '[{number:999, body:"evidence\nalert-fp:c3\nCause: invalid\nfix-verdict: fix", id:123999}]' > "$H/gh/verdict-list-teststuffstash_homelab.json"
jq -n '{body:"evidence\nalert-fp:c3\nCause: invalid\nfix-verdict: fix", id:123999}' > "$H/gh/verdict-issue.json"
go "$(alert c3 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x"}')"
want       "malformed cause line → issue filed normally" "labelled agent-fix"
wantnocall "malformed cause line → no /sub_issues POST" "/sub_issues"

scenario cause-line-already-bound
printf '[]' > "$H/gh/search.json"
jq -n '[{number:999, body:"evidence\nalert-fp:c4\nCause: #123\nfix-verdict: fix", id:123999}]' > "$H/gh/verdict-list-teststuffstash_homelab.json"
jq -n '{id:123123}' > "$H/gh/cause-issue.json"
# The child issue already has a parent (simulating a previous bind). The stub reads verdict-issue.json
# for the */issues/999 API call, so include parent there.
jq -n '{body:"evidence\nalert-fp:c4\nCause: #123\nfix-verdict: fix", id:123999, parent:{id:123123}}' > "$H/gh/verdict-issue.json"
go "$(alert c4 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x"}')"
want       "already bound → issue filed normally" "labelled agent-fix"
wantnocall "already bound → no /sub_issues POST" "/sub_issues"
want       "already bound → logged as 'skip re-link'" "skip re-link"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "#1733 — a HUMAN's close is a decision the session is told about"
# The reopen belt (FU-133 subject + alert-fp) restores a closed thread so a FLAPPING alert does not
# churn new issues — and it had no opinion about WHO closed the thread. Measured on the live board
# 2026-09-16: homelab#103 closed by the operator and reopened by this lane FIVE times since
# 2026-08-05; #100 and #121 three times each; #542/#811/#241/#538 all reopened after an operator
# close, two of them within 48 h of the 2026-09-14 responder pass.
#
# The BELT is the guard and is pinned by `agents/replay/fixtures/responder-reopen/human-closed`
# (it re-closes after the session, ADR-094: the LLM judges, the shell acts). What THIS section
# asserts is the other half — that the session is TOLD, so it spends no turns on a reopen that gets
# reverted and its own record reads honestly.

scenario human-closed-note
searchhit teststuffstash/homelab 103
printf '[{"event":"closed","actor":{"login":"RasmusSoot","type":"User"},"created_at":"2026-08-30T20:19:41Z"}]' > "$H/gh/events.json"
go "$(alert f20 '{"alertname":"NodeSystemSaturation","namespace":"monitoring","node":"wk-01"}')"
want      "the human close is named in the log" "HUMAN-CLOSED"
wantbrief "the brief names the threads the belt will restore" "HUMAN-CLOSED THREADS"
wantbrief "…and says what to do instead of reopening" "COMMENT on it and leave it closed"
wantbrief "…and keeps the flap case legal (machinery undoing machinery)" \
          "Reopening is for a thread the resolve leg closed when its alert cleared"

scenario machine-closed-no-note
searchhit teststuffstash/homelab 103
printf '[{"event":"closed","actor":{"login":"homelab-agents-1234[bot]","type":"Bot"},"created_at":"2026-08-04T10:07:11Z"}]' > "$H/gh/events.json"
go "$(alert f21 '{"alertname":"NodeSystemSaturation","namespace":"monitoring","node":"wk-01"}')"
wantnot   "a lane-closed thread is NOT flagged — the flap case is untouched" "HUMAN-CLOSED"
wantbrief "…and the ordinary reopen instruction still stands" "REOPEN that one"

scenario close-actor-unreadable
searchhit teststuffstash/homelab 103
go "$(alert f22 '{"alertname":"NodeSystemSaturation","namespace":"monitoring","node":"wk-01"}')"
want      "an unreadable close actor says so by name" "close actor unreadable"
wantnot   "…and does NOT claim a human close it cannot prove" "HUMAN-CLOSED"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "FU-230 leg (b) — the DECLARED window"
# Leg (a)'s Alertmanager silences match `node`, `instance`, the node's pod names and the zone
# Garage set. One class is beyond all four: a rollout alert labelled by namespace + daemonset
# carries neither `node` nor `instance`, and the pod that goes Pending is minted AFTER the silence.
# 2026-09-16 proved it twice — an nx-01 reinstall leaked KubeDaemonSetRolloutStuck with all four
# arms armed, and wk-03's shutdown leaked five classes the seat then silenced by hand for 8 h. So
# the seat DECLARES the names instead, and the responder reads that record.

_window() { # <alert,alert,...>
  jq -n --arg a "$1" '{data:{"w-wk-03-1":({id:"wk-03-1", by:"node-maintenance.sh",
      opened_at:"2026-01-01T00:00:00Z", until:"2099-01-01T00:00:00Z", node:"wk-03", note:"",
      reason:"node-maintenance window on wk-03 — planned cordon/drain/shutdown",
      alerts:($a|split(","))} | tojson)}}' > "$H/window.json"
}

scenario window-declared
_window "KubeDaemonSetRolloutStuck,CiliumUnreachableNodes"
go "$(alert w1 '{"alertname":"KubeDaemonSetRolloutStuck","namespace":"kube-system","daemonset":"cilium"}')"
want     "a declared alert spawns no session" "DECLARED WINDOW wk-03-1 names this alert"
wantnot  "…and never reaches the triage" "subject="
wantcall "…with a ledger marker, so a deliberate stop is not a drop (FU-113a)" '"window-'

scenario window-undeclared
_window "KubeDaemonSetRolloutStuck,CiliumUnreachableNodes"
go "$(alert w2 '{"alertname":"GarageClusterFlapping","namespace":"garage","pod":"garage-2"}')"
wantnot "an UNdeclared alert is not suppressed by an open window" "DECLARED WINDOW"
want    "…and triages normally — scoping is by alert NAME, never by node or namespace" "subject=workload:garage/garage-2"

scenario window-expired
jq -n '{data:{"w-old":({id:"wk-03-old", by:"node-maintenance.sh", opened_at:"2020-01-01T00:00:00Z",
   until:"2020-01-01T03:00:00Z", node:"wk-03", note:"", reason:"an old window",
   alerts:["KubeDaemonSetRolloutStuck"]} | tojson)}}' > "$H/window.json"
go "$(alert w3 '{"alertname":"KubeDaemonSetRolloutStuck","namespace":"kube-system","daemonset":"cilium"}')"
wantnot "an EXPIRED window suppresses nothing" "DECLARED WINDOW"
want    "…and the alert triages" "subject=workload:kube-system/cilium"

scenario window-absent
go "$(alert w4 '{"alertname":"KubeDaemonSetRolloutStuck","namespace":"kube-system","daemonset":"cilium"}')"
wantnot "an unreadable/absent record reads as NO window (rule #6, suppressing direction)" "DECLARED WINDOW"
want    "…and the alert triages" "subject=workload:kube-system/cilium"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "FU-210 / FU-231 — the §A1 transcript + finding record"
# A triage that files nothing used to leave NOTHING: the 2026-09-03 forgejo-pg-1 session marked the
# subject triaged, filed no issue anywhere, and the probe lane deferred to it as COVERED while the
# alert stood 8 h. The decision was unrecoverable. So every session now writes its transcript, its
# input alert and a typed finding to s3://agent-transcripts/homelab/alert-<fp>/responder-r1-<ts>/.
# What the harness can hold: the prefix shape, WHICH files go up, that the verdict reaches the
# finding record, and — the load-bearing half — that a missing key degrades instead of failing.

scenario capture-degrades
printf '[]' > "$H/gh/search.json"
go "$(alert ts1 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x"}')"
want      "no S3 key → capture skipped, loudly" "no S3 key in pod"
want      "…and the triage itself still completes" "subject=pvc:monitoring/x"
wantnocall "…and nothing is written to the bucket" "s5cmd"

scenario capture-uploads
printf '[]' > "$H/gh/search.json"
printf '[]' > "$H/gh/verdict-list-teststuffstash_homelab.json"
go_ts "$(alert ts2 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x"}')"
want     "the prefix is FU-210's: homelab/alert-<fp>/responder-r1-<ts>" "s3://agent-transcripts/homelab/alert-ts2/responder-r1-"
wantcall "the INPUT alert is captured (the record is replayable)" "cp /tmp/alert-one.json"
wantcall "the session's own words are captured" "cp /tmp/triage.log"
wantcall "…with the A1 manifest beside them" "cp /tmp/ts-manifest.json"
wantcall "…and the FU-231 typed finding record" "cp /tmp/ts-finding.json"
want     "a triage that filed NOTHING still records a finding — the 09-03 shape" "verdict='none' issue='none'"

# The verdict must REACH the record, or the finding is a list of alerts rather than of decisions.
scenario capture-finding-verdict
printf '[]' > "$H/gh/search.json"
printf '[]' > "$H/gh/verdict-list-teststuffstash_homelab.json"
jq -n '[{number:42, body:"alert-fp:ts3\nfix-verdict: fix"}]' > "$H/gh/verdict-list-teststuffstash_sleep-iac.json"
jq -n '{body:"alert-fp:ts3\nfix-verdict: fix"}' > "$H/gh/verdict-issue.json"
go_ts "$(alert ts3 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x"}')"
want "the finding carries the verdict and the filed issue" "verdict='fix' issue='teststuffstash/sleep-iac#42'"

# The capture runs BEFORE the post-session belts, so a failure down there cannot cost the
# transcript — that ordering IS the FU-210 property and is worth pinning rather than trusting.
scenario capture-precedes-belts
printf '[]' > "$H/gh/search.json"
go_ts "$(alert ts4 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x"}')"
tsline="$(grep -n 'transcripts: uploaded' "$H/out.txt" | head -1 | cut -d: -f1)"
vline="$(grep -n 'verdict:' "$H/out.txt" | head -1 | cut -d: -f1)"
{ [ -n "$tsline" ] && [ -n "$vline" ] && [ "$tsline" -lt "$vline" ]; } \
  && ok "the transcript upload precedes the verdict/dispatch belts" \
  || bad "transcript upload precedes the belts" "upload at line ${tsline:-none}, verdict at ${vline:-none}"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "#1274 — REMEDIATION-WOULD shadow marker (dial trial, leg 1)"
# The responder triage session's output gains ONE structured line when its verdict names a
# mechanical remediation it would have performed had the dial been armed. The brief carries the
# instruction unconditionally (no stack conditional); the LLM emits the line when it would act
# and omits it for report-only verdicts. The claude stub captures the brief, so we assert the
# instruction shape here; the LLM-side emission is verified in production by the first real
# stack-alert triage after merge.

scenario remediation-would-marker
go "$(alert rw1 '{"alertname":"AgentWorkerEgressDropped","source":"oracle-fleet","severity":"warning"}')"
wantbrief "remediation-would → brief carries the REMEDIATION-WOULD instruction" "REMEDIATION-WOULD MARKER"
wantbrief "remediation-would → instruction names the marker format" "REMEDIATION-WOULD: <verb>"
wantbrief "remediation-would → instruction says do NOT emit for report-only" "Do NOT emit this line when your verdict is report-only"
wantbrief "remediation-would → instruction says at most one per session" "At most one per distinct remediation per session"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failed:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
