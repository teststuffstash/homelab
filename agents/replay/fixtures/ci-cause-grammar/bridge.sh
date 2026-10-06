# ── bridge ── the marker line under test (rows/<id>/vars.sh) and the REAL reader. The subject is
# the ci-cause GRAMMAR as the ledger's consumer reads it, so the bridge imports the shipped
# `CI_CAUSE_RE` out of agents/ledger.py — never a copy of the pattern (ADR-122, one parser).
. "$REPLAY_WORLD/vars.sh"

# The reader is Python; the interpreter is declared in fixture.yaml (requires: python3).
_parsed="$(python3 - "$MARKER" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPLAY_ROOT"], "agents"))
import ledger
m = ledger.CI_CAUSE_RE.search(sys.argv[1])
if m:
    print("JOB_STEP\t%s\nCLASS\t%s\nBASIS\t%s" % (m.group(1), m.group(2), m.group(3)))
else:
    print("JOB_STEP\t<no-match>\nCLASS\t<no-match>\nBASIS\t<no-match>")
PY
)"
JOB_STEP="$(printf '%s\n' "$_parsed" | awk -F'\t' '$1=="JOB_STEP"{print $2}')"
CLASS="$(printf '%s\n' "$_parsed" | awk -F'\t' '$1=="CLASS"{print $2}')"
BASIS="$(printf '%s\n' "$_parsed" | awk -F'\t' '$1=="BASIS"{print $2}')"