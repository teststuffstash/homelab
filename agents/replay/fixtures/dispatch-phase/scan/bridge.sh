# ── bridge ── two seams under the block: the wall clock and the transport. The Workflow read is
# deliberately NOT one of them — it goes through the harness's PATH-shim `kubectl`, so the call
# this clause makes (which object, in which namespace) lands in the action stream and the
# `creationTimestamp` → epoch conversion stays real arithmetic over a recorded payload.
#
# THE CLOCK IS SET PER CALL, not advanced by the seam: `dispatch_phase` reads it inside a command
# substitution and a subshell cannot write back, so a self-advancing `dp_now` would hand out its
# first tick forever and every phase would measure 0 while the fixture looked green (the rule
# agents/replay/README.md draws from run-phase-metric and the fix-debounce family).
dp_now() { printf '%s' "${DP_NOW:?the fixture must pin DP_NOW before every dispatch_phase call}"; }

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  while IFS= read -r l; do printf 'STDIN %s\n' "$l" >> "$REPLAY_ACTIONS"; done
  return "${CURL_RC:-0}"
}

# The block took both marks with the REAL clock at definition time — the bridge is composed after
# it, so `dp_now` was still `date` then. Re-arm them on the fixture's clock: the pod started at
# T0 and everything the fixture asserts is a difference from there.
DISPATCH_PHASE_T0=1786464900
DISPATCH_PHASE_MARK=1786464900

# The recorded Workflow was submitted at 17:24:40Z = 1786464880, twenty seconds before the pod's
# own start — the spike's "ring → scan pod cloning" row, give or take.

echo "REACHED: the Workflow is unreadable — the ring row is absent, the scan row still ships"
DP_NOW=1786464930; STUB_KUBECTL=fail dispatch_phase circles
printf 'RETURN %s\n' "$?"

# A failed probe is NOT latched: the next dispatch tries again, and this time the world answers.
echo "REACHED: the ring edge is readable"
DP_NOW=1786464940; dispatch_phase circles
printf 'RETURN %s\n' "$?"

# A second dispatch in the SAME scan (the global instance sweeping a second stack): `scan` measures
# from the first dispatch, not from the pod's start, and `ring-to-scan` is unchanged because it
# belongs to the pod. The probe is cached, so there is no second kubectl call.
echo "REACHED: a second dispatch, a different stack"
DP_NOW=1786465000; dispatch_phase oracle-fleet
printf 'RETURN %s\n' "$?"

# ── the paths that must never cost a dispatch ───────────────────────────────────────────────────
# No project to key the group on: nothing is published, the clock still moves.
echo "REACHED: no project"
DP_NOW=1786465005; dispatch_phase ""
printf 'RETURN %s\n' "$?"

# AGENT_PUSHGATEWAY_URL explicitly emptied (the jail/manual path): same deal, no push at all.
echo "REACHED: gateway disabled"
DP_NOW=1786465011; DISPATCH_PHASE_PGW="" dispatch_phase circles
printf 'RETURN %s\n' "$?"

# The gateway is up but refuses (curl exit 7). One warning, the dispatch is unaffected — and the
# payload proves the two silent calls above still moved the mark (5s + 6s), which is the whole
# reason it advances outside the push gate.
echo "REACHED: gateway refuses the push"
DP_NOW=1786465031; CURL_RC=7 dispatch_phase circles
printf 'RETURN %s\n' "$?"

# The SECOND refusal in the same run says nothing: the warning is latched, because a line per
# dispatch is the noise floor that hid a spinning Sensor for ~50 minutes (homelab#103).
echo "REACHED: gateway refuses again — latched, no second warning"
DP_NOW=1786465033; CURL_RC=7 dispatch_phase circles
printf 'RETURN %s\n' "$?"

# ── the CRON wake (017790c: a ring-to-scan row exists ⇔ edge-woken) ────────────────────────────
# The controller's `workflows.argoproj.io/cron-workflow` label decides: NO ring row (the
# creationTimestamp is a schedule, not a ring) and the CRON stamp instead of the edge one — the
# row the AgentDispatchCronWoken tooth counts. The wake cache is reset because this leg models a
# DIFFERENT pod (a cron-submitted scan), not a re-probe inside one.
echo "REACHED: cron-submitted scan — no ring row, the cron stamp instead"
DISPATCH_PHASE_WAKE=""; DISPATCH_PHASE_POD=coordinate-circles-cron-1
DP_NOW=1786465100; dispatch_phase circles
printf 'RETURN %s\n' "$?"

# The wake source is cached like the edge probe: a second dispatch in the same cron scan makes
# no second workflow read and stamps a fresh cron epoch (changes() is what counts them).
echo "REACHED: second cron dispatch — cached, fresh stamp"
DP_NOW=1786465130; dispatch_phase circles
printf 'RETURN %s\n' "$?"

# ── the JANITOR tick (homelab#459): report-only by design — no doorbell exists for "run the
# periodic janitor", so a janitor dispatch ships its timing rows but stamps NO wake source at
# all. Without this gate every janitor pass minted one guaranteed cron-woken sample and the
# AgentDispatchCronWoken tooth sat one tolerated race away from firing on any janitor day. The
# wake cache is still the cron pod's — the gate must beat a cached cron verdict, not rely on an
# unreadable probe.
echo "REACHED: janitor tick — timing rows ship, NO wake stamp (homelab#459)"
DP_NOW=1786465150; SCAN_JANITOR=1 dispatch_phase circles
printf 'RETURN %s\n' "$?"

# ── the per-clause wake series (homelab#459): a SECOND push whose grouping key carries the
# dimensions — clause-only is the COMMON case (3-field merge-path units carry no class); the
# unit segment appears on queued-dispatch/c4c5 only, and the class is BARE (`fix`, :1642 —
# `task/fix` is a value production cannot produce; the PR#1192 round-3 arbitration).
echo "REACHED: cron dispatch with clause — second push, own group"
DISPATCH_PHASE_WAKE=""; DISPATCH_PHASE_POD=coordinate-circles-cron-2
DP_NOW=1786465200; dispatch_phase circles "changes-requested"
printf 'RETURN %s\n' "$?"

echo "REACHED: edge dispatch with clause and bare unit class"
DISPATCH_PHASE_WAKE=""; DISPATCH_PHASE_POD=coordinate-circles-2
DP_NOW=1786465210; dispatch_phase circles "queued-dispatch" "fix"
printf 'RETURN %s\n' "$?"

echo "REACHED: end"
