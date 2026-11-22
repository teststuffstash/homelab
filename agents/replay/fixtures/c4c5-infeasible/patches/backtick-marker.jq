# backtick-marker: the commonest markdown form of the claim — `` `gateway/devbox.json`: `` (backticks plus a
# trailing colon). The wrapping is stripped fully, so the path is classified (machine-merge) and the
# claim is refuted exactly as the bare `refuted` row.
map(if ((.body // "") | startswith("AGENT_INFEASIBLE:"))
    then .body = "AGENT_INFEASIBLE: `gateway/devbox.json`: acceptance 4 deletes the `tiers` devbox verb, and that is a NEVER-TOUCH path for a worker. No branch pushed."
    else . end)
