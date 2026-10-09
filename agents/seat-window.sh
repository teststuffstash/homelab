#!/usr/bin/env bash
# seat-window — the DECLARED change window (FU-230 leg b) and the CLAIMS made under it.
#
#   bash agents/seat-window.sh open  --reason "<what you are doing>" --alerts A,B,C [--node <n>] [--hours N | --minutes N] [--note "<s>"] [--admit-reconciler] [--admit-apply]
#   bash agents/seat-window.sh renew --id <id> [--minutes N]          # extend the lease (and the window's claims); exit 1 = lapsed/closed
#   bash agents/seat-window.sh claim --id <id> --alert <name> (--match 'k=v,k=~re,...' | --fp <fingerprint>)
#   bash agents/seat-window.sh close [--id <id>] [--node <n> [--by <who>]] [--all] [--tail-min N]
#   bash agents/seat-window.sh tail-silences --created-by <who> [--minutes N]   # a verb's own silences → now+N
#   bash agents/seat-window.sh has --node <n> --by <who>     # exit 0 iff such a live window exists
#   bash agents/seat-window.sh list [--history]
#
# A SECOND READER, and it treats the record as a mutex (a sign on the door — not a lock: `open` is
# a blind merge patch, and a person who declares nothing is invisible). The box's node reconciler
# (mgmt/scripts/mgmt-reconcile.sh) refuses to open a window while ANY live window is declared — on
# another node, seat-wide, or on its target. `--admit-reconciler` (needs `--node`) is the one
# exception: "I am watching this node, the reconciler may act on it inside my window" — the
# attended canary. Without it, a seat's hands-on work on a node is never interrupted by a sync.
# A THIRD reader, the box's apply loop (mgmt/scripts/mgmt-apply.sh, FU-300), defers every plan while
# ANY live window is declared; `--admit-apply` (no `--node`: an apply acts on a whole root) is its
# one exception — "the box may apply master inside my window". The two admits are independent.
#
# WHY THIS EXISTS, and why it is not (only) a silence. FU-230 leg (a) — `node-maintenance.sh`
# opening Alertmanager silences — removed most of the maintenance-storm noise by matching on `node`,
# `instance`, the node's pod names and (on a zone node) the Garage health set. It leaks one class
# structurally, and the leak is not fixable by adding arms:
#
#   2026-09-16 08:08:46Z — an `nx-01` wipe+reinstall window silenced all four matchers, and
#   `KubeDaemonSetRolloutStuck` fired anyway. That alert is labelled by namespace + daemonset: it
#   carries NEITHER `node` NOR `instance`, and the pod that went Pending (`cilium-przdf`) was
#   MINTED AFTER the silence, so the pod-name arm held only its predecessors. The same evening,
#   wk-03's shutdown leaked `CiliumUnreachableNodes` ×11, DaemonSet rollout/misschedule ×8,
#   `KubeNodeUnreachable`, `KubeletInstanceUnreachable` and `KubePodNotReady` ×4 — the seat
#   silenced them by hand for 8 h.
#
# So the window DECLARES the alert names the seat expects (`docs/spikes/responder-week-audit.md`
# §Design read, leg 2), and the responder reads that record. It scopes by ALERT NAME, never by
# namespace — a whole-namespace mute would have hidden the REAL findings of the rf=3 rollout
# (garage-2 flapping, the write-probe 400s), the operator's own boundary on this leg. It does not
# silence anything by itself: the alert still fires, still reaches Home Assistant and Grafana.
#
# OWNERSHIP BY SILENCE (operator ruling 2026-10-09; FU-230). Until then a declared name SKIPPED the
# triage outright, and three defects followed from it:
#   (1) the record outlived nothing: `maintenance-window.sh open` declared `--hours 2`, window 2 opened
#       18:59Z and its declaration lapsed ~20:59Z while the seat's window stayed open until 05:21Z —
#       the 04:57Z KubePodNotReady burst ran ~8 triage sessions undeclared;
#   (2) `close` DELETED the record at Ready: KubePodNotReady (`for: 15m`) on nx-01's DaemonSet pods
#       fired 13:45–13:47Z after the 13:44Z close → 4 sessions;
#   (3) inside a window a NEW `now` alert was owned by nobody — the declared NAME muted the responder
#       cluster-wide, and the seat, whose skill calls a new alert a stop signal, often decided "not
#       my lane" and carried on.
# So the record no longer skips anything. A named `now` alert gets a GRACE (the responder's
# window-grace step, ~10 min, holding no subscription slot), inside which the seat either CLAIMS it
# — `claim`, an Alertmanager silence on that alert's own labels, comment naming this window — or
# leaves it, and the responder triages it after the grace with the window named in its brief. Under
# ADR-148 every `now` alert carries pod/node/instance labels, so a silence CAN match it; the
# label-less class above is `dig` now. Silences are durable since FU-195 (the alertmanager-db PVC).
#
# LEASES, not terms. `until` is a lease: `renew` (the skill's watch calls it, and
# `maintenance-window.sh check`) pushes it to now+N and pushes the window's claims' `endsAt` with it,
# so a dead seat lets both lapse within one lease. `close` no longer deletes: it sets `until` = now
# (every MUTEX reader — the reconciler, the apply loop, `has` — releases at that second), stamps
# `closed_at`, and keeps a triage-only TAIL (`tail_until`, default 20 min ≈ the longest `for:` among
# the `now` alerts a window produces — KubePodNotReady's 15m) during which the responder still graces
# the named alerts and the claims stay up. Closed and lapsed records stay as HISTORY for
# SEAT_WINDOW_HISTORY_DAYS (4) so the deep dig can explain a day after the fact; every write prunes
# what is older. Readers: live (mutex) = `until > now`; live for triage = `(tail_until // until) > now`.
#
# An alert OUTSIDE the declared set still triages at once, and the brief is told a window is open —
# the other half of FU-230, since 7 of the 9 confidently-wrong writes in the 09-04→11 audit had a
# cause the seat made outside the cluster's view and the session filled the gap with a plausible
# story instead of "unknown".
set -euo pipefail

