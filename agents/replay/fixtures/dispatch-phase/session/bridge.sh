# ── bridge ── two seams under the block: the wall clock and the transport.
#
# THE CLOCK IS SET PER CALL, not advanced by the seam. `cs_phase` reads it inside a command
# substitution and a subshell cannot write back, so a self-advancing `cs_now` would hand out its
# first tick forever and every phase would measure 0 while the fixture looked green (the rule
# agents/replay/README.md draws from run-phase-metric, whose emitter this one is the twin of).
cs_now() { printf '%s' "${CS_NOW:?the fixture must pin CS_NOW before every cs_phase call}"; }

# `curl` is shadowed rather than PATH-shimmed, for the reason the README gives for the responder
# pair — a third stub buys nothing. The PAYLOAD is recorded too (it arrives on stdin via
# `--data-binary @-`) because the accumulating family IS the contract: a fixture that pinned only
# the URL would go green on an emitter that publishes one phase and silently deletes the other.
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  while IFS= read -r l; do printf 'STDIN %s\n' "$l" >> "$REPLAY_ACTIONS"; done
  return "${CURL_RC:-0}"
}

echo "REACHED: the pod is asked for — the spin-up segment opens"
CS_NOW=1786464900; cs_phase_arm

# 51s of schedule + image pull + container start: the spike's own coordinator specimen, and the
# single biggest line in the dispatch chain.
echo "REACHED: Ready"
CS_NOW=1786464951; cs_phase coordinator-spinup
printf 'RETURN %s\n' "$?"

# 47s of headless tick: read the issue, dup-check, budget tier, key mint, worker launch.
echo "REACHED: the log stream ended"
CS_NOW=1786464998; cs_phase coordinator-session
printf 'RETURN %s\n' "$?"

# ── a second launcher process, walking the paths that must never cost a dispatch ────────────────
# The accumulator and the warning latch are per-RUN state, so resetting them here is what makes
# these calls a fresh dispatch rather than a third phase of the one above (which would push two
# series with identical labels and be rejected wholesale).
echo "REACHED: a second dispatch — the degenerate paths"
CS_PHASE_FAMILY=""; CS_PHASE_WARNED=""
CS_NOW=1786470000; cs_phase_arm

# An unknown phase is a CALLER bug, not a tick failure: say so, push nothing, return 0 — and do
# not touch the clock, so the mis-call cannot silently swallow the phase actually in flight.
echo "REACHED: unknown phase"
cs_phase sideways
printf 'RETURN %s\n' "$?"

# No stack main repo, so there is no group to push into. Nothing is published; the clock moves.
echo "REACHED: no project"
CS_NOW=1786470005; MAIN_REPO="" cs_phase coordinator-spinup
printf 'RETURN %s\n' "$?"

# AGENT_PUSHGATEWAY_URL explicitly emptied (the jail/manual path): same deal, no push at all.
echo "REACHED: gateway disabled"
CS_NOW=1786470011; CS_PHASE_PGW="" cs_phase coordinator-session
printf 'RETURN %s\n' "$?"

# A THIRD dispatch, so the two refusal pushes below carry each phase exactly ONCE. Two samples
# with identical labels in one body is a rejected push (prometheus/pushgateway#232), so a fixture
# that asserted one would be pinning a payload the gateway would never accept. Only the FAMILY is
# reset — not the mark, whose advance through the two silent calls above is what the 20s below
# proves (the clock left 1786470000 without a push and arrived here having moved).
CS_PHASE_FAMILY=""

# The gateway is up but refuses (curl exit 7). One warning, and the tick is unaffected.
echo "REACHED: gateway refuses the push"
CS_NOW=1786470031; CURL_RC=7 cs_phase coordinator-spinup
printf 'RETURN %s\n' "$?"

# The SECOND refusal in the same run says nothing: the warning is latched.
echo "REACHED: gateway refuses again — latched, no second warning"
CS_NOW=1786470033; CURL_RC=7 cs_phase coordinator-session
printf 'RETURN %s\n' "$?"

echo "REACHED: end"
