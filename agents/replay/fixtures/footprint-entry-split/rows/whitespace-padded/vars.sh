# Whitespace around entries is still trimmed (the old `tr -d ' \t'` did this too) — the fix
# trims only leading/trailing whitespace, never internal structure.
DECLARED="  chassis/build.py  ,  tests/test_build.py  "
CHANGED="chassis/build.py"