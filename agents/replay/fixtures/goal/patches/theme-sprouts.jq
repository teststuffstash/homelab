# theme-sprouts — goal #29 becomes a THEMED goal (ADR-126: `Base: master`, written as the ADR-122
# machine block so the legacy meter stays silent and the row is about themes, not grammar) and two
# open, unlabelled sprouts (#301, #302) join `openall`. Their BODIES are not read from here — the
# goal lane reads `kidsall` (no bodies) and fetches each candidate's body with ONE `gh issue view`,
# recorded under rows/<row>/gh/issue-view-<n>.json — so the bodies here are deliberately bare: a
# nomination that appeared to work off these lines would be reading the wrong source.
map(if .number == 29 then .body = "---\nBase: master\n---\n" + .body else . end)
+ [
  { "number": 301, "title": "sprout: scan helper split", "labels": [], "body": "", "parent": { "number": 29 } },
  { "number": 302, "title": "sprout: coordinator belt docs", "labels": [], "body": "", "parent": { "number": 29 } }
]
