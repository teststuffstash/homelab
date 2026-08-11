# ── bridge ── two seams, both underneath the block: the wall clock and the transport.
#
# THE CLOCK IS SET PER CALL, not advanced by the seam. `run_phase` reads it inside a command
# substitution, and a subshell cannot write back to its parent — a self-advancing `rp_now` would
# hand out its first tick forever and every phase would measure 0 while the fixture looked green.
# So the bridge pins `RP_NOW` before each call and `rp_now` merely reads it, loudly: a DEFAULTED
# clock is a fixture asserting against an accident (the rule agents/replay/README.md draws from
# the fix-debounce-currency family).
rp_now() { printf '%s' "${RP_NOW:?the fixture must pin RP_NOW before every run_phase call}"; }

# `curl` is shadowed rather than PATH-shimmed, for the reason the README gives for the responder
# pair — a third stub buys nothing. The PAYLOAD is recorded too (it arrives on stdin via
# `--data-binary @-`) because the accumulating family IS the contract: a fixture that pinned only
# the URL would go green on an emitter that publishes one phase and silently deletes the rest.
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  while IFS= read -r l; do printf 'STDIN %s\n' "$l" >> "$REPLAY_ACTIONS"; done
  return "${CURL_RC:-0}"
}

# The block took its opening mark with the REAL clock at definition time — the bridge is composed
# after it, so `rp_now` was still `date` then. Re-arm it on the fixture's clock; everything the
# fixture asserts is a DIFFERENCE, and the first difference needs a pinned left-hand side.
RP_NOW=1786464900
RUN_PHASE_MARK="$RP_NOW"

echo "REACHED: a whole ride, four phases in order"
RP_NOW=1786464907; run_phase dispatch-gates   # 7s of deterministic gates
printf 'RETURN %s\n' "$?"
RP_NOW=1786464941; run_phase pod-spinup       # 34s — the spike's own worker specimen
printf 'RETURN %s\n' "$?"
RP_NOW=1786465301; run_phase ride             # 360s in the pod
printf 'RETURN %s\n' "$?"
RP_NOW=1786465313; run_phase bookkeeping      # 12s of exit path
printf 'RETURN %s\n' "$?"

# ── a second launcher process, walking the paths that must never cost a dispatch ────────────────
# The accumulator and the warning latch are per-RUN state, so resetting them here is not a
# convenience: it is what makes these four calls a fresh ride rather than a fifth phase of the one
# above (which would push two series with identical labels and be rejected wholesale).
echo "REACHED: a second run — the degenerate paths"
RUN_PHASE_FAMILY=""; RUN_PHASE_WARNED=""
RP_NOW=1786470000
RUN_PHASE_MARK="$RP_NOW"

# An unknown phase is a CALLER bug, not a ride failure: say so, push nothing, return 0 — and do
# not touch the clock, so the mis-call cannot silently swallow the phase actually in flight.
echo "REACHED: unknown phase"
run_phase sideways
printf 'RETURN %s\n' "$?"

# An interactive / ad-hoc session has no task key, so there is no (project, issue, round) group to
# push into. Nothing is published; the clock still moves.
echo "REACHED: no task key"
RP_NOW=1786470005; TASK="" run_phase dispatch-gates
printf 'RETURN %s\n' "$?"

# AGENT_PUSHGATEWAY_URL explicitly emptied (the jail/manual path): same deal, no marker at all.
echo "REACHED: gateway disabled"
RP_NOW=1786470011; RUN_PHASE_PGW="" run_phase pod-spinup
printf 'RETURN %s\n' "$?"

# The gateway is up but refuses (curl exit 7). One warning, the ride is unaffected — and the
# payload proves the two silent calls above still moved the clock (5s + 6s), which is the whole
# reason the mark advances outside the push gate.
echo "REACHED: gateway refuses the push"
RP_NOW=1786470031; CURL_RC=7 run_phase ride
printf 'RETURN %s\n' "$?"

# The SECOND refusal in the same run says nothing: the warning is latched, because four identical
# lines per jail run is the noise floor that hid a spinning Sensor for ~50 minutes (homelab#103).
echo "REACHED: gateway refuses again — latched, no second warning"
RP_NOW=1786470033; CURL_RC=7 run_phase bookkeeping
printf 'RETURN %s\n' "$?"

echo "REACHED: end"
