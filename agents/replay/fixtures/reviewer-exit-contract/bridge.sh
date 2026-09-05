# ── bridge ── seams only, no gate logic. The exit-contract block's only external read is the
# post-claude `gh pr view --json reviews,comments,labels,commits,headRefOid` re-read. Function-shadow
# `gh` so the fixture controls the EXACT review state the assert parses (its contract is what the
# pod does with the JSON, not how the real gh serves it) — the reviewer-currency pattern. Records the
# CALL line in the action stream, then serves the fixture world recording, falling back inline to a
# CLEAN no-terminal state (a base world that forgot to record a read must not fake a pass). The
# launcher's pod env vars the block reads (PR_NUMBER, REPO_SLUG, REVIEWER_LOGIN) come from the
# rows' env column; RC models the pre-block `claude` exit code — the block only consults it when no
# terminal exists, which is exactly the decision the table pins.
HERE="$REPLAY_FIXTURE"
PR_NUMBER="${PR_NUMBER:-42}"
REPO_SLUG="${REPO_SLUG:-teststuffstash/test-project}"
REVIEWER_LOGIN="${REVIEWER_LOGIN:-homelab-reviewer}"

# The silent-dedup record (homelab#1438): session-scoped path, ALWAYS cleared before the row's
# conditional write — a leftover from a sibling row (or a previous job on a persistent runner)
# must never mint a terminal for a row that set no SILENT_DEDUP.
SILENT_DEDUP_RECORD="${TMPDIR:-/tmp}/silent_dedup_record.$$"
export SILENT_DEDUP_RECORD
rm -f "$SILENT_DEDUP_RECORD"
if [ "${SILENT_DEDUP:-0}" = "1" ]; then
  echo "SILENT_DEDUP_ASIDE: checks-pending at 0c2be42f" > "$SILENT_DEDUP_RECORD"
fi

gh() {
  {
    printf 'CALL gh'
    for _a in "$@"; do
      printf ' %s' "$_a"
    done
    printf '\n'
  } >> "$REPLAY_ACTIONS"
  if [ "${STUB_GH_FAIL:-0}" = "1" ]; then
    echo "gh: Not Found (HTTP 404)" >&2
    return 1
  fi
  if [ -f "$REPLAY_WORLD/gh/pr-view-42.json" ]; then
    cat "$REPLAY_WORLD/gh/pr-view-42.json"
    return 0
  fi
  printf '{"reviews":[],"comments":[],"labels":[],"commits":[{"oid":"abc1234def567890abcdef","messageHeadline":"fix: the thing","committedDate":"2026-08-18T17:50:00Z"}],"headRefOid":"abc1234def567890abcdef"}'
  return 0
}
