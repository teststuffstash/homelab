# The NEGATIVE: a class=infra marker naming the same <job>/<step>, but posted OUTSIDE the 24 h
# window (cutoff 2026-09-09T00:00:00Z) — the window is level-triggered, so a lapsed one releases.
. + [ { "number": 1546,
        "comments": [ { "createdAt": "2026-09-08T12:00:00Z",
                        "body": "ci-cause: ci/OpenTofu-formatting-(fmt--check,-all-roots) class=infra basis=observed\n\nYesterday's runner image." } ] } ]
