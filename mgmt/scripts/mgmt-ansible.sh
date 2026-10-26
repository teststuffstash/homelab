#!/usr/bin/env bash
# mgmt-ansible — the management box's bracket around an UNATTENDED ansible apply (ADR-152's program,
# ROADMAP §Deploy paths step 2; docs/management-box.md §"Ansible applies — Matchbox first"). SOURCED by
# mgmt/scripts/mgmt-apply.sh after mgmt-lib.sh, never run on its own; mgmt-ansible-test.sh sources it
# and stubs the seams. The helm bracket (mgmt-helm.sh, FU-301) is the model: preflight refusals →
# window + ⚓ lease → apply → confirm → STOP on bad, never a revert or a retry.
#
# What admits a group: a `policy/mgmt/plan-input.yaml` `apply_ansible.<group>` row (read from MASTER,
# codeowner-gated) whose `paths` globs match a file any commit in the master span touched. One group:
#   1 toolchain   ansible-core as the clone's devbox.lock pins it, read as DATA (mgmt_lock_tool — FU-305:
#                 devbox never runs in a gate loop; a bad lock fails THIS step with its reason)
#   2 target      `--check --diff` of every play at master. changed=0 everywhere → live already IS master:
#                 nothing to apply (the hand path converged it, or the change is a no-op) — confirmed
#   3 drift       the same plays at the sha this group was last CONFIRMED at ($ADIR/ansible-confirmed-<g> —
#                 written by every check that read live == a declaration, in any mode: a clean target
#                 (= master), a clean drift read (= that sha), a confirmed apply; the previous master
#                 when none) must be changed=0 on live: if live already differs from
#                 what was declared before this span, a human looks first (`ansible-live-drift`, the
#                 `helm-live-drift` analogue — the box never applies on top of a state nobody declared).
#                 A check that errors or does not reach a host refuses too (`ansible-check-failed`,
#                 `ansible-unreachable`): "could not look" is never "clean"
#   shadow        (row `mode: shadow`) stops here: the would-be apply in the journal + the metrics, no
#                 lease, no window, no status — the span still stamps (MGMT_SHADOW's precedent, per row)
#   4 begin       a stale lease of this group = a STOP (the actor died); a declared window (the reconciler
#                 and the apply loop wait it out) + ⚓ upgrade-lease-ansible-<group> (subject ansible/<g>,
#                 from/to = the confirmed sha / master; ADR-150 — the box arms, verifies, deletes)
#   5 apply       every play, in order, each under MGMT_ANSIBLE_TIMEOUT
#   6 confirm     a second `--check` is changed=0 AND the row's `health` reads pass (HTTP answers, units
#                 `active` on the row's hosts, read over the play's own ssh) → lease deleted, window
#                 closed, $ADIR/ansible-confirmed-<g> = master, status success. Anything else → STOP:
#                 lease + window KEPT, $ADIR/ansible-stopped (→ mgmt_apply_ansible_stopped →
#                 MgmtAnsibleApplyStopped) refuses every later ansible apply until a human removes it.
# Never: a revert, a retry, a second apply. The lease loop reads an `ansible/` lease past its deadline as
# outcome `ansible_stopped` (mgmt-lease.sh) — no revert PR, the second arm of the same alert.
#
# Return codes of ans_bracket: 0 done (confirmed / nothing to do / shadow) · 2 STOPPED (the apply
# happened — the caller stamps) · 3 REFUSED (refuse() already called — the caller exits 0) · 1 PROBE-FAIL
# (nothing changed; no stamp, the next tick retries).

ANS_TIMEOUT="${MGMT_ANSIBLE_TIMEOUT:-900}"            # per play per phase
# the record dirs: $MGMT_ANSIBLE_DIR, else $ADIR/ansible — read at bracket time (mgmt-apply.sh sets ADIR after sourcing)
ANS_LEASE_NS="${MGMT_LEASE_NS:-agent-coordinator}"
ANS_LEASE_LABEL="${MGMT_LEASE_LABEL:-homelab.teststuff.net/upgrade-lease}"
ANS_STORE_NAME='python3\.[0-9]+-ansible-core'        # devbox `ansible` = nixpkgs ansible-core (mgmt_lock_tool)

