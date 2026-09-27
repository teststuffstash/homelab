# workflow-pin-revert-candidate / deploy-revert-candidate

The revert-candidate read of both rollback chains in `agents/coordinator/deploy-revert-argo.yaml`
(FU-1990 `workflow-pin-revert`, FU-044 `deploy-revert`). Found by the 2026-09-27 rollback drill
(agent-coordinator#20, homelab#1990): `gh pr list --jq --arg cutoff …` is "unknown arguments"
(gh's `--jq` takes only the expression), swallowed into "no candidate" by `2>/dev/null || true`,
so neither chain had ever found a candidate. The pin is the CALL line with the literal cutoff
(`CUTOFF` is overridable for exactly this) plus the extracted candidate. Contract prose in each
`fixture.yaml`.
