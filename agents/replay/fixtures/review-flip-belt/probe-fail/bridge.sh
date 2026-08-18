# ── bridge ── the per-repo loop variables the review-flip belt holds by the time the block runs.
# `inprog` arrives as a recorded file; `prsjson` is set to GARBAGE directly — this arm is about
# the belt NOT trusting the open-PR read, so a world file would be asserting the wrong half.
slug="teststuffstash/homelab"
repo="homelab"
orphans=""
units=""
inprog="$(cat "$REPLAY_WORLD/gh/issue-list-inprog.json")"
prsjson="upstream connect error or disconnect/reset before headers"
