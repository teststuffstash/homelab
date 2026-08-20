# ── bridge ── the per-repo loop variables the 🌱 slice and unbound-sprout belt read.
slug="$IN_SLUG"
repo="$IN_REPO"
orphans=""
# openall is normally fetched outside the sentinel block; the fixture sets it here so the
# unbound-sprout belt (inside the sentinel) can read it. IN_OPENALL lets a row override it
# (e.g. for the probe-fail row).
openall="${IN_OPENALL:-$(cat "${REPLAY_WORLD}/gh/issue-list.json" 2>/dev/null || echo '[]')}"