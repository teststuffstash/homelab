#!/usr/bin/env bash
# mgmt-lease — the management box's ⚓ upgrade-lease expiry loop (ADR-150, docs/management-box.md
# §MB5; the glossary's "⚓ upgrade lease"). Commit-confirm from outside every cluster cone:
#
#   (1) an upgrade whose dependency cone holds its own detector (kube-prometheus-stack IS
#       Prometheus + Alertmanager) is judged by COMMIT-CONFIRM, never by an alert — the actor
#       DECLARES, VERIFIES and DELETES; this loop REVERTS whatever is still declared past its deadline;
#   (2) the record: one ConfigMap per in-flight upgrade in ns `agent-coordinator` (a sibling of the
#       `responder-window` registry, read on the same path), name `upgrade-lease-<subject-slug>`,
#       label `homelab.teststuff.net/upgrade-lease=true`; `creationTimestamp` = started; data:
#       subject (the Application file), chart, sha (the homelab commit synced), from, to,
#       expected-end, max-end (RFC3339 UTC), by, reason. ONE decisive field: `expected-end`;
#   (3) ARM = the Application's PreSync hook creates it; CONFIRM = the PostSync hook runs the real
#       checks and deletes it (the cluster half — argocd/resources/kube-prometheus-stack-lease/);
#       a renewal moves `expected-end`, never past `max-end`;
#   (4) REVERT = this loop, on the sentinel/apply cadence (`*:3/5`): for every lease with
#       `expected-end` in the past it opens ONE pin-only revert PR of the lease's sha — `automerge`
#       + `dependencies`, auto-merge armed, the reflex approves, the lane's checks still run — never a
#       direct push; the LAST body line `reverted-charts: <chart>@<to>` is pin-only-lint check (h)'s
#       30-day memory;
#   (5) credential: the `homelab-sentinel` App (this box's identity, MGMT_GH_APP_*) with
#       `contents: write` + `pull_requests: write` on homelab — the one operator click. PRE-CLICK the
#       push answers 403: that is outcome `error` with the HTTP reason in the log line, never a crash,
#       and MgmtLeaseRevertFailed names it;
#   (6) a declared window HOLDS the apply loop and NEVER this timer — a window arms nothing and a
#       lease expiring acts whether or not a seat has one open;
#   (7) scope: the subjects in policy/mgmt/upgrade-leases.yaml (kube-prometheus-stack first); a lease
#       on a subject the policy does not name is `no_policy`, read by a human.
#
# The box never diagnoses. An expired lease has exactly one meaning — "this upgrade was not
# confirmed" — which is what makes a dumb box safe; a healthy roll that outlasts its deadline reverts,
# and the fix is that subject's deadline, never a smarter box.
#
# THE REVERT, mechanically: in this loop's own clone (never the box's system checkout) `git revert
# --no-edit <sha>` of the lease's commit, then the policy's `keep` files restored to the sha's
# FORWARD content (a lease revert never downgrades CRDs — ADR-150/151) and amended into the one
# commit; the policy's `regen` files (rendered from the pin) revert with it. Admitted only when the
# commit is PIN-ONLY — touched nothing but `file` + `keep` + `regen`, and in `file`/`keep` every
# changed non-comment line is a `targetRevision:` line, with `file`'s one pair equal to the lease's
# from/to (the predicate of argocd/resources/chart-revert/chart_revert.py classify_commit) — else
# `not_pin_only`.
#
# OUTCOMES (the `outcome` label of mgmt_lease_revert_total, every value pre-initialised at 0 so
# increase() sees the first one — the pod-admission lesson):
#   reverted      the revert PR is open, labelled automerge+dependencies and armed
#   already       a PR for branch revert-chart-lease-<sha8> exists (open or merged), or master's pin
#                 in the subject file is no longer the lease's `to` (reverted or bumped again — stale)
#   no_policy     the lease's subject is not in policy/mgmt/upgrade-leases.yaml
#   not_pin_only  the lease's commit changed more than the pin (+ keep/regen) — a human reads it
#   conflict      `git revert` conflicted — never forced, nothing pushed
#   error         push / PR / label / arm failed, or a read failed mid-revert — the pre-click 403
#                 lands here; the lease stays and the next tick RESUMES where it stopped (a branch
#                 on origin → the PR step; an open un-armed PR → labels + arm) — never a rebuild,
#                 whose new sha could not be pushed over the existing branch (#2350's first review)
# A lease still expired after the tick counts in mgmt_lease_expired (MgmtLeaseExpiredUnreverted).
#
# Usage: mgmt/scripts/mgmt-lease.sh    (the mgmt-lease.timer unit). MGMT_SHADOW=1: builds the revert
# commit locally and logs the would-be push + PR, writes nothing to GitHub. Env: mgmt-lib.sh's, plus
# MGMT_LEASE_DIR (default /var/lib/mgmt/lease — the clone + counters) and MGMT_TEXTFILE_DIR.
# Sourceable (the fixture test overrides the seams, then calls lease_main).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"

