#!/usr/bin/env bash
# mgmt-sentinel — the management sentinel: plan-on-PR on the management box (ADR-131,
# docs/management-box.md §MB3; the tofu lane's L1, iac-lane.md §Assurance layers).
#
# For every open homelab PR head that touches a box-held root (policy/mgmt/plan-input.yaml, read
# from MASTER — never the PR's copy):
#   stage 1  the PR tree as DATA: deny_paths / symlinks / deny_patterns over the added lines.
#            A hit ⇒ `management-sentinel` = failure, rule named, NOTHING executed.
#   stage 2  `tofu plan` in an EPHEMERAL worktree of the head (never this box's system checkout),
#            providers from the committed lockfile (-lockfile=readonly) out of the local cache,
#            main's state via -state=. Then `tofu show -json` → addresses + counts.
# VERDICT-ONLY leaves the box: the commit status + one PR comment (addresses, action counts, and
# whether the apply allowlist covers them). Plan text stays in the journal + local files.
# A head touching no box-held surface gets success "no box-held surface touched" (v1: the box
# posts every verdict; the in-cluster no-root poster arrives with the required flip — §MB3).
#
# Usage:  mgmt/scripts/mgmt-sentinel.sh            # one pass over the open PRs (the timer's unit)
#         MGMT_SHADOW=1 mgmt/scripts/mgmt-sentinel.sh   # no GitHub writes; verdict ledger under done/
#         mgmt/scripts/mgmt-sentinel.sh --human-plan <pr> [--yes]
#            THE ESCAPE HATCH (FU-237 (e), §MB3 "When the box refuses"): ONE PR head, ordered by a
#            human who has read the diff (the jail's `devbox run mgmt-human-plan -- <pr>` ssh-es
#            here). Stage 1 still runs and is REPORTED — in the terminal and in the verdict
#            comment as "overridden" — but does not refuse; stage 2 plans as usual; the plan text
#            is shown in the terminal (the human READS it, as with mgmt-tf plan) and the verdict
#            is posted only after a y/N confirmation (`--yes` skips it; no tty + no --yes = no
#            post). The timer never takes this path: a refused head stays red until a human acts.
# Env: see mgmt/scripts/mgmt-lib.sh. Plus MGMT_SENTINEL_DIR (default /var/lib/mgmt/sentinel) — its clone,
# worktrees, done/ ledger, last-run stamp, and .lock (shared with mgmt-apply: one state file).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"

ORG="${ORG:-teststuffstash}"; MGMT_REPO="${MGMT_REPO:-homelab}"
REPO_URL="${MGMT_REPO_URL:-https://github.com/${ORG}/${MGMT_REPO}.git}"
SDIR="${MGMT_SENTINEL_DIR:-/var/lib/mgmt/sentinel}"
REPO="$SDIR/homelab"; export REPO
CTX="management-sentinel"; MARKER="<!-- management-sentinel -->"
mkdir -p "$SDIR/done"

HUMAN=0; HPR=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --human-plan) HPR="${2:-}"; shift; case "$HPR" in ''|*[!0-9]*) echo "usage: $0 [--human-plan <pr> [--yes]]" >&2; exit 2 ;; esac; HUMAN=1 ;;
    --yes) YES=1 ;;
    *) echo "usage: $0 [--human-plan <pr> [--yes]]" >&2; exit 2 ;;
  esac
  shift
done

if [ "${MGMT_SHADOW:-0}" != 1 ] && ! mgmt_gh_token >/dev/null; then
  log "no App token (MGMT_GH_APP_* unset or key unreadable) — running SHADOW"; export MGMT_SHADOW=1
fi
exec 9>"$SDIR/.lock"; flock -w 600 9 || { log "PROBE-FAIL: lock busy for 10 min"; exit 1; }

mgmt_clone "$REPO" "$REPO_URL" || { log "PROBE-FAIL: clone/fetch of $REPO_URL failed"; exit 1; }
POL="$(mgmt_policy_load "$REPO" "${MGMT_POLICY_REF:-origin/master}")" || exit 1  # MGMT_POLICY_REF: a TEST knob only (a branch's policy before it lands) — production reads master
trap 'rm -f "$POL"' EXIT

# ENGINE REVISION (2026-09-28, homelab#2046/#2047): a verdict is keyed to the head sha AND to the
# engine that produced it — this script, its lib and the policy, all as MASTER holds them. A change
# to any of the three re-judges every open head on the next tick, so a sentinel fix (the position
# lines) or a policy widening (the Deployment allowlist) reaches a parked PR without a push and
# without `mgmt-human-plan`. Before this the box memoized per sha forever: #2046/#2047 kept a red
# whose cause the box would never republish. Empty on a probe failure → the old per-sha memo.
# The revision hashes the files that EXECUTE — this script and the lib next to it come from the
# box's hourly-pulled checkout (/var/lib/homelab), not from the sentinel's own clone, which is
# fetched every run and can be an hour ahead of what runs (2026-09-28 12:06Z: a re-judge wore a
# new tag while the old script ran, and the "proof" it produced was the old engine's). The policy
# is read from the clone's origin/master every run, so its blob id is the right input for it.
ENGINE_REV="$( { cat "$0" "$HERE/mgmt-lib.sh"; git -C "$REPO" rev-parse origin/master:policy/mgmt/plan-input.yaml; } 2>/dev/null | sha256sum | cut -c1-7)" || ENGINE_REV=""
case "$ENGINE_REV" in *[!0-9a-f]*|'') ENGINE_REV="";; esac
[ -n "$ENGINE_REV" ] || log "engine revision unreadable — verdicts fall back to the per-sha memo this run"
ETAG="${ENGINE_REV:+[e:$ENGINE_REV] }"

