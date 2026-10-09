#!/usr/bin/env bash
# deep-dig-test — behavioural harness for agents/deep-dig-select.sh (ADR-148 (3), FU-249 step 4).
#
#   bash agents/deep-dig-test.sh          (devbox run deep-dig-test)
#
# The selector decides WHAT the deep dig looks at; the model only judges what it is handed. Every
# rule in that selection is a one-line jq/awk predicate with cluster-wide reach and no schema, so —
# like responder-behaviour-test.sh — the check is behavioural: the real script, its outside reads
# served from files through the seams the script declares (DIG_AM_FILE, DIG_PROM_DAY_DIR,
# DIG_WINDOW_FILE, DIG_PRIOR_FILE) and a PATH-stub `gh`, assertions on the digest it emits.
# Hermetic: no network, no cluster, DIG_NOW pinned so ages and onset buckets are stable.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEL="$REPO/agents/deep-dig-select.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
command -v jq >/dev/null 2>&1 || { echo "deep-dig-test: needs jq (devbox run -- bash $0)"; exit 2; }

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "$2"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── the clock: 2026-10-04T06:00:00Z ─────────────────────────────────────────────────────────────
NOW=1791093600
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }   # <epoch>

# ── stub gh: `search issues` serves $H/gh-search.json (default: nothing open) ───────────────────
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "gh $*" >> "$H/calls.log"
case "$1 $2" in
  "search issues") cat "$H/gh-search.json" 2>/dev/null || printf '[]'; exit 0;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

# ── scenario plumbing ───────────────────────────────────────────────────────────────────────────
scenario() { H="$TMP/run/$1"; rm -rf "$H"; mkdir -p "$H/prom"; export H; }
am() { printf '%s' "$1" > "$H/am.json"; }                         # the Alertmanager array
promday() { printf '%s' "$2" > "$H/prom/day-$1.json"; }         # <k> <instant-result json>
alert() { # <name> <startsAt-epoch> <labels-json-fragment> [annotations-json] → one AM alert
  jq -nc --arg n "$1" --arg s "$(iso "$2")" --argjson l "$3" --argjson a "${4:-{\}}" \
    '{fingerprint: ($n + "-fp"), startsAt: $s, status: {state: "active"}, labels: ($l + {alertname: $n}), annotations: $a}'
}
day() { # <series-labels-json>... → a Prometheus instant result holding those series
  local arr='[]'; for l in "$@"; do arr="$(jq -nc --argjson a "$arr" --argjson l "$l" '$a + [{metric: $l, value: [0, "1"]}]')"; done
  jq -nc --argjson r "$arr" '{status: "success", data: {resultType: "vector", result: $r}}'
}
# A repo snapshot the FU/meta-state greps read — a scratch copy so the live tracker never leaks in.
REPO_SNAP="$TMP/repo"; mkdir -p "$REPO_SNAP/docs/agents" "$REPO_SNAP/agents/coordinator" "$REPO_SNAP/argocd/platform/values"
cp "$REPO/agents/coordinator/responder-argo.yaml" "$REPO_SNAP/agents/coordinator/"
cp "$REPO/argocd/platform/values/kube-prometheus-stack-triage.yaml" "$REPO_SNAP/argocd/platform/values/"
go() {
  : > "$H/calls.log"
  DIG_NOW="$NOW" DIG_REPO="$REPO_SNAP" DIG_AM_FILE="$H/am.json" DIG_PROM_DAY_DIR="$H/prom" \
  DIG_WINDOW_FILE="$H/window.json" DIG_PRIOR_FILE="$H/prior.json" ORG=teststuffstash \
  PATH="$BIN:$PATH" env ${DIG_ENV:-} bash "$SEL" select --out "$H/digest.json" 2> "$H/err.txt"; RC=$?
  OUT="$(cat "$H/err.txt")"
}
want()   { grep -qF -- "$2" <<< "$OUT" && ok "$1" || bad "$1" "stderr lacks: $2"; }
wantnot(){ grep -qF -- "$2" <<< "$OUT" && bad "$1" "stderr has: $2" || ok "$1"; }
jqok()   { # <label> <jq predicate over the digest>
  # The digest must EXIST and be a digest before a predicate may pass: `jq -e` over an empty file
  # runs the filter zero times and exits 0, which made every assertion here vacuous while the
  # selector's own jq failed to compile on the pod's jq (PR#2212 review). A missing or malformed
  # digest is a failure of the assertion, never a pass.
  if ! [ -s "$H/digest.json" ] || ! jq -e '.schema == "deep-dig-digest/v1"' "$H/digest.json" >/dev/null 2>&1; then
    bad "$1" "no digest produced (rc=$RC): $(head -c 300 "$H/err.txt" | tr '\n' ' ')"; return
  fi
  jq -e "$2" "$H/digest.json" >/dev/null 2>&1 && ok "$1" || bad "$1" "digest fails: $2 — $(jq -c '{counts, groups: [.groups[] | {key, alerts: [.alerts[].alertname]}], explained}' "$H/digest.json" 2>/dev/null)"
}

