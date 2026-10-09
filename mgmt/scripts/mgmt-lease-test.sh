#!/usr/bin/env bash
# mgmt-lease-test — fixture test of the management box's ⚓ upgrade-lease expiry loop
# (mgmt/scripts/mgmt-lease.sh, ADR-150) against policy/mgmt/upgrade-leases.yaml as committed HERE.
# A throwaway BARE repo is `origin` (the real clone/revert/push path runs against it); the lease
# registry read and every GitHub call are seams the test overrides and records. No cluster, no
# box, no GitHub.   devbox run mgmt-policy-test   (or: bash mgmt/scripts/mgmt-lease-test.sh)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WT="$(cd "$HERE/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ── the fixture repo: base → A (pin-only bump, keep + regen move with it) → B (a values edit) ───
SRC="$T/src"; git -C "$T" init -q -b master "$SRC"
mkdir -p "$SRC/argocd/platform/values" "$SRC/policy/mgmt"
cp "$WT/policy/mgmt/upgrade-leases.yaml" "$SRC/policy/mgmt/upgrade-leases.yaml"
app() { printf '# kps\nspec:\n  sources:\n    - chart: kube-prometheus-stack\n      targetRevision: %s\n      helm:\n        skipCrds: true\n%s' "$1" "${2:-}"; }
crds() { printf 'spec:\n  source:\n    chart: prometheus-operator-crds\n    targetRevision: %s\n' "$1"; }
app 86.3.2 >"$SRC/argocd/platform/kube-prometheus-stack.yaml"
crds 29.0.0 >"$SRC/argocd/platform/prometheus-operator-crds.yaml"
printf '# chart: kube-prometheus-stack 86.3.2\nAlertmanagerClusterDown\n' >"$SRC/argocd/platform/values/kube-prometheus-stack-upstream-alerts.txt"
printf 'rules:\n  - AlertmanagerClusterDown: none\n' >"$SRC/argocd/platform/values/kube-prometheus-stack-triage.yaml"
git -C "$SRC" add -A && git -C "$SRC" commit -q -m base
app 91.8.0 >"$SRC/argocd/platform/kube-prometheus-stack.yaml"
crds 32.0.1 >"$SRC/argocd/platform/prometheus-operator-crds.yaml"
printf '# chart: kube-prometheus-stack 91.8.0\nAlertmanagerClusterDown\nAlertmanagerClusterFailedPeers\n' >"$SRC/argocd/platform/values/kube-prometheus-stack-upstream-alerts.txt"
printf 'rules:\n  - AlertmanagerClusterDown: none\n  - AlertmanagerClusterFailedPeers: none\n' >"$SRC/argocd/platform/values/kube-prometheus-stack-triage.yaml"
git -C "$SRC" add -A && git -C "$SRC" commit -q -m "chore(deps): kps 91.8.0 + crds 32.0.1"
A="$(git -C "$SRC" rev-parse HEAD)"
app 91.8.0 "        valueFiles: [x]\n" >"$SRC/argocd/platform/kube-prometheus-stack.yaml"
git -C "$SRC" add -A && git -C "$SRC" commit -q -m "values edit"
B="$(git -C "$SRC" rev-parse HEAD)"
ORIGIN="$T/origin.git"; git clone -q --bare "$SRC" "$ORIGIN"

