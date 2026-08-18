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

# ── RUN A: the production path — the launcher is KILLED mid-follow ──────────────────────────────
# This is what a cluster ride actually looks like, and it is the case homelab#324 was filed for.
# The seat that runs the launcher is a coordinator session whose shell invocation is time-bounded,
# so on 19 of 24 measured rides the process was gone before the log-follow returned. Under the
# corrected contract that costs NOTHING, and the run below is the proof: both phases the launcher
# owns close before the pod is even Ready, so what this run leaves in the gateway is the COMPLETE
# family rather than a truncated one.
RP_NOW=1786464900
RUN_PHASE_MARK="$RP_NOW"

echo "REACHED: run A — the launcher is killed mid-follow"
RP_NOW=1786464907; run_phase dispatch-gates   # 7s of deterministic gates
printf 'RETURN %s\n' "$?"
RP_NOW=1786464941; run_phase pod-spinup       # 34s — the spike's own worker specimen
printf 'RETURN %s\n' "$?"
# …and here the coordinator's invocation times out and this process ceases to exist. There is no
# third call to make, which is exactly the point: nothing was lost by dying.

# ── RUN B: the launcher SURVIVES the ride — and publishes exactly the same two series ───────────
# The other 5 of 24. Before #324 this run diverged from run A by two series, which is what made the
# fleet `ride` p50 a median over the rides that happened to let their launcher live. Now the two
# runs are byte-identical, and THAT is the assertion: whether the launcher outlived the ride must
# not be visible in the metric at all.
# The accumulator and the warning latch are per-RUN state, so resetting them here is not a
# convenience: it is what makes this a fresh ride rather than a third phase of the one above (which
# would push two series with identical labels and be rejected wholesale).
echo "REACHED: run B — the launcher survives the whole ride"
RUN_PHASE_FAMILY=""; RUN_PHASE_WARNED=""
RP_NOW=1786465000
RUN_PHASE_MARK="$RP_NOW"
RP_NOW=1786465007; run_phase dispatch-gates   # the same 7s…
printf 'RETURN %s\n' "$?"
RP_NOW=1786465041; run_phase pod-spinup       # …and the same 34s: identical to run A
printf 'RETURN %s\n' "$?"

# THE REGRESSION GUARD for homelab#324. The log-follow has now returned and the exit path has run —
# the two points where #287 closed `ride` and `bookkeeping`. Both are unknown phases now, so both
# push nothing and both return 0. Re-add either to `run_phase`'s case arm and two CALL blocks
# appear here, run B stops matching run A, and this fixture reds — which is the only thing standing
# between the family and a `ride` series that exists on one ride in five and, when it does exist,
# repeats the sum of the in-pod rows to within 1–3 seconds.
echo "REACHED: the surviving launcher closes no third phase"
run_phase ride
printf 'RETURN %s\n' "$?"
run_phase bookkeeping
printf 'RETURN %s\n' "$?"

# ── RUN C: no task key — silent, but the clock still moves ──────────────────────────────────────
# An interactive / ad-hoc session has no task key, so there is no (project, issue, round) group to
# push into. Nothing is published; the phase is still CLOSED and still accumulated, so the next
# caller measures its own span rather than the sum of two. The push at the end of this run proves
# both halves at once: `pod-spinup` reads 6s — not the 11s a frozen mark would hand it — and the
# payload still carries the `dispatch-gates` value whose own push was skipped.
echo "REACHED: run C — no task key"
RUN_PHASE_FAMILY=""; RUN_PHASE_WARNED=""
RP_NOW=1786470000
RUN_PHASE_MARK="$RP_NOW"

# An unknown phase is a CALLER bug, not a ride failure: say so, push nothing, return 0 — and do
# not touch the clock, so the mis-call cannot silently swallow the phase actually in flight. The
# name used here is `ride` rather than a nonsense word, because `ride` is the one a stale caller
# would actually pass.
echo "REACHED: unknown phase"
run_phase ride
printf 'RETURN %s\n' "$?"
echo "REACHED: no task key"
RP_NOW=1786470005; TASK="" run_phase dispatch-gates
printf 'RETURN %s\n' "$?"
echo "REACHED: the next real push proves the clock advanced through the silence"
RP_NOW=1786470011; run_phase pod-spinup
printf 'RETURN %s\n' "$?"

# ── RUN D: AGENT_PUSHGATEWAY_URL explicitly emptied (the jail / manual path) ────────────────────
# Same guard as a missing task key, one condition earlier: no marker at all — and no warning
# either, because nothing was attempted, so there is nothing to warn about.
echo "REACHED: run D — gateway disabled"
RUN_PHASE_FAMILY=""; RUN_PHASE_WARNED=""
RP_NOW=1786475000
RUN_PHASE_MARK="$RP_NOW"
RP_NOW=1786475004; RUN_PHASE_PGW="" run_phase dispatch-gates
printf 'RETURN %s\n' "$?"

# ── RUN E: the gateway is up but refuses (curl exit 7) — one warning, LATCHED ───────────────────
# The ride is unaffected: a launcher that refused to dispatch because a metrics sink was down would
# be a strictly worse bug than the invisibility this metric exists to fix. The SECOND refusal in
# the same run says nothing, because four identical lines per jail run is the noise floor that hid
# a spinning Sensor for ~50 minutes (homelab#103). The latch is per-RUN state — which is why run D
# resets it, and why exactly one warning comes out of this whole fixture.
echo "REACHED: run E — gateway refuses the push"
RUN_PHASE_FAMILY=""; RUN_PHASE_WARNED=""
RP_NOW=1786480000
RUN_PHASE_MARK="$RP_NOW"
RP_NOW=1786480009; CURL_RC=7 run_phase dispatch-gates
printf 'RETURN %s\n' "$?"
echo "REACHED: gateway refuses again — latched, no second warning"
RP_NOW=1786480011; CURL_RC=7 run_phase pod-spinup
printf 'RETURN %s\n' "$?"

echo "REACHED: end"