KSM='{"job":"kube-state-metrics","instance":"10.244.6.51:8080","container":"kube-state-metrics","service":"kube-prometheus-stack-kube-state-metrics","endpoint":"http"}'

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "candidates — standing, recurring, and what never qualifies"

scenario standing
am "[$(alert KubeDeploymentReplicasMismatch $((NOW - 8*3600)) "$(jq -nc --argjson k "$KSM" '$k + {namespace:"cf-api-proxy", deployment:"cf-api-proxy", severity:"warning", triage:"dig"}')")]"
go
jqok "a dig alert standing 8h (≥ 6h) is a candidate" '.counts.unexplained == 1'
jqok "…with the responder's own subject (the daemonset/deployment arm)" '.groups[0].alerts[0].subject == "workload:cf-api-proxy/cf-api-proxy"'
jqok "…its standing hours recorded" '.groups[0].alerts[0].standing_h == 8'
jqok "…and a kube-state-metrics alert's host is 'cluster', never the exporter's pod IP" '.groups[0].host == "cluster"'

scenario too-fresh
am "[$(alert KubeDeploymentReplicasMismatch $((NOW - 2*3600)) "$(jq -nc --argjson k "$KSM" '$k + {namespace:"cf-api-proxy", deployment:"cf-api-proxy", triage:"dig"}')")]"
go
jqok "a dig alert standing 2h is NOT a candidate (the responder would have been too early too)" '.counts.candidates == 0'

scenario now-and-none-never
am "[$(alert KubePodNotReady $((NOW - 20*3600)) '{"namespace":"a","pod":"p-1","job":"kube-state-metrics","triage":"now"}'), $(alert KubeCPUOvercommit $((NOW - 20*3600)) '{"triage":"none"}'), $(alert SomeStackAlert $((NOW - 20*3600)) '{"namespace":"oracle-fleet"}')]"
go
jqok "triage:now is the responder's — never a dig candidate however long it stands" '.counts.candidates == 0'
want "…and the digest says so in one line" "0 candidate(s)"

scenario recurring-quiet
am '[]'
for k in 0 2 4; do promday $k "$(day '{"alertname":"NodeRebooted","alertstate":"firing","instance":"192.168.2.51:9100","job":"node-exporter","severity":"warning","triage":"dig"}')"; done
go
jqok "an alert present on 3 of 7 days but quiet now is a candidate (recurrence, not level)" '.counts.unexplained == 1'
jqok "…grouped under onset 'recurring'" '.groups[0].onset == "recurring"'
jqok "…with the host from its instance (port stripped)" '.groups[0].host == "192.168.2.51"'
jqok "…days_present counted" '.groups[0].alerts[0].days_present == 3'

scenario recurring-too-few
am '[]'
for k in 0 3; do promday $k "$(day '{"alertname":"NodeRebooted","alertstate":"firing","instance":"192.168.2.51:9100","job":"node-exporter","triage":"dig"}')"; done
go
jqok "2 of 7 days is not recurring" '.counts.candidates == 0'

# A stock-chart name carries no `triage` in Prometheus (the relabel map adds it at SEND time) —
# the selector resolves it from the map as Alertmanager would.
scenario recurring-upstream-unlabelled
am '[]'
for k in 0 1 2; do promday $k "$(day '{"alertname":"KubeNodeNotReady","alertstate":"firing","node":"wk-03","job":"kube-state-metrics","severity":"warning"}')"; done
go
jqok "an upstream name with no label in Prometheus resolves to dig via the relabel map" '.counts.unexplained == 1 and .groups[0].alerts[0].alertname == "KubeNodeNotReady"'
jqok "…and the host comes from the node label" '.groups[0].host == "wk-03"'

