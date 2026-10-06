# Test the GUARDED scan check (L2523) with an annotated entry. Pre-fix the `tr -d ' \t'`
# mangled this into a single token with no `/` boundary, failing to conflict.
DECLARED="agents/coordinator-scan.sh (the scan's own inline split)"
CHANGED="agents/coordinator-scan.sh"
