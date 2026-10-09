# ── bridge ── the `uploads` world (sourced first), with the session's tee'd output replaced by
# one that carries would-lines: two distinct markers (em-dash and ASCII `--`, the second bulleted
# and bolded as models do), an echoed duplicate, a mid-line mention, and one malformed marker.
cat > /tmp/triage.log <<'LOG'
triage report: loki-0 WAL replay wedged on a torn segment after the node reboot
REMEDIATION-WOULD: delete monitoring/pod/loki-0 — WAL replay wedged; the StatefulSet recreates it
the brief's REMEDIATION-WOULD: marker mid-line is prose, not a marker
  - **REMEDIATION-WOULD:** restart monitoring/statefulset/loki -- if the delete alone does not clear it
REMEDIATION-WOULD: delete monitoring/pod/loki-0 — WAL replay wedged; the StatefulSet recreates it
REMEDIATION-WOULD: clear the wal
LOG
