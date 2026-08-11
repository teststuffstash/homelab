# ── observation point ── not retro-session code. It stands in for the `exec bash agent-session.sh
# … --run "$RUN"` that follows the guarded block. Its absence is the assertion: the hand-off that
# would have died E2BIG never happened.
echo "REACHED: exec agent-session.sh --run"
