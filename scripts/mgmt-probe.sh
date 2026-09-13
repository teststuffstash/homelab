#!/usr/bin/env bash
# mgmt-probe — the management box's contract probe (ADR-129, docs/management-box.md §MB2).
#
# ONE mechanism, TWO jobs: `tofu plan` returning "No changes" asserts the toolchain, the state's
# readability, the encryption passphrase, the credentials and the network path in a single
# read-only call — so FU-097's drift belt and this box's own health check are the same probe.
#
# TWO MODES, and keeping them apart is the whole point (review finding, 2026-09-12):
#
#   MODE=belt  (default) — the DRIFT BELT. Asserts the fleet: tofu plan, talosctl skew, the
#              OPNsense --check, credentials. Its verdict is REPORTING. A failure here usually
#              means something OUT THERE broke (Garage unreachable, a node down, real drift), and
#              a box that reboots itself over that is a box that power-cycles precisely when the
#              cluster is having a bad day — the inverse of ADR-129's premise.
#   MODE=gate  — the post-update DEADMAN. Asserts only BOX-LOCAL, unrecoverable-if-lost
#              properties, and NOTHING here may skip: sshd still listening with my keys, the
#              network still up, systemd not degraded, the store still writable. Its failure is
#              the signal to reboot (back into the untouched boot default, because
#              `nixos-rebuild test` never promoted anything).
#
# Exit 0 = pass. Exit 1 = at least one check failed. In `gate` mode a SKIP is also a failure: on
# the box every gate input exists by construction, so a skip means the probe could not look.
# Read-only by construction in both modes: plan/--check/version only, never an apply.
#
# Usage:
#   scripts/mgmt-probe.sh                  # belt: every applicable check, push metrics if configured
#   MODE=gate scripts/mgmt-probe.sh        # the box-local gate (what mgmt-confirm.service runs)
#   DRY_RUN=1 scripts/mgmt-probe.sh        # never push (the jail default — see PUSHGATEWAY below)
#   ROOTS="cloudflare provisioning" scripts/mgmt-probe.sh
#
# Env:
#   ROOTS         space-separated tofu roots to plan. Default = the roots whose plan is CONE-CLEAN,
#                 which is not the same set as "the roots on remote state":
#                   cloudflare    external zone, no cluster dependency
#                   provisioning  Matchbox LXC on Proxmox
#                 ⛔ `infisical` is excluded on purpose even though its state is migrated: its
#                 provider auth comes from the LIVE in-cluster Infisical via a port-forward
#                 (tofu/infisical/apply.sh), so its plan asserts the cluster is up — the opposite
#                 of what this box probes, and it would cry wolf exactly when the cluster is down.
#                 ⛔ `main` is LOCAL state until FU-012's out-of-cone copy lands here; planning it
#                 from the box is a phase-A deliverable, not a probe.
#   PUSHGATEWAY   e.g. http://192.168.40.x:9091 — unset means "do not push" (jail-safe default)
#   TALOS_NODE    a node IP for the client/server skew check (default: the first control plane)
#   TALOSCONFIG / KUBECONFIG   where the file-shaped creds are (box: /var/lib/mgmt/*, set by the env
#                 file scripts/mgmt-provision-secrets.sh writes; jail default: tofu/{talos,kube}config)
#   SKIP          space-separated check names to skip: tofu talos ansible creds
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
[ -n "$REPO" ] && [ -d "$REPO/.git" ] || { echo "FATAL not a checkout: '$REPO'" >&2; exit 1; }
cd "$REPO" || exit 1

# ⚠ systemd does not set $HOME for a system unit without User= (systemd.exec(5)), and BOTH devbox
# and the wallet lookups need it — without this the whole probe died on `HOME: unbound variable`
# under `set -u`, i.e. the deadman would have fired every single run (review finding, 2026-09-12).
export HOME="${HOME:-/root}"

ROOTS="${ROOTS:-cloudflare provisioning}"
PUSHGATEWAY="${PUSHGATEWAY:-}"
TALOS_NODE="${TALOS_NODE:-192.168.2.51}"
SKIP="${SKIP:-}"
DRY_RUN="${DRY_RUN:-0}"
MODE="${MODE:-belt}"

