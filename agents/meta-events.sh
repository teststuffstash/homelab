#!/usr/bin/env bash
# meta-events.sh — THE consolidated meta-seat event loop (FU-166 leg (b), 2026-08-12).
#
# One Monitor arms this; it polls cheap on a 120s tick, diffs each source against durable state,
# and prints ONLY deltas — a quiet loop wakes nobody (a Monitor line is what wakes the seat, so
# edge-detection IS the token economy). ~2-min worst-case latency on the classes the seat serves.
#
# Lessons encoded (the file is the register of why it looks like this):
#   - liveness-not-outputs (2026-07-21): every source is a SET diff with dedup keys, never a log tail.
#   - "too many monitors" (2026-08-08): ONE loop, classed lines; needs-meta is absorbed as a source.
#   - rule #6: a failed probe HOLDS its previous state (no mass-CLEAR churn) and emits one
#     deduplicated PROBEFAIL event — silence is never a verdict.
#   - FU-084: REST + Alertmanager + Prometheus only; the single search call is 1/tick against the
#     30/min search pool. No GraphQL.
#   - Jail PAT: no statusCheckRollup anywhere (Checks perm absent — the hard-fail class).
#
# Sources (per-tick modulo keeps the call budget ~6-8 REST/tick ≈ 250/hr):
#   NEEDSMETA  every 2nd tick — `agents/meta-needs-attention.sh` verbatim (parks, blocked,
#              unlabeled, codeowner parks); its lines are the set elements.
#   GOALCMT    every tick — NEW User comments on open `task/goal` issues (the #278 charter-comment
#              lesson: operator directives on goal threads had no consumer).
#   ALERT      every tick — Alertmanager active fingerprint set (firing/resolved edges).
#   FAMINE     every tick — argo Pending workflow gauge with hysteresis (≥8 raises, ≤2 clears):
#              the doorbell-convoy signal until the FU-168 fixes land.
#
# Usage:  bash agents/meta-events.sh          # the loop (arm via Monitor; verify by process)
#         bash agents/meta-events.sh --once   # one tick; on a cold state dir this prints the
#                                             # full standing set — the fresh-session bootstrap view
set -u
STATE="${META_EVENTS_STATE:-$HOME/.claude/meta-events}"; mkdir -p "$STATE"
INTERVAL="${META_EVENTS_INTERVAL:-120}"
PROM="${META_EVENTS_PROM:-http://192.168.40.13:9090}"
AM="${META_EVENTS_AM:-http://192.168.40.14:9093}"
ORG=teststuffstash
HERE="$(cd "$(dirname "$0")" && pwd)"
TICK=0

emit() { printf 'META-EVENT %s %s\n' "$(date -u +%H:%M:%SZ)" "$1"; }
clearln() { printf 'META-CLEAR %s %s\n' "$(date -u +%H:%M:%SZ)" "$1"; }

# diff_source <name> <newfile> — prints event/clear lines vs stored state, then commits newfile.
diff_source() {
  local name="$1" new="$2" old="$STATE/$1.set"
  touch "$old"
  comm -13 <(sort -u "$old") <(sort -u "$new") | while IFS= read -r l; do emit "$l"; done
  comm -23 <(sort -u "$old") <(sort -u "$new") | while IFS= read -r l; do clearln "$l"; done
  sort -u "$new" > "$old"
}

# hold_source <name> <reason> — probe failed: keep old state, surface ONE deduped PROBEFAIL.
hold_source() {
  local name="$1" reason="$2" old="$STATE/$1.set" tmp
  tmp="$(mktemp)"; touch "$old"
  { cat "$old" | grep -v '^PROBEFAIL|' || true; printf 'PROBEFAIL|%s|%s\n' "$name" "$reason"; } > "$tmp"
  diff_source "$name" "$tmp"; rm -f "$tmp"
}

