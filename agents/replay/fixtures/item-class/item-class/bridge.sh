# ── bridge ── two seams, both underneath the block: the wall clock and the transport.
#
# `curl` is shadowed rather than PATH-shimmed for the same reason as the scan-phase-marker
# fixture — the PAYLOAD is recorded too (it arrives on stdin via `--data-binary @-`), because
# the metric names and labels ARE the contract the board and alert read.
sp_now() { printf '1786465900'; }

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  while IFS= read -r l; do printf 'STDIN %s\n' "$l" >> "$REPLAY_ACTIONS"; done
  return "${CURL_RC:-0}"
}

{
  echo "=== push: strike-held (who=operator) ==="
  item_class_push "homelab" "833" "strike-held" "operator"
  printf 'RETURN %s\n' "$?"

  echo "=== push: queued-held-by-ghost (who=operator) ==="
  item_class_push "homelab" "834" "queued-held-by-ghost" "operator"
  printf 'RETURN %s\n' "$?"

  echo "=== push: riding (who=machine) ==="
  item_class_push "homelab" "889" "riding" "machine"
  printf 'RETURN %s\n' "$?"

  echo "=== push: container (who=none) ==="
  item_class_push "homelab" "840" "container" "none"
  printf 'RETURN %s\n' "$?"

  echo "=== push: backlog-aggregate (who=operator) ==="
  item_class_push "homelab" "aggregate" "backlog-aggregate" "operator"
  printf 'RETURN %s\n' "$?"

  # A run with no gateway (the jail/manual path, AGENT_PUSHGATEWAY_URL=""): no push at all.
  echo "=== push: gateway disabled ==="
  SCAN_PHASE_PGW="" item_class_push "homelab" "999" "riding" "machine"
  printf 'RETURN %s\n' "$?"

  # A run with no pod identity: no push at all.
  echo "=== push: no pod identity ==="
  SCAN_PHASE_POD="" item_class_push "homelab" "999" "riding" "machine"
  printf 'RETURN %s\n' "$?"

  # The gateway is up but refuses (curl exit 7): one warning (silenced by || true), and the
  # classification is unaffected.
  echo "=== push: gateway refuses ==="
  CURL_RC=7 item_class_push "homelab" "999" "riding" "machine"
  printf 'RETURN %s\n' "$?"

  echo "=== end ==="
} >> "$REPLAY_ACTIONS"