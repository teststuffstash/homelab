#!/usr/bin/env bash
# mgmt-helm-engines — the longhorn ENGINE MOVES in their own oneshot unit (FU-301, operator 2026-10-10;
# docs/management-box.md §MB3 "Helm release applies"). Started by the apply tick (`systemctl start
# --no-block mgmt-helm-engines.service`) when the chart is applied and v1 volumes are still on the old
# engine; never on a timer. The body is helm_lh_engines_run (mgmt-helm.sh): window → ⚓ lease (renewed
# on PROGRESS only — one converged volume, one budget, never past max-end) → the ordered moves (one
# patch per volume, then reads, bounded wait) → verdict → CONFIRM or STOP. Forward only: no revert, no
# retry, no remediation. A STOP marker keeps it shut; a stale lease of a dead run is a STOP, not a loop.
# Its own clone (/var/lib/mgmt/helm-engines) — the apply loop resets its clone on every master move.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"
# shellcheck source=mgmt-helm.sh
. "$HERE/mgmt-helm.sh"
ORG="${ORG:-teststuffstash}"; MGMT_REPO="${MGMT_REPO:-homelab}"
REPO_URL="${MGMT_REPO_URL:-https://github.com/${ORG}/${MGMT_REPO}.git}"
EDIR="${MGMT_HELM_ENGINES_DIR:-/var/lib/mgmt/helm-engines}"
REPO="$EDIR/homelab"; export REPO
ADIR="${MGMT_APPLY_DIR:-/var/lib/mgmt/apply}"; export ADIR   # the STOP marker lives with the apply loop's (one gauge)
mkdir -p "$EDIR"
mgmt_clone "$REPO" "$REPO_URL" || { log "PROBE-FAIL: clone/fetch failed"; exit 1; }
mgmt_tree_path "$REPO" || log "WARN a tree-locked tool is unresolvable from $REPO/devbox.lock (why above)"
sha="$(git -C "$REPO" rev-parse origin/master)" || exit 1
POL="$(mgmt_policy_load "$REPO" origin/master)" || exit 1
trap 'rm -f "$POL"' EXIT
held="$(mgmt_apply_window_gate)"; wrc=$?
if [ "$wrc" != 0 ]; then log "helm: engines — a declared window holds (or the registry is unreadable): $(tr '\n' ';' <<<"$held") — not begun; the next apply tick re-starts this unit"; exit 0; fi
helm_lh_engines_run "$POL" main "$sha"; rc=$?
case $rc in 0) log "helm: engines — done" ;; 2) log "helm: engines — STOPPED (marker written)" ;; *) log "helm: engines — not begun" ;; esac
exit 0