NS="${SEAT_WINDOW_NS:-agent-coordinator}"
CM="${SEAT_WINDOW_CM:-responder-window}"
HOURS="${SEAT_WINDOW_HOURS:-3}"
BY="${SEAT_WINDOW_BY:-${USER:-seat}}"
LEASE_MIN="${SEAT_WINDOW_LEASE_MIN:-30}"     # `renew`'s default extension
TAIL_MIN="${SEAT_WINDOW_TAIL_MIN:-20}"       # `close`'s triage-only tail
HISTORY_DAYS="${SEAT_WINDOW_HISTORY_DAYS:-4}"
AM="${SEAT_WINDOW_AM:-${NM_AM:-http://192.168.40.14:9093}}"   # Alertmanager (node-maintenance.sh's default)

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${HERE}/../tofu/kubeconfig" ]; then KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"; else KUBE=""; fi
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"
kubectl() { "$KUBECTL" $KUBE "$@"; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 64; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
plus_min() { date -u -d "+${1} minutes" +%Y-%m-%dT%H:%M:%SZ; }

# Every record, parsed, each carrying its ConfigMap key as `_key`. Empty array when unreadable.
records() {
  local cm; cm="$(kubectl -n "$NS" get cm "$CM" -o json 2>/dev/null)" || { printf '[]'; return 0; }
  jq -ce '[ (.data // {}) | to_entries[] | .key as $k | (.value | fromjson?) // empty | . + {_key: $k} ]' <<<"$cm" 2>/dev/null \
    || printf '[]'
}
# The MUTEX set: `until` still in the future. ISO-8601 with a Z suffix sorts lexicographically, so
# the comparison needs no date parsing in jq. A closed record has until = its close second → out.
live_windows() {
  records | jq -c --arg now "$(now_iso)" '[ .[] | select((.until // "") > $now) ]' 2>/dev/null || printf '[]'
}
put_record() { # <key> <json-body>
  kubectl -n "$NS" get cm "$CM" >/dev/null 2>&1 || kubectl -n "$NS" create cm "$CM" >/dev/null
  kubectl -n "$NS" patch cm "$CM" --type merge -p "$(jq -cn --arg k "$1" --arg v "$(printf '%s' "$2" | jq -c 'del(._key)')" '{data:{($k):$v}}')" >/dev/null
}
# History retention: drop records whose LAST relevant instant is older than HISTORY_DAYS. Best
# effort — a failed prune is a bigger ConfigMap, never a failed verb.
gc_history() {
  local cut k
  cut="$(date -u -d "-${HISTORY_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
  for k in $(records | jq -r --arg cut "$cut" '.[] | select(((.tail_until // .until) // "") < $cut) | ._key' 2>/dev/null); do
    kubectl -n "$NS" patch cm "$CM" --type json -p "$(jq -cn --arg p "/data/$k" '[{op:"remove", path:$p}]')" >/dev/null 2>&1 || true
  done
}

# ── Alertmanager (claims + verb silences) ─────────────────────────────────────────────────────────
# Non-expired silences created by <who>, as a JSON array. rc 1 = Alertmanager unreadable.
am_silences_by() {
  local out; out="$(curl -sf -m 10 "$AM/api/v2/silences" 2>/dev/null)" || return 1
  jq -ce --arg by "$1" '[ .[] | select(.createdBy == $by and .status.state != "expired") ]' <<<"$out" 2>/dev/null || return 1
}
# Re-post one silence with a new endsAt (Alertmanager updates in place, or expires + re-creates —
# either keeps the alert covered). endsAt ≤ now expires it instead.
am_retime() { # <silence-json> <endsAt-iso>
  local id; id="$(jq -r .id <<<"$1")"
  if [[ ! "$2" > "$(now_iso)" ]]; then
    curl -sf -m 10 -X DELETE "$AM/api/v2/silence/$id" >/dev/null 2>&1; return
  fi
  local body; body="$(jq -c --arg e "$2" '{id, matchers, startsAt, endsAt:$e, createdBy, comment}' <<<"$1")"
  curl -sf -m 10 -X POST -H 'Content-Type: application/json' -d "$body" "$AM/api/v2/silences" >/dev/null 2>&1
}
# Every non-expired silence of <who> → <endsAt>; prints "<n-done> <n-failed>". `only_later` skips
# a silence whose endsAt already reaches past the target (a renew never shortens).
retime_all() { # <who> <endsAt-iso> [only_later]
  local sil n=0 f=0 s
  sil="$(am_silences_by "$1")" || { printf '0 -1'; return 0; }
  while read -r s; do
    [ -n "$s" ] || continue
    if [ "${3:-}" = only_later ] && [[ ! "$2" > "$(jq -r .endsAt <<<"$s" | cut -c1-19)Z" ]]; then continue; fi
    if am_retime "$s" "$2"; then n=$((n+1)); else f=$((f+1)); fi
  done < <(jq -c '.[]' <<<"$sil")
  printf '%d %d' "$n" "$f"
}
claim_owner() { printf 'seat-window/%s' "$1"; }

cmd_open() {
  local reason="" alerts="" node="" note="" hours="$HOURS" minutes="" admit=false admit_apply=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --admit-reconciler) admit=true; shift ;;
      --admit-apply) admit_apply=true; shift ;;
      --reason) reason="${2:-}"; shift 2 ;;
      --alerts) alerts="${2:-}"; shift 2 ;;
      --node)   node="${2:-}";   shift 2 ;;
      --note)   note="${2:-}";   shift 2 ;;
      --hours)  hours="${2:-}";  shift 2 ;;
      --minutes) minutes="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$reason" ] || die "--reason is required: the window record exists to tell a triage session what a person is doing"
  [ -n "$alerts" ] || die "--alerts is required: a window with no declared alert names graces nothing (and a namespace-wide mute is deliberately not offered)"
  [ "$admit" = false ] || [ -n "$node" ] || die "--admit-reconciler needs --node: it admits the reconciler to ONE node, never the fleet"
  local id until_ body
  # The suffix: two opens in one second must not share a key — the merge patch would silently
  # overwrite the first record (a seat window and node-maintenance.sh's, 2026-09-22).
  id="${node:-seat}-$(date -u +%s)-$((RANDOM % 10000))"
  if [ -n "$minutes" ]; then until_="$(plus_min "$minutes")"; else until_="$(date -u -d "+${hours} hours" +%Y-%m-%dT%H:%M:%SZ)"; fi
  body="$(jq -cn --arg id "$id" --arg by "$BY" --arg opened "$(now_iso)" --arg until "$until_" \
                 --arg reason "$reason" --arg node "$node" --arg note "$note" --arg alerts "$alerts" \
                 --argjson admit "$admit" --argjson admit_apply "$admit_apply" \
    '{id:$id, by:$by, opened_at:$opened, until:$until, reason:$reason, node:$node, note:$note,
      admit_reconciler:$admit, admit_apply:$admit_apply,
      alerts:($alerts | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0)))}')"
  put_record "w-$id" "$body"
  gc_history
  printf '✓ window %s open until %s — %s\n' "$id" "$until_" "$reason"
  printf '  alerts: %s%s\n' "$(printf '%s' "$body" | jq -r '.alerts | join(", ")')" "${node:+  (node $node)}"
  [ "$admit" = true ] && printf '  the box reconciler MAY sync %s inside this window (--admit-reconciler)\n' "$node"
  if [ "$admit_apply" = true ]; then printf '  the box apply loop MAY apply master inside this window (--admit-apply)\n'
  else printf '  the box apply loop DEFERS every plan while this window is open (--admit-apply lets it through)\n'; fi
  printf '  the responder GRACES a named `now` alert (~10 min) before it triages it: claim it (`claim --id %s`) or leave it to the responder; everything else triages at once, with the window named in its brief.\n' "$id"
}

