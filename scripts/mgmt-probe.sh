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
#   scripts/mgmt-probe.sh                  # belt: every applicable check, metrics to the textfile dir
#   MODE=gate scripts/mgmt-probe.sh        # the box-local gate (what mgmt-confirm.service runs)
#   DRY_RUN=1 scripts/mgmt-probe.sh        # never publish (the textfile dir is absent in the jail anyway)
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
#   MGMT_TEXTFILE_DIR  node_exporter textfile dir (default /var/lib/node-exporter-textfile); absent
#                 means "do not publish" — the jail-safe default, as the dir exists only on the box
#   TALOS_NODE    a node IP for the client/server skew check (default: the first control plane)
#   TALOSCONFIG / KUBECONFIG   where the file-shaped creds are (box: /var/lib/mgmt/*, set by the env
#                 file scripts/mgmt-provision-secrets.sh writes; jail default: tofu/{talos,kube}config)
#   SKIP          space-separated check names to skip: tofu talos nodes ansible creds substrate
#   GITHUB_TOKEN  the read-only PAT the env file already carries for tofu/github — also used to
#                 authenticate the substrate check's upstream release reads (5000/hr vs 60/hr);
#                 absent or insufficient falls back to anonymous
#   MGMT_CACHE_DIR     where the substrate check caches the upstream release answer (default
#                 /var/lib/mgmt/cache; falls back to $TMPDIR when that is not writable)
#   MAIN_STATE    main root's state file (default /var/lib/mgmt/state/main/terraform.tfstate)
#   NODE_TARGETS_JSON  pre-fetched `node_install_targets` JSON — runs the node diff off the box
#   NODE_K8S_JSON      pre-fetched `node_declared_k8s` JSON — the same for the registered/labels/
#                      taints axes. With NODE_TARGETS_JSON set and this unset, those axes are NOT
#                      checked: the two halves of a declaration must come from the same source (the
#                      sentinel passes a PR head's node_install_targets alone)
#   NODE_DRIFT_OUT     write the node diff's (node, axis) verdicts here, one "<node> <axis>\t<drift|ok>"
#                      per line — how the management sentinel reuses THIS diff for its install-impact
#                      line (NODE_TARGETS_JSON = the PR head's declaration; ADR-132 §MB4 layer 2)
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
TALOS_NODE="${TALOS_NODE:-192.168.2.51}"
SKIP="${SKIP:-}"
DRY_RUN="${DRY_RUN:-0}"
MODE="${MODE:-belt}"