# ── seams (mgmt-ansible-test.sh overrides these) ────────────────────────────────────────────────
_akc() { local kc="${KUBECONFIG:-}"; [ -f "$kc" ] || kc=/var/lib/mgmt/kubeconfig; printf '%s' "$kc"; }
_ak()   { ( cd "$REPO" && mgmt_x kubectl --kubeconfig "$(_akc)" --request-timeout=30s "$@" ); }
_awin() { KUBECONFIG="$(_akc)" SEAT_WINDOW_BY=mgmt-apply bash "$REPO/agents/seat-window.sh" "$@"; }
# _ans_playbook <tree> <play> [args…] — one play from <tree>, its own ansible.cfg (inventory, roles)
_ans_playbook() {
  ( cd "$1" && ANSIBLE_CONFIG="$1/ansible/ansible.cfg" ANSIBLE_NOCOLOR=1 ANSIBLE_FORCE_COLOR=0 \
      timeout "$ANS_TIMEOUT" ansible-playbook "$1/$2" "${@:3}" )
}
# _ans_units <hosts> <units…> → rc 0 when every unit is active on every host (the play's own ssh)
_ans_units() {
  local hosts="$1"; shift
  ( cd "$REPO" && ANSIBLE_CONFIG="$REPO/ansible/ansible.cfg" ANSIBLE_NOCOLOR=1 \
      timeout 120 ansible "$hosts" -m ansible.builtin.command -a "systemctl is-active $*" )
}
_ans_http() { curl -sf -m 10 -o /dev/null "$1"; }
_ans_date() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }
_ans_now() { date +%s; }

# ── pure reads (the test feeds them files) ──────────────────────────────────────────────────────
# ans_groups_touched <policy> (files on stdin) → the apply_ansible groups whose `paths` match, sorted.
# rc 1 = the policy could not be read (fail closed: never "touches nothing" — that path STAMPS).
ans_groups_touched() {
  local pol="$1" rows g pat f
  rows="$(_yq -o=json -I=0 '.apply_ansible // {} | to_entries[] | {"g": .key, "p": (.value.paths // [])}' "$pol")" \
    || { echo "policy: apply_ansible unreadable ($pol)" >&2; return 1; }
  local -a files=(); mapfile -t files
  [ -n "$rows" ] || return 0
  while IFS= read -r r; do
    g="$(jq -r .g <<<"$r")"
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      for f in "${files[@]}"; do
        [ -n "$f" ] || continue
        # shellcheck disable=SC2254  # the policy's glob, on purpose
        case "$f" in $pat) printf '%s\n' "$g"; continue 3 ;; esac
      done
    done < <(jq -r '.p[]' <<<"$r")
  done <<<"$rows"
}
ans_row() { _yq -o=json -I=0 ".apply_ansible.\"$2\" // \"\"" "$1"; }