# ── the loop, sourced; its seams overridden ───────────────────────────────────────────────────
export MGMT_LEASE_DIR="$T/lease" MGMT_SENTINEL_DIR="$T/sentinel" MGMT_TEXTFILE_DIR="$T/text" MGMT_REPO_URL="$ORIGIN"
mkdir -p "$T/text"
# shellcheck source=mgmt-lease.sh
. "$HERE/mgmt-lease.sh" || { echo "FATAL: could not source mgmt-lease.sh"; exit 1; }
_yq() { if [ "${DEVBOX_SHELL_ENABLED:-}" = 1 ]; then ( cd "$WT" && yq "$@" ); else ( cd "$WT" && devbox run --quiet -- yq "$@" ); fi; }   # fast path: see mgmt-lib.sh _yq
mgmt_gh_token() { printf 'test-token'; }
GH_MODE="none"; GH_LOG="$T/gh.log"
gh_api() {  # records every call; answers by GH_MODE
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >>"$GH_LOG"
  case "$1 $2" in
    "GET branches/master") return 1 ;;                       # mgmt_clone falls back to a fetch
    "GET pulls?state=all&head="*)
      case "$GH_MODE" in
        pr-exists)  echo '[{"number":77,"state":"open","node_id":"PR_77","labels":[{"name":"automerge"},{"name":"dependencies"}],"auto_merge":{"merge_method":"squash"}}]' ;;
        pr-merged)  echo '[{"number":78,"state":"closed","node_id":"PR_78","labels":[],"auto_merge":null,"merged_at":"2026-10-07T00:00:00Z"}]' ;;
        pr-unarmed) echo '[{"number":79,"state":"open","node_id":"PR_79","labels":[{"name":"dependencies"}],"auto_merge":null}]' ;;
        *) echo '[]' ;;
      esac ;;
    "POST pulls") [ "$GH_MODE" = pr-create-fails ] && { echo "HTTP 502" >&2; return 1; }; echo '{"number":4242,"node_id":"PR_x"}' ;;
    "POST issues/79/labels") echo '[]' ;;
    "POST issues/4242/labels") echo '[]' ;;
    "POST /graphql") echo '{"data":{}}' ;;
    *) echo "gh_api stub: unexpected $1 $2" >&2; return 1 ;;
  esac
}
LEASES='{"items":[]}'; LEASE_RC=0
_mgmt_leases_get() { [ "$LEASE_RC" = 0 ] || { echo "connection refused" >&2; return 1; }; printf '%s' "$LEASES"; }
lease() {  # <name> <subject> <sha> <from> <to> <expected-end> [max-end]
  jq -nc --arg n "$1" --arg s "$2" --arg sha "$3" --arg f "$4" --arg t "$5" --arg e "$6" --arg m "${7:-}" \
    '{metadata:{name:$n,creationTimestamp:"2026-10-07T00:00:00Z"},data:{subject:$s,chart:"kube-prometheus-stack",sha:$sha,from:$f,to:$t,"expected-end":$e,"max-end":$m,by:"presync",reason:"test"}}'
}
PAST="2026-01-01T00:00:00Z"; FUTURE="2999-01-01T00:00:00Z"
pass=0; fail=0
run() {  # <name> <expected rc>  → sets OUT (log) and runs emit_metrics into $T/text/mgmt_lease.prom
  active=0; expired_left=0; unreadable=0; : >"$GH_LOG"; rm -rf "$MGMT_LEASE_DIR"
  lease_main >"$T/out" 2>&1; RC=$?; OUT="$(cat "$T/out")"   # not a $(…): the loop's state must reach emit_metrics
  emit_metrics "$RC"
  if [ "$RC" = "$2" ]; then pass=$((pass+1)); echo "PASS $1 (rc=$RC)"; else fail=$((fail+1)); echo "FAIL $1 — rc=$RC, want $2"; printf '%s\n' "$OUT" | sed 's/^/     /'; fi
}
expect() {  # <name> <grep-pattern> <text>
  if grep -qE -- "$2" <<< "$3"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1 — no '$2' in:"; printf '%s\n' "$3" | sed 's/^/     /'; fi
}
expect_empty() {  # <name> <text>
  if [ -z "$2" ]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1 — expected nothing, got:"; printf '%s\n' "$2" | sed 's/^/     /'; fi
}
metric() { grep -E "^$1( |\{)" "$T/text/mgmt_lease.prom" | grep -E "$2" | awk '{print $2}'; }

# 1. no leases
run no-leases 0
expect no-leases-tick '0 in flight, 0 expired' "$OUT"
expect no-leases-metric-active '^0$' "$(metric mgmt_lease_active .)"
expect no-leases-counters-initialised '^0$' "$(metric mgmt_lease_revert_total 'outcome="reverted"')"

# 2. live, not expired — nothing happens, no GitHub call beyond the clone's level check
LEASES="$(jq -nc --argjson l "$(lease l1 argocd/platform/kube-prometheus-stack.yaml "$A" 86.3.2 91.8.0 "$FUTURE")" '{items:[$l]}')"
run live-not-expired 0
expect live-active '1 in flight, 0 expired' "$OUT"
expect_empty live-no-pr-calls "$(grep -v 'GET branches/master' "$GH_LOG")"