PASS=0 FAIL=0 SKIPPED=0
declare -a RESULTS=()
# The node diff publishes per-node gauges rather than one pass/fail, so it accumulates its own
# (node, axis) pairs: DRIFT = declared and live disagree, DRIFT_OK = they match.
declare -a DRIFT=() DRIFT_OK=()
# The substrate-currency check (FU-254) accumulates one "<component> <behind> <supported> <fetched>"
# row per component it could actually compare; a component it could not fetch contributes none.
declare -a SUBSTRATE=()

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
# belongs to the alerts with a `for:` that read mgmt_node_drift (argocd/resources/mgmt-metrics/;
# the version axis stays with the fleet-split rule in argocd/resources/talos-substrate/).
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
    # ⚠ The box's OWN checkout has never had the main root initialised — only the apply clone
    # (/var/lib/mgmt/apply/homelab) is, because that is where mgmt-tf and mgmt-apply run. The
    # first real run of this check on the box therefore died with "Required plugins are not
    # installed" (2026-09-21, found by starting mgmt-belt by hand right after #1828 merged).
    # Decided UP FRONT from the missing directory, exactly as check_tofu does — not by retrying
    # on any failure, which would also swallow a real regression (review, #1831): a renamed or
    # removed `node_install_targets` must stay a loud FAIL.
    if [ ! -d "$REPO/tofu/.terraform" ]; then
      log "nodes: main root not initialised in this checkout — init once (-lockfile=readonly)"
      if ! tool tofu -chdir=tofu init -input=false -lockfile=readonly >/dev/null; then
        # The one case that is a tool problem rather than a finding (the sentinel's 2026-08-19
        # discrimination): the probe could not read its input, so it has not seen the fleet.
        # Visible on its own terms as mgmt_probe_check{check="nodes",status="skip"}.
        skipped nodes "cannot initialise the main root in this checkout — declaration unreadable"; return
      fi
    fi
    declared="$(tool tofu -chdir=tofu output -state="$statef" -json node_install_targets)" || {
      failed nodes "tofu output node_install_targets failed: $(printf '%s' "$declared" | tail -2 | tr '\n' ' ')"; return; }
  fi
  # The output is a map node => {ip, class, installer, schematic, version}; anything else means the
  # output moved and this check is reading a shape that no longer exists.
  # EPHEMERAL placement's declared half rides node_install_targets (`.ephemeral.disk_selector`,
  # #1858). "?" = the field is absent (a state written before that output grew it) → not checked,
  # never read as "no selector", which would false-drift nx-01.
  local nk sk
  while IFS=$'\t' read -r nk sk; do [ -n "$nk" ] && DK_SEL[$nk]="$sk"; done \
    <<< "$(printf '%s' "$declared" | tool jq -r 'to_entries[] | [.key, (if (.value | has("ephemeral")) then (.value.ephemeral.disk_selector // "-") else "?" end)] | @tsv' 2>/dev/null)"
  # The Kubernetes-facing half (registered/labels/taints) is its own output, so a missing one
  # degrades those axes to "not checked" without touching the others.
  local dk="" k8s_note=""
  if [ -n "${NODE_TARGETS_JSON:-}" ] && [ -z "${NODE_K8S_JSON:-}" ]; then
    k8s_note=" (registered/labels/taints not checked: no NODE_K8S_JSON beside NODE_TARGETS_JSON)"
  else
    dk="$(node_declared_k8s "$statef")"
    [ -n "$dk" ] || k8s_note=" (registered/labels/taints not checked)"
  fi
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
    # EPHEMERAL placement (install-time, nx-01 2026-09-16).
    case "${DK_SEL[$node]-?}" in
      "?") log "nodes: $node declares no .ephemeral (pre-#1858 state) — ephemeral_disk not checked" ;;
      -)   node_ephemeral_disk "$node" "$ip" "" && drift=$((drift+EPH_GAP)) ;;
      *)   node_ephemeral_disk "$node" "$ip" "${DK_SEL[$node]}" && drift=$((drift+EPH_GAP)) ;;
    esac
  done <<< "$rows"
  [ -n "$dk" ] && { node_k8s_axes "$dk"; drift=$((drift+K8S_GAPS)); }
  local detail=""
  [ "$drift" -gt 0 ] && detail=" — $(printf '%s, ' "${DRIFT[@]}" | sed 's/, $//')"
  passed nodes "$n declared, $drift axis-level gap(s)${k8s_note}$detail"
}

# ── node diff, the Kubernetes-facing axes (FU-235's second step) ───────────────────────────────
# DECLARED = `tofu output node_declared_k8s` (tofu/outputs.tf — the labels/taints tofu itself
# declares) and node_install_targets' `.ephemeral.disk_selector`; LIVE = the Node objects (kubectl) and the Talos
# `volumestatus` / `systemdisk` / `disks` resources. Axes, one gauge each per node:
#   registered      a Node object exists — the wk-metal-02 case (2026-09-21): the machine
#                   answered talosctl, the cluster had no Node for ~12 h
#   labels / taints compared over the UNION of the keys any node declares, so a declared key
#                   missing live and an undeclared one present live (an imperative
#                   `kubectl label`) are both drift; keys nobody declares are not looked at
#   ephemeral_disk  EPHEMERAL sits where the VolumeConfig says: no selector = the system disk;
#                   a selector = OFF the system disk AND, for the `disk.<field> == "<value>"` form
#                   (the only one in machines.yaml), that disk's field matching
# A read failure (kubectl, a talosctl get) emits NO series for that axis rather than a 1: the
# probe did not see the fleet, and a false drift is worse than an absent one (the stale-belt
# alert watches the probe itself).
declare -A DK_SEL=()
EPH_GAP=0 K8S_GAPS=0

