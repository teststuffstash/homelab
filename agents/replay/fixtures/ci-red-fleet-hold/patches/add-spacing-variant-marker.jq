# The marker names the same <job>/<step> as the run but with a whitespace RUN (two spaces, a tab)
# where the run has one space — both sides collapse runs to one space before comparing, so this
# is the same fault and holds. Without the collapse the arm would miss it (a hand-typed marker).
. + [ { "number": 1546,
        "comments": [ { "createdAt": "2026-09-09T12:00:00Z",
                        "body": "ci-cause: ci/OpenTofu  formatting\t(fmt -check, all roots) class=infra basis=observed\n\nSame runner image." } ] } ]