# ans_recap <play> <rc> <output-file> → one line per host in the play's PLAY RECAP:
#   <play>\t<host>\t<changed>\t<unreachable>\t<failed>\t<rc>
# A play with no recap (it died before any host: syntax, inventory, interpreter) → one line, host `-`,
# failed 1 — "could not look" is never clean. Connect-error task failures read as unreachable (the
# OPNsense modules run `connection: local`, so a dead node is a task failure — mgmt-probe.sh's rule).
ANS_CONNECT_RE='Got timeout calling|Unable to connect|Connection refused|No route to host|timed out|Name or service not known'
ans_recap() {
  local play="$1" rc="$2" f="$3" clean recap line host counts ch un fl mine
  clean="$(sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r//g' "$f" 2>/dev/null)"
  recap="$(printf '%s\n' "$clean" | awk '/PLAY RECAP/{f=1; next} f && / : ok=/')"
  if [ -z "$recap" ]; then printf '%s\t-\t0\t0\t1\t%s\n' "$play" "$rc"; return 0; fi
  while IFS= read -r line; do
    host="$(awk '{print $1}' <<<"$line")"; counts="${line#*:}"
    ch="$(sed -n 's/.*changed=\([0-9]*\).*/\1/p' <<<"$counts")"
    un="$(sed -n 's/.*unreachable=\([0-9]*\).*/\1/p' <<<"$counts")"
    fl="$(sed -n 's/.*failed=\([0-9]*\).*/\1/p' <<<"$counts")"
    if [ "${fl:-0}" -gt 0 ] && [ "${un:-0}" = 0 ]; then
      mine="$(printf '%s\n' "$clean" | grep -E "^(failed|fatal): \[$host\]" || true)"
      if [ -n "$mine" ] && ! grep -vqE "$ANS_CONNECT_RE" <<<"$mine"; then un=1; fl=0; fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$play" "$host" "${ch:-0}" "${un:-0}" "${fl:-0}" "$rc"
  done <<<"$recap"
}
# ans_judge <recap-file> → ONE line: `clean` | `changed\t<play:host=N …>` | `unreachable\t<play:host …>`
# | `failed\t<play:host …>` (precedence failed > unreachable > changed; a play rc≠0 that is not an
# unreachable host is failed — a timeout kill leaves a partial recap at best)
ans_judge() {
  awk -F'\t' '
    $5 > 0 || ($6 != 0 && $4 == 0) { f = f (f ? " " : "") $1 ":" $2; next }
    $4 > 0 { u = u (u ? " " : "") $1 ":" $2; next }
    $3 > 0 { c = c (c ? " " : "") $1 ":" $2 "=" $3 }
    END { if (f) print "failed\t" f; else if (u) print "unreachable\t" u; else if (c) print "changed\t" c; else print "clean" }' "$1"
}

# ans_run <dir> <phase> <tree> <plays-json> [ansible args…] → runs every play, writes <dir>/<phase>.recap
# (+ one log per play) and prints ans_judge's line. Never fails on its own: the verdict is the line.
ans_run() {
  local d="$1" phase="$2" tree="$3" plays="$4" p log rc; shift 4
  : >"$d/$phase.recap"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    log="$d/$phase-$(basename "$p" .yml).log"
    _ans_playbook "$tree" "$p" "$@" >"$log" 2>&1; rc=$?
    ans_recap "$p" "$rc" "$log" >>"$d/$phase.recap"
  done < <(jq -r '.[]' <<<"$plays")
  ans_judge "$d/$phase.recap"
}

# ans_health <row-json> → rc 0 every read passed; else one finding per line on stdout
ans_health() {
  local row="$1" u hosts units bad=0
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    _ans_http "$u" || { echo "http: $u did not answer 2xx"; bad=1; }
  done < <(jq -r '.health.http[]?' <<<"$row")
  hosts="$(jq -r '.hosts // ""' <<<"$row")"; units="$(jq -r '(.health.units // []) | join(" ")' <<<"$row")"
  if [ -n "$units" ]; then
    if [ -z "$hosts" ]; then echo "units: the row names units but no hosts"; bad=1
    elif ! _ans_units "$hosts" $units >/dev/null 2>&1; then echo "units: not all active on $hosts: $units"; bad=1; fi
  fi
  return $bad
}

# ans_tools → ansible-playbook on PATH: the box resolves the clone's devbox.lock pin as data; the jail's
# devbox shell already has it. rc 1 + why on stderr.
ans_tools() {
  if [ -n "${MGMT_BOX:-}" ]; then
    local p; p="$(mgmt_lock_tool "$REPO" ansible ansible-playbook "$ANS_STORE_NAME")" || return 1
    PATH="$p/bin:$PATH"; export PATH
  fi
  command -v ansible-playbook >/dev/null 2>&1 || { echo "ansible-playbook not on PATH" >&2; return 1; }
}

# ans_lease_check <group> → rc 0 none; 1 a LIVE one (in flight); 2 PAST DUE → STOP marker written; 3 unreadable
ans_lease_check() {
  local g="$1" j e m now_
  j="$(_ak -n "$ANS_LEASE_NS" get cm "upgrade-lease-ansible-$g" -o json 2>&1)" || { grep -q NotFound <<<"$j" && return 0; return 3; }
  e="$(jq -r '.data["expected-end"] // ""' <<<"$j")"; m="$(jq -r '.data["max-end"] // ""' <<<"$j")"
  [ -n "$m" ] && [ "$e" \> "$m" ] && e="$m"
  now_="$(_ans_date now)"
  [ -n "$e" ] && [ "$e" \> "$now_" ] && return 1
  printf '%s\t%s\t%s\t%s\n' "$(jq -r '.data.sha // "?"' <<<"$j")" "ansible/$g" "-" \
    "stale lease upgrade-lease-ansible-$g by $(jq -r '.data.by // "?"' <<<"$j"), expected-end $e passed with no confirm — its actor died or stopped; read the record, then clear (marker + lease)" >"$ADIR/ansible-stopped"
  log "ansible: STOP — lease upgrade-lease-ansible-$g is past due ($e) with no actor confirming it; $ADIR/ansible-stopped written"
  return 2
}