# Read the declaration once. Prints the JSON, or nothing (with a log line) when it is unreadable.
node_declared_k8s() {
  local statef="$1" out
  if [ -n "${NODE_K8S_JSON:-}" ]; then
    cat "$NODE_K8S_JSON" 2>/dev/null || log "nodes: cannot read NODE_K8S_JSON=$NODE_K8S_JSON"
    return
  fi
  [ -f "$statef" ] || return 0
  out="$(tool tofu -chdir=tofu output -state="$statef" -json node_declared_k8s)" || {
    # Transitional, and named: the output exists in git before the apply loop has written it
    # into the state (it applies output-only plans on its next tick, mgmt-apply.sh).
    log "nodes: node_declared_k8s unreadable — registered/labels/taints axes not checked: $(printf '%s' "$out" | tail -1)"
    return 0; }
  printf '%s' "$out" | tool jq -e 'type == "object"' >/dev/null 2>&1 || {
    log "nodes: node_declared_k8s is not a map — registered/labels/taints axes not checked"; return 0; }
  printf '%s' "$out"
}

node_ephemeral_disk() {
  local node="$1" ip="$2" sel="$3" tc="${TALOSCONFIG:-$REPO/tofu/talosconfig}" parent sysd field want got
  EPH_GAP=0
  parent="$(tool talosctl --talosconfig "$tc" -n "$ip" get volumestatus EPHEMERAL -o jsonpath='{.spec.parentLocation}' | grep -o '/dev/[A-Za-z0-9._/-]*' | tail -1)"
  sysd="$(tool talosctl --talosconfig "$tc" -n "$ip" get systemdisk -o jsonpath='{.spec.devPath}' | grep -o '/dev/[A-Za-z0-9._/-]*' | tail -1)"
  if [ -z "$parent" ] || [ -z "$sysd" ]; then
    log "nodes: $node EPHEMERAL/system disk unreadable — ephemeral_disk not checked"; return 1
  fi
  if [ -z "$sel" ]; then
    [ "$parent" = "$sysd" ] && { DRIFT_OK+=("$node ephemeral_disk"); return 0; }
    log "nodes: $node EPHEMERAL on $parent, declared on the system disk ($sysd)"
    DRIFT+=("$node ephemeral_disk"); EPH_GAP=1; return 0
  fi
  if [ "$parent" = "$sysd" ]; then
    log "nodes: $node EPHEMERAL on the system disk $sysd, declared off it ($sel)"
    DRIFT+=("$node ephemeral_disk"); EPH_GAP=1; return 0
  fi
  if [[ "$sel" =~ ^[[:space:]]*disk\.([a-z_]+)[[:space:]]*==[[:space:]]*\"([^\"]*)\"[[:space:]]*$ ]]; then
    field="${BASH_REMATCH[1]}"; want="${BASH_REMATCH[2]}"
    got="$(tool talosctl --talosconfig "$tc" -n "$ip" get disks "${parent#/dev/}" -o jsonpath="{.spec.$field}" | tail -1 | tr -d '\r')"
    if [ "$got" = "$want" ]; then DRIFT_OK+=("$node ephemeral_disk")
    else log "nodes: $node EPHEMERAL on $parent ($field=$got), declared $sel"; DRIFT+=("$node ephemeral_disk"); EPH_GAP=1; fi
  else
    # A selector this parser does not model: the off-system-disk half above is all it asserts.
    log "nodes: $node selector '$sel' not modelled — asserted only that EPHEMERAL is off the system disk"
    DRIFT_OK+=("$node ephemeral_disk")
  fi
  return 0
}

node_k8s_axes() {
  local dk="$1" live rows node reg ldiff tdiff
  K8S_GAPS=0
  # A FILE, not --argjson: the Node list (status.images included) is past the kernel's 128 KiB
  # single-argument limit. stderr dropped, not merged (tool() merges it): a kubectl warning would
  # corrupt the JSON.
  # --kubeconfig EXPLICIT, like --talosconfig everywhere above: devbox.json's env block sets
  # KUBECONFIG=$PWD/tofu/kubeconfig inside `devbox run`, overriding the box's /var/lib/mgmt one —
  # the first box run hit localhost:8080 (2026-09-21; the jail has tofu/kubeconfig, so it passed).
  live="$(mktemp)" || return 0
  devbox run --quiet -- kubectl --kubeconfig "${KUBECONFIG:-$REPO/tofu/kubeconfig}" get nodes -o json >"$live" 2>/dev/null
  tool jq -e '.items | type == "array"' "$live" >/dev/null 2>&1 || {
    rm -f "$live"; log "nodes: kubectl get nodes failed — registered/labels/taints axes not checked"; return 0; }
  # One row per declared node: name, present|absent, label diff, taint diff ("-" = none — bash
  # `read` collapses empty tab-separated fields).
  # The program goes in a FILE too: `devbox run` re-parses its arguments through a shell, which
  # expanded every jq `$var` to nothing and joined the lines (found running this from the jail).
  local prog; prog="$(mktemp)" || { rm -f "$live"; return 0; }
  cat >"$prog" <<'JQ'
. as $d
| ([$d[].labels | keys[]] | unique) as $lk
| ([$d[].taints[] | sub("=.*"; "")] | unique) as $tk
| ($live[0].items | map({key: .metadata.name, value: .}) | from_entries) as $L
| $d | to_entries[] | .key as $n | .value as $v
| if $L[$n] == null then [$n, "absent", "-", "-"]
  else
    ($L[$n].metadata.labels // {}) as $ll
    | ([$lk[] | select(($ll[.] // null) != ($v.labels[.] // null))
        | "\(.) declared=\($v.labels[.] // "none") live=\($ll[.] // "none")"] | join("; ")) as $ld
    | ([$L[$n].spec.taints[]? | "\(.key)=\(.value // ""):\(.effect)"
        | select(sub("=.*"; "") as $k | any($tk[]; . == $k))] | sort) as $lt
    | ($v.taints | sort) as $dt
    | [$n, "present", (if $ld == "" then "-" else $ld end),
       (if $lt == $dt then "-" else "declared=\($dt | join(",")) live=\($lt | join(","))" end)]
  end
| @tsv
JQ
  rows="$(printf '%s' "$dk" | tool jq -r --slurpfile live "$live" -f "$prog")" || {
    rm -f "$live" "$prog"; log "nodes: the k8s diff did not evaluate — registered/labels/taints axes not checked"; return 0; }
  rm -f "$live" "$prog"
  while IFS=$'\t' read -r node reg ldiff tdiff; do
    [ -n "$node" ] || continue
    if [ "$reg" = absent ]; then
      DRIFT+=("$node registered"); K8S_GAPS=$((K8S_GAPS+1)); continue
    fi
    DRIFT_OK+=("$node registered")
    if [ "$ldiff" = "-" ]; then DRIFT_OK+=("$node labels")
    else DRIFT+=("$node labels"); K8S_GAPS=$((K8S_GAPS+1)); log "nodes: $node labels: $ldiff"; fi
    if [ "$tdiff" = "-" ]; then DRIFT_OK+=("$node taints")
    else DRIFT+=("$node taints"); K8S_GAPS=$((K8S_GAPS+1)); log "nodes: $node taints: $tdiff"; fi
  done <<< "$rows"
}

# ── check: is the declared substrate still current, and still in support? (FU-254) ───────────────
# The belt's other checks ask "does live match git". This one asks the question NOTHING asked
# before: **does git still match the world.** Talos 1.13 left community support at the 1.14.0
# release (2026-09-03) and the fleet learned it from a conversation. Renovate cannot fill the gap —
# class 6 in docs/dependency-upgrades.md is deliberately "must not auto-deploy", and Renovate opens
# no homelab PRs at all.
#
# DECLARED = the `default` of the tofu variables in tofu/variables.tf, read straight out of the
# CHECKOUT. Deliberately NOT a `tofu output`: no output carries kubernetes_version or
# cilium_version, and node_install_targets needs the main state + an initialised root (the box's
# own checkout has neither — check_nodes carries that scar). Git is the declaration here, so a
# plain HCL read of the four defaults is both sufficient and credential-free.
#
# UPSTREAM = the GitHub releases of each project, filtered to real releases (draft/prerelease
# dropped, and again by an `X.Y.Z`-only tag match so an `-rc`/`-beta` tag mislabelled upstream
# cannot sneak in). Cached on disk with a TTL — see SUBSTRATE_CACHE_TTL below.
#
# ⚠ It REPORTS, it never FAILS the probe — the check_nodes rule. "A minor behind" is the normal
# state of a fleet between windows, and a belt that reds the box for it teaches everyone to ignore
# it. The judgement of "too long" belongs to the `for:` of MgmtSubstrateBehind /
# MgmtSubstrateUnsupported (argocd/resources/mgmt-metrics/).
check_substrate() {
  skip_requested substrate && { skipped substrate "SKIP requested"; return; }

  # ══ OPERATOR-VISIBLE CONSTANTS — the upstream support policies, encoded by hand ═══════════════
  # Nothing here discovers a policy; each number is a SUPPORTED MINOR COUNT (the current minor
  # included), so "EOL" means `minors_behind >= count`. **If an upstream changes its policy, this
  # table is the one place to correct it** — a wrong number here makes the EOL gauge lie quietly.
  #   siderolabs/talos    1 — ONLY the current minor has community support: the support matrix
  #                           gives 1.13's "End of Community Support" as the 1.14.0 RELEASE DATE
  #                           (and 1.12's as 1.13.0's). One minor behind is already EOL — which is
  #                           precisely the 2026-09-03 case this check exists for, so a `2` here
  #                           would miss it by a whole release cycle (review finding, #1949).
  #                           Consequence, deliberate: Talos can never be `Behind`-but-supported,
  #                           so it skips MgmtSubstrateBehind's 7-day grace and goes straight to
  #                           MgmtSubstrateUnsupported. That is what the policy says.
  #   kubernetes/kubernetes 3 — the three most recent minors receive patch releases (EOL at n-3).
  #   cilium/cilium       3 — the three most recent minors receive fixes (EOL at n-3).
  # Columns: component label | GitHub repo | tofu variable | supported minors.
  local components=(
    "talos-controlplane|siderolabs/talos|talos_version_controlplane|1"
    "talos-worker|siderolabs/talos|talos_version_worker|1"
    "kubernetes|kubernetes/kubernetes|kubernetes_version|3"
    "cilium|cilium/cilium|cilium_version|3"
  )

  [ -f "$REPO/tofu/variables.tf" ] || { skipped substrate "no tofu/variables.tf in this checkout"; return; }

  local row comp repo var window declared ours upstream minors fetched behind supported
  local n=0 nbehind=0 neol=0 unread=() detail=""
  for row in "${components[@]}"; do
    IFS='|' read -r comp repo var window <<< "$row"
    declared="$(substrate_declared "$var")"
    if [ -z "$declared" ]; then
      # A RENAMED OR DELETED variable must be loud, not silently "not checked" (the #1831
      # discrimination): the declaration this belt exists to compare has moved.
      failed substrate "tofu/variables.tf has no readable default for var.$var"
      return
    fi
    ours="$(printf '%s' "$declared" | sed 's/^v//' | cut -d. -f1,2)"
    # ⚠ The answer comes back as ONE string, timestamp first — NOT through a global: this runs in
    # a command substitution, i.e. a SUBSHELL, so a variable the callee sets never reaches here
    # (the first fixture run published a fetched-timestamp of 0 for every component).
    if ! upstream="$(substrate_upstream_minors "$repo")"; then
      # The probe could not look at upstream and has no cached answer. NO series for this
      # component — an absent gauge, never a false "current" (the mgmt_node_drift rule).
      unread+=("$comp"); continue
    fi
    fetched="$(printf '%s\n' "$upstream" | head -1)"
    minors="$(printf '%s\n' "$upstream" | tail -n +2)"
    [ -n "$minors" ] && [ -n "$fetched" ] || { unread+=("$comp"); continue; }
    # How many distinct upstream minors are strictly newer than ours. ⚠ Bounded by the release
    # page (100 entries): if our minor predates the whole page this is a LOWER bound — which only
    # under-reports when we are already many minors past EOL, where the EOL gauge is 0 regardless.
    behind="$(printf '%s\n' "$minors" | awk -F. -v om="$ours" '
      BEGIN { split(om, o, ".") }
      NF == 2 && (($1 + 0) > (o[1] + 0) || (($1 + 0) == (o[1] + 0) && ($2 + 0) > (o[2] + 0))) { c++ }
      END { print c + 0 }')"
    supported=1
    [ "$behind" -ge "$window" ] && supported=0
    SUBSTRATE+=("$comp $behind $supported $fetched")
    n=$((n + 1))
    [ "$behind" -gt 0 ] && { nbehind=$((nbehind + 1)); detail="$detail, $comp $declared is $behind minor(s) behind"; }
    [ "$supported" -eq 0 ] && { neol=$((neol + 1)); log "substrate: $comp $declared is EOL — $behind minor(s) behind, upstream supports $window"; }
  done

  if [ "$n" -eq 0 ]; then
    skipped substrate "upstream release lists unreachable and nothing cached (${unread[*]:-all})"
    return
  fi
  [ ${#unread[@]} -gt 0 ] && detail="$detail, not checked: ${unread[*]}"
  passed substrate "$n component(s) compared, $nbehind behind, $neol out of support${detail}"
}

# The declared half: the `default` of one variable in tofu/variables.tf. An HCL read, not `tofu
# output` (see check_substrate's header for why). Prints nothing when the variable or its default
# is absent — which the caller treats as a FAIL, not as "not checked".
substrate_declared() {
  local name="$1"
  awk -v v="$name" '
    $0 ~ ("^variable[[:space:]]+\"" v "\"[[:space:]]*\\{") { inb = 1; next }
    inb && /^}/ { exit }
    inb && /^[[:space:]]*default[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      gsub(/"/, "")
      sub(/[[:space:]]+$/, "")
      print; exit
    }
  ' "$REPO/tofu/variables.tf"
}

# ⚠ CACHE, and it is not an optimisation. The belt runs every 15 minutes (nixos/hosts/mgmt:
# mgmt-belt.timer, OnCalendar=*:0/15) = 96 runs a day; three upstream repos fetched every tick is
# ~288 GitHub API calls a day for an answer that changes a few times a YEAR, and unauthenticated
# the per-IP budget is 60/hour for the whole box. **6 h** (below): 3 repos × 4 refreshes = 12 calls
# a day, and a new upstream minor is at most 6 h old before the belt sees it — two orders of
# magnitude finer than MgmtSubstrateBehind's 7-day `for:`, so the TTL is never the limiting term.
SUBSTRATE_CACHE_TTL="${SUBSTRATE_CACHE_TTL:-21600}"   # 6 h, in seconds
SUBSTRATE_CACHE_DIR="${SUBSTRATE_CACHE_DIR:-${MGMT_CACHE_DIR:-/var/lib/mgmt/cache}}"

# <owner/repo> → the unix time the answer was fetched on the FIRST line, then the distinct
# released MINORs ("X.Y", one per line). One stream, because the caller reads it through a command
# substitution and a subshell cannot hand a variable back. Non-zero exit = no answer at all (no
# network AND no cache), which the caller turns into "no series", never a value.
#
# A refresh that FAILS while a cached answer exists serves the cache: the answer is at most one
# TTL stale, and its true age is published as mgmt_substrate_upstream_fetched_timestamp_seconds —
# so a GitHub blip degrades the freshness series, not the verdict.
substrate_upstream_minors() {
  local repo="$1" cache now age raw
  mkdir -p "$SUBSTRATE_CACHE_DIR" 2>/dev/null || SUBSTRATE_CACHE_DIR="${TMPDIR:-/tmp}/mgmt-substrate-cache"
  mkdir -p "$SUBSTRATE_CACHE_DIR" 2>/dev/null || return 1
  cache="$SUBSTRATE_CACHE_DIR/$(printf '%s' "$repo" | tr '/' '_').minors"
  now="$(date -u +%s)"
  if [ -s "$cache" ]; then
    age=$((now - $(stat -c %Y "$cache" 2>/dev/null || echo 0)))
    if [ "$age" -lt "$SUBSTRATE_CACHE_TTL" ]; then
      stat -c %Y "$cache" 2>/dev/null || echo 0
      cat "$cache"; return 0
    fi
  fi
  # AUTHENTICATED when the box has a token (GITHUB_TOKEN — the read-only `github-mgmt-readonly-pat`
  # the env file already carries for tofu/github, docs/management-box.md §Credentials): 5000/hour
  # instead of 60. It is a FINE-GRAINED PAT owned by teststuffstash, so its reach over another
  # org's public repo is not guaranteed — an authenticated attempt that comes back empty retries
  # anonymously rather than reporting upstream as unreachable.
  local url="https://api.github.com/repos/$repo/releases?per_page=100"
  raw=""
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    raw="$(_substrate_curl -H "Authorization: Bearer $GITHUB_TOKEN" "$url")" || raw=""
  fi
  [ -n "$raw" ] || raw="$(_substrate_curl "$url")" || raw=""
  local parsed=""
  if [ -n "$raw" ]; then
    # Real releases only: not draft, not prerelease, AND an exact X.Y.Z tag — belt and braces,
    # because an upstream that forgets the prerelease flag on an `-rc` tag would otherwise read as
    # a new minor and page the fleet over a release candidate.
    parsed="$(printf '%s' "$raw" | _substrate_jq -r '
        .[]? | select((.draft // false) == false and (.prerelease // false) == false) | .tag_name' 2>/dev/null \
      | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | awk -F. '{ print $1 "." $2 }' \
      | sort -u -t. -k1,1n -k2,2n)"
  fi
  if [ -n "$parsed" ]; then
    printf '%s\n' "$parsed" >"$cache" 2>/dev/null || true
    printf '%s\n' "$now"
    printf '%s\n' "$parsed"; return 0
  fi
  if [ -s "$cache" ]; then
    # ⚠ >&2 on every log in THIS function: it prints its answer on stdout inside the caller's
    # command substitution, so an unredirected log line would become the answer's first line.
    log "substrate: $repo refresh failed — serving the cached answer from $(date -u -d "@$(stat -c %Y "$cache")" +%FT%TZ 2>/dev/null || echo unknown)" >&2
    stat -c %Y "$cache" 2>/dev/null || echo 0
    cat "$cache"; return 0
  fi
  log "substrate: $repo release list unreachable and nothing cached — no series for it" >&2
  return 1
}

# curl and jq are in the belt unit's closure (nixos/hosts/mgmt/default.nix) but not on the jail's
# bare PATH; devbox is the other way round. Try the binary, fall back to the pinned one — and NOT
# through tool(), which merges stderr into stdout and would corrupt the JSON.
_substrate_curl() {
  if have curl; then curl -fsS --max-time 30 -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" "$@" 2>/dev/null
  else devbox run --quiet -- curl -fsS --max-time 30 -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" "$@" 2>/dev/null; fi
}
_substrate_jq() {
  if have jq; then jq "$@"; else devbox run --quiet -- jq "$@"; fi
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

# NODE_DRIFT_OUT: the diff's verdicts as data, for a caller that is not Prometheus (mgmt-sentinel.sh)
dump_drift() {
  [ -n "${NODE_DRIFT_OUT:-}" ] || return 0
  local d
  { for d in "${DRIFT[@]:-}";    do [ -n "$d" ] && printf '%s\tdrift\n' "$d"; done
    for d in "${DRIFT_OK[@]:-}"; do [ -n "$d" ] && printf '%s\tok\n' "$d"; done; } >"$NODE_DRIFT_OUT" || true
}

# ── publish ─────────────────────────────────────────────────────────────────────────────────────
# Same shape as the Garage write probe: the verdict AND a last-run timestamp, so a staleness alert
# catches "the box is wedged" and not only "the box says no". TRANSPORT (FU-252, ruled 2026-09-21):
# node_exporter's textfile collector on the box, scraped by the cluster Prometheus as the static
# job `mgmt-node` (argocd/resources/mgmt-metrics/) — the same one mgmt-apply.sh writes through.
# One file PER MODE with a `mode` label, so the gate and the belt never overwrite each other.
TEXTDIR="${MGMT_TEXTFILE_DIR:-/var/lib/node-exporter-textfile}"
publish() {
  local ts; ts="$(date -u +%s)"
  if [ "$DRY_RUN" = "1" ] || [ ! -d "$TEXTDIR" ]; then
    log "not publishing (DRY_RUN=$DRY_RUN, textfile dir $TEXTDIR $([ -d "$TEXTDIR" ] && echo present || echo absent))"
    return 0
  fi
  local m="mode=\"$MODE\"" body=""
  body+="# HELP mgmt_probe_last_run_timestamp Unix time the probe last finished (any verdict)."$'\n'
  body+="# TYPE mgmt_probe_last_run_timestamp gauge"$'\n'
  body+="mgmt_probe_last_run_timestamp{$m} $ts"$'\n'
  body+="# HELP mgmt_probe_checks Checks by result in the last run."$'\n'
  body+="# TYPE mgmt_probe_checks gauge"$'\n'
  body+="mgmt_probe_checks{$m,result=\"pass\"} $PASS"$'\n'
  body+="mgmt_probe_checks{$m,result=\"fail\"} $FAIL"$'\n'
  body+="mgmt_probe_checks{$m,result=\"skip\"} $SKIPPED"$'\n'
  body+="# HELP mgmt_probe_check 1 per check of the last run, labelled with its status."$'\n'
  body+="# TYPE mgmt_probe_check gauge"$'\n'
  local r name status
  for r in "${RESULTS[@]}"; do
    name="${r% *}"; status="${r##* }"
    body+="mgmt_probe_check{$m,check=\"$name\",status=\"$status\"} 1"$'\n'
  done
  # One series per (node, axis), both states present: a 0 is a positive statement that the node
  # was checked and matched, which "no series" cannot make.
  if [ ${#DRIFT[@]} -gt 0 ] || [ ${#DRIFT_OK[@]} -gt 0 ]; then
    body+="# HELP mgmt_node_drift 1 = declared and live disagree on this axis, 0 = checked and matched (FU-235)."$'\n'
    body+="# TYPE mgmt_node_drift gauge"$'\n'
    local d
    for d in "${DRIFT[@]:-}";    do [ -n "$d" ] && body+="mgmt_node_drift{node=\"${d% *}\",axis=\"${d##* }\"} 1"$'\n'; done
    for d in "${DRIFT_OK[@]:-}"; do [ -n "$d" ] && body+="mgmt_node_drift{node=\"${d% *}\",axis=\"${d##* }\"} 0"$'\n'; done
  fi
  # FU-254 — the substrate-currency gauges. Same rule as mgmt_node_drift: a 0 is a POSITIVE
  # statement ("compared, and current" / "compared, and supported"), which "no series" cannot make,
  # so every component that was actually compared publishes all three; a component whose upstream
  # answer could not be obtained publishes none.
  if [ ${#SUBSTRATE[@]} -gt 0 ]; then
    body+="# HELP mgmt_substrate_minors_behind Upstream MINOR releases newer than the declared version (0 = current)."$'\n'
    body+="# TYPE mgmt_substrate_minors_behind gauge"$'\n'
    local srow scomp sbehind ssup sfetched
    for srow in "${SUBSTRATE[@]}"; do
      read -r scomp sbehind ssup sfetched <<< "$srow"
      body+="mgmt_substrate_minors_behind{component=\"$scomp\"} $sbehind"$'\n'
    done
    body+="# HELP mgmt_substrate_supported 1 = the declared minor is inside the project's support window, 0 = EOL."$'\n'
    body+="# TYPE mgmt_substrate_supported gauge"$'\n'
    for srow in "${SUBSTRATE[@]}"; do
      read -r scomp sbehind ssup sfetched <<< "$srow"
      body+="mgmt_substrate_supported{component=\"$scomp\"} $ssup"$'\n'
    done
    body+="# HELP mgmt_substrate_upstream_fetched_timestamp_seconds Unix time the cached upstream release list was fetched."$'\n'
    body+="# TYPE mgmt_substrate_upstream_fetched_timestamp_seconds gauge"$'\n'
    for srow in "${SUBSTRATE[@]}"; do
      read -r scomp sbehind ssup sfetched <<< "$srow"
      body+="mgmt_substrate_upstream_fetched_timestamp_seconds{component=\"$scomp\"} $sfetched"$'\n'
    done
  fi
  # Atomic (tmp + rename in the same dir — the collector must never read a half file). Never fail
  # the probe on a reporting failure: the deadman's verdict is about the BOX, and Prometheus is
  # in-cluster — exactly the thing that may be down. (The staleness alert notices, from the other side.)
  local tmp
  if tmp="$(mktemp "$TEXTDIR/.mgmt_probe_$MODE.XXXXXX" 2>/dev/null)" \
      && printf '%s' "$body" >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$TEXTDIR/mgmt_probe_$MODE.prom"; then
    log "published $TEXTDIR/mgmt_probe_$MODE.prom"
  else
    [ -n "${tmp:-}" ] && rm -f "$tmp"
    log "WARN could not write metrics (reporting only, verdict unaffected)"
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
    dump_drift
    check_ansible
    check_creds
    check_substrate
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
