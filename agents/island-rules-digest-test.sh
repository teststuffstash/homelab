#!/usr/bin/env bash
# island-rules-digest-test — hermetic harness for the weekly island rules digest (FU-320):
# agents/island_rules.py's own self-test, then the CronWorkflow's script EXTRACTED from
# agents/coordinator/island-rules-digest-argo.yaml and RUN against stubs (deep-dig-test.sh's
# pattern: /tmp and the clone path redirected; `git clone` builds a fixture repo from this checkout
# with a crafted history, every other git call is real git; gh / claude / curl / s5cmd stubbed).
# No network, no cluster.
#
#   bash agents/island-rules-digest-test.sh      (also run by `devbox run deep-dig-test`)
#
# Scenarios: a change in the window → one session + the report committed + ONE PR; no change → no
# session, a one-line record; the island gauges unreadable → the report is still written ("not
# measured" reaches the session); a session that prints no report → no PR, no success push.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YAML="${YAML:-$REPO/agents/coordinator/island-rules-digest-argo.yaml}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
command -v jq >/dev/null 2>&1 || { echo "island-rules-digest-test: needs jq (devbox run -- bash $0)"; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "island-rules-digest-test: needs yq (devbox run -- bash $0)"; exit 2; }
REALGIT="$(command -v git)"

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "$2"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

section "agents/island_rules.py self-test (the derivation + the change record)"
if python3 "$REPO/agents/island_rules.py" self-test > "$TMP/selftest.log" 2>&1; then ok "island_rules self-test"; else bad "island_rules self-test" "$(grep -E 'FAIL|Error|error' "$TMP/selftest.log" | head -5)"; fi

section "the manifest's shape"
CW='select(.kind == "CronWorkflow")'
yqw() { yq -r "$CW | $1" "$YAML"; }
[ "$(yqw '.spec.schedules[0]')" != "0 5 * * 1" ] && ok "the schedule is not the retro's Monday 05:00Z slot" || bad "schedule" "collides with retro-session"
[ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "digest") | .synchronization.semaphores[0].configMapKeyRef.name')" = subscription-capacity ] \
  && ok "the digest LEAF holds the subscription semaphore" || bad "leaf semaphore" "missing"
[ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "digest-retry") | .synchronization // "none"')" = none ] \
  && ok "…and the retry wrapper holds none (FU-198)" || bad "wrapper semaphore" "the retry wrapper holds a lock"
grep -qx '  - island-rules-digest-argo.yaml' "$REPO/agents/coordinator/kustomization.yaml" \
  && ok "registered in agents/coordinator/kustomization.yaml (an unlisted manifest is pruned)" || bad "kustomization" "not listed"

# ── the extracted script + stubs ────────────────────────────────────────────────────────────────
yq -r "$CW | .spec.workflowSpec.templates[] | select(.name == \"digest\") | .container.args[0]" "$YAML" \
  | sed -e "s#/tmp/#$TMP/r/#g" -e "s#/tmp #$TMP/r #g" -e "s#/work/homelab#$TMP/w/homelab#g" \
        -e 's#{{workflow.parameters.since}}#2026-01-05#' -e 's#{{workflow.parameters.until}}#2026-01-12#' > "$TMP/digest-script.sh"
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/git" <<EOF
#!/bin/bash
# clone → a fixture repo from this checkout (base before the window; scenario "changes" adds one
# commit on gateway/intake.md inside it); push → logged; everything else → real git.
case "\$1" in
  clone)
    dest="\${@: -1}"; mkdir -p "\$dest"
    (cd "$REPO" && "$REALGIT" ls-files -z | tar --null -T - -cf -) | (cd "\$dest" && tar -xf -)
    printf '#!/bin/bash\necho anthropic\n' > "\$dest/agents/subscription-latch.sh"
    printf '#!/bin/bash\necho old-proxy-model\n' > "\$dest/agents/resolve-model.sh"
    cd "\$dest" || exit 1
    export GIT_AUTHOR_NAME=Op GIT_AUTHOR_EMAIL=op@example.org GIT_COMMITTER_NAME=Op GIT_COMMITTER_EMAIL=op@example.org
    "$REALGIT" init -q -b master && "$REALGIT" add -A \
      && GIT_AUTHOR_DATE=2026-01-01T12:00:00Z GIT_COMMITTER_DATE=2026-01-01T12:00:00Z "$REALGIT" commit -qm base || exit 1
    if [ "\$SCENARIO" != quiet ]; then
      printf '\nA session now does one more thing.\n' >> gateway/intake.md
      GIT_AUTHOR_DATE=2026-01-06T10:00:00Z GIT_COMMITTER_DATE=2026-01-06T10:00:00Z "$REALGIT" commit -qam "intake: one more thing (#7)" || exit 1
    fi
    exit 0;;
  push|fetch) echo "git \$*" >> "\$H/calls.log"; exit 0;;
