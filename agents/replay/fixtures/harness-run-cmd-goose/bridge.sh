# ── bridge ── the four variables the block reads, set exactly as agent-session.sh sets them
# upstream. No seam is needed: the block is pure string assembly over them, so the real code runs
# unmodified and the only stand-in is the recipe payload itself — `UkVDSVBF` ("RECIPE") instead of
# ~40KB of base64, because this fixture pins the SHAPE of the pod command, not the recipe's bytes.
CTX_PRELUDE="mkdir -p /work/context; git clone --depth 1 --quiet https://github.com/teststuffstash/circles.git /work/context/circles || echo \"WARN: context clone failed: https://github.com/teststuffstash/circles.git\"; "
RECIPE_B64="UkVDSVBF"
ISSUE_N="19"
HARNESS="goose"
RUN_CMD=""
