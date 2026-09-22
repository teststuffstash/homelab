#!/usr/bin/env bash
# maintenance-window — the mechanical half of the /maintenance-window skill.
#
#   bash scripts/maintenance-window.sh open  --reason "<what you are doing>" [--alerts A,B,C] [--hours N] [--node <n> [--admit-reconciler]]
#   bash scripts/maintenance-window.sh check [--id <window-id>]
#   bash scripts/maintenance-window.sh close [--id <window-id>] [--force]
#   bash scripts/maintenance-window.sh list              # the windows this tool has open (its state slots)
#   bash scripts/maintenance-window.sh cilium-check      # probe 3 alone, no baseline needed
#   bash scripts/maintenance-window.sh snapshot          # probes 1–4 as JSON on stdout; exit 1 if any read failed
#   bash scripts/maintenance-window.sh compare <file>    # probes 1–4 now vs a `snapshot` file; exit 2 on regression
#
# ONE STATE SLOT PER WINDOW: `open` keeps its baseline under $STATE_DIR/<window-id>/, keyed by the
# seat-window id it prints. `check`/`close` take `--id`; without it they use the ONE open slot and
# REFUSE (listing them) when there are several — never a guess. The first cut kept a single
# per-user slot, so on 2026-09-22 a seat and its subagent with windows open at once clobbered each
# other: the second `open` overwrote the first's baseline and window id, and the first `close`
# would have closed the subagent's window (GAPS maintenance-window-G1). A slot lives until its
# `close` succeeds, so a stale one from a dead session makes the no-`--id` form refuse: `list`,
# then `close --id <it> --force`.
#
# `snapshot` + `compare` are the UNATTENDED form — no window, no CI probe (the caller has no gh):
# the management box's apply loop brackets a Talos config apply with them (scripts/mgmt-apply.sh,
# docs/management-box.md §MB3 "Talos config applies"). Same probes, same verdicts, one home.
#
# WHY. `agents/seat-window.sh` declares a window to the responder and `node-maintenance.sh`
# opens the Alertmanager silences — both only ever wired for NODE maintenance. Everything else
# the seat does to live infrastructure (a tofu apply, a talosctl patch, a rollout restart, an
# upgrade) had neither, and no before/after comparison at all. On 2026-09-20 a control-plane
# config apply took the cluster's control plane down and the SEAT did not notice: the operator
# did, from Alertmanager, while the session reported success. Nodes stayed `Ready` throughout.
#
# So this does the one thing a human cannot do reliably by eye: it SNAPSHOTS the cluster's
# health signals before the change and DIFFS them afterwards. `check` is the gate — run it
# during and after, and treat any new firing alert as a stop signal, not a footnote.
#
# The checks are the paid lessons of that day, in order of what actually broke:
#   1. firing alert names  — new names since baseline
#   2. sum(up)             — scrape targets lost (48 -> 0 went unnoticed for ~30 min)
#   3. cilium k8s backend  — EVERY apiserver restart drops the 10.96.0.1:443 backend on every
#                            node and Cilium does NOT re-sync it; pods then get "connection
#                            refused" to the API while nodes still read Ready. Seen twice.
#                            Also callable alone (`cilium-check`) and shared with
#                            scripts/controlplane-upgrade.sh, which restarts an apiserver by
#                            construction — see docs/spikes/cilium-apiserver-restart-backend-loss.md.
#   4. non-Running pods    — controllers crashlooping on a broken API path
#   5. stranded CI         — ARC listeners restart during cluster work and do not re-claim jobs
#                            queued during the gap; they sit in `queued` forever (CiDispatchStalled)
set -euo pipefail

