# ── bridge ── the state corpus-dispatch-argo.yaml's `dispatch` step sets BEFORE the allowlist
# block, and nothing else. Each name is the manifest's own: `RING_REPO` and `RING_PREFIX` are the
# two `jq -r` reads two lines above the opening sentinel (the ring body's `repo`/`prefix`), and
# `GH_TOKEN` comes off the container env (the `coordinator-git` Secret). A bridge that invents a
# variable pins a different clause.
#
# The ring PARSE itself (`printf '%s' "$PAYLOAD" > /tmp/ring.json` + the two `jq -r` reads) is
# deliberately NOT under replay here: it is the doorbell's payload half, it would drag a
# /tmp/ring.json world file into a fixture whose subject is the allowlist gate, and the block the
# reviewer named opens at the `case`. The row's `rows/<id>/vars.sh` supplies the two names the
# parse would have produced.
#
# Hermeticity: the pod's own environment must not decide a row. `RING_REPO`/`RING_PREFIX` are
# computed inside the step (never ambient), and `GH_TOKEN` is a credential the runner already
# unsets — cleared here too, so the absent-token row is genuinely absent rather than inheriting one.
unset RING_REPO RING_PREFIX GH_TOKEN
. "$REPLAY_WORLD/vars.sh"