# ── bridge ── the scan state the footprint-hold block reads. Every name is a variable the shipped
# script sets before the queued loop (`HERE`, `busy_fps`, `wip_busy`), never a harness invention.
HERE="$REPLAY_ROOT/agents"
. "${HERE}/footprint.sh"
# A non-empty busy_fps — two in-progress issues with chassis/ and docs/ footprints respectively.
busy_fps="chassis/**
docs/**"
# WIP ceiling check must be non-triggering for these tests
wip_busy=""
# orphans accumulator — the footprint-hold block appends to it
orphans=""