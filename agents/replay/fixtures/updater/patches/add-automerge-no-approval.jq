# automerge-no-approval-update (homelab#1896): ONE armed+BEHIND PR on a repo whose ruleset requires
# no approval (reviewDecision ""), carrying the `automerge` label — the review reflex's SKIP class
# (docs/agents/merge-path.md §Decisions/FU-046; docs/agents/iac-lane.md). The mechanical classes on
# the -iac repos are CI-only BY DESIGN, so the reflex never reviews them and the #1452
# bot-approval arm can never reach them; before #1896 they stranded armed+BEHIND forever
# (oracle-iac, 2026-09-21: 10 open PRs, all armed+BEHIND, the oldest from 09-16, ~500 updater
# passes over them). The updater must bring it current. THIS ROW IS THE PIN: it REDs on the
# pre-#1896 source, where the label arm does not exist and the PR has no bot approval.
. + [
  { number: 160, createdAt: "2026-09-16T09:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-09-16T09:01:00Z" }, reviewDecision: "", baseRefName: "master",
    labels: [ { name: "automerge" } ], headRefOid: "auto160oid789" }
]