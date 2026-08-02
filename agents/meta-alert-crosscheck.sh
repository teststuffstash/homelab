#!/usr/bin/env bash
# meta-alert-crosscheck — the belt FOR the belts (meta-coordinate heartbeat sweep, 2026-07-27).
#
# The responder (FU-103 v2) turns firing alerts into triage sessions; but when the responder
# MACHINERY is what broke (EventSource down, Sensor dead, subscription latch stuck, ledger RBAC),
# no event ever fires — and silence looks like health. This script is level-triggered and reads
# DIFFERENT surfaces than the event path: Alertmanager's API (what is firing) vs the
# responder-seen ledger (what got triaged). A firing, triage-eligible alert older than the grace
# window with NO ledger entry = the responder is stuck → the meta session investigates the
# machinery (EventSource/Sensor/latch), never hand-triages the alert first.
#
# Output: one line per discrepancy (empty + exit 0 = belts healthy). Loud probe failures per
# rule #6 — a dead Alertmanager/apiserver read is ITSELF the finding.
set -euo pipefail

AM_URL="${AM_URL:-http://192.168.40.14:9093}"
GRACE_MIN="${GRACE_MIN:-15}"

# kubectl resolution: jail (devbox profile + tofu/kubeconfig) vs in-cluster (bare, SA auth) —
# the agent-session.sh pattern.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${HERE}/../tofu/kubeconfig" ]; then KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"; else KUBE=""; fi
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"
kubectl() { "$KUBECTL" $KUBE "$@"; }

ALERTS="$(curl -fsS --max-time 10 "$AM_URL/api/v2/alerts?active=true&silenced=false&inhibited=false" 2>/dev/null)" \
  || { echo "PROBE_FAILED: Alertmanager unreachable at $AM_URL — that is itself the incident"; exit 1; }

# FU-113(a): marker values (deferred-/cap-/none- prefixes) mean SEEN-BUT-NOT-TRIAGED — they
# explain the machinery but do not settle the alert. Split the ledger accordingly.
LEDGER_JSON="$(kubectl -n agent-coordinator get cm responder-seen -o json 2>/dev/null | jq -c '.data // {}' 2>/dev/null)" || LEDGER_JSON='{}'
LEDGER="$(printf '%s' "$LEDGER_JSON" | jq -r 'to_entries[] | select(.value | test("^(deferred-|cap-|none-)") | not) | .key' | tr '\n' ' ')"
MARKED="$(printf '%s' "$LEDGER_JSON" | jq -r 'to_entries[] | select(.value | test("^(deferred-|cap-)")) | "\(.key)=\(.value)"' | tr '\n' ' ')"
NONE_MARKED="$(printf '%s' "$LEDGER_JSON" | jq -r 'to_entries[] | select(.value | test("^none-")) | .key' | tr '\n' ' ')"
[ -n "$LEDGER$MARKED$NONE_MARKED" ] || echo "NOTE: responder-seen ledger empty/unreadable — every eligible alert below is unexplained"

CUTOFF="$(date -u -d "-${GRACE_MIN} minutes" +%Y-%m-%dT%H:%M:%SZ)"
FOUND=0
while IFS=$'\t' read -r fp name started; do
  [ -n "$fp" ] || continue
  case " $LEDGER " in
    *" fp-$fp "*) : ;;  # triaged — healthy
    *)
      case " $NONE_MARKED " in *" fp-$fp "*) continue;; esac  # triage:none — self-describing
      case " $MARKED " in
        *" fp-$fp="*)
          FOUND=1
          MV="$(printf '%s' "$MARKED" | grep -o "fp-$fp=[^ ]*" | cut -d= -f2)"
          echo "DEFERRED-STUCK: $name (fp $fp) firing since $started, responder marker '$MV' but never triaged — the FU-113(b) Argo retry chain should have re-run it; check the respond workflow retries/latch"
          ;;
        *)
          FOUND=1
          echo "UNTRIAGED: $name (fp $fp) firing since $started with no responder ledger entry — check the respond Sensor/EventSource/latch chain, NOT the alert itself"
          ;;
      esac
      ;;
  esac
done < <(printf '%s' "$ALERTS" | jq -r --arg cutoff "$CUTOFF" '
  .[]
  | select(.labels.alertname != "Watchdog" and .labels.alertname != "InfoInhibitor")
  | select((.labels.triage // "") != "none")
  | select(.startsAt < $cutoff)
  | [.fingerprint, .labels.alertname, .startsAt] | @tsv')

[ "$FOUND" -eq 0 ] && echo "belts healthy: every firing triage-eligible alert (> ${GRACE_MIN}m) has a responder ledger entry"
