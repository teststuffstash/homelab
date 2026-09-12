#!/usr/bin/env bash
# mgmt-probe — the management box's contract probe (ADR-129, docs/management-box.md §Detection).
#
# ONE mechanism, TWO jobs: `tofu plan` returning "No changes" asserts the toolchain, the state's
# readability, the encryption passphrase, the credentials and the network path in a single
# read-only call — so FU-097's drift belt and this box's own health check are the same probe.
#
# Exit 0 = every APPLICABLE check passed (skips do not fail). Exit 1 = at least one check failed,
# which on the box is the local deadman's signal to `nixos-rebuild --rollback` (mgmt-probe.service).
# Read-only by construction: plan/--check/version only, never an apply.
#
# Usage:
#   scripts/mgmt-probe.sh                 # run every applicable check, push metrics if configured
#   DRY_RUN=1 scripts/mgmt-probe.sh       # never push (the jail default — see PUSHGATEWAY below)
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
#   SKIP          space-separated check names to skip: tofu talos ansible creds
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

ROOTS="${ROOTS:-cloudflare provisioning}"
PUSHGATEWAY="${PUSHGATEWAY:-}"
TALOS_NODE="${TALOS_NODE:-192.168.2.51}"
SKIP="${SKIP:-}"
DRY_RUN="${DRY_RUN:-0}"

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
  [ -f "$REPO/tofu/talosconfig" ] || { skipped talos "no talosconfig in this checkout"; return; }
  local out
  out="$(tool talosctl --talosconfig tofu/talosconfig -n "$TALOS_NODE" version --short)" || {
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
  local out
  out="$(bash scripts/opnsense-playbook.sh ansible/opnsense-unbound.yml --check 2>&1)" || {
    failed ansible "--check run failed: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; return; }
  passed ansible "opnsense-unbound --check clean"
}

# ── check: every credential the box holds is readable ────────────────────────────────────────────
# A rotation that half-landed locks the box out of its own job. Read, never print.
check_creds() {
  skip_requested creds && { skipped creds "SKIP requested"; return; }
  local missing=() f
  for f in tofu/kubeconfig tofu/talosconfig; do
    [ -s "$REPO/$f" ] || missing+=("$f")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    passed creds "kubeconfig + talosconfig readable"
  else
    skipped creds "not provisioned yet: ${missing[*]}"
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
      "$PUSHGATEWAY/metrics/job/mgmt-probe/instance/$(hostname)" >/dev/null; then
    log "pushed to $PUSHGATEWAY"
  else
    # Never fail the probe on a reporting failure: the deadman's verdict is about the BOX, and
    # Prometheus is in-cluster — exactly the thing that may be down. (The staleness alert is what
    # notices this, from the other side.)
    log "WARN could not push metrics (reporting only, verdict unaffected)"
  fi
}

have devbox || { log "FATAL devbox not on PATH — the toolchain pin is unreachable"; exit 1; }

check_tofu
check_talos
check_ansible
check_creds
publish

log "probe: $PASS pass, $FAIL fail, $SKIPPED skip"
[ "$FAIL" -eq 0 ]
