# The NEGATIVE for the non-greedy capture: the marker's leftmost ` class=` field is `content`, and
# the free text AFTER `basis=` happens to contain ` class=infra basis=…`. The capture anchors on
# the LEFTMOST ` class=` followed by a basis (the ledger's CI_CAUSE_RE shape), so the ruling's
# class is content → NOT held. A greedy capture, or a class test run on the whole line before the
# capture, would read `infra` and freeze a PR whose red is its own code.
. + [ { "number": 1546,
        "comments": [ { "createdAt": "2026-09-09T12:00:00Z",
                        "body": "ci-cause: ci/OpenTofu formatting (fmt -check, all roots) class=content basis=observed note: not class=infra basis=prior\n\nThe PR's own diff." } ] } ]
