# ── the five arms ── each overrides PF_ISSUE / WORK_BRANCH so the SAME recorded world answers all
# five shapes. The refusal arms run in a subshell because fu042_guard_a EXITS 3; the rc is printed
# and the refusal (captured through the command substitution) is re-emitted to stderr so it lands
# in the action stream without leaving a stray file in the fixture dir.
echo "REACHED: bare-mention PR (#344 in prose) — must NOT refuse"
PF_ISSUE="344"; WORK_BRANCH=""
fu042_guard_a
printf 'MENTION_ONLY continues\n'

echo "REACHED: strong-link PR (#351 Fixes) — must refuse"
PF_ISSUE="351"; WORK_BRANCH=""
set +e
link_err="$( { fu042_guard_a; } 2>&1 )"
link_rc=$?
set -e
printf 'STRONG_LINK rc=%s\n' "$link_rc"
printf '%s\n' "$link_err" >&2

echo "REACHED: strong-link PR, --work-branch == headRef — must resume"
PF_ISSUE="351"; WORK_BRANCH="fix/issue-351-exporter-down-fixture"
fu042_guard_a
printf 'RESUME_MATCH continues\n'

echo "REACHED: strong-link PR, --work-branch != headRef — must refuse"
PF_ISSUE="351"; WORK_BRANCH="fix/issue-351-some-other"
set +e
mismatch_err="$( { fu042_guard_a; } 2>&1 )"
mismatch_rc=$?
set -e
printf 'RESUME_MISMATCH rc=%s\n' "$mismatch_rc"
printf '%s\n' "$mismatch_err" >&2

echo "REACHED: mid-word match (#352 unresolved in prose) — must NOT refuse"
PF_ISSUE="352"; WORK_BRANCH=""
fu042_guard_a
printf 'MIDWORD_MENTION continues\n'

echo "REACHED: duplicate PRs (#353 has two Fixes PRs) — must refuse loudly"
PF_ISSUE="353"; WORK_BRANCH=""
set +e
dup_err="$( { fu042_guard_a; } 2>&1 )"
dup_rc=$?
set -e
printf 'DUPLICATE_PRS rc=%s\n' "$dup_rc"
printf '%s\n' "$dup_err" >&2

echo "REACHED: end"
