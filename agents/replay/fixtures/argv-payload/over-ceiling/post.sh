# ── observation point ── not launcher code. In agent-session.sh the very next statement after the
# guarded block is `ARGS=…`, and a few dozen lines later the pod is created. This line stands in
# for "execution continued to there"; its ABSENCE from the action stream is the assertion that the
# refusal happened before anything was created, and diff asserts absences for free.
echo "REACHED: pod command frozen into args:"
