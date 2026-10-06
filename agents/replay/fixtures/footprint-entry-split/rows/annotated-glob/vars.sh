# An annotated GLOB: the annotation sits after the `**`, so the old splitter mangled the glob
# itself (`…ingest/**(ingestonly)`) and the prefix cut at the first `*` left a broken boundary.
DECLARED="mcps/riigiteataja/ingest/** (ingest only)"
CHANGED="mcps/riigiteataja/ingest/delta.py"