ROOT="${DEVBOX_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${MAINT_STATE_DIR:-$HOME/.claude/maintenance-window}"
# Per-window slot: $STATE_DIR/<key>/{baseline.json,window-id,meta.json}. <key> IS the seat-window
# id for every slot `open` writes; `window-id` inside is the id close hands to seat-window.sh (it
# can be empty only for a migrated pre-slot state whose open never recorded one). BASE/WID are set
# by use_slot() once the verb has resolved which window it is acting on.
BASE=""
WID=""
SLOT=""
PROM="${PROM_URL:-http://192.168.40.13:9090}"
export KUBECONFIG="${KUBECONFIG:-$ROOT/tofu/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-$ROOT/tofu/talosconfig}"
# ON THE MANAGEMENT BOX the client configs live in /var/lib/mgmt/, not in the checkout, and
# `devbox run` exports devbox.json's KUBECONFIG/TALOSCONFIG=$PWD/tofu/* regardless — a path that
# does not exist there. kubectl then fell back to localhost:8080 and every box-side run of the
# upgrade verbs failed (found 2026-09-21; the only box run before was the LAB=1 rehearsal, which
# passed explicit paths). So a configured path that does not exist yields to the box's copy.
# Same three lines in node-maintenance.sh, controlplane-upgrade.sh, maintenance-window.sh.
[ -f "$KUBECONFIG" ] || { [ -f /var/lib/mgmt/kubeconfig ] && export KUBECONFIG=/var/lib/mgmt/kubeconfig; }
[ -f "$TALOSCONFIG" ] || { [ -f /var/lib/mgmt/talosconfig ] && TALOSCONFIG=/var/lib/mgmt/talosconfig; }
export TALOSCONFIG

# FAIL LOUDLY on a missing kubeconfig. Caught building this script: run from a git worktree, ROOT
# had no tofu/kubeconfig (gitignored, so a fresh worktree lacks it), kubectl fell through to
# localhost:8080, and `open` recorded a cheerful baseline of nodes=0, cilium_backends=0/0 —
# a check that passes because it measured NOTHING. That is precisely the failure class this
# script exists to prevent, so it refuses instead of guessing.
[ -r "$KUBECONFIG" ] || {
  echo "maintenance-window: no readable kubeconfig at $KUBECONFIG" >&2
  echo "  set KUBECONFIG=/path/to/tofu/kubeconfig (a worktree does not have one — use the main checkout)" >&2
  exit 1
}
# The repos whose CI can be stranded by cluster work. Override for a wider sweep.
MAINT_REPOS="${MAINT_REPOS:-homelab oracle-fleet oracle-iac sleep-tracking snore-recorder sleep-iac}"

# The classes a maintenance window structurally produces. Same default as node-maintenance.sh's
# DECLARED_ALERTS plus the control-plane names the 2026-09-20 apply produced.
DEFAULT_ALERTS="KubeAPIDown,KubeletInstanceUnreachable,KubeNodeNotReady,KubeNodeUnreachable,KubePodNotReady,KubeSchedulerInstanceUnreachable,KubeControllerManagerInstanceUnreachable,KubeAggregatedAPIDown,KubeDeploymentReplicasMismatch,KubeDaemonSetRolloutStuck,KubeDaemonSetMisScheduled,CiliumUnreachableNodes,CiliumAgentScrapeDown,TargetDown"

# EVERY read distinguishes "queried and found nothing" from "the query failed" — and returns
# non-zero for the latter. Caught in review (#1804): the first cut piped `curl … 2>/dev/null` into
# jq, and on a failed curl jq iterates an empty stream, exits 0 and prints nothing. That empty
# result flowed through as "no new firing alerts" — `ok`. Same for a transient `kubectl get pods`
# failure. So a network hiccup to Prometheus mid-maintenance, exactly when this runs, silently
# downgraded a check to a false pass and `close` (which gates purely on check's exit) would let
# the window close on a signal nobody ever read. That is this script's own stated failure class —
# "a check that passes because it measured NOTHING" — so all three reads now fail loudly instead.

# Prometheus JSON, validated for shape. Non-zero if the read failed or the answer is not an
# `{"status":"success"}` envelope — an HTML error page or a truncated body must never parse as data.
prom_get() {
  local out
  out="$(curl -sS --max-time 20 "$@" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  jq -e '.status == "success"' >/dev/null 2>&1 <<<"$out" || return 1
  printf '%s' "$out"
}
firing() {
  local out; out="$(prom_get "$PROM/api/v1/alerts")" || return 1
  jq -e 'has("data") and (.data|has("alerts"))' >/dev/null 2>&1 <<<"$out" || return 1
  jq -r '[.data.alerts[]|select(.state=="firing")|.labels.alertname]|unique' <<<"$out"
}
targets_up() {
  local out; out="$(prom_get --data-urlencode 'query=sum(up)' "$PROM/api/v1/query")" || return 1
  # An empty result vector is a real answer (nothing is up) and stays 0; a failed read returned above.
  jq -r '.data.result[0].value[1] // "0"' <<<"$out"
}

