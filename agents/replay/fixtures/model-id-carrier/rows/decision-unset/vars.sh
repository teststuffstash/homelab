# DECISION-UNSET leg: _decision is entirely absent (the set -u guard case).
# Falls back to model_id.py --shell parse — no unbound-variable death.
MODEL="claude/haiku"
# _decision is deliberately unset — the block uses ${_decision:-} defensively