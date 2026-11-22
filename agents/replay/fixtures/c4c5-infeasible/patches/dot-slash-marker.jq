# dot-slash-marker: the review's fail-open shape (PR #3681) — #66's marker names the ROOT devbox.json
# spelled `./devbox.json`. classify_touches matches literal case arms, so the raw spelling reads
# machine-merge; the scan canonicalizes first (drop `./`, collapse `//` and `/./`) and the
# CORRECT never-touch claim parks. RED on 6766aca06 (it refuted the claim).
map(if ((.body // "") | startswith("AGENT_INFEASIBLE:"))
    then .body = "AGENT_INFEASIBLE: ./devbox.json — the fix adds a package to the ROOT devbox.json, which CI executes from the branch. Ending without pushing."
    else . end)
