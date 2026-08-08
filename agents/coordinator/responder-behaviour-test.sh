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
# NOT WIRED INTO CI, deliberately and not by preference: doing so needs a devbox.json script plus a
# step in .github/workflows/ci.yaml, and both files are off-limits to this lane precisely because
# CI runs them from the PR's own branch. Run it by hand when you touch the embedded script; it
# takes a few seconds. See the PR for #124.
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
    */issues/*)   { cat "$H/gh/verdict-issue.json" 2>/dev/null || printf '{}'; } | _emit; exit 0 ;;
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
exit 0
EOF
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "curl $*" >> "$H/calls.log"; exit 0
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
want()      { printf '%s' "$OUT" | grep -qF -- "$2" && ok "$1" || bad "$1" "stdout lacks: $2"; }
wantnot()   { printf '%s' "$OUT" | grep -qF -- "$2" && bad "$1" "stdout has: $2" || ok "$1"; }
wantbrief() { grep -qF -- "$2" "$H/brief.txt" 2>/dev/null && ok "$1" || bad "$1" "brief lacks: $2"; }
wantcall()  { grep -qF -- "$2" "$H/calls.log" 2>/dev/null && ok "$1" || bad "$1" "no call: $2"; }
wantnocall(){ grep -qF -- "$2" "$H/calls.log" 2>/dev/null && bad "$1" "unexpected call: $2" || ok "$1"; }
alert()     { printf '{"alerts":[{"status":"firing","fingerprint":"%s","labels":%s}]}' "$1" "$2"; }
resolved()  { printf '{"alerts":[{"status":"resolved","fingerprint":"%s","labels":{"alertname":"%s"}}]}' "$1" "$2"; }
searchhit() { printf '[{"repository":{"nameWithOwner":"%s"},"number":%s}]' "$1" "$2" > "$H/gh/search.json"; }
issuebody() { jq -n --arg b "$1" --argjson c "$2" '{body:$b, comments:$c}' > "$H/gh/issue-77.json"; }

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
section "ROUND-2 REGRESSION — the source fallback is scoped to ONE alert"
# Round 1 read `.labels.namespace // .labels.source` for EVERY alert, justified by the claim that
# no other rule uses `source`. False: RouterRotationStale
# (argocd/resources/openrouter-proxy/prometheusrule.yaml:58-59) is a bare selector on
# router_rotation_age_seconds{source="openrouter-daily-rankings"} and carries no `triage: none`,
# so it flows through here with a `source` that is a FEED name. Unscoped, its subject flipped to
# ns:openrouter-daily-rankings — a marker discontinuity that files a duplicate on the next fire.

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
fix-verdict: report-only' '[{"author":{"login":"homelab-agents-1234[bot]"}}]'
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
fix-verdict: report-only' '[{"author":{"login":"RasmusSoot"}}]'
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
last-cleared: 2026-08-07T23:00:00Z — PVCNearFull stopped firing (alert-fp:r3). A human is engaged.' '[{"author":{"login":"RasmusSoot"}}]'
go "$(resolved r3 PVCNearFull)"
wantnocall "second clear on an OPEN human-engaged issue → ZERO new comments (the flap case)" "issue comment"
n="$(grep -c '^last-cleared:' /tmp/rbody.md 2>/dev/null || echo 0)"
[ "$n" = "1" ] && ok "second clear → still exactly 1 line (N flaps never accumulate)" || bad "second-clear line count (open issue)" "got $n"

scenario resolve-report-only-human-no-marker
searchhit teststuffstash/homelab 77
issuebody 'a body the search matched via a COMMENT — it carries no alert-fp line of its own' '[{"author":{"login":"RasmusSoot"}}]'
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
printf '{"body":"alert-fp:r6","comments":[' > "$H/gh/issue-77.json"   # truncated, still exit 0
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
# STEP 1 can land a session on any claimed -iac, so searching only (default, platform) would drop
# the verdict: the issue would sit unlabelled and the bell would never ring.

scenario verdict-rerouted
printf '[]' > "$H/gh/search.json"
printf '[]' > "$H/gh/verdict-list-teststuffstash_homelab.json"
jq -n '[{number:42, body:"alert-fp:v1\nfix-verdict: fix"}]' > "$H/gh/verdict-list-teststuffstash_sleep-iac.json"
jq -n '{body:"alert-fp:v1\nfix-verdict: fix"}' > "$H/gh/verdict-issue.json"
go "$(alert v1 '{"alertname":"PVCNearFull","namespace":"monitoring","persistentvolumeclaim":"x"}')"
want     "verdict found on the re-routed repo and labelled agent-fix" "sleep-iac#42 labelled agent-fix"
wantcall "verdict → /fix-verdict bell rung" "/fix-verdict"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failed:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