esac
exec "$REALGIT" "\$@"
EOF
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$H/calls.log"
case "$1 $2" in
  "pr list") exit 0;;
  "pr create") echo "https://github.com/teststuffstash/homelab/pull/9001"; exit 0;;
esac
exit 0
EOF
cat > "$BIN/claude" <<'EOF'
#!/bin/bash
echo "claude $*" | cut -c1-200 >> "$H/calls.log"
[ "$SCENARIO" = noreport ] && { echo "I could not finish."; exit 0; }
g="$(jq -r 'if .measured then "measured" else .note end' "$TMPR/digest/gauges.json")"
echo "BEGIN-ISLAND-RULES-DIGEST"
echo "Verdict: 1 rule file changed in 1 island, +38 bytes, 1 commit, 0 widen authority."
printf '\n## What changed\n\n### gateway\n\nThe intake sitting does one more thing. Evidence: no reason given. Class: adds a rule.\n\n## Worth a look\n\n- no stated evidence\n\n## Numbers\n\n%s\n\n## What you can do\n\nNothing.\n' "$g"
echo "END-ISLAND-RULES-DIGEST"
EOF
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
case "$*" in
  *api/v1/query*) echo "curl prom $*" >> "$H/calls.log"; [ -f "$H/prom.json" ] || exit 22; cat "$H/prom.json"; exit 0;;
  *metrics/job/island_rules_digest*) { echo "curl pgw"; cat; } >> "$H/pgw.log"; exit 0;;
