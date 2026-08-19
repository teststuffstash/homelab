# ── bridge ── vars the block reads; curl shadowed as the /opencode-limit seam (recorded — a
# probe that silently stopped happening is a gate that stopped gating); `bash` shadowed as a
# TRIPWIRE (the Go arm must never reach subscription-latch.sh).
HARNESS="claude"
MODEL="opencode-go/deepseek-v4-flash"
PROJECT="test-project"
HERE="."
PROXY_URL=""
OR_CREDITS=""
OR_MIN="0.25"
AGENT_CREDIT_GATE="1"
AGENT_EGRESS_PROXY="http://proxy.test:8080"
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  # SEMAPHORE — the transient reason (openrouter-proxy.py:1552, "reason \"semaphore\"", the
  # FU-088 concurrency semaphore folded server-side; FU-170 composes the Go semaphore into the
  # same top-level limited). This is the branch that must keep DEFERRING.
  printf '{"limited": true, "reason": "semaphore"}'
}
bash() {
  printf 'CALL bash %s\n' "$*" >> "$REPLAY_ACTIONS"
  echo "TRIPWIRE: the Go arm consulted the Anthropic latch" >&2
  exit 9
}
