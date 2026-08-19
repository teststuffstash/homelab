# Issue #660 leg 2: 429-quota classifier in raw-log fallback (no AGENT_RUN_STATS).
HARNESS="claude"
MODEL="claude/opus-5"
TASK="issue-43"
STRUCK_MODEL="claude/opus-5"
ROUND="1"
NS="test-namespace"
POD="test-pod-123"
KUBE=""
HERE="."
# For the fu088-gates block's subscription-latch.sh call, return a clear rail value
BASH_PICK_RAIL="claude/opus"
# RUNLOG with a line matching the 429 quota pattern
RUNLOG="$(mktemp)"
printf 'Error: rate limit exceeded\nStatus: 429\nDetails: quota limit reached\n' > "$RUNLOG"
