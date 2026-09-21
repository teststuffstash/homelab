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
#   ROOTS="provisioning" scripts/mgmt-probe.sh
#
# Env:
#   ROOTS         space-separated tofu roots to plan. Default = the roots whose plan is CONE-CLEAN,
#                 which is not the same set as "the roots on remote state":
#                   provisioning  Matchbox LXC on Proxmox
#                   github        org/repos/rulesets — read-only PAT (GITHUB_TOKEN) + the App keys via
#                                 scripts/mgmt-root-env/github.sh; plan-only, applies stay on the host (FU-238)
#                 ⛔ `cloudflare` is NOT cone-clean, contrary to the 2026-09-12 reading: half of it
#                 is in-cluster (the cloudflared Deployment via the kubernetes provider) — the
#                 SENTINEL plans it per PR head (policy root, read-only token, FU-238), the belt
#                 does not — so its
#                 plan reads the API server and fails with the cluster down — found 2026-09-13 on
#                 the box ("dial tcp [::1]:80: connection refused" = no kubeconfig, but WITH one it
#                 asserts the cluster). Same class as `infisical`, whose provider auth comes from
#                 the LIVE in-cluster Infisical via a port-forward (tofu/infisical/apply.sh). Both
#                 would cry wolf exactly when the cluster is down — the opposite of this box's job.
#   TOFU_VAR_DIR  directory holding optional per-root var files named <root>.tfvars (the box:
#                 /var/lib/mgmt, placed by scripts/mgmt-provision-secrets.sh — a gitignored
#                 terraform.tfvars in the jail's checkout is invisible to a fresh clone)
#                 ⛔ `main` is LOCAL state until FU-012's out-of-cone copy lands here; planning it
#                 from the box is a phase-A deliverable, not a probe.
#   PUSHGATEWAY   e.g. http://192.168.40.x:9091 — unset means "do not push" (jail-safe default)
#   TALOS_NODE    a node IP for the client/server skew check (default: the first control plane)
#   TALOSCONFIG / KUBECONFIG   where the file-shaped creds are (box: /var/lib/mgmt/*, set by the env
#                 file scripts/mgmt-provision-secrets.sh writes; jail default: tofu/{talos,kube}config)
#   SKIP          space-separated check names to skip: tofu talos nodes ansible creds
#   MAIN_STATE    main root's state file (default /var/lib/mgmt/state/main/terraform.tfstate)
#   NODE_TARGETS_JSON  pre-fetched `node_install_targets` JSON — runs the node diff off the box
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
# `-e`, not `-d`: in a git WORKTREE .git is a file pointing at the real gitdir, and the jail's PR
# lane runs entirely out of worktrees (a branch is never checked out in the shared tree), so the
# `-d` form made this script the one thing that could not be exercised before it shipped.
[ -n "$REPO" ] && [ -e "$REPO/.git" ] || { echo "FATAL not a checkout: '$REPO'" >&2; exit 1; }
cd "$REPO" || exit 1

# ⚠ systemd does not set $HOME for a system unit without User= (systemd.exec(5)), and BOTH devbox
# and the wallet lookups need it — without this the whole probe died on `HOME: unbound variable`
# under `set -u`, i.e. the deadman would have fired every single run (review finding, 2026-09-12).
export HOME="${HOME:-/root}"

ROOTS="${ROOTS:-provisioning github}"   # github: read-only PAT + Garage state since 2026-09-13 (FU-238)
TOFU_VAR_DIR="${TOFU_VAR_DIR:-}"
PUSHGATEWAY="${PUSHGATEWAY:-}"
TALOS_NODE="${TALOS_NODE:-192.168.2.51}"
SKIP="${SKIP:-}"
DRY_RUN="${DRY_RUN:-0}"
MODE="${MODE:-belt}"