# Only HARD-failed pods. Deliberately not "everything that is not Running": a cluster with an
# agent loop in it always has pods in ContainerCreating/Init/Pending, and a gate that cries wolf
# on normal churn is a gate people stop reading. The states below do not clear on their own.
POD_BAD_STATES='CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerError|InvalidImageName|^Error$|Init:Error|Init:CrashLoopBackOff'
pods_bad_list() {
  local out
  out="$(kubectl get pods -A --no-headers 2>/dev/null)" || return 1
  # A cluster with zero pods is not a thing; an empty body here means the read, not the cluster.
  [ -n "$out" ] || return 1
  awk -v re="$POD_BAD_STATES" '$4 ~ re {print $1"/"$2" ("$4")"}' <<<"$out"
}
node_count() {
  local out
  out="$(kubectl get nodes --no-headers 2>/dev/null)" || { echo 0; return 0; }
  # awk, not `grep -c`: grep EXITS 1 on a zero count, which under `set -e` aborted the whole
  # snapshot mid-way and left a truncated baseline behind (caught by the self-test).
  printf '%s\n' "$out" | awk 'NF{n++} END{print n+0}'
}

# How many cilium agents still hold a backend for the in-cluster apiserver Service.
# Prints "<have> <missing> <unknown>". The three-way split is deliberate: a `kubectl exec` into a
# cilium agent fails intermittently, and counting a flaky exec as "backend missing" produced a
# false ⚠ the first time this ran. An unreliable gate is a gate that gets ignored, so "could not
# tell" is reported as itself and never as a failure. Each agent gets two attempts.
# But "could not tell" about the WHOLE fleet is not a caveat, it is an unread check — cmd_check
# blocks on have=0 with unknown>0, and cmd_open refuses to bank such a baseline (#1804 round 5).
# Non-zero if the AGENT LIST itself could not be read — distinct from an individual exec failing,
# which is what `unknown` covers. Missed on the first pass (review, #1804): a failing
# `kubectl get pod -l k8s-app=cilium` made the loop iterate zero times, returned "0 0 0", and
# cmd_check printed `ok  cilium apiserver backend: have=0 missing=0 unknown=0` — a false pass on
# the one check this whole tool exists for, and likeliest during exactly the apiserver
# instability that makes the list call flaky in the first place.
cilium_backends() {
  local have=0 missing=0 unknown=0 p out ok pods
  pods="$(kubectl -n kube-system get pod -l k8s-app=cilium -o name 2>/dev/null)" || return 1
  # A cluster running Cilium always has agents; an empty list means the read, not the fleet.
  [ -n "$pods" ] || return 1
  for p in $pods; do
    ok=0; out=""
    for _ in 1 2; do
      if out="$(kubectl -n kube-system exec -i "$p" -c cilium-agent -- cilium-dbg service list 2>/dev/null)" \
         && [ -n "$out" ]; then ok=1; break; fi
      sleep 1
    done
    if [ "$ok" -ne 1 ]; then unknown=$((unknown+1)); continue; fi
    if awk '$2=="10.96.0.1:443/TCP"' <<<"$out" | grep -q '=>'; then have=$((have+1)); else missing=$((missing+1)); fi
  done
  echo "$have $missing $unknown"
}