# 3. expired, pin-only → reverted: branch on origin, keep forward, regen reverted, body's last line, labels, arm
LEASES="$(jq -nc --argjson l "$(lease l2 argocd/platform/kube-prometheus-stack.yaml "$A" 86.3.2 91.8.0 "$PAST")" '{items:[$l]}')"
run expired-pin-only 0
expect reverted-outcome "lease l2: reverted — PR #4242 opened: kube-prometheus-stack 91.8.0 → 86.3.2, branch revert-chart-lease-${A:0:8}" "$OUT"
BR="revert-chart-lease-${A:0:8}"
expect reverted-branch-on-origin "refs/heads/$BR" "$(git -C "$ORIGIN" show-ref)"
expect reverted-pin-back 'targetRevision: 86.3.2' "$(git -C "$ORIGIN" show "$BR:argocd/platform/kube-prometheus-stack.yaml")"
expect reverted-values-edit-kept 'valueFiles: \[x\]' "$(git -C "$ORIGIN" show "$BR:argocd/platform/kube-prometheus-stack.yaml")"
expect reverted-keep-forward 'targetRevision: 32.0.1' "$(git -C "$ORIGIN" show "$BR:argocd/platform/prometheus-operator-crds.yaml")"
expect reverted-regen-back '^# chart: kube-prometheus-stack 86.3.2$' "$(git -C "$ORIGIN" show "$BR:argocd/platform/values/kube-prometheus-stack-upstream-alerts.txt")"
expect reverted-one-commit '^1$' "$(git -C "$ORIGIN" rev-list --count "master..$BR")"
expect reverted-master-untouched "^$B\$" "$(git -C "$ORIGIN" rev-parse master)"
expect reverted-pr-body-last-line 'reverted-charts: kube-prometheus-stack@91.8.0$' "$(grep '^POST pulls ' "$GH_LOG" | sed 's/^POST pulls //' | jq -r '.body' | tail -1)"
expect reverted-pr-head "\"head\":\"$BR\"" "$(grep '^POST pulls ' "$GH_LOG")"
expect reverted-labels '"labels":\["automerge","dependencies"\]' "$(grep '^POST issues/4242/labels' "$GH_LOG")"
expect reverted-armed 'enablePullRequestAutoMerge.*SQUASH' "$(grep '^POST /graphql' "$GH_LOG")"
expect reverted-counter '^1$' "$(metric mgmt_lease_revert_total 'outcome="reverted"')"
expect reverted-expired-gauge '^1$' "$(metric mgmt_lease_expired .)"

# 4. expired, a PR for the branch already exists → already (nothing pushed: origin unchanged)
GH_MODE=pr-exists; BEFORE="$(git -C "$ORIGIN" show-ref | sha256sum)"
run expired-already-pr 0
expect already-pr "lease l2: already — PR #77 is open, labelled and armed for $BR" "$OUT"
expect already-origin-untouched "^$BEFORE\$" "$(git -C "$ORIGIN" show-ref | sha256sum)"
GH_MODE=none

# 5. expired, master's pin is no longer the lease's `to` → already (stale)
LEASES="$(jq -nc --argjson l "$(lease l3 argocd/platform/kube-prometheus-stack.yaml "$A" 86.3.2 99.0.0 "$PAST")" '{items:[$l]}')"
run expired-stale-pin 0
expect stale-already "lease l3: already — master's argocd/platform/kube-prometheus-stack.yaml pin is 91.8.0, not the lease's 99.0.0" "$OUT"

# 6. expired, the commit is not pin-only (B edits values) → not_pin_only, nothing pushed
LEASES="$(jq -nc --argjson l "$(lease l4 argocd/platform/kube-prometheus-stack.yaml "$B" 86.3.2 91.8.0 "$PAST")" '{items:[$l]}')"
run expired-not-pin-only 0
expect not-pin-only "lease l4: not_pin_only — argocd/platform/kube-prometheus-stack.yaml: 1 changed line\(s\) outside the pin grammar" "$OUT"
expect_empty not-pin-only-no-branch "$(git -C "$ORIGIN" show-ref | grep "revert-chart-lease-${B:0:8}" || true)"

# 7. a subject the policy does not name → no_policy
LEASES="$(jq -nc --argjson l "$(lease l5 argocd/platform/other.yaml "$A" 1.0.0 2.0.0 "$PAST")" '{items:[$l]}')"
run no-policy 0
expect no-policy-outcome "lease l5: no_policy — subject 'argocd/platform/other.yaml' is not in policy/mgmt/upgrade-leases.yaml" "$OUT"

# 8. max-end caps expected-end: a renewal past the cap is expired once max-end is past
LEASES="$(jq -nc --argjson l "$(lease l6 argocd/platform/kube-prometheus-stack.yaml "$A" 86.3.2 91.8.0 "$FUTURE" "$PAST")" '{items:[$l]}')"
GH_MODE=pr-exists
run max-end-caps 0
expect max-end-expired '0 in flight, 1 expired' "$OUT"
GH_MODE=none

