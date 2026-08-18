# ── observation point ── not launcher code. In agent-session.sh the next statement past this block
# is the TASK_CLASS resolution and then the dispatch itself. This line stands in for "execution
# continued"; its ABSENCE from the action stream is the assertion that the refusal arm still exits
# non-zero, and diff asserts absences for free. The `terminal` and `within` rows show it present
# with `RC 0`, which is what makes the pass-through contract visible in one stream.
echo "REACHED: the dispatch continued past the pre-flight"