esac
echo "curl $*" >> "$H/calls.log"; exit 0
EOF
printf '#!/bin/bash\necho "s5cmd $*" >> "$H/calls.log"\n' > "$BIN/s5cmd"
chmod +x "$BIN"/*

run() { # <scenario> [prom: yes|no]
  SCENARIO="$1"; H="$TMP/h-$1"; rm -rf "$H" "$TMP/r" "$TMP/w"; mkdir -p "$H" "$TMP/r" "$TMP/w" "$TMP/home"; export H SCENARIO
  [ "${2:-yes}" = yes ] && printf '%s' '{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"island_intake_queued","island":"gateway","job":"island_intake"},"value":[0,"2"]}]}}' > "$H/prom.json"
  ( cd "$TMP" && PATH="$BIN:$PATH" HOME="$TMP/home" TMPR="$TMP/r" GH_TOKEN=x AGENT_GATEWAY="" PUSHGATEWAY=http://pgw \
      PROMETHEUS=http://prom ISLAND_GAUGE_RE="island_intake_.+" REPORT_REPO=teststuffstash/homelab REPORT_DIR=docs/agents/retros/island-rules \
      AGENT_TS_BUCKET=b AGENT_TS_ENDPOINT=e AGENT_TS_ACCESS_KEY_ID=k AGENT_TS_SECRET_ACCESS_KEY=s \
      bash "$TMP/digest-script.sh" ) > "$H/out.txt" 2> "$H/err.txt"
  RC=$?
}
has()   { grep -qF -- "$3" "$2" 2>/dev/null && ok "$1" || bad "$1" "no '$3' in $(basename "$2") | $(tail -3 "$H/out.txt" "$H/err.txt" 2>/dev/null | tr '\n' ' ')"; }
hasnt() { grep -qF -- "$3" "$2" 2>/dev/null && bad "$1" "unexpected '$3' in $(basename "$2")" || ok "$1"; }
REPORT="$TMP/w/homelab/docs/agents/retros/island-rules/2026-01-11.md"   # the window's last day = until - 1

section "a change in the window → one session, the report committed, ONE PR"
run changes
[ "$RC" -eq 0 ] && ok "the run succeeds" || bad "changes rc" "rc=$RC $(tail -5 "$H/out.txt")"
[ "$(jq -r '.counts.commits' "$TMP/r/digest/changes.json" 2>/dev/null)" = 1 ] && ok "the change record holds the one window commit" || bad "change record" "$(jq -c .counts "$TMP/r/digest/changes.json" 2>&1)"
has   "the session ran on the role's model (old path: resolve-model)" "$H/calls.log" "claude -p"
has   "…the brief is the committed brief file" "$TMP/r/digest/brief.md" "# Island rules digest — the session brief"
has   "…and names the inputs" "$TMP/r/digest/brief.md" "digest/changes.json"
[ -f "$TMP/r/digest/diffs/gateway_intake.md.diff" ] && grep -q '^+A session now does one more thing' "$TMP/r/digest/diffs/gateway_intake.md.diff" \
  && ok "the per-file diff over the window is an input" || bad "diff input" "$(ls "$TMP/r/digest/diffs" 2>&1)"
grep -qm1 '^Verdict:' "$REPORT" 2>/dev/null && ok "the report is committed at the dated path, verdict first" || bad "report path" "$(ls "$TMP/w/homelab/docs/agents/retros/island-rules" 2>&1)"
[ "$(git -C "$TMP/w/homelab" log -1 --format=%s 2>/dev/null)" = "island rules digest: week ending 2026-01-11 (1 change(s), FU-320)" ] \
  && ok "…on its own commit" || bad "commit" "$(git -C "$TMP/w/homelab" log -1 --format=%s 2>&1)"
has   "…pushed to the week's branch" "$H/calls.log" "git push -q origin HEAD:island-rules/2026-01-11"
has   "ONE PR, base master, the week's branch" "$H/calls.log" "gh pr create --repo teststuffstash/homelab --base master --head island-rules/2026-01-11"
has   "last_success pushed (the outcome landed)" "$H/pgw.log" "island_rules_digest_last_success_timestamp_seconds"
has   "the manifest is captured (A1)" "$H/calls.log" "manifest.json"
has   "the gauges were read (measured)" "$TMP/r/digest/gauges.json" '"measured": true'

section "no change in the window → no session, a one-line record"
run quiet
[ "$RC" -eq 0 ] && ok "the run succeeds" || bad "quiet rc" "rc=$RC $(tail -5 "$H/out.txt")"
hasnt "no session" "$H/calls.log" "claude -p"
hasnt "no PR" "$H/calls.log" "gh pr create"
has   "the record says no rule files changed" "$TMP/r/digest/record.json" '"outcome": "no rule files changed"'
has   "…and is captured" "$H/calls.log" "record.json"
has   "last_success pushed (a quiet week is an outcome)" "$H/pgw.log" "island_rules_digest_last_success_timestamp_seconds"

section "the island gauges unreadable → the report is still written"
run changes no
[ "$RC" -eq 0 ] && ok "the run succeeds" || bad "nogauge rc" "rc=$RC $(tail -5 "$H/out.txt")"
has   "gauges.json says not measured" "$TMP/r/digest/gauges.json" '"measured": false'
has   "…the session saw it and the report carries it" "$REPORT" "not measured"
has   "…and the PR still opens" "$H/calls.log" "gh pr create"

section "a session that prints no report → no PR, no success"
run noreport
[ "$RC" -eq 1 ] && ok "the run fails (exit 1 → the retry wrapper)" || bad "noreport rc" "rc=$RC"
hasnt "no PR" "$H/calls.log" "gh pr create"
hasnt "no last_success" "$H/pgw.log" "island_rules_digest_last_success_timestamp_seconds"
has   "the transcript is still captured" "$H/calls.log" "session.log"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failed:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
