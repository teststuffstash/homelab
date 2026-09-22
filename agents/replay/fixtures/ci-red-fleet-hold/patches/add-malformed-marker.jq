# The NEGATIVE: a sibling's `ci-cause:` line that does NOT carry the full grammar (the arbitrate
# lane's live `ci-cause: policy-ambiguity` shape). It must be ignored — and, load-bearing, it must
# not abort the whole jq expression and silently disable the arm for every other sibling.
. + [ { "number": 1546,
        "comments": [ { "createdAt": "2026-09-09T12:00:00Z",
                        "body": "ci-cause: policy-ambiguity\n\nRuled ambiguous; no class tag." } ] } ]