# The VERDICT on one cilium_backends reading — ONE home, two callers: `check` below and the
# post-rejoin gate in scripts/controlplane-upgrade.sh, which reads the exit code to decide
# whether a `rollout restart ds/cilium` is warranted. Copying this three-way logic into the CP
# verb is precisely what the spike's mitigation §2 says not to do: "a flaky kubectl exec must
# never read as a missing backend" has to mean the same thing in both places, forever.
#
# The exit codes ARE the contract, and 2 vs 3 is the whole point:
#   0  every responsive agent holds the backend for 10.96.0.1:443
#   2  at least one agent is genuinely MISSING it — the known, remediable signature
#   3  the reading says nothing (agent list unreadable, or every exec failed twice) — NOT
#      remediable: rolling the DaemonSet on a reading nobody could take is acting blind, and
#      the likeliest cause of an unreadable fleet is apiserver trouble a restart will not fix.
cilium_verdict() { # <ok:true|false> <have> <missing> <unknown>
  local ok="$1" have="$2" missing="$3" unknown="$4"
  if [ "$ok" != true ]; then
    echo "  ⚠ cilium UNREADABLE — could not list the cilium agents; the backend check did NOT run"
    return 3
  fi
  if [ "$missing" -gt 0 ]; then
    echo "  ⚠ cilium: $missing agent(s) have NO backend for 10.96.0.1:443 (have=$have unknown=$unknown)"
    echo "       → pods get 'connection refused' to the API. Fix: kubectl -n kube-system rollout restart ds/cilium"
    return 2
  fi
  if [ "$have" -eq 0 ] && [ "$unknown" -gt 0 ]; then
    # unknown == the WHOLE fleet (missing is 0 here, so have+unknown is every agent): every exec
    # failed, so this check answered nothing about a single node and must not read as `ok`. The
    # footnote below is the right response only while SOME agent answered — then missing=0 is a
    # real reading of the responsive ones. Review, #1804 round 5.
    echo "  ⚠ cilium UNREADABLE — every agent's exec failed twice ($unknown agent(s)); the backend check did NOT run"
    echo "       → re-run the check. If it keeps failing, the apiserver path itself is likely the problem."
    return 3
  fi
  echo "  ok  cilium apiserver backend: have=$have missing=0 unknown=$unknown"
  [ "$unknown" -gt 0 ] && echo "       (unknown = exec did not answer twice; re-run rather than acting on it)"
  return 0
}

# Runs stuck in `queued` for longer than the grace period — the ARC-stranded class.
# Prints stranded runs as plain lines and any repo whose read FAILED as `UNREADABLE:<repo>`.
# The second half was missing (review, #1804): `gh … || true` plus `[ -n "$out" ] || continue`
# swallowed an auth failure, a rate limit or a network blip as "nothing stranded" — and a GitHub
# token problem during an incident is precisely when that lie costs something.
stranded_ci() {
  local grace="${1:-600}" now r out
  now="$(date -u +%s)"
  for r in $MAINT_REPOS; do
    if ! out="$(gh run list --repo "teststuffstash/$r" --limit 30 \
            --json status,createdAt,databaseId,name,headBranch \
            -q '.[]|select(.status=="queued")|"\(.createdAt) \(.databaseId) \(.name) [\(.headBranch)]"' 2>/dev/null)"; then
      echo "UNREADABLE:$r"; continue
    fi
    [ -n "$out" ] || continue
    while read -r line; do
      [ -n "$line" ] || continue
      local ts age
      ts="$(date -u -d "${line%% *}" +%s 2>/dev/null)" || continue
      age=$(( now - ts ))
      [ "$age" -gt "$grace" ] && echo "  $r $line (queued ${age}s)"
    done <<EOF
$out
EOF
  done
  # UNCONDITIONAL. Without it the function's exit status is whatever the last
  # `[ "$age" -gt "$grace" ] && echo` left behind — so a LAST repo whose newest queued run is
  # younger than the grace period (an ordinary, healthy state) returned 1, and `ci_all="$(…)"`
  # is a bare assignment, so `set -e` killed cmd_check before the CI line ever printed: no ⚠, no
  # message, just a dead process. `close` survived the same input only by accident (it calls
  # cmd_check under `||`, which suspends -e). Review, #1804 round 3.
  return 0
}

