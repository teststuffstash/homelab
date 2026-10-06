# The backtracking trap the issue names: a step name containing the literal text ` class=`. A
# greedy `.+` would drag the match to the later field; the non-greedy capture anchored on
# ` basis=` recovers the whole step name. Pre-fix this marker is dropped.
MARKER='ci-cause: e2e/foo class=bar class=content basis=observed'