ORG="${ORG:-teststuffstash}"; MGMT_REPO="${MGMT_REPO:-homelab}"
REPO_URL="${MGMT_REPO_URL:-https://github.com/${ORG}/${MGMT_REPO}.git}"
LDIR="${MGMT_LEASE_DIR:-/var/lib/mgmt/lease}"
REPO="$LDIR/homelab"; export REPO
LOCK="${MGMT_SENTINEL_DIR:-/var/lib/mgmt/sentinel}/.lock"
TEXTDIR="${MGMT_TEXTFILE_DIR:-/var/lib/node-exporter-textfile}"
LEASE_NS="${MGMT_LEASE_NS:-agent-coordinator}"
LEASE_LABEL="${MGMT_LEASE_LABEL:-homelab.teststuff.net/upgrade-lease}"
POLICY_PATH="policy/mgmt/upgrade-leases.yaml"
BRANCH_PREFIX="revert-chart-lease-"
OUTCOMES="reverted already no_policy not_pin_only conflict error"

# ── seams (the fixture test overrides these) ───────────────────────────────────────────────────
# raw ConfigMap LIST JSON on stdout — the responder-window read path (_mgmt_windows_get), by label
_mgmt_leases_get() {
  local kc="${KUBECONFIG:-}"; [ -f "$kc" ] || kc=/var/lib/mgmt/kubeconfig
  ( cd "$REPO" && devbox run --quiet -- kubectl --kubeconfig "$kc" -n "$LEASE_NS" get cm -l "$LEASE_LABEL=true" -o json )
}
_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── state: counters persist across ticks (a textfile counter must be monotonic) ───────────────
active=0; expired_left=0; unreadable=0
declare -A cnt=()
_counters_load() { local o; for o in $OUTCOMES; do cnt[$o]=0; done
  [ -f "$LDIR/revert-counters" ] && while read -r o n; do [ -n "$o" ] && cnt[$o]="${n:-0}"; done <"$LDIR/revert-counters"; return 0; }
_counters_save() { local o; : >"$LDIR/revert-counters.tmp"; for o in $OUTCOMES; do printf '%s %s\n' "$o" "${cnt[$o]:-0}" >>"$LDIR/revert-counters.tmp"; done; mv -f "$LDIR/revert-counters.tmp" "$LDIR/revert-counters"; }
outcome() {  # <outcome> <lease-name> <line>
  cnt[$1]=$(( ${cnt[$1]:-0} + 1 )); _counters_save
  log "lease $2: $1 — $3"
}
emit_metrics() {
  local rc=$1 o tmp
  [ -d "$TEXTDIR" ] || return 0
  [ "$rc" = 0 ] && date +%s >"$LDIR/last-ok-tick"
  tmp="$(mktemp "$TEXTDIR/.mgmt_lease.XXXXXX")" || return 0
  {
    echo "# HELP mgmt_lease_active Upgrade leases in flight (not yet expired) at the last tick."
    echo "# TYPE mgmt_lease_active gauge"
    echo "mgmt_lease_active $active"
    echo "# HELP mgmt_lease_expired Upgrade leases still EXPIRED after the last tick (no revert PR could be opened, or it is not merged+confirmed yet)."
    echo "# TYPE mgmt_lease_expired gauge"
    echo "mgmt_lease_expired $expired_left"
    echo "# HELP mgmt_lease_unreadable 1 while the last tick could not read the lease registry (never 'no leases')."
    echo "# TYPE mgmt_lease_unreadable gauge"
    echo "mgmt_lease_unreadable $unreadable"
    echo "# HELP mgmt_lease_last_run_timestamp_seconds Last tick of the lease loop that completed its evaluation."
    echo "# TYPE mgmt_lease_last_run_timestamp_seconds gauge"
    echo "mgmt_lease_last_run_timestamp_seconds $(cat "$LDIR/last-ok-tick" 2>/dev/null || echo 0)"
    echo "# HELP mgmt_lease_revert_total Decisions of the lease expiry loop, by outcome (ADR-150)."
    echo "# TYPE mgmt_lease_revert_total counter"
    for o in $OUTCOMES; do echo "mgmt_lease_revert_total{outcome=\"$o\"} ${cnt[$o]:-0}"; done
  } >"$tmp"
  chmod 0644 "$tmp" && mv -f "$tmp" "$TEXTDIR/mgmt_lease.prom"
}

