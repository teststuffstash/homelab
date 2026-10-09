#!/usr/bin/env bash
# runner-maintenance — take a ci-runner VM (the non-Talos GitHub Actions runner VMs, tofu/ci-runner.tf)
# out of the job stream, let the main root replace it, and prove it came back. The attended-now,
# box-run-later verb for the one VM class `node-maintenance.sh` (Talos only) does not cover.
#
#   bash scripts/runner-maintenance.sh drain   <vm>              # labels off every registration, wait idle
#   bash scripts/runner-maintenance.sh undrain <vm>              # declared labels back on
#   bash scripts/runner-maintenance.sh verify  <vm>              # READ-ONLY: registrations + exporter up
#   bash scripts/runner-maintenance.sh run <plan-id> <vm>        # ATTENDED: window → drain → apply → verify
#   bash scripts/runner-maintenance.sh silence-close <vm>        # expire THIS verb's silences for <vm>
#                                                                  (a failed `run` leaves them, like its window)
#   (devbox run runner-maint -- <verb> …)
#
# WHY (operator, 2026-10-08): any edit to templates/ci-runner-cloud-init.yaml.tftpl REPLACES the
# runner VM(s) — #2379 and #2381 both did — and a replace is outside the box's apply allowlist, so it
# is a human `mgmt-tf apply`. The runner is stateless (boot-minted registration, fresh disk), so a
# replace is safe exactly when no job is running on it: the job dies with the VM, and its repo reads
# a red run nobody caused. This verb makes "no job in flight" a computed answer. It is built ATTENDED
# first and wired into the box later — the shape `scripts/helm-release-evidence.sh` took
# (docs/management-box.md §"Non-Talos VMs: the runner verb").
#
# A VM is its registrations: cloud-init registers `<vm>` and `<vm>-2` (two slots, same labels,
# `var.github_runner_labels`). `drain` REMOVES the declared custom labels from every registration of
# the VM — the workflows route on `runs-on: [self-hosted, proxmox-vm]`, so a runner without its
# labels is never assigned a new job, while the other VM still serves the lane — then polls until
# every registration reads `busy=false` twice in a row (≤ DRAIN_TIMEOUT). A timeout or ANY unreadable
# GitHub answer restores the labels and exits 2: an API that did not answer is never "idle".
# `undrain` is the restore on its own. The replacement VM re-registers with the declared labels
# (config.sh --replace), so a successful `run` needs no undrain.
#
# `verify` is the health read, never a wait: every expected registration `online` with the full
# declared label set, and `up{job="ci-runner-node",instance="<ip>:9100"} == 1` in Prometheus (the
# VM's own node_exporter — argocd/resources/ci-runner-metrics/; the ip from machines/machines.yaml).
#
# `run` — REPORT-ONLY, it never reverts. Refuses (3) while any other declared window is live, and
# unless the saved plan's only VM change is a REPLACE of a `proxmox_virtual_environment_vm` named
# <vm> (read via `mgmt-tf summary`, which filters the plan JSON on the box — the cloud-init snippet in
# it carries the runner App's private key). Then: its own maintenance window, a `snapshot` baseline,
# drain, `MGMT_YES=1 mgmt-tf apply <plan-id>`, wait for `verify` (≤ VERIFY_TIMEOUT: cloud-init
# installs docker + nix and registers both slots), `compare` against the baseline until clean
# (≤ COMPARE_SETTLE), and close the window only then. A failure after acting leaves the window open.
# Between the baseline and the drain it opens Alertmanager silences for the VM (see §silences below)
# and expires them where it closes the window — a refusal before the apply closes both, a failure
# after acting leaves both (node-maintenance.sh's precedent): the silences then self-expire at the
# run's own bound, or `silence-close <vm>` expires them once the human has finished by hand.
# Passing the plan id IS the confirmation — plan it scoped and read it first (docs/runbook.md).
#
# Exit: 0 ok · 1 failed after acting (or a verify fail / unreadable) · 2 refused, nothing touched
# (drain's timeout/unreadable, labels restored) · 3 refused before any window (live window, plan scope,
# window did not open) · 64 usage.
# Env: DRAIN_TIMEOUT (3600 s), VERIFY_TIMEOUT (1800 s), COMPARE_SETTLE (600 s), RUNNER_POLL (20 s),
#      RUNNER_APP_KEY (the runner-registrar App's .pem; default the box's TF_VAR_github_app_private_key_file,
#      else ~/.claude/homelab-runner-app/private-key.pem), GH_RUNNER_TOKEN (an installation token
#      already minted — skips the mint), PROM_URL, RUNNER_EVIDENCE_DIR, KUBECONFIG,
#      AM_URL (Alertmanager; else NM_AM, else http://192.168.40.14:9093), SILENCE=0 (touch no silence).
set -euo pipefail

