# ── observation point ── not clause code. The gate's decision is carried in three variables and
# only one of them reaches stdout, so the fixture would otherwise pin the log line and nothing
# about what the SESSION is actually told.
#
# SELF_NOTE is rendered by PREDICATE, never verbatim: it is ~800 characters of prompt text that
# will legitimately be reworded, and a fixture that diffed it byte-for-byte would red on every
# copy-edit until someone started updating it without reading it. What must not move is that the
# cap sentence is IN there — this exact string drifted once already (50b8418/60c2826 updated the
# comment and the echo but not the binding text, so "report-only" kept running for three days
# after the cap-the-merge ruling), which is the one failure a predicate can still catch.
printf 'SELF_REF=%s\n' "${SELF_REF:-<empty>}"
printf 'SELF_WHY=%s\n' "${SELF_WHY:-<empty>}"
case "$SELF_NOTE" in
  "")                                  echo "SELF_NOTE: empty — nothing appended to the brief" ;;
  *"NEVER enable auto-merge on it"*)   echo "SELF_NOTE: carries the never-auto-merge cap" ;;
  *)                                   echo "SELF_NOTE: PRESENT but the cap sentence is MISSING" ;;
esac
case "$SELF_NOTE" in
  *"'self-referential: true' on its own line"*) echo "SELF_NOTE: asks for the marker the debouncer reads" ;;
  "")                                           echo "SELF_NOTE: no marker instruction (nothing appended)" ;;
  *)                                            echo "SELF_NOTE: cap present but the MARKER instruction is missing" ;;
esac