verdicted() {   # <sha> → 0 if already judged BY THIS ENGINE REVISION
  if [ "${MGMT_SHADOW:-0}" = 1 ]; then [ -f "$SDIR/done/$1${ENGINE_REV:+-$ENGINE_REV}" ]; return; fi
  local n
  n="$(gh_api GET "commits/$1/status" | jq --arg c "$CTX" --arg e "$ETAG" '[.statuses[]|select(.context==$c and (($e == "") or ((.description // "") | startswith($e))))]|length')" || { echo probe-fail; return 1; }
  [ "${n:-0}" -gt 0 ]
}
post_verdict() {   # <sha> <state> <description> — the status carries the engine tag; the local memo is keyed the same way
  mgmt_post_status "$1" "$CTX" "$2" "${ETAG}$3" && touch "$SDIR/done/$1${ENGINE_REV:+-$ENGINE_REV}"
}

if [ $HUMAN = 1 ]; then
  # one head, named by the human; must be OPEN and master-bound (the same population the timer judges)
  one="$(gh_api GET "pulls/$HPR")" || { log "PROBE-FAIL: PR #$HPR unreadable"; exit 1; }
  [ "$(jq -r '.state' <<<"$one")" = open ] && [ "$(jq -r '.base.ref' <<<"$one")" = master ] \
    || { log "#$HPR is not an open master-bound PR (state $(jq -r .state <<<"$one"), base $(jq -r .base.ref <<<"$one")) — nothing to plan"; exit 1; }
  prs="$(jq -c '[.]' <<<"$one")"
  log "HUMAN PLAN of #$HPR@$(jq -r '.head.sha[0:8]' <<<"$one") — stage 1 reported, not enforced; the verdict posts only on confirmation"
else
  prs="$(gh_api_paged "pulls?state=open&base=master")" || { log "PROBE-FAIL: PR list failed — evaluating nothing"; exit 1; }
  count=$(jq 'length' <<<"$prs"); log "open PRs on ${ORG}/${MGMT_REPO} (base master): $count"
fi

# human_confirm <pr> <sha> <state> → 0 to post. --yes skips; no tty and no --yes = no post (rc 1).
human_confirm() {
  [ $YES = 1 ] && return 0
  [ -r /dev/tty ] && [ -w /dev/tty ] || { log "no tty and no --yes — NOT posting the verdict for #$1@${2:0:8}"; return 1; }
  local ans
  printf 'post management-sentinel=%s on #%s@%s under homelab-sentinel? [y/N] (the loops wait on the lock — answer within 10 min) ' "$3" "$1" "${2:0:8}" >/dev/tty
  # -t 600: the prompt holds SDIR/.lock, which the timer and mgmt-apply wait on for at most 600 s
  # (review finding on PR#1721) — an unanswered prompt times out to "no" before they PROBE-FAIL
  read -r -t 600 ans </dev/tty || ans=""
  case "$ans" in y|Y|yes) return 0 ;; *) log "declined — nothing posted for #$1@${2:0:8}"; return 1 ;; esac
}
# head_still <pr> <sha> → 0 while the PR's head is still <sha> (a push during the plan = the verdict is stale)
head_still() {
  local now; now="$(gh_api GET "pulls/$1" | jq -r '.head.sha // empty')" || return 1
  [ "$now" = "$2" ] || { log "#$1 head moved to ${now:0:8} during the plan — NOT posting on ${2:0:8}"; return 1; }
}
human_stamp=""

