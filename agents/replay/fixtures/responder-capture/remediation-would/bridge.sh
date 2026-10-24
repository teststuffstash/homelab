# ── bridge ── the `uploads` world (sourced first), with the session's tee'd output replaced by
# one that carries would-lines: two distinct markers (em-dash and ASCII `--`, the second bulleted
# and bolded as models do), an echoed duplicate, a mid-line mention, one malformed marker (kept as `raw`), and three
# declared non-actions (`none`, bolded `N/A`, backticked `no action`) that must be DROPPED.
cat > "$SCRATCH/triage.log" <<'LOG'
triage report: loki-0 WAL replay wedged on a torn segment after the node reboot
REMEDIATION-WOULD: delete monitoring/pod/loki-0 — WAL replay wedged; the StatefulSet recreates it
the brief's REMEDIATION-WOULD: marker mid-line is prose, not a marker
  - **REMEDIATION-WOULD:** restart monitoring/statefulset/loki -- if the delete alone does not clear it
REMEDIATION-WOULD: delete monitoring/pod/loki-0 — WAL replay wedged; the StatefulSet recreates it
REMEDIATION-WOULD: clear the wal
REMEDIATION-WOULD: none — the pod is healthy and the problem is at the node level
- **REMEDIATION-WOULD:** **N/A.** deleting the pod would not help while the node is down
REMEDIATION-WOULD: `no action`
REMEDIATION-WOULD: nonexistent-verb monitoring/pod/loki-0 — a verb that merely starts with none still counts
LOG
