# Test the whitespace-safe iteration in fp_conflict and fp_conflict_strict. Entries with
# internal whitespace in the annotation should still match correctly. Pre-fix the unquoted
# `for _a in $_la` word-splits internal spaces.
DECLARED="docs/agents/issue-authoring.md (the Touches authoring guide)"
CHANGED="docs/agents/issue-authoring.md"