# install_impact <plan-out> <sha> → appends the install-impact section to $bodyf and sets
# $impact_desc (the status-description suffix). ADR-132 §MB4 layer 2, docs/management-box.md §MB3
# "The install-impact line": the class `tofu plan` cannot see — Talos honours schematic, install
# disk, the EPHEMERAL VolumeConfig and machine_type only on the next install, so a head changing
# them plans as a clean in-place config apply. Declared at the head (node_install_targets' AFTER)
# vs the applied declaration (its BEFORE) names the nodes this head moves; for those, the head's
# declaration is then diffed against LIVE by mgmt-probe.sh's own check_nodes (NODE_TARGETS_JSON),
# so a head that only codifies what already runs costs no window. Node + field NAMES leave the
# box, never values (the #1635 rule — the schematic ids and disk selectors stay in the journal).
impact_desc=""
install_impact() {
  local out="$1" sha="$2" rows node kind fields unk nodes=() drift="" line w win reinstall=0 upgrade=0 install=0 gone=0 codified=0
  local -a lines=() headline=()
  impact_desc=""
  if ! rows="$(mgmt_install_impact "$out")"; then
    { echo; echo "**Install impact: UNREADABLE** — this plan carries no \`node_install_targets\` output, so the install-time diff (schematic, install disk, EPHEMERAL, role) was not computed. Read the head's \`machines/machines.yaml\` / \`image.tf\` changes by hand."; } >>"$bodyf"
    impact_desc=" · install: UNREADABLE"; return 0
  fi
  if [ -z "$rows" ]; then
    { echo; echo "**Install impact: none** — no node's install-time declaration (schematic, installer, version, install disk, EPHEMERAL, role) changes at this head."; } >>"$bodyf"
    return 0
  fi
  if [ "$rows" = "$(printf '*\tunknown\t\t')" ]; then
    { echo; echo "**Install impact: UNKNOWN until apply** — the whole \`node_install_targets\` output is computed at apply time on this head; every node may move. Read the plan by hand."; } >>"$bodyf"
    impact_desc=" · install: UNKNOWN"; return 0
  fi
  while IFS=$'\t' read -r node kind fields unk; do [ "$kind" = changed ] && nodes+=("$node"); done <<<"$rows"
  # the live half: only the changed nodes, only their fully-known head values
  if [ ${#nodes[@]} -gt 0 ]; then
    local tj dj; tj="$(mktemp)"; dj="$(mktemp)"
    if mgmt_install_after "$out" "${nodes[@]}" >"$tj" 2>/dev/null && [ "$(jq 'length' "$tj" 2>/dev/null || echo 0)" -gt 0 ]; then
      SKIP="tofu talos ansible creds substrate" DRY_RUN=1 NODE_TARGETS_JSON="$tj" NODE_DRIFT_OUT="$dj" \
        bash "$REPO/mgmt/scripts/mgmt-probe.sh" >"$out.live.log" 2>&1 || true
      drift="$(cat "$dj" 2>/dev/null)"
    fi
    rm -f "$tj" "$dj"
  fi
  # live_axis <node> <axis> → ok | drift | unread
  live_axis() { local v; v="$(awk -F'\t' -v k="$1 $2" '$1==k{print $2; exit}' <<<"$drift")"; printf '%s' "${v:-unread}"; }
  while IFS=$'\t' read -r node kind fields unk; do
    [ -n "$node" ] || continue
    case "$kind" in
      new)  install=$((install+1)); lines+=("| \`$node\` | new node | — | install |"); headline+=("$node (new)") ;;
      gone) gone=$((gone+1));       lines+=("| \`$node\` | leaves the declaration | — | none (the plan's destroys, above) |") ;;
      changed)
        w=upgrade; live=""
        case ", $fields," in *", install disk,"*|*", EPHEMERAL,"*|*", role,"*) w=reinstall ;; esac
        if [ "$w" = upgrade ]; then
          # schematic/version are the axes check_nodes compares; an installer-only change (the
          # platform half) has no live reader here and always counts as a window
          local sv=() a lv allok=1 anyunread=0
          case ", $fields," in *", schematic,"*) sv+=(schematic) ;; esac
          case ", $fields," in *", version,"*) sv+=(version) ;; esac
          [ ${#sv[@]} -gt 0 ] || allok=0   # installer alone: no live reader for the platform half
          for a in "${sv[@]}"; do
            case ", $unk," in *", $a,"*) allok=0; anyunread=1; continue ;; esac
            lv="$(live_axis "$node" "$a")"
            [ "$lv" = ok ] || allok=0; [ "$lv" = unread ] && anyunread=1
          done
          if [ ${#sv[@]} = 0 ]; then live="not compared (installer/platform)"
          elif [ $allok = 1 ]; then w="none — live already runs it"; live="matches the head"
          elif [ $anyunread = 1 ]; then live="not read"
          else live="differs"; fi
        else
          live="not compared (install-time layout)"
        fi
        [ -n "$unk" ] && fields="$fields (known after apply: $unk)"
        case "$w" in
          reinstall) reinstall=$((reinstall+1)); headline+=("$node ($fields)") ;;
          upgrade)   upgrade=$((upgrade+1));     headline+=("$node ($fields)") ;;
          *)         codified=$((codified+1)) ;;
        esac
        lines+=("| \`$node\` | $fields | $live | $w |") ;;
    esac
  done <<<"$rows"
  win=$((reinstall+upgrade+install))
  local parts=() num
  [ $reinstall -gt 0 ] && parts+=("$reinstall reinstall"); [ $upgrade -gt 0 ] && parts+=("$upgrade upgrade"); [ $install -gt 0 ] && parts+=("$install install")
  num="$(printf '%s + ' "${parts[@]}" | sed 's/ + $//')"; [ "$num" = "1 reinstall" ] && num="one reinstall"; [ "$num" = "1 upgrade" ] && num="one upgrade"; [ "$num" = "1 install" ] && num="one install"
  {
    echo
    if [ $win -gt 0 ]; then
      w=windows; [ $win = 1 ] && w=window
      echo "**Install impact — this head changes the install of $(printf '%s, ' "${headline[@]}" | sed 's/, $//') → $num $w.**"
    else
      echo "**Install impact: no window** — the install declaration moves, but live already matches it (or the nodes only leave the declaration)."
    fi
    echo
    echo "\`tofu plan\` cannot see this class (Talos applies install-time fields only on the next install — ADR-132). Before = the applied declaration, after = this head; the live column is the head vs the running node (\`mgmt-probe.sh\` check_nodes). Node and field names only — values stay on the box."
    echo; echo "| node | install-time change | live | window |"; echo "|---|---|---|---|"
    printf '%s\n' "${lines[@]}"
  } >>"$bodyf"
  if [ $win -gt 0 ]; then
    if [ ${#headline[@]} = 1 ]; then impact_desc=" · install: ${headline[0]%% (*} $( [ $reinstall = 1 ] && echo reinstall || { [ $upgrade = 1 ] && echo upgrade || echo install; })"
    else impact_desc=" · install: $win windows"; fi
  fi
}

while IFS=$'\t' read -r pr sha; do
  [ -n "$pr" ] || continue
  if [ $HUMAN = 0 ] && verdicted "$sha"; then continue; fi
  log "[#$pr@${sha:0:8}] evaluating"
  mgmt_git -C "$REPO" fetch --quiet origin "+refs/pull/$pr/head:refs/mgmt/pr-$pr" || { log "[#$pr] fetch of the head failed — skipped this run"; continue; }
  base="$(git -C "$REPO" merge-base origin/master "$sha" 2>/dev/null)" || { log "[#$pr] no merge-base with master — skipped"; continue; }
  files_out="$(git -C "$REPO" diff --name-only "$base" "$sha" --)" || { log "[#$pr] diff of the head failed — skipped this run"; continue; }   # an empty list reads as "no surface": never from a failed read
  files=(); [ -n "$files_out" ] && mapfile -t files <<<"$files_out"
  # the classifier's rc decides between "no box-held surface" (a success) and "could not classify"
  # (no verdict, retried next tick) — `$(…) ||`, never mapfile over a process substitution (#1631)
  roots_out="$(printf '%s\n' "${files[@]}" | mgmt_roots_touched "$POL")" || { log "[#$pr] classifier failed (policy unreadable) — skipped this run"; continue; }
  roots=(); [ -n "$roots_out" ] && mapfile -t roots <<<"$roots_out"
  if [ ${#roots[@]} -eq 0 ]; then
    if [ $HUMAN = 1 ]; then log "[#$pr] touches no box-held surface — nothing to override; the in-cluster half posts this head's success"; continue; fi
    post_verdict "$sha" success "no box-held surface touched"
    continue
  fi
  # stage 1
  hits="$(mgmt_stage1 "$POL" "$REPO" "$base" "$sha")" || { log "[#$pr] stage 1 could not run (policy unreadable) — skipped this run"; continue; }
  # PROVIDER-PIN head (ADR-131 amended 2026-09-27): stage 1 admitted a denied file because its diff
  # is the bump shape (mgmt_provider_pin_shape). Such a head must plan EMPTY — a provider bump that
  # changes the plan is the evidence a human reads, so on a pin head a non-empty plan is a FAILURE.
  # A human plan keeps its own semantics (the human reads whatever the plan says).
  admitted="$(grep $'^admitted\t' <<<"$hits" || true)"; hits="$(grep -v $'^admitted\t' <<<"$hits" || true)"
  PIN=0; [ -n "$admitted" ] && [ $HUMAN = 0 ] && PIN=1
  [ $PIN = 1 ] && log "[#$pr] provider-pin head — stage 1 admitted: $(awk -F'\t' '{printf "%s ", $2}' <<<"$admitted")"
  overridden=""
  if [ -n "$hits" ] && [ $HUMAN = 1 ]; then
    overridden="$hits"
    log "[#$pr] stage 1 would REFUSE — overridden by the human plan:"; awk -F'\t' '{printf "    %s  %s  (%s)\n", $1, $2, $3}' <<<"$hits"
    hits=""
  fi
  if [ -n "$hits" ]; then
    first="$(head -1 <<<"$hits")"; rule="${first%%$'\t'*}"; rest="${first#*$'\t'}"; file="${rest%%$'\t'*}"
    bodyf="$(mktemp)"
    {
      echo "**management-sentinel: stage 1 refused** (input allowlist, \`policy/mgmt/plan-input.yaml\` on master) — nothing was planned."
      echo; echo "| rule | file | detail |"; echo "|---|---|---|"
      awk -F'\t' -v bt='`' '{printf "| %s | %s%s%s | %s%s%s |\n", $1, bt, $2, bt, bt, $3, bt}' <<<"$hits"
      echo; echo "A PR that legitimately needs this lands the allowlist widening first (its own change), or a human who has read the diff orders the plan from the jail: \`devbox run mgmt-human-plan -- $pr\` (docs/management-box.md §MB3 \"When the box refuses\")."
    } >"$bodyf"
    mgmt_upsert_comment "$pr" "$MARKER" "$bodyf"; rm -f "$bodyf"
    post_verdict "$sha" failure "stage 1: $rule on ${file##*/} — human plan"
    continue
  fi
  # stage 2
  # PLAN WHAT WOULD LAND, not the stale head (2026-09-28, homelab#2047/#2037): the worktree is
  # master with the head MERGED onto it — the same tree GitHub's merge ref holds. Planning the bare
  # head made every master change since the fork read as the PR's own (#2047, kubernetes 3, showed
  # "+0 ~1" = the FU-289 unpark of ci_runner_02 that #2048 had already applied; #2037 the same);
  # the box then refused to auto-apply and three provider bumps sat on a human for nothing. Stage 1
  # keeps judging the PR's OWN diff (base..head) — this only changes what stage 2 executes.
  # A head that does not merge cleanly gets a failure verdict and no plan (GitHub blocks it too).
  wt="$SDIR/wt-${sha:0:8}"; rm -rf "$wt"; git -C "$REPO" worktree prune
  m8="$(git -C "$REPO" rev-parse --short=8 origin/master 2>/dev/null || echo master)"
  git -C "$REPO" worktree add --quiet --detach "$wt" origin/master || { log "[#$pr] worktree add failed"; continue; }
  if ! git -c user.name=management-sentinel -c user.email=management-sentinel@homelab.invalid -C "$wt" merge --quiet --no-edit --no-ff "$sha" >/dev/null 2>&1; then
    git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    log "[#$pr] head ${sha:0:8} does not merge cleanly onto master@${m8} — no plan"
    if [ $HUMAN = 1 ]; then continue; fi
    post_verdict "$sha" failure "head does not merge onto master@${m8} — rebase/update the branch; nothing planned"
    continue
  fi
  # STATE COMPATIBILITY of a provider-pin head (S9 #1988, 2026-10-04): master's lockfiles (this
  # worktree) vs the head's, each root's provider schemas compared per root below
  wtb=""
  if [ $PIN = 1 ]; then
    wtb="$SDIR/wtb-${sha:0:8}"; rm -rf "$wtb"
    git -C "$REPO" worktree add --quiet --detach "$wtb" origin/master || wtb=""
  fi
  bodyf="$(mktemp)"; desc=""; state=success; failed_roots=""; pin_changed=""; pin_state=""
  if [ $HUMAN = 1 ]; then
    { echo "**management-sentinel: HUMAN PLAN** — \`tofu plan\` of ${sha:0:8} merged onto master@${m8} (what would land) on the management box, ordered from the jail by a human who read the diff (ADR-131's escape hatch, §MB3 \"When the box refuses\"). Addresses and counts only; the plan text stays on the box."
      if [ -n "$overridden" ]; then
        echo; echo "Stage 1 would have refused this head — **overridden** by the human order:"
        echo; echo "| rule | file | detail |"; echo "|---|---|---|"
        awk -F'\t' -v bt='`' '{printf "| %s | %s%s%s | %s%s%s |\n", $1, bt, $2, bt, bt, $3, bt}' <<<"$overridden"
      fi
    } >"$bodyf"
    desc="human plan: "
  else
    echo "**management-sentinel** — \`tofu plan\` of ${sha:0:8} merged onto master@${m8} (what would land) on the management box (ADR-131). Addresses and counts only; the plan text stays on the box." >"$bodyf"
    if [ $PIN = 1 ]; then
      { echo; echo "**Provider-pin head** — stage 1 admitted the \`provider-pin\` shape (only version / constraint / hash lines change, every provider source unchanged; ADR-131 amended 2026-09-27) in: $(awk -F'\t' -v bt='`' '{printf "%s%s%s ", bt, $2, bt}' <<<"$admitted"). The plan ran with the head's providers, verified against its lockfile hashes and the registry's signatures. **A bump must plan empty** — relative to master's own pending plan, or be a default backfill (attributes the new provider introduced with a static default, null → default and nothing else; ADR-131 amended 2026-10-04) — anything else below fails this context and is the evidence a human reads."; } >>"$bodyf"
    fi
  fi
  for root in "${roots[@]}"; do
    backfill_desc=""
    out="$wt/.mgmt-plan-$root.bin"
    mgmt_plan_root "$wt" "$POL" "$root" "$out" false; rc=$?
    if [ $HUMAN = 1 ]; then   # the human READS the plan — terminal only (stderr), never the comment
      { echo; echo "──── plan of root $root (${sha:0:8}) — rc $rc ────"; cat "$out.log" 2>/dev/null; echo "──── end of plan ────"; } >&2
    fi
    if [ $rc = 1 ]; then
      state=failure; failed_roots="$failed_roots $root"
      tail3="$(tail -3 "$out.log" 2>/dev/null)"
      # what leaves the box on an error: the tofu error HEADLINES only (`Error: …` lines, ≤3), never
      # the detail body — a provider's message can name live objects and values, and this comment
      # is public (the #1635 review: an error quoted verbatim is an existence oracle)
      heads="$(grep -E '^(│ )?Error: ' "$out.log" 2>/dev/null | sed -E 's/^│ //' | grep -v 'error running script' | head -3)"
      # …plus the POSITIONS (2026-09-28, homelab#2046/#2047): tofu's `  on <file> line N, in <block>:`
      # lines name a file, a line and a block header — never a value — and they are what a worker
      # or the migration lens needs to adapt the PR without a human reading the box journal (the
      # helm 3 major errored "Unsupported block type" with no location; the kubernetes 3 major
      # posted nothing at all because its headline carried an `=`). Same `=` guard as the headlines.
      locs="$(grep -E '^(│ )?[[:space:]]+on [^[:space:]]+ line [0-9]+' "$out.log" 2>/dev/null | sed -E 's/^│ //; s/^[[:space:]]+//' | grep -v '=' | head -3)"
      { echo; echo "### \`$root\` — plan ERRORED"
        if [ -n "$heads" ] && ! printf '%s' "$heads" | grep -q '='; then echo '```'; printf '%s\n' "$heads"; [ -n "$locs" ] && printf '%s\n' "$locs"; echo '```'; echo "(headlines + positions only — the full log stays in the box journal)"
        elif [ -n "$locs" ]; then echo '```'; printf '%s\n' "$locs"; echo '```'; echo "(positions only — the headline may carry values; the full log stays in the box journal)"
        else echo "see the box journal (output withheld: it may carry values)"; fi
      } >>"$bodyf"
      log "[#$pr] $root plan errored: $(tr '\n' ' ' <<<"$tail3" | head -c 200)"
      continue
    fi
    if ! changes="$(mgmt_plan_changes "$wt" "$POL" "$root" "$out")"; then
      state=failure; failed_roots="$failed_roots $root"
      { echo; echo "### \`$root\` — plan SUMMARY failed (the plan ran; its summary did not — see the box journal)"; } >>"$bodyf"
      log "[#$pr] $root plan summary failed"; continue
    fi
    # OUTPUT-ONLY plans are rc=2 with zero resource changes and are NOT inconsistent (#1774, the
    # `node_install_targets` output): a new `output` block changes state, not infrastructure. The
    # inconsistency is rc=2 with NEITHER — that is still the silent zero #1629 ruled on.
    outs="$(mgmt_plan_outputs "$out")"; o=0; [ -n "$outs" ] && o=$(grep -c . <<<"$outs")
    op=s; [ "$o" = 1 ] && op=""
    if [ $rc = 2 ] && [ -z "$changes" ] && [ -z "$outs" ]; then   # the plan says "changes", the summary says none — never trust the zero
      state=failure; failed_roots="$failed_roots $root"
      { echo; echo "### \`$root\` — INCONSISTENT: plan exit 2 (changes) but an empty summary — see the box journal"; } >>"$bodyf"
      log "[#$pr] $root inconsistent: plan rc=2, summary empty"; continue
    fi
    os=""; oh=""; [ "$o" -gt 0 ] && { os=" ⇢$o output$op"; oh=", $o output value$op to save"; }
    read -r a c d r <<<"$(printf '%s\n' "$changes" | mgmt_plan_counts)"; rs=""; [ "${r:-0}" -gt 0 ] && rs="×$r"
    if [ $PIN = 1 ] && [ -n "$changes" ]; then
      # RELATIVE TO MASTER'S OWN PENDING PLAN (S9 #1988, 2026-10-04): a pin head merged onto a master
      # that carries unapplied residue plans that residue too — and the one pin that MUST merge then,
      # the tofu-provider-revert chain's revert (master is refused on the errored apply), would park
      # on a human by construction. So plan master alone: a pin that adds NOTHING (identical
      # address/action set) passes; anything it adds, drops or alters is still the human read.
      mout="$wtb/.mgmt-plan-$root.bin"; same=0; mchanges=""   # reset per root: a failed master plan must not leave the previous root's set behind
      if [ -n "$wtb" ] && { mgmt_plan_root "$wtb" "$POL" "$root" "$mout" false; mrc=$?; [ $mrc != 1 ]; } \
         && mchanges="$(mgmt_plan_changes "$wtb" "$POL" "$root" "$mout")" \
         && [ "$(printf '%s\n' "$changes" | sort)" = "$(printf '%s\n' "$mchanges" | sort)" ]; then same=1; fi
      if [ $same = 1 ]; then
        { echo; echo "Provider-pin head: the plan is master's OWN pending plan (+$a ~$c -$d, identical address/action set planned on master@${m8} alone) — the pin adds nothing to it."; } >>"$bodyf"
        log "[#$pr] provider-pin head: $root plan (+$a ~$c -$d) = master's own pending plan — the pin adds nothing"
      else
        # DEFAULT BACKFILL (ADR-131 amended 2026-10-04, homelab#2191): what the pin ADDS to master's own
        # pending plan may be in-place updates writing only attributes the new provider introduced
        # with a static default (null → default, nothing else differs, nothing known-after-apply —
        # cloudflare 5.26.0's `include_shadow_metadata = false` on six dns records; its changelog never
        # mentioned the attribute, so no release-notes reader would have caught it: the plan is the
        # evidence). The old provider drops attributes it does not know when it reads state, and the
        # state-compatibility check below still guards the schema version, so the revert stays a
        # revert. Policy-admitted (`admit_plan_shapes`, read from master), judged by
        # mgmt_plan_default_backfill from the local `show -json`; attribute NAMES reach the comment,
        # never values. Anything else the pin adds, drops or alters is still the human read. When
        # master's own plan could not be read, EVERY change must be backfill-shaped — residue is not.
        extra="$changes"; [ -n "$mchanges" ] && extra="$(comm -23 <(printf '%s\n' "$changes" | sort) <(printf '%s\n' "$mchanges" | sort))"
        bf=""; : >"$out.backfill-why"
        if mgmt_policy_get "$POL" '.admit_plan_shapes[]?' 2>/dev/null | grep -qx default-backfill \
           && bf="$(printf '%s\n' "$extra" | mgmt_plan_default_backfill "$out" 2>"$out.backfill-why")"; then
          nbf=$(grep -c . <<<"$bf"); nx=$(grep -c . <<<"$extra"); nres=""; [ -n "$mchanges" ] && nres=" (master's own: $(grep -c . <<<"$mchanges"))"
          backfill_desc=" (default backfill)"
          { echo; echo "Provider-pin head: **default backfill** — the $nx change(s) the pin adds beyond master's own pending plan$nres are in-place updates writing only attributes the new provider introduced with a static default (null → default; nothing else differs; nothing known only after apply). The old provider ignores attributes it does not know when it reads state, so the lockfile revert stays a revert (state compatibility below). Attribute names only (\`admit_plan_shapes: default-backfill\`, ADR-131 amended 2026-10-04):"
            echo; echo "| address | backfilled attribute |"; echo "|---|---|"; awk -F'\t' '{printf "| `%s` | `%s` |\n", $1, $2}' <<<"$bf"; } >>"$bodyf"
          log "[#$pr] provider-pin head: $root plan (+$a ~$c -$d) = master's own + a default backfill ($nbf attribute(s) on $nx address(es)) — admitted"
        else
          state=failure; pin_changed="${pin_changed:-} $root(+$a ~$c -$d)"
          why=""; [ -s "$out.backfill-why" ] && why="; not a default backfill: $(head -3 "$out.backfill-why" | awk -F'\t' '{printf "%s\`%s\` (%s)", (NR>1?"; ":""), $1, $2}')"
          { echo; echo "### ⚠ \`$root\` — the provider bump CHANGES the plan (+$a ~$c -$d${rs:+, $r to replace}; master's own pending plan differs or could not be read$why) — human read"; } >>"$bodyf"
          log "[#$pr] provider-pin head: $root plan is NOT empty (+$a ~$c -$d), differs from master's own and is not a default backfill — failing the context"
        fi
        rm -f "$out.backfill-why"
      fi
    fi
    if [ $PIN = 1 ]; then
      # a bump may ride only if reverting the lockfile stays a revert after the box applies under it:
      # no type in this root's state may move to a schema (or identity) version master's provider
      # cannot read back (mgmt_schema_upgrades). Unreadable = failure — never a vacuous pass.
      rel="$(mgmt_root_dir "$POL" "$root")"
      # the types to judge: plan + state + plan exclusions (mgmt_judged_types; PR#2205's review)
      types_ok=0
      if xt="$(mgmt_policy_get "$POL" ".roots.\"$root\".plan_exclude_types[]?")" && mgmt_judged_types "$out" "$xt" >"$out.types-all"; then types_ok=1; fi
      if [ -n "$wtb" ] && [ $types_ok = 1 ] \
         && mgmt_provider_schema "$wtb/$rel" "$out.schema-base.json" \
         && mgmt_provider_schema "$wt/$rel" "$out.schema-head.json" \
         && ups="$(mgmt_schema_upgrades "$out.schema-base.json" "$out.schema-head.json" "$out.types-all")"; then
        if [ -n "$ups" ]; then
          state=failure; pin_state="${pin_state:-} $root($(awk -F'\t' '{printf "%s%s", (NR>1?",":""), $1}' <<<"$ups"))"
          { echo; echo "### ⚠ \`$root\` — the provider bump changes what STATE stores — human read"
            echo; echo "The next apply under the head's provider rewrites these types at the new version; master's provider cannot read them back, so reverting the lockfile would no longer be a revert (a state restore would). A bump that keeps every stored version stays lockfile-revertable even after applies."
            echo; echo "| type | master | head |"; echo "|---|---|---|"
            awk -F'\t' -v bt='`' '{printf "| %s%s%s | %s | %s |\n", bt, $1, bt, $2, $3}' <<<"$ups"; } >>"$bodyf"
          log "[#$pr] provider-pin head: $root state shape changes ($(tr '\n' ' ' <<<"$ups")) — failing the context"
        else
          { echo; echo "State compatibility: every managed resource type in \`$root\` (plan, state and plan exclusions: $(grep -c . "$out.types-all") types) keeps its schema and identity version under the head's providers — the lockfile revert stays a revert."; } >>"$bodyf"
        fi
      else
        state=failure; failed_roots="$failed_roots $root"
        { echo; echo "### \`$root\` — state-compatibility check FAILED to run (provider schemas or the plan's type list unreadable — see the box journal)"; } >>"$bodyf"
        log "[#$pr] $root: provider schema compare could not run — failing the context"
      fi
    fi
    excl_n=0; excl_types=""
    notplanned="$(mgmt_plan_not_planned "$out")"
    if [ -n "$notplanned" ]; then
      excl_n=$(wc -l <<<"$notplanned")
      # type = the address minus its name (a data source keeps its `data.` prefix)
      excl_types="$(sed -E 's/^((data\.)?[^.]+)\..*/\1/' <<<"$notplanned" | sort | uniq -c | awk '{printf "%s%s `%s`", (NR>1?", ":""), $1, $2}')"
    fi
    excl_note=""; [ "$excl_n" -gt 0 ] && excl_note=" ($excl_n not planned)"
    desc="$desc$root: +$a ~$c -$d ${rs}${os}${excl_note}${backfill_desc} "
    { echo; echo "### \`$root\` — +$a to add, ~$c to change, -$d to destroy${rs:+, $r to replace}${oh}"
      if [ "$excl_n" -gt 0 ]; then
        note="$(mgmt_root_exclude_note "$POL" "$root")" || note="(reason unreadable this run)"
        echo; echo "⚠ **Not planned on the box** (policy \`plan_exclude_types\`${note:+ — $note}): $excl_types."
      fi
      if [ -n "$changes" ]; then echo; echo "| address | actions |"; echo "|---|---|"; awk -F'\t' '{printf "| `%s` | %s |\n", $1, $2}' <<<"$changes"
      elif [ -n "$outs" ]; then echo; echo "No resource changes."
      else echo; echo "No changes."; fi
      # output NAMES and actions, never values (the #1635 rule: a value is an existence oracle)
      if [ -n "$outs" ]; then echo; echo "| output | actions |"; echo "|---|---|"; awk -F'\t' '{printf "| `%s` | %s |\n", $1, $2}' <<<"$outs"; fi
      echo
      ap="$(mgmt_root_apply "$POL" "$root")" || ap=unknown   # a failed read must not print "plan only" for an apply:true root
      if [ "$ap" = unknown ]; then echo "apply: UNKNOWN — the apply flag could not be read from the policy this run; the apply loop reads it again after merge."
      elif [ "$ap" != true ]; then echo "apply: plan only — this root is not on the box's apply list."
      elif [ -z "$changes" ] && [ -n "$outs" ]; then echo "apply: output values only — the box applies after merge (no infrastructure changes)."
      elif [ -z "$changes" ]; then echo "apply: nothing to apply."
      else
        outside="$(printf '%s\n' "$changes" | mgmt_apply_allowed "$POL" "$root")" || outside="(allowlist unreadable — the apply loop refuses until it reads)"
        if [ -z "$outside" ]; then echo "apply: all addresses inside the apply allowlist — the box applies after merge."
        else n=$(wc -l <<<"$outside"); echo "apply: $n address(es) OUTSIDE the apply allowlist — human apply: $(tr '\n' ' ' <<<"$outside" | sed 's/ $//' | sed 's/ /, /g')"; fi
      fi
    } >>"$bodyf"
    # the install-impact line: only a root whose plan carries node_install_targets (main)
    if [ "$root" = main ]; then install_impact "$out" "$sha"; [ -n "$impact_desc" ] && desc="${desc% }${impact_desc} "; fi
    log "[#$pr] $root: +$a ~$c -$d ${rs}${os}${impact_desc}"
  done
  if [ "$state" = failure ]; then
    if [ -n "${pin_changed:-}${pin_state:-}" ] && [ -z "$failed_roots" ]; then
      desc="provider bump${pin_changed:+ changes the plan:${pin_changed}}${pin_changed:+${pin_state:+;}}${pin_state:+ changes stored state:${pin_state}} — human read (see the PR comment)"
    else desc="plan errored:$failed_roots — see the PR comment"; [ $HUMAN = 1 ] && desc="human plan: $desc"; fi
  fi
  pin_changed=""; pin_state=""
  [ -n "$wtb" ] && { git -C "$REPO" worktree remove --force "$wtb" 2>/dev/null || rm -rf "$wtb"; }
  if [ -n "$overridden" ] && [ "$state" = success ]; then
    desc="${desc% } — stage 1 overridden: $(awk -F'\t' 'NR==1{f=$2; sub(".*/","",f); printf "%s %s", $1, f}' <<<"$overridden")"
  fi
  if [ $HUMAN = 1 ]; then
    if ! human_confirm "$pr" "$sha" "$state" || ! head_still "$pr" "$sha"; then
      rm -f "$bodyf"; git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"; human_stamp=declined; continue
    fi
  fi
  mgmt_upsert_comment "$pr" "$MARKER" "$bodyf"; rm -f "$bodyf"
  post_verdict "$sha" "$state" "${desc% }"
  [ $HUMAN = 1 ] && human_stamp="$state"
  git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
done < <(jq -r '.[] | [.number, .head.sha] | @tsv' <<<"$prs")

if [ $HUMAN = 1 ]; then
  case "$human_stamp" in
    success) log "HUMAN PLAN posted: #$HPR management-sentinel=success" ;;
    failure) log "HUMAN PLAN posted: #$HPR management-sentinel=FAILURE (the plan itself errored — fix the head)"; exit 1 ;;
    declined) exit 3 ;;
    *) log "HUMAN PLAN: nothing posted for #$HPR (no box-held surface, or the head could not be evaluated — see above)"; exit 1 ;;
  esac
fi

date +%s >"$SDIR/last-run"
log "done"