# The one record <id> names, or die.
one_record() { # <id>
  local r; r="$(records | jq -c --arg id "$1" '[ .[] | select(.id == $id) ] | first // empty' 2>/dev/null || true)"
  [ -n "$r" ] && [ "$r" != null ] || die "no declared window '$1' (bash agents/seat-window.sh list --history)"
  printf '%s' "$r"
}

cmd_renew() {
  local id="" minutes="$LEASE_MIN"
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id="${2:-}"; shift 2 ;;
      --minutes) minutes="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$id" ] || die "renew needs --id"
  local r now target cur
  r="$(one_record "$id")"; now="$(now_iso)"
  [ -z "$(jq -r '.closed_at // ""' <<<"$r")" ] || die "window $id was CLOSED at $(jq -r .closed_at <<<"$r") — a closed window is not renewed; open a new one"
  cur="$(jq -r '.until // ""' <<<"$r")"
  [[ "$cur" > "$now" ]] || die "window $id LAPSED at $cur — the lease ran out (dead watch?); the record is history now, open a new one"
  target="$(plus_min "$minutes")"
  [[ "$target" > "$cur" ]] || target="$cur"       # a renew never shortens a longer term
  put_record "$(jq -r ._key <<<"$r")" "$(jq -c --arg u "$target" --arg n "$now" '.until = $u | .renewed_at = $n' <<<"$r")"
  local res; res="$(retime_all "$(claim_owner "$id")" "$target" only_later)"
  printf '✓ window %s renewed until %s' "$id" "$target"
  case "${res#* }" in -1) printf ' — ⚠ Alertmanager unreadable, claims NOT extended\n' ;;
                      0) printf ' — %s claim(s) extended\n' "${res%% *}" ;;
                      *) printf ' — %s claim(s) extended, ⚠ %s failed\n' "${res%% *}" "${res#* }" ;; esac
}

