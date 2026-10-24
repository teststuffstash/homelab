.alerts |= map(if .labels.id == "39363243469" then .labels.workflow = "CI" else . end)
