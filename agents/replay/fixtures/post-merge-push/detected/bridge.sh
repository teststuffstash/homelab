# ── bridge ── the launcher variables the post-merge-push detector block reads. PR_URL and GH_TOKEN
# are the gate condition. TASK and REPO_URL are used to derive the issue number and repo slug for
# the marker comment.
#
# World: PR #1250 is MERGED at 2026-09-01T18:33:52Z, head branch fix-issue-1212-post-merge-guard
# still exists with a commit dated 2026-09-01T18:37:34Z (after merge). The detector should emit
# the marker log line AND post an issue comment.
PR_URL="https://github.com/teststuffstash/homelab/pull/1250"
GH_TOKEN="stub-token"
TASK="issue-1212"
REPO_URL="https://github.com/teststuffstash/homelab"