# ── observation point ── not launcher code. The finished pod command is the observable: whether
# the ladder left the dispatched model alone (anthropic clear), re-pointed it at the Go rail
# (failover, either shape), or deferred without ever assembling one (both-latched / unthreadable —
# this line never runs; the block `exit 0`s before reaching it, and that absence is itself part of
# what those two rows assert) is visible in the RUN_CMD that reaches the pod. For the `--run` shape
# the round-1 failure mode was a NO-OP substitution (command unchanged) with a success log on top —
# this line pins the command, so a no-op substitution reds the fixture instead of looking green.
echo "RUN_CMD: ${RUN_CMD}"