ROOT="${DEVBOX_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# Same fallback as maintenance-window.sh / node-maintenance.sh / helm-release-evidence.sh: on the
# management box the client config lives in /var/lib/mgmt/, and devbox exports the checkout path
# regardless. Only `run` needs it (its window and health compare); drain/verify read GitHub + Prometheus.
export KUBECONFIG="${KUBECONFIG:-$ROOT/tofu/kubeconfig}"
[ -f "$KUBECONFIG" ] || { [ -f /var/lib/mgmt/kubeconfig ] && export KUBECONFIG=/var/lib/mgmt/kubeconfig; }

# The declaration is tofu/ci-runner.tf's variable defaults, overridden by the TF_VAR_* the box's env
# carries — the same values the cloud-init was rendered from. Never a second list here.
TFFILE="$ROOT/tofu/ci-runner.tf"
tfdefault() { # <variable> → its string default
  awk -v v="variable \"$1\"" 'index($0, v) == 1 {f=1} f && $1 == "default" {s=$0; sub(/^[^"]*"/, "", s); sub(/".*/, "", s); print s; exit}' "$TFFILE"
}
ORG="${TF_VAR_github_runner_org:-$(tfdefault github_runner_org)}"
APP_ID="${TF_VAR_github_app_id:-$(tfdefault github_app_id)}"
INSTALL_ID="${TF_VAR_github_app_installation_id:-$(tfdefault github_app_installation_id)}"
LABELS="${TF_VAR_github_runner_labels:-$(tfdefault github_runner_labels)}"
APP_KEY="${RUNNER_APP_KEY:-${TF_VAR_github_app_private_key_file:-$HOME/.claude/homelab-runner-app/private-key.pem}}"
GH_API="${GH_API_URL:-https://api.github.com}"
PROM="${PROM_URL:-http://192.168.40.13:9090}"
AM="${AM_URL:-${NM_AM:-http://192.168.40.14:9093}}"   # same default + override as node-maintenance.sh
SILENCE="${SILENCE:-1}"
SLOTS="${RUNNER_SLOTS:-2}"   # cloud-init's `<vm>` + `<vm>-2`
POLL="${RUNNER_POLL:-20}"
MGMT_TF="${MGMT_TF:-$ROOT/mgmt/scripts/mgmt-tf.sh}"
MAINT="${MAINT_WINDOW:-$ROOT/scripts/maintenance-window.sh}"
SEATWIN="${SEAT_WINDOW:-$ROOT/agents/seat-window.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
log() { echo "runner-maintenance: $*" >&2; }

