# ── bridge ── sets up the environment for the parity assertion block.
#
# The parity assertion block (extracted via block:parity-assertion) reads
# $REPLAY_ROOT/.github/workflows/ci.yaml to extract the ratchet regex, then
# checks clause_files parity. The harness sets REPLAY_ROOT to the repo root.
#
# We override REPLAY_ROOT to point at the synthetic world so the block reads
# the synthetic ci.yaml (2000 matching lines) instead of the real one (2 lines).
# With 2000 lines, the pipe race (head -1 closing before sed/grep finish) is a
# certainty rather than a coin flip — the fixture reliably fails against the
# pre-fix source (no || true guard) and reliably passes with the guard.
REPLAY_ROOT="$REPLAY_WORLD"
#
# clause_files is the canonical list (same as the live scan uses). The synthetic
# ci.yaml has 2000 lines matching `grep -E.*agents/`, so the regex extracts the
# first one and the find loop checks parity against this list.
clause_files="agents/model-scout.sh
agents/coordinator-scan.sh
agents/review-reflex.sh
agents/reviewer-session.sh
agents/reviewer-optout.sh
agents/machine-comment.sh
agents/goal-budget.sh
agents/agent-session.sh
agents/retro-session.sh
agents/argv-guard.sh
agents/coordinator/reflexes-argo.yaml
agents/coordinator/review-argo.yaml
agents/coordinator/reviewer-git.yaml
agents/coordinator/coordinate-argo.yaml
agents/coordinator/responder-argo.yaml
agents/coordinator/retro-argo.yaml
agents/coordinator/fix-debounce-argo.yaml
agents/coordinator/deploy-revert-argo.yaml"