src_needsmeta() {
  local tmp; tmp="$(mktemp)"
  if bash "$HERE/meta-needs-attention.sh" --once > "$tmp" 2>/dev/null; then
    # each non-empty line is a set element, keyed by its own content
    awk 'NF {print "NEEDSMETA|" $0}' "$tmp" > "$tmp.set"
    diff_source needsmeta "$tmp.set"
  else
    hold_source needsmeta "meta-needs-attention.sh failed"
  fi
  rm -f "$tmp" "$tmp.set" 2>/dev/null
}

src_goalcmt() {
  local tmp; tmp="$(mktemp)"
  # one search call: the open goals (long-lived; search lag acceptable here, unlike dispatch)
  if ! gh api "search/issues?q=org:${ORG}+is:issue+label:task/goal+state:open&per_page=20" \
      --jq '.items[] | [.repository_url, .number] | @tsv' > "$tmp" 2>/dev/null; then
    hold_source goalcmt "goal search failed"; rm -f "$tmp"; return
  fi
  : > "$tmp.set"
  while IFS=$'\t' read -r rurl n; do
    [ -n "${n:-}" ] || continue
    local repo="${rurl##*/repos/}" curfile="$STATE/goalcmt-cursor-${rurl##*/}-$n"
    local since; since="$(cat "$curfile" 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
    # User (non-bot) comments since the cursor; the cursor advances only on a served read
    local out
    if out="$(gh api "repos/$repo/issues/$n/comments?since=$since&per_page=30" \
        --jq '.[] | select(.user.type=="User") | [.id, (.body|split("\n")[0][0:90])] | @tsv' 2>/dev/null)"; then
      printf '%s\n' "$out" | awk -v r="$repo" -v n="$n" -F'\t' \
        'NF {print "GOALCMT|" r "#" n "/" $1 "|operator comment: " $2}' >> "$tmp.set"
      date -u +%Y-%m-%dT%H:%M:%SZ > "$curfile"
    fi
  done < "$tmp"
  # GOALCMT events are one-shot (a comment never "clears"): merge into cumulative seen-set
  cat "$STATE/goalcmt.set" 2>/dev/null >> "$tmp.set" || true
  diff_source goalcmt "$tmp.set"
  rm -f "$tmp" "$tmp.set" 2>/dev/null
}

src_alert() {
  local tmp; tmp="$(mktemp)"
  # keyed on (alertname, namespace) — NEVER the fingerprint: instance churn re-keys fingerprints
  # (the #355 restart-gap identity lesson) and would flap this set forever. Watchdog (the
  # always-firing liveness canary) and InfoInhibitor (stock machinery) are excluded.
  if curl -sf -m 10 "$AM/api/v2/alerts?active=true" \
      | jq -r '.[] | select(.labels.alertname != "Watchdog" and .labels.alertname != "InfoInhibitor")
               | "ALERT|\(.labels.alertname)/\(.labels.namespace // "-")|firing"' | sort -u > "$tmp" 2>/dev/null; then
    diff_source alert "$tmp"
  else
    hold_source alert "alertmanager unreachable"
  fi
  rm -f "$tmp"
}

src_famine() {
  local v tmp; tmp="$(mktemp)"
  v="$(curl -sf -m 10 -G "$PROM/api/v1/query" \
        --data-urlencode 'query=max(argo_workflows_gauge{phase="Pending"})' \
        | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)" || v=""
  case "$v" in (''|*[!0-9.]*) hold_source famine "prometheus unreachable"; rm -f "$tmp"; return;; esac
  local prev; prev="$(cat "$STATE/famine.level" 2>/dev/null || echo ok)"
  local level="$prev"
  awk -v v="$v" 'BEGIN{exit !(v>=8)}' && level=high
  [ "$prev" = high ] && awk -v v="$v" 'BEGIN{exit !(v<=2)}' && level=ok
  echo "$level" > "$STATE/famine.level"
  if [ "$level" = high ]; then printf 'FAMINE|convoy|pending workflows ≥8 (now %s)\n' "$v" > "$tmp"; else : > "$tmp"; fi
  diff_source famine "$tmp"; rm -f "$tmp"
}