scenario recurring-upstream-none
am '[]'
for k in 0 1 2; do promday $k "$(day '{"alertname":"KubeCPUOvercommit","alertstate":"firing","severity":"warning"}')"; done
go
jqok "an upstream name the map classifies 'none' never qualifies" '.counts.candidates == 0'

scenario recurring-stack-unlabelled
am '[]'
for k in 0 1 2; do promday $k "$(day '{"alertname":"OracleGatewayErrorShareHigh","alertstate":"firing","namespace":"oracle-fleet","severity":"warning"}')"; done
go
jqok "a stack rule with no triage anywhere is nobody's (the label is the stack's to declare)" '.counts.candidates == 0'

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "explained — what already owns the condition is recorded and skipped"

scenario explained-window
am "[$(alert KubeDaemonSetRolloutStuck $((NOW - 10*3600)) "$(jq -nc --argjson k "$KSM" '$k + {namespace:"kube-system", daemonset:"cilium", triage:"dig"}')")]"
jq -n --arg u "$(iso $((NOW + 3600)))" '{data:{"w-1":({id:"wk-03-1", by:"node-maintenance.sh", until:$u, reason:"wk-03 drain", alerts:["KubeDaemonSetRolloutStuck"]} | tojson)}}' > "$H/window.json"
go
jqok "a declared window naming the alert explains it" '.counts.explained == 1 and (.explained[0].explained_by | startswith("window wk-03-1"))'
jqok "…and nothing is selected" '.counts.selected == 0'

scenario explained-window-expired
am "[$(alert KubeDaemonSetRolloutStuck $((NOW - 10*3600)) "$(jq -nc --argjson k "$KSM" '$k + {namespace:"kube-system", daemonset:"cilium", triage:"dig"}')")]"
jq -n --arg u "$(iso $((NOW - 3600)))" '{data:{"w-1":({id:"wk-03-old", until:$u, reason:"old", alerts:["KubeDaemonSetRolloutStuck"]} | tojson)}}' > "$H/window.json"
go
jqok "an EXPIRED window explains nothing" '.counts.unexplained == 1'
jqok "…but rides the digest as HISTORY (FU-230: closed/lapsed windows kept ≥ 4 days)" '.windows | map(.id) == ["wk-03-old"]'

scenario explained-window-tail
am "[$(alert KubeDaemonSetRolloutStuck $((NOW - 10*3600)) "$(jq -nc --argjson k "$KSM" '$k + {namespace:"kube-system", daemonset:"cilium", triage:"dig"}')")]"
jq -n --arg c "$(iso $((NOW - 600)))" --arg t "$(iso $((NOW + 600)))" '{data:{"w-1":({id:"wk-03-closed", until:$c, closed_at:$c, tail_until:$t, reason:"closed", alerts:["KubeDaemonSetRolloutStuck"]} | tojson)}}' > "$H/window.json"
go
jqok "a CLOSED window still in its tail explains what it named" '.counts.explained == 1 and (.explained[0].explained_by | startswith("window wk-03-closed"))'

scenario window-history-lookback
am '[]'
jq -n --arg o "$(iso $((NOW - 9*86400)))" --arg y "$(iso $((NOW - 2*86400)))" '{data:{
    "w-o":({id:"too-old", until:$o, closed_at:$o, tail_until:$o, reason:"r", alerts:["X"]} | tojson),
    "w-y":({id:"two-days", until:$y, closed_at:$y, tail_until:$y, reason:"r", alerts:["X"]} | tojson)}}' > "$H/window.json"
go
jqok "history is bounded by the dig lookback (7 d), not the record's retention" '(.windows | map(.id)) == ["two-days"]'

