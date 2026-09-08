# ── bridge ── the two scan variables the block reads, and nothing else. `ib_get`/`ib_body`/`IB_PY`
# are NOT defined here: run.sh prepends coordinator-scan.sh's own `config-defaults` block to every
# composition sourced from it, so the helpers and the module path are the shipped ones (the
# PR#1459 lesson — a per-fixture seam is a fixture change the pin-vacuity gate then judges).
# Nothing is shadowed: the parser runs for real against the recorded issue array.
repo="homelab"
queued="$(cat "$REPLAY_WORLD/queued.json")"
