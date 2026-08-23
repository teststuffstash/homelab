# Degrade leg 3: present, non-empty, but PERMISSION-DENIED — pins `-r` specifically (a future
# swap to `-f`/`-e` regresses here and nowhere else). Runtime chmod because git cannot commit a
# mode-000 file; the file lives in the harness temp dir (scrubbed to $TMP, removed at exit —
# owner unlink works regardless of file mode). ⚠ Assumes a non-root runner (root reads through
# 000 and this fixture then reds LOUDLY — visible, not silent; CI and both jails run non-root).
GROUND_RULES_FILE="$(dirname "$REPLAY_ACTIONS")/gr-unreadable.md"
printf 'x\n' > "$GROUND_RULES_FILE"
chmod 000 "$GROUND_RULES_FILE"