scenario explained-issue
am "[$(alert LonghornDiskBelowSchedulingFloor $((NOW - 30*3600)) '{"node":"hp-01","job":"longhorn-backend","triage":"dig"}')]"
printf '[{"repository":{"nameWithOwner":"teststuffstash/homelab"},"number":2101,"title":"🚨 LonghornDiskBelowSchedulingFloor: hp-01 stuck system snapshot"}]' > "$H/gh-search.json"
go
jqok "an OPEN issue whose title names the alert explains it" '.explained[0].explained_by == "issue teststuffstash/homelab#2101"'
grep -q 'gh search issues --owner teststuffstash LonghornDiskBelowSchedulingFloor --match title --state open' "$H/calls.log" \
  && ok "…found by an org-wide title search (the route can move between fires)" || bad "org-wide title search" "$(cat "$H/calls.log")"

scenario explained-issue-other-object
am "[$(alert LonghornDiskBelowSchedulingFloor $((NOW - 30*3600)) '{"node":"hp-01","job":"longhorn-backend","triage":"dig"}')]"
printf '[{"repository":{"nameWithOwner":"teststuffstash/homelab"},"number":2050,"title":"🚨 LonghornDiskBelowSchedulingFloor: m70s below floor","body":"subject:node:m70s"}]' > "$H/gh-search.json"
go
jqok "an open issue about the SAME alert on ANOTHER object explains nothing (a different record)" '.counts.unexplained == 1'

scenario explained-issue-per-class
am "[$(alert GarageWriteProbeFailing $((NOW - 30*3600)) '{"namespace":"monitoring","pod":"prometheus-pushgateway-5f67df54bd-kzjs7","container":"pushgateway","job":"garage_write_probe","service":"prometheus-pushgateway","triage":"dig"}')]"
printf '[{"repository":{"nameWithOwner":"teststuffstash/homelab"},"number":2060,"title":"🚨 GarageWriteProbeFailing: write probe 400s","body":"nothing"}]' > "$H/gh-search.json"
go
jqok "a per-class subject (alert:<name>) is explained by the title alone" '.explained[0].explained_by == "issue teststuffstash/homelab#2060"'

scenario explained-issue-wrong-title
am "[$(alert LonghornDiskBelowSchedulingFloor $((NOW - 30*3600)) '{"node":"hp-01","job":"longhorn-backend","triage":"dig"}')]"
printf '[{"repository":{"nameWithOwner":"teststuffstash/homelab"},"number":7,"title":"something about Longhorn generally"}]' > "$H/gh-search.json"
go
jqok "a search hit whose title does NOT carry the alertname explains nothing" '.counts.unexplained == 1'

scenario explained-fu
am "[$(alert PveHostSwapUsed $((NOW - 30*3600)) '{"instance":"192.168.2.59:9100","job":"pve-node","triage":"dig"}')]"
cat > "$REPO_SNAP/docs/follow-ups.md" <<'EOF'
# follow-ups
## open
- [ ] **FU-301** — something else entirely.
- [ ] **FU-302** — **nx-02 swap: PveHostSwapUsed stands by design** until the NUMA rebalance.
      Next: the box's own read.
- [x] **FU-300** — done.
EOF
go
jqok "an OPEN follow-up item naming the alert explains it, by id" '.explained[0].explained_by == "follow-up FU-302"'
rm -f "$REPO_SNAP/docs/follow-ups.md"

scenario explained-fu-closed-only
am "[$(alert PveHostSwapUsed $((NOW - 30*3600)) '{"instance":"192.168.2.59:9100","job":"pve-node","triage":"dig"}')]"
cat > "$REPO_SNAP/docs/follow-ups.md" <<'EOF'
- [x] **FU-300** — PveHostSwapUsed was a thing once.
EOF
go
jqok "a CLOSED item naming the alert explains nothing" '.counts.unexplained == 1'
rm -f "$REPO_SNAP/docs/follow-ups.md"

scenario explained-meta-state
am "[$(alert MgmtBeltCheckFailing $((NOW - 30*3600)) '{"check":"talos","job":"mgmt-node","triage":"dig"}')]"
printf -- '- ⚑ PICKUP: MgmtBeltCheckFailing{check="talos"} clears when PR#1963 merges.\n' > "$REPO_SNAP/docs/agents/meta-state.md"
go
jqok "the seat's meta-state naming the alert explains it" '.explained[0].explained_by == "meta-state"'
rm -f "$REPO_SNAP/docs/agents/meta-state.md"