PASS=0 FAIL=0 SKIPPED=0
declare -a RESULTS=()
# The node diff publishes per-node gauges rather than one pass/fail, so it accumulates its own
# (node, axis) pairs: DRIFT = declared and live disagree, DRIFT_OK = they match.
declare -a DRIFT=() DRIFT_OK=()

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
      [ -f "$REPO/scripts/mgmt-root-env/$root.sh" ] && . "$REPO/scripts/mgmt-root-env/$root.sh"   # per-root env (github: the App keys)
      cd "$REPO" || exit 1
      # A fresh checkout (the box after install, 2026-09-13) has no .terraform/: plan fails with
      # "Backend initialization required". Init once, with the backend creds already in the env —
      # the same thing scripts/tf.sh does for the main root on every call.
      if [ ! -d "$REPO/tofu/$root/.terraform" ]; then
        devbox run --quiet -- tofu -chdir="tofu/$root" init -input=false -lock=false >/dev/null 2>&1 || exit 91
      fi
      varfile=""
      [ -n "$TOFU_VAR_DIR" ] && [ -f "$TOFU_VAR_DIR/$root.tfvars" ] && varfile="-var-file=$TOFU_VAR_DIR/$root.tfvars"
      # the policy's plan_exclude_types for this root (github: repo settings a read-only token cannot
      # see — policy/mgmt/plan-input.yaml explains); the sentinel applies the same knob via mgmt-lib
      excl=""
      for t in $(devbox run --quiet -- yq -r ".roots.\"$root\".plan_exclude_types[]?" "$REPO/policy/mgmt/plan-input.yaml" 2>/dev/null); do
        excl="$excl $(devbox run --quiet -- tofu -chdir="tofu/$root" state list 2>/dev/null | grep "^$t\." | sed 's/^/-exclude=/' | tr '\n' ' ')"
      done
      # shellcheck disable=SC2086
      devbox run --quiet -- tofu -chdir="tofu/$root" plan -detailed-exitcode -input=false -lock=false $varfile $excl 2>&1
    )"
    rc=$?
    case $rc in
      0)  passed "tofu:$root" "No changes" ;;
      2)  failed "tofu:$root" "DRIFT — plan is non-empty" ;;
      90) skipped "tofu:$root" "no state credential reachable (wallet absent?)" ;;
      91) failed "tofu:$root" "tofu init failed (backend creds, provider download, or egress)" ;;
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
  # Unanchored + ANSI/CR-stripped: under the systemd unit the first run's captured output carried
  # devbox install chatter around these lines and the anchored match found nothing (2026-09-13).
  local client server clean
  clean="$(printf '%s' "$out" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r//g')"
  client="$(printf '%s' "$clean" | awk '/Talos v[0-9]/{for(i=1;i<=NF;i++) if($i ~ /^v[0-9]/){print $i; exit}}')"
  server="$(printf '%s' "$clean" | awk '/Tag:/{for(i=1;i<=NF;i++) if($i ~ /^v[0-9]/){print $i; exit}}')"
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

