# The GUARD's pin: a malformed `ci-cause:` line on sibling #1546 (which `capture` would raise on)
# sits BESIDE a valid class=infra marker on sibling #1547. Unguarded, the raise aborts the whole
# expression and the arm silently misses the valid marker (no hold); guarded, the malformed line is
# filtered and the valid one holds. This row is what makes the `select(test(...))` load-bearing.
. + [ { "number": 1546,
        "comments": [ { "createdAt": "2026-09-09T12:00:00Z",
                        "body": "ci-cause: policy-ambiguity\n\nRuled ambiguous; no class tag." } ] },
      { "number": 1547,
        "comments": [ { "createdAt": "2026-09-09T13:00:00Z",
                        "body": "ci-cause: ci/OpenTofu-formatting-(fmt--check,-all-roots) class=infra basis=observed\n\nSame runner image." } ] } ]