# The prior findings are what `harvest` REALLY writes: run select, wrap a session block for the
# digest's group in the brief's markers, harvest it with the run's digest (DIG_DIGEST) — never a
# hand-written {alertname, subject} object. That hand-written shape is the one the gate matched
# and no harvested record ever carried: the fixture passed while the live gate re-dug the same
# group four days running (2026-10-06…09).
CFP_ALERT() { alert KubeDeploymentReplicasMismatch $((NOW - 8*3600)) "$(jq -nc --argjson k "$KSM" --arg d "${1:-cf-api-proxy}" '$k + {namespace:$d, deployment:$d, triage:"dig"}')"; }
prior_from_run() { # <finding-ts-epoch> <verdict> — harvest a finding for THIS scenario's group 0 → $H/prior.json
  go
  local key; key="$(jq -r '.groups[0].key' "$H/digest.json")"
  # The session's `alerts` prose deliberately names nothing: the stamped members are the key.
  { echo BEGIN-DIG-FINDING
    jq -nc --arg g "$key" --arg v "$2" '{schema:"dig-finding/v1", group:$g, alerts:["(the session wrote prose here)"], verdict:$v,
      cause:"", evidence:[], recommendation:"", pr:"", related:[], tool_gaps:[]}'
    echo END-DIG-FINDING; } > "$H/prior-dig.log"
  rm -rf "$H/prior-findings"
  DIG_DIGEST="$H/digest.json" DIG_TS="$(iso "$1")" DIG_RUN=dig-x/dig-r1-x bash "$SEL" harvest "$H/prior-dig.log" "$H/prior-findings" >/dev/null 2>&1
  jq -s '.' "$H/prior-findings"/finding-*.json > "$H/prior.json" 2>/dev/null || printf '[]' > "$H/prior.json"
}

scenario explained-prior-dig
am "[$(CFP_ALERT)]"
prior_from_run $((NOW - 2*86400)) cause-found
jq -e '.[0] | has("alertname") | not' "$H/prior.json" >/dev/null 2>&1 && jq -e '.[0].members == [{alertname:"KubeDeploymentReplicasMismatch", subject:"workload:cf-api-proxy/cf-api-proxy"}]' "$H/prior.json" >/dev/null 2>&1 \
  && ok "the harvested record carries the digest's members, no top-level alertname (the real shape)" || bad "harvested prior shape" "$(cat "$H/prior.json")"
go
jqok "a HARVESTED dig finding for the same (alert, subject) 2 days ago explains it (no daily re-dig)" '.counts.unexplained == 0 and (.explained[0].explained_by | startswith("dug "))'

scenario explained-prior-dig-stale
am "[$(CFP_ALERT)]"
prior_from_run $((NOW - 9*86400)) unexplained
go
jqok "…but a finding older than the redig window does not (the condition is new again)" '.counts.unexplained == 1'

scenario explained-prior-dig-other-subject
am "[$(CFP_ALERT other)]"
prior_from_run $((NOW - 86400)) cause-found
am "[$(CFP_ALERT)]"
go
jqok "a finding on another SUBJECT of the same alert explains nothing" '.counts.unexplained == 1'

# Findings harvested before the stamp (pre-2026-10-09, still in the bucket) carry only the
# session's `alerts` strings in the brief's "<alertname> (<subject>)" form — the fallback key.
scenario explained-prior-dig-legacy
am "[$(CFP_ALERT)]"
jq -n --arg ts "$(iso $((NOW - 86400)))" '[{schema:"dig-finding/v1", group:"2026-10-03T22:00:00Z|cluster",
  alerts:["KubeDeploymentReplicasMismatch (workload:cf-api-proxy/cf-api-proxy)"], verdict:"unexplained", ts:$ts, run:"dig-x/dig-r1-x"}]' > "$H/prior.json"
go
jqok "a LEGACY (unstamped) finding naming the pair in its alerts strings still explains it" '(.explained[0].explained_by | startswith("dug "))'

scenario explained-prior-dig-legacy-other
am "[$(CFP_ALERT)]"
jq -n --arg ts "$(iso $((NOW - 86400)))" '[{schema:"dig-finding/v1", group:"g", alerts:["KubeDeploymentReplicasMismatch (workload:other/other)"], verdict:"unexplained", ts:$ts}]' > "$H/prior.json"
go
jqok "…and a legacy finding on another subject explains nothing" '.counts.unexplained == 1'

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "grouping — onset and host are the correlation keys; the cap defers, never drops"