# ── GitHub (the runner-registrar App: org self_hosted_runners write) ──────────────────────────────
# The JWT → installation-token half of scripts/gh-app-runner-token.sh (same RS256 recipe, same App).
# Not a call into that script: it stops at a REGISTRATION token, and it is embedded verbatim in the
# runner cloud-init — editing it replaces both runner VMs.
TOKEN="${GH_RUNNER_TOKEN:-}"; TOKEN_AT=0
mint() {
  local now unsigned sig
  [ -r "$APP_KEY" ] || { log "runner App key not readable: $APP_KEY (RUNNER_APP_KEY)"; return 1; }
  b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }
  now=$(date +%s)
  unsigned="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url).$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)"
  sig="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$APP_KEY" -binary | b64url)"
  TOKEN="$(curl -fsS --max-time 20 -X POST -H "Authorization: Bearer $unsigned.$sig" \
    -H "Accept: application/vnd.github+json" "$GH_API/app/installations/$INSTALL_ID/access_tokens" | jq -r '.token // empty')" || return 1
  [ -n "$TOKEN" ] || return 1
  TOKEN_AT=$now
}
token() { # an installation token lives 60 min; a drain may poll for 60 — re-mint at 45
  [ -n "${GH_RUNNER_TOKEN:-}" ] && return 0
  if [ -z "$TOKEN" ] || [ $(( $(date +%s) - TOKEN_AT )) -gt 2700 ]; then mint || { log "could not mint an installation token"; return 1; }; fi
}
gh_api() { # <METHOD> <path> [<json body>] → body on stdout; non-zero on any failure (never an empty "ok")
  token || return 1
  local args=(-fsS --max-time 20 -X "$1" -H "Authorization: token $TOKEN"
              -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  [ -n "${3:-}" ] && args+=(-H "Content-Type: application/json" -d "$3")
  curl "${args[@]}" "$GH_API$2"
}

# Every registration of <vm> (name == vm, or vm-<n>) as a JSON array of {id,name,status,busy,labels}
# (custom labels only). Non-zero if the list could not be read. Paged: the org also lists every ARC
# ephemeral runner.
regs() { # <vm>
  local page=1 n
  : > "$T/regs.jsonl"
  while :; do
    gh_api GET "/orgs/$ORG/actions/runners?per_page=100&page=$page" > "$T/page.json" || return 1
    jq -e '.runners | type == "array"' "$T/page.json" >/dev/null 2>&1 || return 1
    jq -c --arg vm "$1" '.runners[] | select(.name == $vm or (.name | startswith($vm + "-") and (ltrimstr($vm + "-") | test("^[0-9]+$"))))
        | {id, name, status, busy, labels: [.labels[] | select(.type == "custom") | .name]}' "$T/page.json" >> "$T/regs.jsonl"
    n="$(jq '.runners | length' "$T/page.json")"
    [ "$n" -ge 100 ] || break
    page=$((page + 1))
  done
  jq -sc '.' "$T/regs.jsonl"
}
declared_json() { jq -nc --arg l "$LABELS" '$l | split(",") | map(select(length > 0))'; }

# Put every declared label back on every registration that lacks one. Non-zero if any write failed.
restore() { # <vm>
  local r id missing rc=0
  regs "$1" > "$T/r.json" || { log "restore: runner list UNREADABLE — labels NOT verified restored"; return 1; }
  while IFS= read -r r; do
    id="$(jq -r .id <<<"$r")"
    missing="$(jq -c --argjson d "$(declared_json)" '$d - .labels' <<<"$r")"
    [ "$missing" = "[]" ] && continue
    if gh_api POST "/orgs/$ORG/actions/runners/$id/labels" "$(jq -nc --argjson l "$missing" '{labels:$l}')" >/dev/null; then
      log "  restored $(jq -r '.name' <<<"$r"): +$(jq -r 'join(",")' <<<"$missing")"
    else log "  ⚠ could not restore labels on $(jq -r '.name' <<<"$r")"; rc=1; fi
  done < <(jq -c '.[]' "$T/r.json")
  return $rc
}

need_vm() { # <vm> — a ci-runner VM that machines.yaml knows, with its ip → $VM_IP
  [ -n "${1:-}" ] || { log "a VM name is required (ci-runner-01, ci-runner-02)"; exit 64; }
  case "$1" in ci-runner-*) ;; *) log "'$1' is not a ci-runner VM — Talos nodes go through node-maintenance.sh"; exit 64 ;; esac
  VM_IP="$(yq -r ".machines[] | select(.name == \"$1\") | .ip // \"\"" "$ROOT/machines/machines.yaml" 2>/dev/null)" || VM_IP=""
  [ -n "$VM_IP" ] || { log "'$1' has no ip in machines/machines.yaml"; exit 64; }
}