snapshot() {
  # A zero node count means kubectl answered nothing useful — the apiserver is unreachable, which
  # is the WORST case this tool exists for, not a reason to say less about it. So it is a FLAG like
  # every other read, never a script-level `exit`: the first cut exited here, and because cmd_open
  # calls snapshot by redirection while cmd_check calls it in a command substitution, the identical
  # cluster state produced a full five-probe breakdown under `close` and a single bare stderr line
  # under `check` — no header, no ⚠ lines, nothing about the alerts/pods/CI reads that all still
  # worked. Same call-site accident as round 3's `stranded_ci`. Review, #1804 round 4.
  local n nodes_ok=true; n="$(node_count)"
  [ "${n:-0}" -gt 0 ] || nodes_ok=false
  local cil cilium_ok=true; cil="$(cilium_backends)" || { cil="0 0 0"; cilium_ok=false; }
  # Each read carries an *_ok flag. A false flag is never "0" or "clean" — cmd_check reports it
  # as unreadable and fails, because "we did not look" must not be indistinguishable from "fine".
  local alerts alerts_ok=true up up_ok=true pods pods_ok=true pods_out
  alerts="$(firing)" || { alerts='[]'; alerts_ok=false; }
  up="$(targets_up)" || { up=0;        up_ok=false; }
  if pods_out="$(pods_bad_list)"; then
    pods="$(printf '%s\n' "$pods_out" | awk 'NF{n++} END{print n+0}')"
  else
    pods=0; pods_ok=false
  fi
  jq -n --argjson alerts "$alerts" --argjson alerts_ok "$alerts_ok" \
        --arg up "$up" --argjson up_ok "$up_ok" \
        --arg pods "$pods" --argjson pods_ok "$pods_ok" \
        --arg have "${cil%% *}" --arg missing "$(cut -d' ' -f2 <<<"$cil")" \
        --arg unknown "${cil##* }" --arg nodes "$n" --argjson cilium_ok "$cilium_ok" \
        --argjson nodes_ok "$nodes_ok" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{at:$at, alerts:$alerts, alerts_ok:$alerts_ok, up:($up|tonumber), up_ok:$up_ok,
          pods_bad:($pods|tonumber), pods_ok:$pods_ok, cilium_ok:$cilium_ok,
          cilium_have:($have|tonumber), cilium_missing:($missing|tonumber),
          cilium_unknown:($unknown|tonumber), nodes:($nodes|tonumber), nodes_ok:$nodes_ok}'
}

# Is a snapshot file a baseline worth banking? Non-zero + the unread flags on stderr if not.
baseline_readable() { # <snapshot-file>
  jq -e '.alerts_ok and .up_ok and .pods_ok and .cilium_ok and .nodes_ok
         and (.cilium_have > 0 or .cilium_unknown == 0)' >/dev/null "$1" && return 0
  jq -r '"  UNREADABLE at baseline: alerts_ok=\(.alerts_ok) up_ok=\(.up_ok) pods_ok=\(.pods_ok) cilium_ok=\(.cilium_ok) nodes_ok=\(.nodes_ok) cilium[have=\(.cilium_have) unknown=\(.cilium_unknown)]"' "$1" >&2
  return 1
}

cmd_open() {
  local reason="" alerts="$DEFAULT_ALERTS" hours=2 node="" admit=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --admit-reconciler) admit=1; shift ;;
      --reason) reason="$2"; shift 2 ;;
      --alerts) alerts="$2"; shift 2 ;;
      --hours)  hours="$2";  shift 2 ;;
      --node)   node="$2";   shift 2 ;;
      *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
  done
  [ -n "$reason" ] || { echo "open: --reason is required (it is what the responder reads)" >&2; exit 64; }
  mkdir -p "$STATE_DIR"
  # The baseline is taken BEFORE the window exists (the window id is minted by seat-window.sh),
  # so it lands in a pending slot and is renamed to the id once the window is open.
  local pend; pend="$(mktemp -d "$STATE_DIR/.pending.XXXXXX")"
  BASE="$pend/baseline.json"
  echo "== baseline =="
  snapshot > "$BASE"
  jq -r '"  at=\(.at) targets_up=\(.up) alerts=\(.alerts|length) hard_failed_pods=\(.pods_bad) cilium[have=\(.cilium_have) missing=\(.cilium_missing) unknown=\(.cilium_unknown)] nodes=\(.nodes)"' "$BASE"
  # A baseline built from failed reads is worse than no baseline: every later check compares
  # favourably against it. Refuse rather than bank one.
  # `cilium_have == 0 and cilium_unknown > 0` is the same thing as an unread signal: no agent
  # answered, so the baseline knows nothing about the backend the whole tool is built around.
  baseline_readable "$BASE" || {
    echo "open: refusing to bank a baseline with unread signals — fix the read and re-run" >&2
    rm -rf "$pend"; exit 1
  }
  local args=(open --reason "$reason" --alerts "$alerts" --hours "$hours"
              --note "opened by scripts/maintenance-window.sh; baseline in $STATE_DIR/<this id>/")
  [ -n "$node" ] && args+=(--node "$node")
  [ -n "$admit" ] && args+=(--admit-reconciler)
  local out id
  out="$(bash "$ROOT/agents/seat-window.sh" "${args[@]}")" || { rm -rf "$pend"; exit 1; }
  printf '%s\n' "$out"
  id="$(printf '%s' "$out" | sed -n 's/^✓ window \([^ ]*\) open.*/\1/p' | head -1)"
  # No id means no slot key and nothing close could target: say so loudly rather than bank an
  # anonymous slot that every later no-`--id` call would have to guess about.
  if [ -z "$id" ] || [ -e "$STATE_DIR/$id" ]; then
    echo "open: could not record the window id (got '${id}') — the window MAY be open; baseline kept at $BASE" >&2
    echo "  'bash agents/seat-window.sh list' to find it" >&2
    exit 1
  fi
  printf '%s' "$id" > "$pend/window-id"
  jq -n --arg id "$id" --arg reason "$reason" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg until "$(date -u -d "+${hours} hours" +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:$id, reason:$reason, opened_at:$at, until:$until}' > "$pend/meta.json"
  mv "$pend" "$STATE_DIR/$id"
  echo "  maintenance-window slot: $id — pass '--id $id' to check/close if any other session may have a window open"
}