scenario group-same-onset-host
T0=$((NOW - 12*3600))
am "[$(alert NodeMemoryMajorPagesFaults $((T0 + 600)) '{"instance":"192.168.2.182:9100","job":"node-exporter","container":"node-exporter","namespace":"monitoring","triage":"dig"}'), \
     $(alert NodeDiskIOSaturation $((T0 + 1500)) '{"instance":"192.168.2.182:9100","job":"node-exporter","container":"node-exporter","namespace":"monitoring","triage":"dig"}'), \
     $(alert NodeDiskIOSaturation $((T0 + 1500)) '{"instance":"192.168.2.186:9100","job":"node-exporter","container":"node-exporter","namespace":"monitoring","triage":"dig"}')]"
go
jqok "two alerts on one host inside one onset bucket are ONE group" '(.groups | map(select(.host == "192.168.2.182")) | length) == 1 and (.groups[] | select(.host == "192.168.2.182") | .alerts | length) == 2'
jqok "the same alert on another host is its own group" '(.groups | map(select(.host == "192.168.2.186")) | length) == 1'
jqok "the larger group ranks first" '.groups[0].host == "192.168.2.182"'
jqok "the group key is onset|host" '.groups[0].key == (.groups[0].onset + "|" + .groups[0].host)'

scenario group-different-onset
am "[$(alert NodeMemoryMajorPagesFaults $((NOW - 30*3600)) '{"instance":"192.168.2.182:9100","job":"node-exporter","container":"node-exporter","triage":"dig"}'), \
     $(alert NodeDiskIOSaturation $((NOW - 7*3600)) '{"instance":"192.168.2.182:9100","job":"node-exporter","container":"node-exporter","triage":"dig"}')]"
go
jqok "the same host with onsets a day apart is two groups (two stories)" '.counts.groups == 2'

scenario group-cap-defers
am "[$(alert A1 $((NOW - 50*3600)) '{"node":"n1","triage":"dig"}'), $(alert A2 $((NOW - 40*3600)) '{"node":"n2","triage":"dig"}'), $(alert A3 $((NOW - 30*3600)) '{"node":"n3","triage":"dig"}')]"
DIG_ENV="DIG_MAX_GROUPS=2" go
jqok "with the cap at 2, two groups are selected" '.counts.selected == 2 and (.groups | length) == 2'
jqok "…and the third is DEFERRED, named, not dropped" '(.deferred | length) == 1 and (.deferred[0].alerts[0] | startswith("A3"))'
jqok "…longest-standing first among equal sizes" '.groups[0].alerts[0].alertname == "A1"'
want "the summary names the deferred group" "deferred"

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "rule #6 — unreadable reads fail in the safe direction"

scenario am-unreadable
rm -f "$H/am.json"
go
[ "$RC" -ne 0 ] && ok "an unreadable Alertmanager is exit non-zero (no digest, no silent empty run)" || bad "AM unreadable → non-zero" "rc=$RC"
want "…and says so" "PROBE_FAILED"

scenario prom-day-missing
am "[$(alert KubeDeploymentReplicasMismatch $((NOW - 8*3600)) "$(jq -nc --argjson k "$KSM" '$k + {namespace:"x", deployment:"x", triage:"dig"}')")]"
go
jqok "missing Prometheus days degrade to zero recurrence, the standing alert still qualifies" '.counts.unexplained == 1 and .groups[0].alerts[0].days_present == 0'
want "…with a note per unreadable day" "unreadable"

scenario digest-shape
am "[$(alert KubeDeploymentReplicasMismatch $((NOW - 8*3600)) "$(jq -nc --argjson k "$KSM" '$k + {namespace:"x", deployment:"x", triage:"dig"}')" '{"summary":"x mismatch","description":"read the rollout"}')]"
go
jqok "the digest carries its schema, timestamp and params" '.schema == "deep-dig-digest/v1" and .ts == "2026-10-04T06:00:00Z" and .params.standing_h == 6'
jqok "…and each alert's labels + annotations (the rule author's runbook hints ride along)" '.groups[0].alerts[0].annotations.description == "read the rollout" and .groups[0].alerts[0].labels.deployment == "x"'

