# ── bridge ── the per-repo loop variables the 🌱 slice and unbound-sprout belt read.
slug="$IN_SLUG"
repo="$IN_REPO"
orphans=""
openall_fetch_rc=0
[ -n "${IN_OPENALL:-}" ] && openall_fetch_rc=1
# openall is normally fetched outside the sentinel block; the fixture sets it here so the
# unbound-sprout belt (inside the sentinel) can read it. IN_OPENALL lets a row override it
# (e.g. for the probe-fail row).
openall="${IN_OPENALL:-$(cat "${REPLAY_WORLD}/gh/issue-list.json" 2>/dev/null || echo '[]')}"

# ── stub ── item_class_push is defined in the item-class block; the sprout-report block calls it
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$REPLAY_ACTIONS"
}