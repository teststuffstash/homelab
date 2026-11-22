# gateway-marker: the homelab#3309 shape — the SAME `verdict` world, #66's marker naming a NESTED
# `gateway/devbox.json` (the worker read it as the ❌ root devbox.json). `classify_touches` rates it
# machine-merge — only the ROOT devbox.json|lock is codeowner-author (agents/footprint.sh) — so the
# claim is refuted: no park, one refutation comment, #66 keeps its C4/C5 handling beside #70.
# On the base tree the scan took the worker's word and parked it (PR #3590 sat two days).
map(if ((.body // "") | startswith("AGENT_INFEASIBLE:"))
    then .body = "AGENT_INFEASIBLE: gateway/devbox.json — acceptance 4 deletes the `tiers` devbox verb, and `devbox.json` is a NEVER-TOUCH path for a worker. No branch pushed.\n\nNeeds a code owner to author this issue (or split the devbox.json edit out)."
    else . end)
