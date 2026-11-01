# A sibling open PR (#1546) carries a line-anchored `ci-cause:` marker naming the SAME <job>/<step>
# as the red PR, class=infra, inside the 24 h window (cutoff 2026-09-09T00:00:00Z). The identifier
# is written VERBATIM, spaces included — the §ci-cause grammar (agents/coordinator/README.md,
# homelab#1775): the step's real name carries spaces and the marker copies it from the run.
. + [ { "number": 1546,
        "comments": [ { "createdAt": "2026-09-09T12:00:00Z",
                        "body": "ci-cause: ci/OpenTofu formatting (fmt -check, all roots) class=infra basis=observed\n\nReran on a fresh runner; the image is missing tofu." } ] } ]
