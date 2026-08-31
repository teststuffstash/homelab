# ── bridge ── the retro-session variables the block reads, each named exactly as retro-session.sh
# sets it upstream, plus the two `kube.sh` resolves (the stub `kubectl` stands in for the binary).
HERE="$REPLAY_ROOT/agents"
HARNESS="goose"
MODEL="deepseek/deepseek-v4-pro"
PROJECT="oracle-fleet"
RUN_ID="r4"
REVIEW=""
BRIEF="$REPLAY_FIXTURE/brief.md"
KUBECTL="kubectl"
KUBE=""

# ── seam ── estimate_budget.py prices against the LIVE OpenRouter registry, and a replay that can
# reach the network is a replay that goes green for the wrong reason. Shadowing `python3` with a
# function is the same seam shape the responder fixtures use for `curl`; it pins ONLY the price, so
# the real estimator, the real tier logic and the real emit_cr rendering are all under assertion.
# The same shadow also covers the inline python3 parser that reads metadata.name/spec.secretName
# from the emitted CR (shape-agnostic — handles both inline flow and block style, homelab#989).
python3() { command python3 "$@" --price-per-mtok 0.30; }