# ---- slot resolution --------------------------------------------------------------------------
# A pre-slot state (baseline.json + window-id directly in $STATE_DIR, written by the single-slot
# version) becomes a slot of its own, so a window opened before the upgrade still closes cleanly.
migrate_legacy() {
  [ -f "$STATE_DIR/baseline.json" ] || return 0
  local id=""; [ -s "$STATE_DIR/window-id" ] && id="$(cat "$STATE_DIR/window-id")"
  local key="${id:-legacy}"
  [ -e "$STATE_DIR/$key" ] && return 0
  mkdir -p "$STATE_DIR/$key"
  mv "$STATE_DIR/baseline.json" "$STATE_DIR/$key/baseline.json"
  printf '%s' "$id" > "$STATE_DIR/$key/window-id"
  rm -f "$STATE_DIR/window-id"
}
slots() { # one key per line, oldest first
  [ -d "$STATE_DIR" ] || return 0
  local d
  for d in "$STATE_DIR"/*/; do
    [ -f "$d/baseline.json" ] || continue
    d="${d%/}"; printf '%s %s\n' "$(jq -r '.at // ""' "$d/baseline.json" 2>/dev/null)" "${d##*/}"
  done | sort | awk '{print $NF}'
}
slot_line() { # <key>
  local m="$STATE_DIR/$1/meta.json" now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -f "$m" ]; then
    jq -r --arg now "$now" '"  \(.id)  opened \(.opened_at)  until \(.until)\(if .until < $now then " (EXPIRED — stale?)" else "" end)\n      reason: \(.reason)"' "$m"
  else
    printf '  %s  (pre-slot state, baseline at %s)\n' "$1" "$(jq -r .at "$STATE_DIR/$1/baseline.json")"
  fi
}
use_slot() { # <verb> [<id>] — sets BASE/WID, or exits naming why it will not choose
  local verb="$1" id="${2:-}"
  migrate_legacy
  if [ -n "$id" ]; then
    # A key is a seat-window id: never a path. `--id ..` must not resolve outside the state dir.
    case "$id" in .*|*/*|*[!A-Za-z0-9._-]*) echo "$verb: '$id' is not a window id" >&2; exit 64 ;; esac
    [ -f "$STATE_DIR/$id/baseline.json" ] || {
      echo "$verb: no maintenance-window slot for '$id'" >&2
      local k; for k in $(slots); do slot_line "$k" >&2; done
      exit 1
    }
  else
    local all n; all="$(slots)"; n="$(printf '%s' "$all" | awk 'NF{c++} END{print c+0}')"
    if [ "$n" -eq 0 ]; then echo "$verb: no baseline — run 'open' first" >&2; exit 1; fi
    if [ "$n" -gt 1 ]; then
      echo "$verb: REFUSING — $n maintenance windows are open from this user; name one with --id:" >&2
      local k; for k in $all; do slot_line "$k" >&2; done
      echo "  (a subagent's window is one of these; a stale one closes with '$verb --id <id> --force')" >&2
      exit 1
    fi
    id="$all"
  fi
  SLOT="$id"
  BASE="$STATE_DIR/$id/baseline.json"
  WID="$STATE_DIR/$id/window-id"
}

cmd_list() {
  migrate_legacy
  local all; all="$(slots)"
  [ -n "$all" ] || { echo "no maintenance window open from this tool"; return 0; }
  local k; for k in $all; do slot_line "$k"; done
}

# The cluster half of `check`: probes 1–4 of <now> against <baseline>, one ok/⚠ line each.
# rc 2 on any regression or unread probe, else 0. Shared by `check` and `compare`.
compare_snapshots() { # <baseline-json> <now-json>
  local b="$1" now="$2" rc=0

  # The precondition, not a sixth check: did kubectl answer at all? Reported like the probes so a
  # dead apiserver still yields the full breakdown instead of killing the run (review, #1804 r4).
  if [ "$(jq -r .nodes_ok <<<"$now")" != true ]; then
    echo "  ⚠ nodes UNREADABLE — 'kubectl get nodes' returned 0 nodes; the apiserver is not answering"; rc=2
  else
    local n0 n1; n0="$(jq -r .nodes <<<"$b")"; n1="$(jq -r .nodes <<<"$now")"
    if [ "$n1" -lt "$n0" ]; then echo "  ⚠ nodes LEFT the API: $n0 -> $n1"; rc=2
    else echo "  ok  nodes: $n0 -> $n1"; fi
  fi

  # An unreadable probe fails the check. It is NOT "ok", and it is NOT "0" — the whole point is
  # that "we could not look" is a distinct, blocking answer (review, #1804).
  if [ "$(jq -r .alerts_ok <<<"$now")" != true ]; then
    echo "  ⚠ alerts UNREADABLE — Prometheus $PROM/api/v1/alerts did not answer; the new-alert check did NOT run"; rc=2
  else
    local new; new="$(jq -r --argjson b "$b" '[.alerts[]|select(. as $a | ($b.alerts|index($a))|not)]|join(", ")' <<<"$now")"
    if [ -n "$new" ]; then echo "  ⚠ NEW firing alerts: $new"; rc=2; else echo "  ok  no new firing alerts"; fi
  fi

  if [ "$(jq -r .up_ok <<<"$now")" != true ]; then
    echo "  ⚠ scrape targets UNREADABLE — Prometheus query failed; the target count was NOT compared"; rc=2
  else
    local u0 u1; u0="$(jq -r .up <<<"$b")"; u1="$(jq -r .up <<<"$now")"
    if [ "$(printf '%.0f' "$u1")" -lt "$(printf '%.0f' "$u0")" ]; then
      echo "  ⚠ scrape targets DOWN: $u0 -> $u1"; rc=2
    else echo "  ok  scrape targets: $u0 -> $u1"; fi
  fi

  # The cilium reading is judged by cilium_verdict (above), shared with the CP verb. Any of its
  # non-zero verdicts — genuinely missing (2) or unread (3) — is this gate's single rc=2.
  cilium_verdict "$(jq -r .cilium_ok <<<"$now")" "$(jq -r .cilium_have <<<"$now")" \
                 "$(jq -r .cilium_missing <<<"$now")" "$(jq -r .cilium_unknown <<<"$now")" || rc=2

  if [ "$(jq -r .pods_ok <<<"$now")" != true ]; then
    echo "  ⚠ pods UNREADABLE — 'kubectl get pods -A' failed; the pod check did NOT run"; rc=2
  else
    local p0 p1; p0="$(jq -r .pods_bad <<<"$b")"; p1="$(jq -r .pods_bad <<<"$now")"
    if [ "$p1" -gt "$p0" ]; then
      echo "  ⚠ hard-failed pods: $p0 -> $p1"
      pods_bad_list 2>/dev/null | sed 's/^/       /'
      rc=2
    else echo "  ok  hard-failed pods: $p0 -> $p1"; fi
  fi
  return $rc
}

cmd_check() {
  local b; b="$(cat "$BASE")"
  local now; now="$(snapshot)"
  local rc=0
  echo "== check vs baseline ($(jq -r .at <<<"$b"), window $SLOT) =="
  compare_snapshots "$b" "$now" || rc=$?

  local ci_all ci ci_unread; ci_all="$(stranded_ci 600)"
  ci_unread="$(printf '%s\n' "$ci_all" | sed -n 's/^UNREADABLE://p' | tr '\n' ' ' | sed 's/ *$//')"
  ci="$(printf '%s\n' "$ci_all" | grep -v '^UNREADABLE:' || true)"
  if [ -n "$ci_unread" ]; then
    echo "  ⚠ CI status UNREADABLE for: $ci_unread — gh did not answer; those repos were NOT checked"; rc=2
  fi
  if [ -n "$(printf '%s' "$ci" | tr -d '[:space:]')" ]; then
    echo "  ⚠ CI runs stranded in queued (ARC listeners do not re-claim across a restart):"
    echo "$ci"
    echo "       → gh run cancel <id> --repo teststuffstash/<r>; wait for completed/cancelled; gh run rerun <id>"
    rc=2
  elif [ -z "$ci_unread" ]; then echo "  ok  no CI runs stranded in queued"; fi

  return $rc
}

cmd_close() {
  echo "== final check =="
  local rc=0; cmd_check || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo
    echo "REFUSING to close: the cluster is not back to baseline. Fix the ⚠ lines above, re-run"
    echo "check, and close only when it is clean (or close --force if you are deliberately"
    echo "leaving a known-open item, and SAY SO)."
    [ "${FORCE:-0}" = 1 ] || return "$rc"
  fi
  # Close only the window this tool opened: `--all` also closed windows other sessions had
  # declared (a spike's close removed a concurrent seat window, 2026-09-21).
  if [ -s "$WID" ]; then
    bash "$ROOT/agents/seat-window.sh" close --id "$(cat "$WID")"
  else
    echo "close: no recorded window id — closing none; 'bash agents/seat-window.sh list' to find it" >&2
  fi
  rm -rf "${STATE_DIR:?}/${SLOT:?}"
}

# The cilium backend probe on its own, with no baseline and no window — for a caller that has
# just restarted an apiserver and needs the answer NOW (scripts/controlplane-upgrade.sh). It
# reports and exits; deciding what to do about a 2 is the caller's business.
cmd_cilium() {
  local cil ok=true have missing unknown
  cil="$(cilium_backends)" || { cil="0 0 0"; ok=false; }
  read -r have missing unknown <<<"$cil"
  echo "== cilium apiserver backend =="
  cilium_verdict "$ok" "$have" "$missing" "$unknown"
}

# The unattended pair (header). `snapshot` refuses — exit 1, flags on stderr, JSON still on
# stdout — exactly where `open` refuses to bank a baseline: a caller must never compare against a
# reading that measured nothing. `compare` is `check` minus the window and the CI probe.
cmd_snapshot() {
  local tmp; tmp="$(mktemp)"
  snapshot > "$tmp"
  cat "$tmp"
  baseline_readable "$tmp" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}
cmd_compare() {
  [ -s "${1:-}" ] || { echo "compare: no baseline file '${1:-}'" >&2; return 1; }
  local b; b="$(cat "$1")"
  echo "== compare vs baseline ($(jq -r .at <<<"$b")) =="
  compare_snapshots "$b" "$(snapshot)"
}

case "${1:-}" in
  open)  shift; cmd_open "$@" ;;
  check|close)
    verb="$1"; shift; id=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --id)    [ -n "${2:-}" ] || { echo "$verb: --id needs a window id" >&2; exit 64; }; id="$2"; shift 2 ;;
        --force) [ "$verb" = close ] || { echo "check: unknown arg --force" >&2; exit 64; }; FORCE=1; shift ;;
        *) echo "$verb: unknown arg: $1" >&2; exit 64 ;;
      esac
    done
    use_slot "$verb" "$id"
    if [ "$verb" = check ]; then cmd_check; else cmd_close; fi ;;
  list) shift; cmd_list ;;
  # `|| exit $?` so the exit CODE survives: the caller distinguishes 2 (roll the DaemonSet) from
  # 3 (do not) — under `set -e` a bare call would exit non-zero all the same, but silently
  # collapsing the two here is one refactor away from a verb that rolls cilium on a blind read.
  cilium-check) shift; cmd_cilium || exit $? ;;
  snapshot) shift; cmd_snapshot ;;
  compare)  shift; cmd_compare "$@" || exit $? ;;
  *) echo "usage: maintenance-window.sh open --reason <s> [--alerts A,B] [--hours N] [--node n [--admit-reconciler]] | check [--id <id>] | close [--id <id>] [--force] | list | cilium-check | snapshot | compare <file>" >&2; exit 64 ;;
esac