# ────────────────────────────────────────────────────────────────────────────────────────────────
section "harvest — the session's finding blocks become records, invalid ones are dropped loudly"

scenario harvest-ok
cat > "$H/dig.log" <<'EOF'
Looking at group one...
BEGIN-DIG-FINDING
{"schema":"dig-finding/v1","group":"2026-10-03T18:00:00Z|192.168.2.182","alerts":["NodeMemoryMajorPagesFaults (instance:192.168.2.182:9100)"],"verdict":"cause-found","cause":"the X240's 8 GB with a Longhorn rebuild","evidence":["prometheus node_memory → 95%"],"recommendation":"","pr":"","related":[],"tool_gaps":[]}
END-DIG-FINDING
some prose
BEGIN-DIG-FINDING
{"schema":"dig-finding/v1","group":"recurring|192.168.2.51","alerts":["NodeRebooted (instance:192.168.2.51:9100)"],"verdict":"explained","cause":"","evidence":[],"recommendation":"","pr":"","related":["FU-247"],"tool_gaps":[]}
END-DIG-FINDING
BEGIN-DIG-FINDING
{"schema":"dig-finding/v1","group":"x","verdict":"maybe"}
END-DIG-FINDING
EOF
jq -n '{schema:"deep-dig-digest/v1", groups:[{key:"2026-10-03T18:00:00Z|192.168.2.182", alerts:[
  {alertname:"NodeMemoryMajorPagesFaults", subject:"instance:192.168.2.182:9100", standing_h:12},
  {alertname:"NodeDiskIOSaturation", subject:"instance:192.168.2.182:9100", standing_h:11}]}]}' > "$H/digest.json"
DIG_DIGEST="$H/digest.json" DIG_TS=2026-10-04T06:30:00Z DIG_RUN=dig-2026-10-04/dig-r1-x bash "$SEL" harvest "$H/dig.log" "$H/findings" > "$H/h.out" 2> "$H/h.err"; RC=$?
[ "$RC" -eq 0 ] && ok "harvest exits 0 when at least one block validates" || bad "harvest rc" "rc=$RC"
[ "$(ls "$H/findings"/finding-*.json 2>/dev/null | wc -l | tr -d ' ')" = "2" ] && ok "two valid blocks → two finding files" || bad "finding count" "$(ls "$H/findings")"
jq -e '.ts == "2026-10-04T06:30:00Z" and .run == "dig-2026-10-04/dig-r1-x" and .verdict == "cause-found"' "$H/findings/finding-1.json" >/dev/null 2>&1 \
  && ok "the record carries ts + run beside the session's fields" || bad "finding-1 shape" "$(cat "$H/findings/finding-1.json")"
jq -e '.members == [{alertname:"NodeMemoryMajorPagesFaults", subject:"instance:192.168.2.182:9100"}, {alertname:"NodeDiskIOSaturation", subject:"instance:192.168.2.182:9100"}]' "$H/findings/finding-1.json" >/dev/null 2>&1 \
  && ok "the record is stamped with ALL its digest group's members (the shell's key, not the session's alerts prose)" || bad "finding-1 members" "$(cat "$H/findings/finding-1.json")"
grep -q 'finding-2.*not a group of the run.s digest' "$H/h.err" && jq -e '.members == []' "$H/findings/finding-2.json" >/dev/null 2>&1 \
  && ok "a block whose group is not in the digest is kept, unstamped, and said so" || bad "unknown group stamp" "$(cat "$H/h.err")"
grep -q 'did not validate' "$H/h.err" && ok "the block with an unknown verdict is dropped LOUDLY" || bad "invalid block dropped loudly" "$(cat "$H/h.err")"
grep -q '2 finding(s) written .* (1 dropped)' "$H/h.out" && ok "…and the summary counts both" || bad "harvest summary" "$(cat "$H/h.out")"

scenario harvest-none
printf 'the session died before its first turn\n' > "$H/dig.log"
bash "$SEL" harvest "$H/dig.log" "$H/findings" > "$H/h.out" 2>&1; RC=$?
[ "$RC" -ne 0 ] && ok "no block at all → non-zero (the workflow log says the transcript is the only record)" || bad "harvest none rc" "rc=$RC"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failed:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