# SEATPR — the fix-on-feedback loop's own events (added 2026-08-12 after PR#381's approval went
# unseen: needs-meta reports STUCK states by design, so a healthy verdict→merge — and worse, a
# CHANGES_REQUESTED the seat must act on — had no source). Set lines carry the phase, so a
# verdict flip emits (old clears, new fires); merged PRs hold a line for 24h. CR lines carry
# the newest CR verdict's timestamp (@...) so a SAME-verdict re-review still edges — without it
# #398's round-2 CHANGES_REQUESTED (15:59, three minutes after the fix push) was invisible and
# the seat sat blind for an hour (operator caught it, 2026-08-12).
# CI-RED belt (2026-08-12, operator catch: PR#394 sat CI-red UNSEEN — a red check parks a PR in
# a state no review-decision edge crosses, because the reviewer only lifts green+current PRs, so
# the phase line above never moves). For OPEN seat PRs the head commit's `CI` run conclusion is
# read via `gh run list --commit` (Actions:read) — NEVER statusCheckRollup, which the jail PAT
# hard-fails whole (no Checks scope). A red head emits a set-line, so it fires once and clears
# on the green push. A failed conclusion read emits nothing — needs-meta's unreviewed-PR clause
# is the level backstop underneath.
SEAT_REPOS="${SEAT_REPOS:-homelab agent-runtime agent-coordinator openrouter-operator}"
src_seatpr() {
  local tmp me; tmp="$(mktemp)"; : > "$tmp"
  me="$(cat "$STATE/seatpr.login" 2>/dev/null)" || me=""
  [ -n "$me" ] || { me="$(gh api user --jq .login 2>/dev/null)" && echo "$me" > "$STATE/seatpr.login"; }
  [ -n "$me" ] || { hold_source seatpr "cannot resolve own login"; rm -f "$tmp"; return; }
  local r ok=1 prs pr_sha n sha c
  for r in $SEAT_REPOS; do
    prs="$(gh pr list -R "$ORG/$r" --state all --limit 15 \
        --json number,author,state,reviewDecision,mergedAt,headRefOid,latestReviews 2>/dev/null)" || { ok=0; continue; }
    # pipe to REAL jq — `gh --jq` takes no --arg (the standing coordinator-scan rule)
    printf '%s' "$prs" | jq -r --arg me "$me" --arg r "$r" \
        '.[] | select(.author.login==$me)
         | select(.state=="OPEN" or ((.mergedAt // "") > (now - 86400 | todate)))
         | "SEATPR|\($r)#\(.number)|\(if .state=="MERGED" then "MERGED" else (.reviewDecision // "AWAITING-REVIEW") end)\(if .state != "MERGED" and .reviewDecision == "CHANGES_REQUESTED" then "@" + ([.latestReviews[]? | select(.state == "CHANGES_REQUESTED") | .submittedAt] | max // "?") else "" end)"' \
        >> "$tmp" || ok=0
    for pr_sha in $(printf '%s' "$prs" | jq -r --arg me "$me" \
        '.[] | select(.author.login==$me and .state=="OPEN") | "\(.number):\(.headRefOid)"' 2>/dev/null); do
      n="${pr_sha%%:*}"; sha="${pr_sha##*:}"
      c="$(gh run list -R "$ORG/$r" --commit "$sha" --json name,conclusion \
             --jq '[.[] | select(.name=="CI")][0].conclusion // ""' 2>/dev/null)" || c=""
      case "$c" in failure|timed_out|startup_failure) echo "SEATPR|${r}#${n}|CI-RED" >> "$tmp";; esac
    done
  done
  if [ "$ok" = 1 ]; then diff_source seatpr "$tmp"; else hold_source seatpr "gh pr list failed"; fi
  rm -f "$tmp"
}

tick() {
  TICK=$((TICK+1))
  [ $((TICK % 2)) -eq 1 ] && src_needsmeta
  src_seatpr
  src_goalcmt
  src_alert
  src_famine
}

if [ "${1:-}" = "--once" ]; then TICK=0; tick; exit 0; fi
echo "meta-events: loop up (interval ${INTERVAL}s, state $STATE)"
while true; do tick; sleep "$INTERVAL"; done
