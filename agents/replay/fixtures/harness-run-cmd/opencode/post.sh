# ── observation point ── not launcher code. RUN_CMD is an internal variable, and the harness
# asserts action streams rather than variables — so this prints the finished pod command, which is
# the observable thing: it is what agent-session.sh freezes into `args: ["bash","-c", …]`. Ordering
# inside the string is therefore asserted too, which is what contract 2 rests on.
echo "RUN_CMD: ${RUN_CMD}"