# ── the reads ──────────────────────────────────────────────────────────────────────────────────
# leases_live → one JSON object per lease on stdout (the data keys flattened, started = the
# creationTimestamp, expected_end = min(expected-end, max-end)); rc 1 = unreadable — never `[]`.
leases_live() {
  local raw err rc
  err="$(mktemp)" || return 1
  raw="$(_mgmt_leases_get 2>"$err")"; rc=$?
  if [ "$rc" != 0 ]; then log "PROBE-FAIL: lease registry unreadable: $(tail -c 200 "$err" | tr '\n' ' ')" >&2; rm -f "$err"; return 1; fi
  rm -f "$err"
  jq -c '.items[]? | {name: .metadata.name, started: .metadata.creationTimestamp,
     subject: (.data.subject // ""), chart: (.data.chart // ""), sha: (.data.sha // ""),
     from: (.data.from // ""), to: (.data.to // ""), by: (.data.by // ""), reason: (.data.reason // ""),
     max_end: (.data["max-end"] // ""),
     expected_end: (if ((.data["max-end"] // "") != "") and ((.data["expected-end"] // "") > .data["max-end"]) then .data["max-end"] else (.data["expected-end"] // "") end)}' <<<"$raw"
}
# policy_subject <policy-file> <subject> → JSON row or rc 1
policy_subject() { local row; row="$(_yq -o=json ".subjects[] | select(.file == \"$2\")" "$1" 2>/dev/null)"; [ -n "$row" ] && [ "$row" != "null" ] || return 1; printf '%s' "$row"; }
# pin_at <ref> <file> → the file's one targetRevision value (rc 1 if not exactly one)
pin_at() { local pins; pins="$(git -C "$REPO" show "$1:$2" 2>/dev/null | sed -n -E 's/^[[:space:]]*targetRevision:[[:space:]]*"?([^[:space:]"#]+)"?.*$/\1/p')" || return 1; [ "$(printf '%s\n' "$pins" | grep -c .)" = 1 ] || return 1; printf '%s' "$pins"; }
# pin_only_commit <sha> <file> <keep…(space-sep)> <regen…(space-sep)> <from> <to> → 0, or 1 with the reason on stdout
pin_only_commit() {
  local sha="$1" file="$2" keep="$3" regen="$4" from="$5" to="$6" names n allowed f diffl bad removed added
  allowed=" $file $keep $regen "
  names="$(git -C "$REPO" show --name-only --format= "$sha" 2>/dev/null)" || { echo "cannot read commit $sha"; return 1; }
  [ -n "$names" ] || { echo "commit $sha has no files"; return 1; }
  while read -r n; do [ -n "$n" ] || continue; case "$allowed" in *" $n "*) ;; *) echo "commit touches $n — outside file+keep+regen"; return 1 ;; esac; done <<<"$names"
  grep -qx -- "$file" <<<"$names" || { echo "commit does not touch $file"; return 1; }
  for f in $file $keep; do
    grep -qx -- "$f" <<<"$names" || continue
    diffl="$(git -C "$REPO" show --format= --unified=0 "$sha" -- "$f" | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ')" || diffl=""
    bad="$(printf '%s\n' "$diffl" | sed -E 's/^[-+][[:space:]]*//' | grep -v '^#' | grep -vE '^targetRevision:[[:space:]]*"?[^[:space:]"#]+"?[[:space:]]*(#.*)?$' | grep -c .)"
    [ "$bad" = 0 ] || { echo "$f: $bad changed line(s) outside the pin grammar"; return 1; }
    if [ "$f" = "$file" ]; then
      removed="$(printf '%s\n' "$diffl" | sed -n -E 's/^-[[:space:]]*targetRevision:[[:space:]]*"?([^[:space:]"#]+)"?.*$/\1/p')"
      added="$(printf '%s\n' "$diffl" | sed -n -E 's/^\+[[:space:]]*targetRevision:[[:space:]]*"?([^[:space:]"#]+)"?.*$/\1/p')"
      [ "$removed" = "$from" ] && [ "$added" = "$to" ] || { echo "$f: pin pair -$removed +$added is not the lease's $from → $to"; return 1; }
    fi
  done
  return 0
}
pr_body() {  # <chart> <to> <from> <name> <sha> <started> <expected_end> <by> <reason>
  printf '%s' "Deterministic chart-pin rollback by the management box (ADR-150, the ⚓ upgrade lease): the lease \`$4\` on \`$1\` (commit \`${5:0:8}\`, $3 → $2, opened by \`$8\` at $6, reason: ${9:-—}) passed its deadline $7 without being confirmed — the PostSync hook never deleted it. An expired lease has one meaning, \"this upgrade was not confirmed\": this PR reverts the pin commit, keeps the \`keep\` files at their forward version (a lease revert never downgrades CRDs, ADR-151) and reverts the \`regen\` files with the pin (policy/mgmt/upgrade-leases.yaml). A Renovate PR that re-proposes the reverted version is refused by pin-only-lint check (h) (the \`reverted-charts:\` memory) until Renovate proposes a newer one. Mechanical lane: \`automerge\` + \`dependencies\` → the reflex approves, CI is the gate. Actor: \`mgmt/scripts/mgmt-lease.sh\` on the management box (docs/management-box.md §MB5), outside every cluster cone.

**Reverted commit:** $5
**Lease:** $4 — started $6, expected-end $7

reverted-charts: $1@$2"
}

# ── the revert of ONE expired lease (one outcome line) ─────────────────────────────────────────
revert_lease() {  # <lease-json> <policy-file>
  local L="$1" POL="$2" name subject chart sha from to started exp by reason row keep regen branch sha8 mpin why prs pr num node f
  name="$(jq -r .name <<<"$L")"; subject="$(jq -r .subject <<<"$L")"; sha="$(jq -r .sha <<<"$L")"
  from="$(jq -r .from <<<"$L")"; to="$(jq -r .to <<<"$L")"; started="$(jq -r .started <<<"$L")"; exp="$(jq -r .expected_end <<<"$L")"
  by="$(jq -r .by <<<"$L")"; reason="$(jq -r .reason <<<"$L")"
  if ! row="$(policy_subject "$POL" "$subject")"; then outcome no_policy "$name" "subject '$subject' is not in $POLICY_PATH — a human reads it"; return; fi
  chart="$(jq -r '.chart // ""' <<<"$row")"; keep="$(jq -r '(.keep // []) | join(" ")' <<<"$row")"; regen="$(jq -r '(.regen // []) | join(" ")' <<<"$row")"
  case "$sha" in *[!0-9a-f]*|'') outcome error "$name" "lease carries no usable sha ('$sha')"; return ;; esac
  sha8="${sha:0:8}"; branch="${BRANCH_PREFIX}${sha8}"
  # ledger 1: a PR for the revert branch exists — a previous tick owns it. OPEN but un-labelled or
  # un-armed (a label/arm call failed on that tick) → RESUME at the labels, never rebuild: the
  # mechanical lane needs both or the PR parks on nobody. Closed/merged → already.
  if [ "${MGMT_SHADOW:-0}" != 1 ]; then
    if ! prs="$(gh_api GET "pulls?state=all&head=${ORG}:${branch}" 2>/dev/null)"; then outcome error "$name" "cannot read the PRs of branch $branch — nothing written"; return; fi
    if [ "$(jq 'length' <<<"$prs")" != 0 ]; then
      pr="$(jq -c '(map(select(.state == "open")) | first) // (.[0])' <<<"$prs")"
      num="$(jq -r '.number' <<<"$pr")"; node="$(jq -r '.node_id // empty' <<<"$pr")"
      if [ "$(jq -r '.state' <<<"$pr")" != open ]; then outcome already "$name" "PR #$num exists for $branch ($(jq -r .state <<<"$pr"))"; return; fi
      if jq -e '([.labels[]?.name] | index("automerge") != null and index("dependencies") != null) and (.auto_merge != null)' <<<"$pr" >/dev/null; then
        outcome already "$name" "PR #$num is open, labelled and armed for $branch"; return
      fi
      log "lease $name: PR #$num for $branch is open but not labelled+armed — resuming there"
      label_and_arm "$name" "$num" "$node" "re-armed" && return; return
    fi
  fi
  # ledger 2: master's pin is no longer the lease's `to` → reverted or bumped again, a stale lease
  if ! mpin="$(pin_at origin/master "$subject")"; then outcome error "$name" "cannot read the pin of $subject at origin/master"; return; fi
  if [ "$mpin" != "$to" ]; then outcome already "$name" "master's $subject pin is $mpin, not the lease's $to — stale lease"; return; fi
  git -C "$REPO" cat-file -e "${sha}^{commit}" 2>/dev/null || { outcome error "$name" "commit $sha is not in the clone (fetch depth?)"; return; }
  if ! why="$(pin_only_commit "$sha" "$subject" "$keep" "$regen" "$from" "$to")"; then outcome not_pin_only "$name" "$why"; return; fi
  # ledger 3: the branch is already on origin (a previous tick pushed it, then the PR call failed —
  # a 5xx, a blip, a secondary rate limit). RESUME at the PR step: a rebuilt revert carries a new
  # committer timestamp = a new sha, and its push would be refused as non-fast-forward on every
  # later tick — the wedge the first review of this loop named (#2350). Never rebuild what exists.
  if [ "${MGMT_SHADOW:-0}" != 1 ] && mgmt_git -C "$REPO" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1; then
    log "lease $name: branch $branch exists on origin with no PR — resuming at the PR, nothing rebuilt"
    open_pr_label_arm "$name" "$branch" "$chart" "$to" "$from" "$sha" "$started" "$exp" "$by" "$reason"; return
  fi
  # build the revert on a fresh branch off origin/master (the clone is this loop's own)
  git -C "$REPO" checkout -q -B "$branch" origin/master 2>/dev/null || { outcome error "$name" "cannot branch $branch off origin/master"; return; }
  if ! git -C "$REPO" revert --no-edit "$sha" >/dev/null 2>&1; then
    git -C "$REPO" revert --abort >/dev/null 2>&1; git -C "$REPO" checkout -q --detach origin/master; git -C "$REPO" branch -q -D "$branch" 2>/dev/null
    outcome conflict "$name" "git revert $sha8 conflicted — nothing pushed"; return
  fi
  for f in $keep; do git -C "$REPO" cat-file -e "$sha:$f" 2>/dev/null && git -C "$REPO" checkout -q "$sha" -- "$f"; done
  git -C "$REPO" diff --cached --quiet || git -C "$REPO" commit -q --amend --no-edit
  git -C "$REPO" commit -q --amend -m "revert: $chart chart $to → $from (upgrade lease $name expired)" \
    -m "The ⚓ upgrade lease on $subject (commit $sha, $from → $to) passed its deadline $exp unconfirmed; the management box reverts the pin (ADR-150). keep: ${keep:-—}; regen: ${regen:-—}." >/dev/null 2>&1
  if [ "${MGMT_SHADOW:-0}" = 1 ]; then
    log "[shadow] lease $name: would push $branch ($(git -C "$REPO" rev-parse --short HEAD)) and open 'revert: $chart chart $to → $from' (automerge+dependencies, armed)"
    git -C "$REPO" checkout -q --detach origin/master; git -C "$REPO" branch -q -D "$branch" 2>/dev/null; return
  fi
  if ! why="$(mgmt_git -C "$REPO" push -q origin "refs/heads/$branch:refs/heads/$branch" 2>&1)"; then
    git -C "$REPO" checkout -q --detach origin/master; git -C "$REPO" branch -q -D "$branch" 2>/dev/null
    outcome error "$name" "push of $branch FAILED: $(printf '%s' "$why" | tr '\n' ' ' | tail -c 200) (pre-click? homelab-sentinel needs contents:write — ADR-150 (5))"; return
  fi
  git -C "$REPO" checkout -q --detach origin/master; git -C "$REPO" branch -q -D "$branch" 2>/dev/null
  open_pr_label_arm "$name" "$branch" "$chart" "$to" "$from" "$sha" "$started" "$exp" "$by" "$reason"
}
# open_pr_label_arm <name> <branch> <chart> <to> <from> <sha> <started> <exp> <by> <reason> — the PR step
# for a branch that IS on origin (just pushed, or found there). A failure here leaves the branch;
# the next tick resumes at this step (ledger 3), never at the build.
open_pr_label_arm() {
  local name="$1" branch="$2" chart="$3" to="$4" from="$5" sha="$6" started="$7" exp="$8" by="$9" reason="${10}" pr num node
  if ! pr="$(gh_api POST pulls "$(jq -nc --arg t "revert: $chart chart $to → $from (upgrade lease expired)" --arg h "$branch" \
        --arg b "$(pr_body "$chart" "$to" "$from" "$name" "$sha" "$started" "$exp" "$by" "$reason")" '{title:$t, head:$h, base:"master", body:$b}')" 2>&1)"; then
    outcome error "$name" "branch $branch is on origin but the PR could not be opened: $(printf '%s' "$pr" | tr '\n' ' ' | tail -c 200) — the next tick resumes at the PR step"; return 1
  fi
  num="$(jq -r '.number // empty' <<<"$pr")"; node="$(jq -r '.node_id // empty' <<<"$pr")"
  [ -n "$num" ] || { outcome error "$name" "PR create returned no number for $branch — the next tick resumes from the ledger"; return 1; }
  label_and_arm "$name" "$num" "$node" "opened: $chart $to → $from, branch $branch"
}
# label_and_arm <name> <pr-number> <pr-node-id> <what> — labels + auto-merge on an OPEN PR; idempotent
# (a label already present and an already-armed PR both answer 2xx), so a failed tick resumes here.
label_and_arm() {
  local name="$1" num="$2" node="$3" what="$4"
  if ! gh_api POST "issues/$num/labels" '{"labels":["automerge","dependencies"]}' >/dev/null 2>&1; then
    outcome error "$name" "PR #$num open but the automerge+dependencies labels FAILED — the next tick resumes here"; return 1
  fi
  [ -n "$node" ] || { outcome error "$name" "PR #$num open + labelled but its node id is unknown — cannot arm; the next tick resumes here"; return 1; }
  if ! gh_api POST /graphql "$(jq -nc --arg id "$node" '{query:"mutation($id:ID!){enablePullRequestAutoMerge(input:{pullRequestId:$id,mergeMethod:SQUASH}){clientMutationId}}", variables:{id:$id}}')" 2>/dev/null | jq -e '.errors == null' >/dev/null; then
    outcome error "$name" "PR #$num open + labelled but auto-merge could NOT be armed — the next tick resumes here"; return 1
  fi
  outcome reverted "$name" "PR #$num $what, automerge+dependencies, armed"
}

lease_main() {
  mkdir -p "$LDIR" "$(dirname "$LOCK")"
  _counters_load
  trap 'emit_metrics $?' EXIT
  if [ "${MGMT_SHADOW:-0}" != 1 ] && ! mgmt_gh_token >/dev/null; then
    log "no App token — running SHADOW (revert built locally, nothing written to GitHub)"; export MGMT_SHADOW=1
  fi
  exec 9>"$LOCK"; flock -w 600 9 || { log "PROBE-FAIL: lock busy for 10 min"; return 1; }
  mgmt_clone "$REPO" "$REPO_URL" || { log "PROBE-FAIL: clone/fetch of $REPO_URL failed"; return 1; }
  local leases now POL L exp n_exp=0
  if ! leases="$(leases_live)"; then unreadable=1; return 1; fi
  now="$(_now)"
  POL="$(mktemp --suffix=.yaml)"
  if ! git -C "$REPO" show "${MGMT_POLICY_REF:-origin/master}:$POLICY_PATH" >"$POL" 2>/dev/null || [ ! -s "$POL" ]; then
    rm -f "$POL"; log "PROBE-FAIL: $POLICY_PATH missing at ${MGMT_POLICY_REF:-origin/master}"; return 1
  fi
  while read -r L; do
    [ -n "$L" ] || continue
    exp="$(jq -r .expected_end <<<"$L")"
    if [ -z "$exp" ]; then outcome error "$(jq -r .name <<<"$L")" "lease has no expected-end — unreadable record"; n_exp=$((n_exp+1)); continue; fi
    if [ "$exp" \> "$now" ]; then active=$((active+1)); continue; fi
    n_exp=$((n_exp+1))
    revert_lease "$L" "$POL"
  done <<<"$leases"
  expired_left=$n_exp
  rm -f "$POL"
  log "tick: $active in flight, $n_exp expired"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then lease_main; exit $?; fi
return 0 2>/dev/null || true
