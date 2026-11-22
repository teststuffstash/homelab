# ── bridge ── the launcher variables the two blocks read, pinned to one scan-built noop-rerun.
LAUNCH="oracle-fleet --task issue-1530 --round 3 --work-branch fix/issue-1530-red-step --recipe /work/oracle-fleet/.agents/fix.yaml"
MODEL="opencode-go/deepseek-v4-flash"
GO_CTX_ENV=""
COMMON_FLAGS="--model ${MODEL} --append-system-prompt-file /work/homelab/agents/coordinator/README.md --permission-mode bypassPermissions"