# ── silences (the shape of node-maintenance.sh §"the window silence") ────────────────────────────
# The declared window (seat-window.sh) only graces the responder's triage; the PAGE goes through
# Alertmanager, so `run` silences what the replace raises (2026-10-08, the first attended run paged on
# all three). One silence per matcher set — Alertmanager ANDs the matchers inside one silence:
#   1. instance=~"<ip>(:[0-9]+)?" — every alert keyed on the VM's own exporter: CiRunnerNodeExporterDown,
#      NodeRebooted (the fresh VM's first boot), CiRunnerRootFs{FillingUp,AlmostFull} (a new disk).
#   2. alertname="TargetDown", job="ci-runner-node" — kube-prometheus-stack's TargetDown is a
#      JOB-level ratio with no instance label, so it cannot be scoped to one VM: for the run's
#      duration this ALSO hides a genuine outage of the OTHER runner's exporter (its own
#      CiRunnerNodeExporterDown, matcher 1 for the other ip, stays live and covers it).
# Deliberately NOT silenced: the pve exporter's guest alerts (PveVmIoError, PveGuestSwapped — keyed
# name=<vm>, vmid): a replace does not raise them, and an io-error on the new disk is the thin pool
# filling, a real fault the window must not hide (node-maintenance keeps capacity alerts live too).
# Owner tag `runner-maintenance.sh/<vm>` in createdBy: close expires ONLY these, never a silence a
# human or node-maintenance made. Best-effort, like node-maintenance: an unreachable Alertmanager
# warns and the run goes on — a page is a nuisance, a refused window over it would be a worse one.
# ⚠ Alertmanager keeps silences on an emptyDir (FU-195): a monitoring restart mid-run drops them.
silence_owner() { printf 'runner-maintenance.sh/%s' "$1"; }
silence_ids() { # <vm> → ids of this verb's live silences for <vm>; non-zero if Alertmanager was unreadable
  local out
  out="$(curl -fsS --max-time 10 "$AM/api/v2/silences" 2>/dev/null)" || return 1
  jq -r --arg by "$(silence_owner "$1")" '.[] | select(.createdBy == $by and .status.state != "expired") | .id' <<<"$out" 2>/dev/null
}
post_silence() { # <vm> <matchers-json> <seconds> <comment>
  local body id
  body="$(jq -cn --argjson m "$2" --arg by "$(silence_owner "$1")" --arg s "$3" --arg c "$4" \
    '{matchers:$m, startsAt:(now|todate), endsAt:((now + ($s|tonumber))|todate), createdBy:$by, comment:$c}')"
  id="$(curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' -d "$body" "$AM/api/v2/silences" 2>/dev/null \
    | jq -r '.silenceID // empty' 2>/dev/null)" || id=""
  [ -n "$id" ] || return 1
  log "  silence $id: $(jq -r 'map("\(.name)\(if .isRegex then "=~" else "=" end)\(.value)") | join(" ")' <<<"$2")"
}
silence_open() { # <vm> <ip> <seconds> <why>
  [ "$SILENCE" = 1 ] || { log "SILENCE=0 — not touching Alertmanager"; return 0; }
  local existing m
  existing="$(silence_ids "$1")" || { log "  ⚠ Alertmanager unreadable at $AM — trying the silences anyway"; existing=""; }
  [ -z "$existing" ] || { log "silences already active for $1: $(tr '\n' ' ' <<<"$existing")"; return 0; }
  while IFS= read -r m; do
    post_silence "$1" "$m" "$3" "runner-maintenance window on $1 ($(date -u +%FT%TZ)) — $4. Expired by the run's close, or \`runner-maintenance.sh silence-close $1\`." \
      || log "  ⚠ could not open a silence ($m at $AM) — these alerts will page for this window"
  done < <(jq -cn --arg ip "$2" '[{name:"instance", value:($ip + "(:[0-9]+)?"), isRegex:true, isEqual:true}],
                                 [{name:"alertname", value:"TargetDown", isRegex:false, isEqual:true},
                                  {name:"job", value:"ci-runner-node", isRegex:false, isEqual:true}]')
}
silence_close() { # <vm> → non-zero if a silence of ours may still be live (warned; each self-expires)
  [ "$SILENCE" = 1 ] || return 0
  local ids id n=0 rc=0
  ids="$(silence_ids "$1")" || { log "  ⚠ Alertmanager unreadable at $AM — silences for $1 NOT expired (they self-expire at their endsAt)"; return 1; }
  [ -n "$ids" ] || { log "no runner-maintenance silence to expire for $1"; return 0; }
  for id in $ids; do
    if curl -fsS --max-time 10 -X DELETE "$AM/api/v2/silence/$id" >/dev/null 2>&1; then n=$((n + 1))
    else log "  ⚠ could not expire silence $id — it self-expires at its endsAt"; rc=1; fi
  done
  log "expired $n silence(s) for $1"
  return $rc
}

# ── verbs ────────────────────────────────────────────────────────────────────────────────────────
cmd_drain() { # <vm>
  need_vm "$1"; local vm="$1" r id name l timeout="${DRAIN_TIMEOUT:-3600}" end idle=0 busy
  regs "$vm" > "$T/d.json" || { log "drain: runner list UNREADABLE — refusing, nothing touched"; return 2; }
  [ "$(jq length "$T/d.json")" -gt 0 ] || { log "drain: no registration named $vm / $vm-<n> — refusing (an unregistered VM is not a drained one)"; return 2; }
  log "drain $vm: $(jq -r 'map("\(.name)[\(.status) busy=\(.busy)]") | join(" ")' "$T/d.json") — removing $LABELS"
  while IFS= read -r r; do
    id="$(jq -r .id <<<"$r")"; name="$(jq -r .name <<<"$r")"
    for l in $(jq -r --argjson d "$(declared_json)" '.labels - (.labels - $d) | .[]' <<<"$r"); do
      gh_api DELETE "/orgs/$ORG/actions/runners/$id/labels/$l" >/dev/null || {
        log "drain: could not remove '$l' from $name — restoring and refusing"
        restore "$vm" || return 1; return 2; }
    done
  done < <(jq -c '.[]' "$T/d.json")
  # Idle = every registration busy=false on TWO consecutive reads: a job assigned in the instant
  # before the label went is not yet `busy` on the first.
  end=$(( $(date +%s) + timeout ))
  while :; do
    if ! regs "$vm" > "$T/d.json"; then
      log "drain: runner list UNREADABLE mid-drain — an unread runner is not an idle one; restoring, refusing"
      restore "$vm" || return 1; return 2
    fi
    busy="$(jq -r '[.[] | select(.busy) | .name] | join(" ")' "$T/d.json")"
    if [ -z "$busy" ]; then
      idle=$((idle + 1)); [ "$idle" -ge 2 ] && break
    else idle=0; fi
    if [ "$(date +%s)" -ge "$end" ]; then
      log "drain: still busy after ${timeout}s ($busy) — restoring labels, refusing"
      restore "$vm" || return 1; return 2
    fi
    [ -n "$busy" ] && log "  waiting: busy $busy"
    sleep "$POLL"
  done
  log "drain $vm: idle, labels off — no new job lands here ($(jq -r 'map(.name) | join(" ")' "$T/d.json"))"
}

cmd_undrain() { need_vm "$1"; restore "$1" && log "undrain $1: declared labels on ($LABELS)"; }

# READ-ONLY. Every expected slot registered, online, carrying every declared label; the VM's own
# exporter up. Exit 1 on any failure or unread signal.
cmd_verify() { # <vm>
  need_vm "$1"; local vm="$1" rc=0 s name out v
  if regs "$vm" > "$T/v.json"; then
    for s in $(seq 1 "$SLOTS"); do
      name="$vm"; [ "$s" = 1 ] || name="$vm-$s"
      out="$(jq -r --arg n "$name" --argjson d "$(declared_json)" '[.[] | select(.name == $n)] |
        if length == 0 then "MISSING"
        elif .[0].status != "online" then "status=\(.[0].status)"
        elif ($d - .[0].labels) != [] then "labels missing \($d - .[0].labels | join(","))"
        else "ok" end' "$T/v.json")"
      if [ "$out" = ok ]; then echo "  ok  $name online, labels $LABELS"
      else echo "  ⚠ $name: $out"; rc=1; fi
    done
  else echo "  ⚠ runner list UNREADABLE — registrations NOT checked"; rc=1; fi
  if out="$(curl -fsS --max-time 20 --data-urlencode "query=up{job=\"ci-runner-node\",instance=\"$VM_IP:9100\"}" "$PROM/api/v1/query")" \
     && jq -e '.status == "success"' >/dev/null 2>&1 <<<"$out"; then
    v="$(jq -r '[.data.result[].value[1]] | if length == 1 then .[0] else "series=\(length)" end' <<<"$out")"
    if [ "$v" = 1 ]; then echo "  ok  node_exporter $VM_IP:9100 up"
    else echo "  ⚠ node_exporter $VM_IP:9100 up=$v"; rc=1; fi
  else echo "  ⚠ Prometheus UNREADABLE ($PROM) — exporter NOT checked"; rc=1; fi
  return $rc
}

# The plan's VM changes must be exactly one REPLACE of a proxmox_virtual_environment_vm named <vm>.
# Everything else in the plan (the snippet file, k8s residue) is the plan's own business.
plan_scope() { # <plan-id> <vm> → 0 in scope; prints why not
  local out j
  out="$(bash "$MGMT_TF" summary "$1" 2>"$T/sum.err")" || { echo "plan $1 unreadable: $(tail -2 "$T/sum.err" | tr '\n' ' ')"; return 1; }
  j="$(sed -n 's/^MGMT_SUMMARY //p' <<<"$out" | tr -d '\r')"
  jq -e '.changes | type == "array"' >/dev/null 2>&1 <<<"$j" || { echo "plan $1: no readable summary"; return 1; }
  jq -r --arg vm "$2" '[.changes[] | select(.type == "proxmox_virtual_environment_vm")] as $v |
    if ($v | length) == 0 then "plan replaces no VM"
    elif ($v | length) > 1 then "plan changes \($v | length) VMs (\($v | map("\(.name)=\(.actions | join("+"))") | join(", "))) — one VM per run"
    elif $v[0].name != $vm then "plan changes VM \($v[0].name) (\($v[0].address)), not \($vm)"
    elif ($v[0].actions | sort) != ["create", "delete"] then "plan does not REPLACE \($vm) (actions: \($v[0].actions | join("+")))"
    else "ok \($v[0].address) replace; \(.changes | length) change(s) in plan, scoped=\(.scoped)" end' <<<"$j" > "$T/scope.txt"
  cat "$T/scope.txt"
  read -r out < "$T/scope.txt"; [ "${out%% *}" = ok ]
}

cmd_run() { # <plan-id> <vm>
  local plan="${1:-}" vm="${2:-}"
  [ -n "$plan" ] && [ -n "$vm" ] || { log "run: <plan-id> <vm> required (plan it scoped first: docs/runbook.md)"; exit 64; }
  need_vm "$vm"
  [ -f "$KUBECONFIG" ] || { log "run: no kubeconfig at $KUBECONFIG — the window's health compare needs one"; exit 3; }
  # The window is this verb's own: another live window means another session is changing things,
  # and two changes in one window make both records worthless (helm-release-evidence.sh, same rule).
  local live; live="$(bash "$SEATWIN" list 2>&1)" \
    || { log "run: cannot read the window registry — refusing (an unread registry is not an empty one)"; printf '%s\n' "$live" >&2; exit 3; }
  grep -q '^no live seat window' <<<"$live" || { log "run: a maintenance window is already open — refusing:"; printf '%s\n' "$live" >&2; exit 3; }
  local scope; scope="$(plan_scope "$plan" "$vm")" || { log "run: plan $plan is not scoped to $vm — refusing: $scope"; exit 3; }
  log "run: $scope"

  local dir; dir="${RUNNER_EVIDENCE_DIR:-$HOME/.claude/runner-maintenance}/$(date -u +%Y%m%dT%H%M%SZ)-$vm"
  mkdir -p "$dir"; log "evidence → $dir"
  local hours=$(( (${DRAIN_TIMEOUT:-3600} + ${VERIFY_TIMEOUT:-1800} + ${COMPARE_SETTLE:-600} + 1800 + 3599) / 3600 ))
  bash "$MAINT" open --reason "ci-runner VM replace: $vm, plan $plan — scripts/runner-maintenance.sh" \
    --alerts "TargetDown,CiRunnerNodeExporterDown,CiDispatchStalled" --hours "$hours" \
    > "$dir/window-open.log" 2>&1 || { cat "$dir/window-open.log" >&2; log "run: window did not open — not draining"; exit 3; }
  local wid; wid="$(sed -n 's/^  maintenance-window slot: \([^ ]*\) .*/\1/p' "$dir/window-open.log")"; wid="${wid%%$'\n'*}"
  [ -n "$wid" ] || { log "run: could not read the window id from 'open' — not draining ('devbox run maint -- list')"; exit 3; }
  log "window $wid open"
  if ! bash "$MAINT" snapshot > "$dir/health-before.json" 2>"$dir/health-before.err"; then
    log "run: baseline unreadable — closing the window, nothing touched"
    bash "$MAINT" close --id "$wid" --force > "$dir/window-close.log" 2>&1 || true; exit 3
  fi
  # Silences after the baseline (it records what was already firing), before anything acts; same
  # lifetime as the window — the run's own bounds plus margin.
  silence_open "$vm" "$VM_IP" "$((hours * 3600))" "ci-runner VM replace, plan $plan, window $wid"

  local rc=0; cmd_drain "$vm" || rc=$?
  if [ "$rc" = 2 ]; then
    log "run: drain refused (labels restored) — closing the window + silences, nothing applied"
    silence_close "$vm" || true
    bash "$MAINT" close --id "$wid" --force > "$dir/window-close.log" 2>&1 || true; exit 2
  elif [ "$rc" != 0 ]; then
    log "run: ⚠ drain failed AND its label restore failed — window $wid + silences LEFT OPEN; 'runner-maint -- undrain $vm', then 'silence-close $vm'"; exit 1
  fi

  # MGMT_YES=1: passing the plan id to `run` is the confirmation (helm-release-evidence.sh, same).
  rc=0; MGMT_YES=1 bash "$MGMT_TF" apply "$plan" 2>&1 | tee "$dir/apply.log" >&2 || rc=${PIPESTATUS[0]}
  if [ "$rc" != 0 ]; then
    log "run: ⚠ apply rc=$rc — window $wid + silences LEFT OPEN, $vm's labels left OFF (read apply.log: if the old VM still runs, 'runner-maint -- undrain $vm'; done: 'silence-close $vm')"
    exit 1
  fi

  local end=$(( $(date +%s) + ${VERIFY_TIMEOUT:-1800} )) ok=0
  log "applied; waiting for $vm to re-register + export (≤ ${VERIFY_TIMEOUT:-1800}s)"
  while [ "$(date +%s)" -lt "$end" ]; do
    if cmd_verify "$vm" > "$dir/verify.txt" 2>&1; then ok=1; break; fi
    sleep "$POLL"
  done
  cat "$dir/verify.txt" >&2
  [ "$ok" = 1 ] || { log "run: ⚠ $vm did not verify within ${VERIFY_TIMEOUT:-1800}s — window $wid + silences LEFT OPEN"; exit 1; }

  # An alert the replace raised (TargetDown on the exporter) resolves an evaluation or two after
  # `up` returns — compare until clean, like the box loop's post-check.
  end=$(( $(date +%s) + ${COMPARE_SETTLE:-600} )); ok=0
  while :; do
    if bash "$MAINT" compare "$dir/health-before.json" > "$dir/health-compare.txt" 2>&1; then ok=1; break; fi
    [ "$(date +%s)" -lt "$end" ] || break
    sleep 30
  done
  cat "$dir/health-compare.txt" >&2
  [ "$ok" = 1 ] || { log "run: ⚠ health compare still regressed after ${COMPARE_SETTLE:-600}s — window $wid + silences LEFT OPEN"; exit 1; }
  if bash "$MAINT" close --id "$wid" > "$dir/window-close.log" 2>&1; then
    silence_close "$vm" || true   # a silence left behind self-expires at the run's bound (warned)
    log "run: $vm replaced and verified; window $wid closed"
  else
    cat "$dir/window-close.log" >&2
    log "run: ⚠ window $wid LEFT OPEN — its close check is not clean; read it, then 'devbox run maint -- close --id $wid' + 'runner-maint -- silence-close $vm'"; exit 1
  fi
}

case "${1:-}" in
  drain)   shift; rc=0; cmd_drain "${1:-}" || rc=$?; exit "$rc" ;;
  undrain) shift; cmd_undrain "${1:-}" || exit 1 ;;
  verify)  shift; cmd_verify "${1:-}" || exit 1 ;;
  run)     shift; cmd_run "$@" ;;
  silence-close) shift; need_vm "${1:-}"; silence_close "$1" || exit 1 ;;
  *) echo "usage: runner-maintenance.sh drain|undrain|verify|silence-close <vm> | run <plan-id> <vm>" >&2; exit 64 ;;
esac