# ans_mark <group> <mode> <outcome> <changed-count> — the per-group record emit_metrics publishes
ans_mark() { printf '%s\t%s\t%s\t%s\n' "$(_ans_now)" "$2" "$3" "${4:-0}" >"$ADIR/ansible-last-$1"; }
_ans_count() { [ "${1%%$'\t'*}" = changed ] || { echo 0; return; }; tr ' ' '\n' <<<"${1#*$'\t'}" | sed -n 's/.*=\([0-9]*\)$/\1/p' | awk '{s+=$1} END {print s+0}'; }

# ── the bracket ─────────────────────────────────────────────────────────────────────────────────
# ans_bracket <policy> <group> <sha> <last> → see the header's return codes. Uses refuse() + mgmt_post_status
# from the caller (mgmt-apply.sh) and REPO (its clone, reset to <sha>).
ans_bracket() {
  local pol="$1" g="$2" sha="$3" last="$4" row mode plays cap hosts walerts d base j jb n conf wid lease end
  row="$(ans_row "$pol" "$g")" && [ -n "$row" ] && [ "$row" != '""' ] \
    || { refuse "$sha" "ansible $g: apply_ansible row unreadable — human apply"; return 3; }
  mode="$(jq -r '.mode // "shadow"' <<<"$row")"; plays="$(jq -c '.plays // []' <<<"$row")"
  cap="$(jq -r '.cap_min // 30' <<<"$row")"; hosts="$(jq -r '.hosts // ""' <<<"$row")"
  walerts="$(jq -r '(.window_alerts // ["none"]) | join(",")' <<<"$row")"
  [ "$(jq 'length' <<<"$plays")" -gt 0 ] || { refuse "$sha" "ansible $g: the row names no plays — human"; return 3; }
  case "$mode" in on|shadow) ;; *) refuse "$sha" "ansible $g: mode '$mode' is not on|shadow — human"; return 3 ;; esac
  # the loop's own SHADOW (no App token, or MGMT_SHADOW=1) shadows every row: nothing is applied
  [ "${MGMT_SHADOW:-0}" = 1 ] && mode=shadow
  d="${MGMT_ANSIBLE_DIR:-$ADIR/ansible}/$(date -u +%Y%m%dT%H%M%SZ)-$g-${sha:0:8}"; mkdir -p "$d" || { log "PROBE-FAIL: ansible $g: record dir $d not writable"; return 1; }
  if [ "$mode" = on ] && [ -s "$ADIR/ansible-stopped" ]; then
    refuse "$sha" "ansible $g: ansible applies STOPPED since $(cut -f2,4 "$ADIR/ansible-stopped" | tr '\t' ' ' | head -c 80) — a human reads the record, then rm $ADIR/ansible-stopped"
    return 3
  fi
  if ! ans_tools 2>"$d/tools.err"; then
    log "ansible $g: toolchain unresolvable: $(tail -1 "$d/tools.err")"
    [ "$mode" = shadow ] && { ans_mark "$g" "$mode" refused 0; log "[shadow] ansible $g: would REFUSE (toolchain)"; return 0; }
    refuse "$sha" "ansible $g: ansible toolchain unresolvable from devbox.lock — see the box journal"; return 3
  fi

  # 2 the target: --check --diff of master
  j="$(ans_run "$d" target "$REPO" "$plays" --check --diff)"
  n="$(_ans_count "$j")"
  log "ansible $g: --check at ${sha:0:8} → ${j//$'\t'/ — }"
  case "${j%%$'\t'*}" in
    clean)
      log "ansible $g: live already matches master — nothing to apply"
      ans_mark "$g" "$mode" converged 0
      # an OBSERVATION, in any mode: live holds master's declaration (the drift read's next baseline)
      printf '%s' "$sha" >"$ADIR/ansible-confirmed-$g"
      [ "$mode" = on ] && mgmt_post_status "$sha" "$CTX" success "ansible $g: live matches master (--check changed=0) — nothing to apply"
      return 0 ;;
    failed|unreachable)
      local rule="ansible-check-failed"; [ "${j%%$'\t'*}" = unreachable ] && rule="ansible-unreachable"
      ans_mark "$g" "$mode" refused 0
      [ "$mode" = shadow ] && { log "[shadow] ansible $g: would REFUSE — $rule: ${j#*$'\t'}"; return 0; }
      refuse "$sha" "ansible $g: $rule on --check of master (${j#*$'\t'}) — human" "$(tail -3 "$d"/target-*.log 2>/dev/null)"; return 3 ;;
  esac
  # the would-be diff, for the journal (names + the --diff hunks; the plays carry no secrets here)
  grep -hE '^(changed|---|\+\+\+|[-+@])' "$d"/target-*.log 2>/dev/null | head -60 | sed 's/^/    /'

  # 3 drift: the plays as last confirmed (else the previous master) must be clean on live
  conf="$(cat "$ADIR/ansible-confirmed-$g" 2>/dev/null)"; conf="${conf:-$last}"
  base="$d/base"
  if ! git -C "$REPO" worktree add --quiet --detach "$base" "$conf" 2>"$d/base.err"; then
    log "PROBE-FAIL: ansible $g: worktree at ${conf:0:8} failed ($(tail -1 "$d/base.err")) — not applying, not stamping"; return 1
  fi
  jb="$(ans_run "$d" base "$base" "$plays" --check)"
  git -C "$REPO" worktree remove --force "$base" 2>/dev/null || true
  log "ansible $g: --check at ${conf:0:8} (the declaration live should hold) → ${jb//$'\t'/ — }"
  if [ "$jb" != clean ]; then
    local brule="ansible-live-drift" bwhy="live differs from ${conf:0:8} before this span"
    case "${jb%%$'\t'*}" in
      failed) brule="ansible-check-failed"; bwhy="the plays at ${conf:0:8} could not be read clean on live" ;;
      unreachable) brule="ansible-unreachable"; bwhy="the plays at ${conf:0:8} did not reach every host" ;;
    esac
    ans_mark "$g" "$mode" refused "$n"
    [ "$mode" = shadow ] && { log "[shadow] ansible $g: would REFUSE — $brule: $bwhy (${jb#*$'\t'})"; return 0; }
    refuse "$sha" "ansible $g: $brule — $bwhy (${jb#*$'\t'}) — human looks first"; return 3
  fi
  # the drift read was clean: live holds <conf>'s declaration — recorded as an OBSERVATION, so a span
  # this tick only SHADOWS stays pending (not drift) for the next span's read: shadow → on is seamless
  printf '%s' "$conf" >"$ADIR/ansible-confirmed-$g"
  if [ "$mode" = shadow ]; then
    ans_mark "$g" "$mode" shadow "$n"
    log "[shadow] ansible $g: would apply ${conf:0:8} → ${sha:0:8} now — ${j#*$'\t'} (window + lease upgrade-lease-ansible-$g, cap ${cap}m, confirm = --check changed=0 + health)"
    return 0
  fi

  # 4 begin: a stale lease is a STOP; then the window and the lease
  ans_lease_check "$g"; case $? in
    1) log "PROBE-FAIL: ansible $g: lease upgrade-lease-ansible-$g still in flight — not begun"; return 1 ;;
    2) refuse "$sha" "ansible $g: STOPPED — a stale lease upgrade-lease-ansible-$g (see $ADIR/ansible-stopped)"; return 3 ;;
    3) log "PROBE-FAIL: ansible $g: lease unreadable — not begun"; return 1 ;;
  esac
  _awin open --reason "box ansible apply: $g ${conf:0:8} → ${sha:0:8} — mgmt/scripts/mgmt-ansible.sh (ADR-152 step 2)" \
    --alerts "$walerts" --minutes "$(( cap + 30 ))" \
    --note "forward only: a bad confirm STOPS the box (lease kept, window kept, MgmtAnsibleApplyStopped) — nothing reverts" \
    >"$d/window-open.log" 2>&1 || { log "PROBE-FAIL: ansible $g: window did not open ($(tail -1 "$d/window-open.log"))"; return 1; }
  wid="$(sed -n 's/^✓ window \([^ ]*\) open .*/\1/p' "$d/window-open.log" | head -1)"
  [ -n "$wid" ] || { log "PROBE-FAIL: ansible $g: window id unreadable"; return 1; }
  lease="upgrade-lease-ansible-$g"; end="$(_ans_date "+${cap} minutes")"
  jq -n --arg n "$lease" --arg ns "$ANS_LEASE_NS" --arg l "$ANS_LEASE_LABEL" --arg subj "ansible/$g" --arg chart "$g" \
        --arg sha "$sha" --arg from "$conf" --arg to "$sha" --arg end "$end" --arg w "$wid" \
    '{apiVersion:"v1", kind:"ConfigMap", metadata:{name:$n, namespace:$ns, labels:{($l):"true"}},
      data:{subject:$subj, chart:$chart, sha:$sha, from:$from, to:$to, "expected-end":$end, "max-end":$end,
            by:"mgmt-apply", reason:("box ansible bracket under window " + $w + " — forward only (ADR-152 step 2): an expired lease here is a STOP, never a revert")}}' >"$d/lease.json"
  if ! _ak create -f "$d/lease.json" >/dev/null 2>"$d/lease.err"; then
    log "PROBE-FAIL: ansible $g: lease not created ($(tail -c 200 "$d/lease.err")) — closing the window, not applying"
    _awin close --id "$wid" --tail-min 0 >/dev/null 2>&1 || true; return 1
  fi
  log "ansible $g: begun — window $wid, lease $ANS_LEASE_NS/$lease (expected-end $end), record $d"

  # 5 apply, 6 confirm
  local ja jc hf=""
  ja="$(ans_run "$d" apply "$REPO" "$plays")"
  log "ansible $g: APPLY → ${ja//$'\t'/ — }"
  jc="$(ans_run "$d" confirm "$REPO" "$plays" --check)"
  log "ansible $g: confirm --check → ${jc//$'\t'/ — }"
  hf="$(ans_health "$row")" || true
  { echo "box ansible apply $g ${conf:0:8} → ${sha:0:8}  window $wid  lease $lease"
    echo "== target --check: $j"; echo "== apply: $ja"; echo "== confirm --check: $jc"
    echo "== health: ${hf:-ok}"; } >"$d/summary.txt"
  if [ "${ja%%$'\t'*}" != failed ] && [ "${ja%%$'\t'*}" != unreachable ] && [ "$jc" = clean ] && [ -z "$hf" ]; then
    _ak -n "$ANS_LEASE_NS" delete cm "$lease" >/dev/null 2>&1 || log "ansible $g: WARN lease $lease not deleted — the lease loop reads it as ansible_stopped at expiry"
    _awin close --id "$wid" >/dev/null 2>&1 || log "ansible $g: WARN window $wid not closed — it lapses at its until"
    printf '%s' "$sha" >"$ADIR/ansible-confirmed-$g"
    ans_mark "$g" "$mode" applied "$n"
    log "ansible $g: CONFIRMED ${sha:0:8} — lease deleted, window closed"
    mgmt_post_status "$sha" "$CTX" success "ansible $g: applied by the management box ($n change(s)) · confirm clean"
    return 0
  fi
  local why
  why="apply ${ja%%$'\t'*}; confirm --check ${jc%%$'\t'*}${hf:+; $(tr '\n' ';' <<<"$hf" | sed 's/;$//')}"
  printf '%s\t%s\t%s\t%s\n' "$sha" "ansible/$g" "$d" "$why" >"$ADIR/ansible-stopped"
  ans_mark "$g" "$mode" stopped "$n"
  log "ansible $g: STOPPED — $why — lease $lease KEPT, window $wid LEFT OPEN, $ADIR/ansible-stopped written; nothing reverted"
  mgmt_post_status "$sha" "$CTX" failure "ansible $g: applied, STOPPED on the confirm: $why"
  return 2
}