PASS=0 FAIL=0 SKIPPED=0
declare -a RESULTS=()

log()  { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
skipped() { RESULTS+=("$1 skip"); SKIPPED=$((SKIPPED+1)); log "SKIP $1 — $2"; }
passed()  { RESULTS+=("$1 pass"); PASS=$((PASS+1));       log "PASS $1${2:+ — $2}"; }
failed()  { RESULTS+=("$1 fail"); FAIL=$((FAIL+1));       log "FAIL $1 — $2" >&2; }

skip_requested() { case " $SKIP " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
have() { command -v "$1" >/dev/null 2>&1; }

# devbox is how BOTH the jail and the box reach the pinned toolchain (one devbox.lock, ADR-129).
tool() { devbox run --quiet -- "$@" 2>&1; }

# ── check: tofu plan is empty on every root that has remote state ────────────────────────────────
# A non-empty diff means "merged but not applied" or "live drifted from state" — the two things
# FU-097 says nothing detects today. A non-zero exit means the toolchain, the passphrase, the S3
# credential or the network path broke, which is the toolchain canary after a devbox.lock bump.
check_tofu() {
  skip_requested tofu && { skipped tofu "SKIP requested"; return; }
  if [ ! -f "$REPO/scripts/tofu-state-env.sh" ]; then
    skipped tofu "no tofu-state-env.sh in this checkout"; return
  fi
  for root in $ROOTS; do
    if [ ! -f "$REPO/tofu/$root/backend.tf" ]; then
      skipped "tofu:$root" "no backend.tf — root is not on remote state"; continue
    fi
    if [ -f "$REPO/tofu/$root/apply.sh" ]; then
      # A root with its own wrapper derives provider auth from something live (the infisical
      # shape). Skip rather than fail: its plan measures that dependency, not this box.
      skipped "tofu:$root" "root has apply.sh — provider auth is live-derived, not cone-clean"; continue
    fi
    # ⚠ BOTH env scripts, in a SUBSHELL per root: tofu-state-env.sh is per-ROOT (it resolves the
    # S3 credential + TF_ENCRYPTION for one root at a time — docs/tofu-state.md "encryption is per
    # ROOT, not per shell"), and keepass-env.sh supplies the TF_VAR_* the providers want. Sourcing
    # only keepass-env.sh is the documented trap: every command dies with "No valid credential
    # sources found" (the 2026-09-07 stale-doc hit in the onboard-metal-node skill).
    local out rc
    out="$(
      set +u
      . "$REPO/scripts/keepass-env.sh" >/dev/null 2>&1 || true
      TOFU_STATE_ROOT_DIR="$REPO/tofu/$root" . "$REPO/scripts/tofu-state-env.sh" >/dev/null 2>&1 || exit 90
      cd "$REPO" && devbox run --quiet -- tofu -chdir="tofu/$root" plan -detailed-exitcode -input=false -lock=false 2>&1
    )"
    rc=$?
    case $rc in
      0)  passed "tofu:$root" "No changes" ;;
      2)  failed "tofu:$root" "DRIFT — plan is non-empty" ;;
      90) skipped "tofu:$root" "no state credential reachable (wallet absent?)" ;;
      *)  failed "tofu:$root" "plan errored (rc=$rc): $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
    esac
  done
}