# --match 'k=v,k=~re' → an Alertmanager matcher array. Commas separate matchers, so a value cannot
# carry one (a regex alternation uses `|`).
parse_match() { # <spec>
  printf '%s' "$1" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0)) | map(
      if test("^[A-Za-z_][A-Za-z0-9_]*=~") then capture("^(?<name>[^=]+)=~(?<value>.*)$") + {isRegex:true, isEqual:true}
      elif test("^[A-Za-z_][A-Za-z0-9_]*=") then capture("^(?<name>[^=]+)=(?<value>.*)$") + {isRegex:false, isEqual:true}
      else error("not k=v or k=~re: " + .) end)'
}

cmd_claim() {
  local id="" alert="" match="" fp=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id="${2:-}"; shift 2 ;;
      --alert) alert="${2:-}"; shift 2 ;;
      --match) match="${2:-}"; shift 2 ;;
      --fp) fp="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$id" ] || die "claim needs --id <window>: a claim lives under a window's lease"
  [ -n "$match" ] || [ -n "$fp" ] || die "claim needs --match 'label=value,...' or --fp <fingerprint>"
  [ -z "$match" ] || [ -z "$fp" ] || die "claim takes --match OR --fp, not both"
  local r now until_
  r="$(one_record "$id")"; now="$(now_iso)"; until_="$(jq -r '.until // ""' <<<"$r")"
  [ -z "$(jq -r '.closed_at // ""' <<<"$r")" ] && [[ "$until_" > "$now" ]] \
    || die "window $id is not live (closed or lapsed) — a claim needs a live lease"
  local ms
  if [ -n "$fp" ]; then
    # The alert's OWN label set, every label an equality matcher: exactly that alert instance.
    local am lab; am="$(curl -sf -m 10 "$AM/api/v2/alerts" 2>/dev/null)" || die "Alertmanager unreadable at $AM — cannot derive matchers from fingerprint $fp"
    lab="$(jq -c --arg fp "$fp" '[ .[] | select(.fingerprint == $fp) ] | first | .labels // empty' <<<"$am" 2>/dev/null || true)"
    [ -n "$lab" ] || die "no alert with fingerprint $fp in Alertmanager (resolved already?)"
    [ -n "$alert" ] || alert="$(jq -r '.alertname // ""' <<<"$lab")"
    [ "$(jq -r '.alertname // ""' <<<"$lab")" = "$alert" ] || die "fingerprint $fp is $(jq -r .alertname <<<"$lab"), not $alert"
    ms="$(jq -c 'to_entries | map({name:.key, value:.value, isRegex:false, isEqual:true})' <<<"$lab")"
  else
    [ -n "$alert" ] || die "--match needs --alert <alertname>: a claim is per alert NAME + labels, never labels alone"
    ms="$(parse_match "$match")" || die "could not parse --match '$match' (k=v or k=~re, comma-separated)"
    # Never a name-wide mute: that is precisely what the declared name used to be (defect 3).
    [ "$(jq '[ .[] | select(.name != "alertname") ] | length' <<<"$ms")" -gt 0 ] \
      || die "a claim needs at least one label matcher besides alertname — a name-wide silence is the cluster-wide mute this replaced"
    jq -e 'any(.[]; .isRegex and (.value | IN(".*", ".+", "")))' <<<"$ms" >/dev/null \
      && die "a match-everything regex is not a claim"
    # A pod-name regex (reinstalls mint new names: pod=~<daemonset>-.*) is namespace-scoped.
    if jq -e 'any(.[]; .name == "pod" and .isRegex)' <<<"$ms" >/dev/null \
       && ! jq -e 'any(.[]; .name == "namespace" and (.isRegex | not))' <<<"$ms" >/dev/null; then
      die "a pod=~ claim needs namespace=<ns> too (pod-name regexes are namespace-scoped)"
    fi
    ms="$(jq -c --arg a "$alert" '[ .[] | select(.name != "alertname") ] + [{name:"alertname", value:$a, isRegex:false, isEqual:true}]' <<<"$ms")"
  fi
  local body sid
  body="$(jq -cn --argjson m "$ms" --arg s "$now" --arg e "$until_" --arg by "$(claim_owner "$id")" \
        --arg c "claimed under declared window $id ($(jq -r .reason <<<"$r")) by $BY — a lease: \`renew\` extends it, \`close\` tails it (agents/seat-window.sh)" \
        '{matchers:$m, startsAt:$s, endsAt:$e, createdBy:$by, comment:$c}')"
  sid="$(curl -sf -m 10 -X POST -H 'Content-Type: application/json' -d "$body" "$AM/api/v2/silences" 2>/dev/null | jq -r '.silenceID // empty' 2>/dev/null || true)"
  [ -n "$sid" ] || die "Alertmanager refused the claim silence (unreachable at $AM?) — the alert is NOT claimed; the responder triages it after the grace"
  printf '✓ claimed %s under window %s — silence %s until %s\n' "$alert" "$id" "$sid" "$until_"
  printf '  matchers: %s\n' "$(jq -r 'map("\(.name)\(if .isRegex then "=~" else "=" end)\(.value)") | join(" ")' <<<"$ms")"
}

cmd_close() {
  local id="" node="" by="" all=0 tail="$TAIL_MIN"
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id="${2:-}"; shift 2 ;;
      --node) node="${2:-}"; shift 2 ;;
      --by) by="${2:-}"; shift 2 ;;
      --all) all=1; shift ;;
      --tail-min) tail="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  # --by narrows a --node close to ONE writer's records: a tool closes what it opened, never a
  # seat's window on the same node (node-maintenance.sh, 2026-09-22: it removed the seat's
  # admitting window at the end of every sync). Already-closed records are history, not targets.
  local sel
  sel="$(records | jq -c --arg id "$id" --arg node "$node" --arg by "$by" --argjson all "$all" '
        [ .[] | select((.closed_at // "") == "")
          | select($all == 1 or ($id != "" and .id == $id)
                   or ($node != "" and .node == $node and ($by == "" or .by == $by))) ]' 2>/dev/null || printf '[]')"
  [ "$(jq 'length' <<<"$sel")" -gt 0 ] || { printf 'no matching window to close\n'; return 0; }
  local r n=0 now tail_until wid res
  now="$(now_iso)"; tail_until="$(plus_min "$tail")"
  while read -r r; do
    [ -n "$r" ] || continue
    wid="$(jq -r .id <<<"$r")"
    # CLOSED, not removed: `until` = now releases every mutex reader this second; the TAIL keeps
    # the responder's grace (and the claims) alive for the `for:` of what this window caused; the
    # record stays as history for the deep dig.
    if put_record "$(jq -r ._key <<<"$r")" "$(jq -c --arg n "$now" --arg t "$tail_until" \
          '.closed_at = $n | .tail_until = $t | (if (.until // "") > $n then .until = $n else . end)' <<<"$r")"; then
      n=$((n+1))
    else
      printf '⚠ could not close %s (it self-expires at its `until`)\n' "$wid"
    fi
    res="$(retime_all "$(claim_owner "$wid")" "$tail_until")"
    case "${res#* }" in -1) printf '⚠ Alertmanager unreadable — %s'"'"'s claims keep their own endsAt\n' "$wid" ;;
                        0) [ "${res%% *}" = 0 ] || printf '  %s claim(s) of %s tail until %s\n' "${res%% *}" "$wid" "$tail_until" ;;
                        *) printf '⚠ %s claim(s) of %s could not be retimed\n' "${res#* }" "$wid" ;; esac
  done < <(jq -c '.[]' <<<"$sel")
  gc_history
  printf '✓ closed %d window(s) — mutex released now; triage tail until %s\n' "$n" "$tail_until"
}

cmd_tail_silences() {
  local who="" minutes="$TAIL_MIN"
  while [ $# -gt 0 ]; do
    case "$1" in
      --created-by) who="${2:-}"; shift 2 ;;
      --minutes) minutes="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$who" ] || die "tail-silences needs --created-by <who>"
  local res; res="$(retime_all "$who" "$(plus_min "$minutes")")"
  case "${res#* }" in -1) die "Alertmanager unreadable at $AM — $who's silences keep their own endsAt" ;; esac
  printf '✓ %s silence(s) of %s now end in %sm' "${res%% *}" "$who" "$minutes"
  [ "${res#* }" = 0 ] && printf '\n' || { printf ' — ⚠ %s failed\n' "${res#* }"; return 1; }
}

cmd_has() {
  local node="" by=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --node) node="${2:-}"; shift 2 ;;
      --by) by="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$node" ] && [ -n "$by" ] || die "has needs --node and --by"
  live_windows | jq -e --arg n "$node" --arg b "$by" 'any(.[]; .node == $n and .by == $b)' >/dev/null
}

# Default: the LIVE (mutex) set first — its first line stays `no live seat window` when empty, which
# scripts/helm-release-evidence.sh greps — then the closed windows still in their triage tail.
# --history: every retained record (closed, lapsed, live).
fmt_windows() { # <json-array> <now>
  printf '%s' "$1" | jq -r --arg now "$2" '.[] |
    (if (.closed_at // "") != "" then (if (.tail_until // "") > $now then "CLOSED \(.closed_at), triage tail until \(.tail_until)" else "CLOSED \(.closed_at)" end)
     elif (.until // "") > $now then "until \(.until)"
     else "LAPSED \(.until)" end) as $st |
    "\(.id)  \($st)  by \(.by)\n  reason: \(.reason)\n  alerts: \(.alerts | join(", "))\(if (.node // "") != "" then "\n  node:   " + .node else "" end)\(if (.note // "") != "" then "\n  note:   " + .note else "" end)\([if .admit_reconciler == true then "reconciler" else empty end, if .admit_apply == true then "apply" else empty end] | if length > 0 then "\n  admits: " + join(", ") else "" end)"'
}
cmd_list() {
  local now all live tail; now="$(now_iso)"; all="$(records)"
  if [ "${1:-}" = --history ]; then
    [ "$(jq 'length' <<<"$all")" -gt 0 ] || { printf 'no declared window on record\n'; return 0; }
    fmt_windows "$all" "$now"; return 0
  fi
  live="$(jq -c --arg now "$now" '[ .[] | select((.until // "") > $now) ]' <<<"$all")"
  tail="$(jq -c --arg now "$now" '[ .[] | select((.until // "") <= $now and (.tail_until // "") > $now) ]' <<<"$all")"
  if [ "$(jq 'length' <<<"$live")" -gt 0 ]; then fmt_windows "$live" "$now"; else printf 'no live seat window\n'; fi
  if [ "$(jq 'length' <<<"$tail")" -gt 0 ]; then
    printf -- '-- closed, still in their triage tail (the responder graces their names; no mutex):\n'
    fmt_windows "$tail" "$now"
  fi
}

case "${1:-}" in
  open)  shift; cmd_open "$@" ;;
  renew) shift; cmd_renew "$@" ;;
  claim) shift; cmd_claim "$@" ;;
  close) shift; cmd_close "$@" ;;
  tail-silences) shift; cmd_tail_silences "$@" ;;
  has)   shift; cmd_has "$@" ;;
  list)  shift; cmd_list "$@" ;;
  *) usage ;;
esac
