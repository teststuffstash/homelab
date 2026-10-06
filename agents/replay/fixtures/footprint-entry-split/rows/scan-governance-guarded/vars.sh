# Test the GOVERNANCE scan check (L2595) with an annotated entry in the `agents/` governance
# set (non-dot-prefix paths). Pre-fix the `tr -d ' \t'` mangled the annotation, failing to conflict.
DECLARED="agents/footprint.sh (the splitter function)"
CHANGED="agents/footprint.sh"