# ── check: talosctl client/server skew ──────────────────────────────────────────────────────────
# A devbox.lock bump can move talosctl past the cluster's Talos version; the client refuses or
# misbehaves, and every recovery path through the Talos API goes with it.
check_talos() {
  skip_requested talos && { skipped talos "SKIP requested"; return; }
  # On the box the file is /var/lib/mgmt/talosconfig (TALOSCONFIG from the env file); in the jail
  # it is the tofu-generated one in the checkout.
  local tc="${TALOSCONFIG:-$REPO/tofu/talosconfig}"
  [ -f "$tc" ] || { skipped talos "no talosconfig at $tc"; return; }
  local out
  out="$(tool talosctl --talosconfig "$tc" -n "$TALOS_NODE" version --short)" || {
    failed talos "talosctl version failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return; }
  # `version --short` prints "Talos vX.Y.Z" under Client: and a "Tag: vX.Y.Z" line under Server:.
  local client server
  client="$(printf '%s' "$out" | awk '/^Talos /{print $2; exit}')"
  server="$(printf '%s' "$out" | awk '/Tag:/{print $2; exit}')"
  [ -n "$client" ] && [ -n "$server" ] || { failed talos "unparseable version output"; return; }
  # PATCH skew is fine and normal (the devbox pin moves ahead of the cluster — 2026-09-12: client
  # v1.13.8 vs server v1.13.2, which is FU-155's pin). MINOR skew is the one that breaks the API,
  # so only that fails: an equality check here would cry wolf on every toolchain bump.
  local cmin smin
  cmin="$(printf '%s' "$client" | cut -d. -f1,2)"
  smin="$(printf '%s' "$server" | cut -d. -f1,2)"
  if [ "$cmin" = "$smin" ]; then
    passed talos "client $client / server $server (same minor)"
  else
    failed talos "MINOR skew: client=$client server=$server"
  fi
}

# ── check: the OPNsense play still parses and connects (--check, no writes) ──────────────────────
# Class 9 in docs/dependency-upgrades.md is the sharpest FU-097 gap and it is the ROUTER: a merged
# group_vars change sits until a human remembers. Running it in check mode makes this probe the
# router's drift belt too — and it catches the collection/httpx/API-credential regressions this
# repo has already been bitten by.
check_ansible() {
  skip_requested ansible && { skipped ansible "SKIP requested"; return; }
  [ -f "$REPO/scripts/opnsense-playbook.sh" ] || { skipped ansible "no opnsense-playbook.sh"; return; }
  if [ -z "${OPN_API_KEY:-}" ] && [ ! -f "$HOME/.claude/homelab-keepass/homelab.kdbx" ]; then
    skipped ansible "no OPNsense credential reachable"; return
  fi
  local out changed
  out="$(bash scripts/opnsense-playbook.sh ansible/opnsense-unbound.yml --check 2>&1)" || {
    failed ansible "--check run failed: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; return; }
  # ⚠ `ansible-playbook --check` exits 0 even when tasks report `changed` — only a task ERROR is
  # non-zero. So the exit code alone says "the collection, the httpx interpreter and the API
  # credential work", NOT "the router matches git". The recap is where drift shows.
  changed="$(printf '%s' "$out" | awk -F'changed=' '/PLAY RECAP/{f=1} f&&NF>1{split($2,a," "); print a[1]; exit}')"
  if [ -n "$changed" ] && [ "$changed" != "0" ]; then
    failed ansible "router DRIFT — recap says changed=$changed"
    return
  fi
  # ⚠ AND the recap under-reports: `oxlorg.opnsense.raw` tasks with action:post (the Unbound
  # advanced-settings task and the reconfigure handler) return changed=False in check mode BY
  # CONSTRUCTION, so advanced-settings drift is invisible to --check no matter how it is parsed.
  # This check therefore covers the plumbing + the module-shaped tasks, not the whole router.
  passed ansible "opnsense-unbound --check: plumbing ok, recap changed=${changed:-?}"
}

# ── check: every credential the box holds is readable ────────────────────────────────────────────
# A rotation that half-landed locks the box out of its own job. Read, never print.
check_creds() {
  skip_requested creds && { skipped creds "SKIP requested"; return; }
  local missing=() f
  for f in "${KUBECONFIG:-$REPO/tofu/kubeconfig}" "${TALOSCONFIG:-$REPO/tofu/talosconfig}"; do
    [ -s "$f" ] || missing+=("$f")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    passed creds "kubeconfig + talosconfig readable"
  else
    skipped creds "not provisioned yet: ${missing[*]}"
  fi
}

# ══ MODE=gate — box-local, unskippable, the only checks a reboot may be based on ═══════════════
# Each of these tests something whose loss cannot be recovered without carrying a USB stick to the
# box. None may skip: on the box every input exists.

gate_sshd() {
  local out
  out="$(ss -ltnH 2>/dev/null || true)"
  if printf '%s' "$out" | awk '{print $4}' | grep -qE '(^|:)22$'; then
    passed gate:sshd "listening on 22"
  else
    failed gate:sshd "nothing listening on 22 — an update that breaks sshd is unrecoverable here"
  fi
}

gate_keys() {
  local f=/root/.ssh/authorized_keys n=0
  if [ -s "$f" ]; then
    n="$(ssh-keygen -lf "$f" 2>/dev/null | grep -c . || true)"
  fi
  if [ "${n:-0}" -ge 1 ]; then
    passed gate:keys "$n authorized key(s) parse"
  else
    failed gate:keys "no parseable authorized key — locked out"
  fi
}

gate_network() {
  local gw
  gw="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
  if [ -z "$gw" ]; then
    failed gate:network "no default route"
  elif ping -c1 -W2 "$gw" >/dev/null 2>&1; then
    passed gate:network "gateway $gw reachable"
  else
    failed gate:network "gateway $gw unreachable"
  fi
}

gate_systemd() {
  local st
  st="$(systemctl is-system-running 2>/dev/null || true)"
  case "$st" in
    running|starting) passed gate:systemd "$st" ;;
    *)                failed gate:systemd "system state '$st'" ;;
  esac
}