# 9. the registry is unreadable → PROBE-FAIL, exit 1, the unreadable gauge — never "no leases"
LEASE_RC=1
run unreadable 1
expect unreadable-line 'PROBE-FAIL: lease registry unreadable: connection refused' "$OUT"
expect unreadable-metric '^1$' "$(metric mgmt_lease_unreadable .)"
LEASE_RC=0

# 10. the pre-click state: the push is refused → outcome error naming the credential, nothing opened
LEASES="$(jq -nc --argjson l "$(lease l7 argocd/platform/kube-prometheus-stack.yaml "$A" 86.3.2 91.8.0 "$PAST")" '{items:[$l]}')"
git -C "$ORIGIN" update-ref -d "refs/heads/$BR"
chmod -R a-w "$ORIGIN/refs" "$ORIGIN/objects" 2>/dev/null; chmod a-w "$ORIGIN"
run push-refused 0
chmod -R u+w "$ORIGIN"
expect push-error "lease l7: error — push of $BR FAILED: .*contents:write" "$OUT"
expect_empty push-error-no-pr "$(grep '^POST pulls' "$GH_LOG" || true)"
expect push-error-counter '^1$' "$(metric mgmt_lease_revert_total 'outcome="error"')"

# 11. push succeeded, the PR call failed (a 5xx) → error; the NEXT tick must RESUME at the PR step on
#     the branch already on origin — never rebuild (a new sha could not be pushed over it; #2350 review)
LEASES="$(jq -nc --argjson l "$(lease l8 argocd/platform/kube-prometheus-stack.yaml "$A" 86.3.2 91.8.0 "$PAST")" '{items:[$l]}')"
GH_MODE=pr-create-fails
run pr-create-fails 0
expect pr-create-fails-error "lease l8: error — branch $BR is on origin but the PR could not be opened: .*HTTP 502.*resumes at the PR step" "$OUT"
expect pr-create-fails-branch-pushed "refs/heads/$BR" "$(git -C "$ORIGIN" show-ref)"
PUSHED="$(git -C "$ORIGIN" rev-parse "refs/heads/$BR")"
GH_MODE=none
run pr-create-then-succeeds 0
expect resume-at-pr "lease l8: branch $BR exists on origin with no PR — resuming at the PR, nothing rebuilt" "$OUT"
expect resume-reverted "lease l8: reverted — PR #4242 opened: kube-prometheus-stack 91.8.0 → 86.3.2, branch $BR, automerge\+dependencies, armed" "$OUT"
expect resume-branch-unchanged "^$PUSHED\$" "$(git -C "$ORIGIN" rev-parse "refs/heads/$BR")"
expect resume-one-pr-call '^1$' "$(grep -c '^POST pulls ' "$GH_LOG")"
expect resume-labelled '"labels":\["automerge","dependencies"\]' "$(grep '^POST issues/4242/labels' "$GH_LOG")"
expect resume-armed 'enablePullRequestAutoMerge' "$(grep '^POST /graphql' "$GH_LOG")"

# 12. the PR is open but a label/arm call failed on an earlier tick → resume at labels + arm, no push
GH_MODE=pr-unarmed; BEFORE="$(git -C "$ORIGIN" show-ref | sha256sum)"
run pr-open-unarmed 0
expect unarmed-resume "lease l8: PR #79 for $BR is open but not labelled\+armed — resuming there" "$OUT"
expect unarmed-rearmed "lease l8: reverted — PR #79 re-armed, automerge\+dependencies, armed" "$OUT"
expect unarmed-labels '"labels":\["automerge","dependencies"\]' "$(grep '^POST issues/79/labels' "$GH_LOG")"
expect unarmed-arm-node 'PR_79' "$(grep '^POST /graphql' "$GH_LOG")"
expect unarmed-origin-untouched "^$BEFORE\$" "$(git -C "$ORIGIN" show-ref | sha256sum)"
expect_empty unarmed-no-pr-create "$(grep '^POST pulls' "$GH_LOG" || true)"

# 13. a merged/closed PR for the branch → already
GH_MODE=pr-merged
run pr-merged 0
expect merged-already "lease l8: already — PR #78 exists for $BR \(closed\)" "$OUT"
GH_MODE=none

echo "mgmt-lease-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
