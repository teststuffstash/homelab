# ── bridge ── as retro-key-minted's, on an OpenRouter cell (the branch that WOULD mint). What
# separates this fixture from that one is the pinned RETRO_OPENROUTER_SECRET in `env:` — the
# variable the retro-cell step exports from the cron's `retroKeySecret` param.
HERE="$REPLAY_ROOT/agents"
HARNESS="goose"
MODEL="deepseek/deepseek-v4-pro"
PROJECT="oracle-fleet"
RUN_ID="r4"
REVIEW=""
BRIEF="$REPLAY_FIXTURE/brief.md"
KUBECTL="kubectl"
KUBE=""