gate_store() {
  # If the store cannot be written, the reboot-into-the-old-generation path still works but no
  # future update or repair can — worth failing loudly while someone is watching.
  if [ -w /nix/store ] || [ ! -d /nix/store ]; then
    passed gate:store "store writable (or absent — jail)"
  else
    failed gate:store "/nix/store not writable"
  fi
}

# ── publish ─────────────────────────────────────────────────────────────────────────────────────
# Same shape as the Garage write probe: the verdict AND a last-run timestamp, so a staleness alert
# catches "the box is wedged" and not only "the box says no".
publish() {
  local ts; ts="$(date -u +%s)"
  if [ "$DRY_RUN" = "1" ] || [ -z "$PUSHGATEWAY" ]; then
    log "not pushing (DRY_RUN=$DRY_RUN, PUSHGATEWAY=${PUSHGATEWAY:-unset})"
    return 0
  fi
  local body=""
  body+="# TYPE mgmt_probe_last_run_timestamp gauge"$'\n'
  body+="mgmt_probe_last_run_timestamp $ts"$'\n'
  body+="# TYPE mgmt_probe_checks gauge"$'\n'
  body+="mgmt_probe_checks{result=\"pass\"} $PASS"$'\n'
  body+="mgmt_probe_checks{result=\"fail\"} $FAIL"$'\n'
  body+="mgmt_probe_checks{result=\"skip\"} $SKIPPED"$'\n'
  local r name status
  for r in "${RESULTS[@]}"; do
    name="${r% *}"; status="${r##* }"
    body+="mgmt_probe_check{check=\"$name\",status=\"$status\"} 1"$'\n'
  done
  if printf '%s' "$body" | curl -sf --max-time 10 --data-binary @- \
      "$PUSHGATEWAY/metrics/job/mgmt-probe/instance/$(uname -n)" >/dev/null; then
    log "pushed to $PUSHGATEWAY"
  else
    # Never fail the probe on a reporting failure: the deadman's verdict is about the BOX, and
    # Prometheus is in-cluster — exactly the thing that may be down. (The staleness alert is what
    # notices this, from the other side.)
    log "WARN could not push metrics (reporting only, verdict unaffected)"
  fi
}

case "$MODE" in
  gate)
    # No devbox needed: every gate check is box-local on purpose.
    gate_sshd
    gate_keys
    gate_network
    gate_systemd
    gate_store
    publish
    log "gate: $PASS pass, $FAIL fail, $SKIPPED skip"
    # A skip is a failure here: on the box every input exists, so a skip means we could not look.
    [ "$FAIL" -eq 0 ] && [ "$SKIPPED" -eq 0 ]
    ;;
  belt)
    have devbox || { log "FATAL devbox not on PATH — the toolchain pin is unreachable"; exit 1; }
    check_tofu
    check_talos
    check_ansible
    check_creds
    publish
    log "belt: $PASS pass, $FAIL fail, $SKIPPED skip"
    [ "$FAIL" -eq 0 ]
    ;;
  *)
    log "FATAL unknown MODE='$MODE' (belt|gate)"; exit 1
    ;;
esac
