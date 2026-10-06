# Entry with internal whitespace — the unquoted iteration in fp_conflict / fp_conflict_strict
# word-splits on whitespace. Pre-fix, it incorrectly holds (false positive). Post-fix, iteration
# is quoted-safe and the entry is read as a whole, returning no holds.
DECLARED="docs/a b.md"
CHANGED="docs/a"
