# ── bridge ── the launcher variables the post-merge-push detector block reads. Same PR as the
# detected case, but the branch's latest commit is at the same timestamp as mergedAt (no movement).
#
# World: PR #1250 is MERGED at 2026-09-01T18:33:52Z, head branch fix-issue-1212-post-merge-guard
# still exists with a commit dated 2026-09-01T18:33:52Z (same as merge — no movement).
# The detector should emit nothing.
PR_URL="https://github.com/teststuffstash/homelab/pull/1250"
GH_TOKEN="stub-token"
TASK="issue-1212"
REPO_URL="https://github.com/teststuffstash/homelab"