# ── check: declared node state vs live (FU-235, ADR-132 §MB4 layer 1) ───────────────────────────
# `talos_machine_configuration_apply` records DELIVERY, not installation: Talos honours the
# install-time fields (schematic, install disk, EPHEMERAL VolumeConfig) only on the next install,
# so state is truthful, `plan` is clean, and the node still runs the wrong image. nx-01 after
# #1717 is the worked example — `nodeLabels` took, the schematic did not. This check is the diff
# that sees it: DECLARED (`tofu output node_install_targets`, the same expression the upgrade verb
# passes as `--image`) vs LIVE (`talosctl version` + the `schematic` extension), one line and one
# gauge per node per axis.
#
# ⚠ It reports, it never FAILS the probe. A declared-vs-live version gap is the normal state of a
# rollout in progress ("the progress bar, not drift" — tofu/variables.tf), and a belt that reds the
# box every time a node is mid-upgrade teaches everyone to ignore it. The judgement of "too long"
# belongs to an alert with a `for:`, reading mgmt_node_drift — or, until this box has a metrics
# transport (§MB2), to the fleet-split rule in argocd/resources/talos-substrate/.
check_nodes() {
  skip_requested nodes && { skipped nodes "SKIP requested"; return; }
  local statef="${MAIN_STATE:-/var/lib/mgmt/state/main/terraform.tfstate}"
  local tc="${TALOSCONFIG:-$REPO/tofu/talosconfig}"
  [ -f "$tc" ] || { skipped nodes "no talosconfig at $tc"; return; }
  local declared
  if [ -n "${NODE_TARGETS_JSON:-}" ]; then
    # The declared half, pre-fetched. Exists so the diff can be exercised from the jail (where the
    # main state deliberately is not) against the live fleet — `devbox run mgmt-tf -- output -json
    # node_install_targets > /tmp/d.json` then NODE_TARGETS_JSON=/tmp/d.json.
    declared="$(cat "$NODE_TARGETS_JSON")" || { failed nodes "cannot read $NODE_TARGETS_JSON"; return; }
  else
    [ -f "$statef" ] || { skipped nodes "no main state at $statef — this check runs on the box"; return; }
    declared="$(tool tofu -chdir=tofu output -state="$statef" -json node_install_targets)" || {
      failed nodes "tofu output node_install_targets failed: $(printf '%s' "$declared" | tail -2 | tr '\n' ' ')"; return; }
  fi
  # The output is a map node => {ip, class, installer, schematic, version}; anything else means the
  # output moved and this check is reading a shape that no longer exists.
  local rows
  rows="$(printf '%s' "$declared" | tool jq -r 'to_entries[] | [.key, .value.ip, .value.version, .value.schematic] | @tsv' 2>/dev/null)" || true
  [ -n "$rows" ] || { failed nodes "node_install_targets did not parse as the expected map"; return; }
  local n=0 drift=0 node ip dver dsch live_v live_s clean
  while IFS=$'\t' read -r node ip dver dsch; do
    [ -n "$node" ] || continue
    n=$((n+1))
    clean="$(tool talosctl --talosconfig "$tc" -n "$ip" version --short | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r//g')"
    live_v="$(printf '%s' "$clean" | awk '/Tag:/{for(i=1;i<=NF;i++) if($i ~ /^v[0-9]/){print $i; exit}}')"
    if [ -z "$live_v" ]; then
      # A declared node that does not answer at all is the EXTREME case of this diff, and the one
      # that went unseen for ~12 h on 2026-09-21 (wk-metal-02 declared, no Node object, nothing
      # fired). It is reported as its own axis, not folded into "version".
      DRIFT+=("$node reachable"); drift=$((drift+1)); continue
    fi
    DRIFT_OK+=("$node reachable")
    [ "$live_v" = "$dver" ] && DRIFT_OK+=("$node version") || { DRIFT+=("$node version"); drift=$((drift+1)); }
    live_s="$(tool talosctl --talosconfig "$tc" -n "$ip" get extensions | awk '$(NF-1)=="schematic"{print $NF; exit}')"
    if [ -z "$live_s" ]; then
      DRIFT+=("$node schematic"); drift=$((drift+1))
    elif [ "$live_s" = "$dsch" ]; then
      DRIFT_OK+=("$node schematic")
    else
      DRIFT+=("$node schematic"); drift=$((drift+1))
    fi
  done <<< "$rows"
  local detail=""
  [ "$drift" -gt 0 ] && detail=" — $(printf '%s, ' "${DRIFT[@]}" | sed 's/, $//')"
  passed nodes "$n declared, $drift axis-level gap(s)$detail"
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
  changed="$(printf '%s' "$out" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r//g' | awk -F'changed=' '/PLAY RECAP/{f=1} f&&NF>1{split($2,a," "); print a[1]; exit}')"
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
  # NixOS writes declared keys to /etc/ssh/authorized_keys.d/<user>, NOT ~/.ssh/authorized_keys
  # (found by the first live gate run, 2026-09-13: "locked out" on a box with two working keys).
  # Both locations count; sshd reads both.
  local n=0 f
  for f in /etc/ssh/authorized_keys.d/root /root/.ssh/authorized_keys; do
    [ -s "$f" ] || continue
    n=$((n + $(ssh-keygen -lf "$f" 2>/dev/null | grep -c . || true)))
  done
  if [ "$n" -ge 1 ]; then
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
  # "Can a future update or repair still land?" — NOT `[ -w /nix/store ]`: on NixOS the store is a
  # read-only bind mount by design (the daemon writes through its own remount), so that test fails
  # on every healthy box (first live gate run, 2026-09-13). The real properties: the daemon answers,
  # and the store's filesystem has headroom (default.nix sets nix.settings.min-free = 5 GiB).
  if [ ! -d /nix/store ]; then
    passed gate:store "no store (jail)"; return
  fi
  if ! nix --extra-experimental-features nix-command store info >/dev/null 2>&1; then
    failed gate:store "nix daemon does not answer"; return
  fi
  local free_kb
  free_kb="$(df -Pk /nix/store 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$free_kb" ] && [ "$free_kb" -lt $((5 * 1024 * 1024)) ]; then
    failed gate:store "only $((free_kb / 1024)) MiB free on the store — below min-free, no update can build"
  else
    passed gate:store "daemon answers, $((${free_kb:-0} / 1024 / 1024)) GiB free"
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
  # One series per (node, axis), both states present: a 0 is a positive statement that the node
  # was checked and matched, which "no series" cannot make.
  if [ ${#DRIFT[@]} -gt 0 ] || [ ${#DRIFT_OK[@]} -gt 0 ]; then
    body+="# TYPE mgmt_node_drift gauge"$'\n'
    local d
    for d in "${DRIFT[@]:-}";    do [ -n "$d" ] && body+="mgmt_node_drift{node=\"${d% *}\",axis=\"${d##* }\"} 1"$'\n'; done
    for d in "${DRIFT_OK[@]:-}"; do [ -n "$d" ] && body+="mgmt_node_drift{node=\"${d% *}\",axis=\"${d##* }\"} 0"$'\n'; done
  fi
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
    check_nodes
    check_ansible
    check_creds
    # devbox on the box (nixpkgs' 0.17.2) rewrites devbox.lock's plugin_version fields that the
    # jail's 0.17.5 wrote — package pins unchanged, but the checkout is left dirty (2026-09-13).
    # Put it back so the tree stays "what git says".
    git -C "$REPO" checkout -q -- devbox.lock 2>/dev/null || true
    publish
    log "belt: $PASS pass, $FAIL fail, $SKIPPED skip"
    [ "$FAIL" -eq 0 ]
    ;;
  *)
    log "FATAL unknown MODE='$MODE' (belt|gate)"; exit 1
    ;;
esac
