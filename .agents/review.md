# homelab review rubric (appended to the reviewer's system prompt)

This repo is the PLATFORM'S OWN -iac, and it is **public**. ArgoCD watches `argocd/`,
`agents/coordinator` and `agents/fixer`, so for those paths **a merge syncs to the live cluster
within minutes**. It is also where the agent loop's own machinery lives, which is why scope here is
judged PER PATH (`docs/agents/iac-lane.md` §The platform lane) rather than per repo.

## BLOCKING

- **A literal secret or credential value, anywhere.** References only (ExternalSecret,
  `existingSecret`, `ref:<ns>/<name>`). The repo is public; this is not a style question.
- **A diff outside the author's declared `Touches:` footprint** that lands in a governance path —
  `agents/**`, `scripts/**`, `policy/**`, `.github/**`, `tofu/github/**`, `tofu/cloudflare/**`.
  Those are the launcher, the scan, the reflex and the rulesets over them. A worker editing its own
  governor is ungated whatever the ruleset says. Block regardless of how good the change looks.
- **A hand-edited chart or image pin** outside the deploy pipeline (ADR-084), unless the PR says
  why. `targetRevision:` and `agents/images.env` move via bump PRs.
- **A manifest that does not validate**, or a PR claiming green without saying WHICH lints ran —
  there is no single `devbox run ci` here, so "CI green" is not a meaningful claim on its own.
- **A `prune: true` Application edit that deletes a service** without its data story (PVCs,
  buckets, what happens to the objects).
- **An alert rule whose `description` asserts a CAUSE.** Descriptions state the SYMPTOM and what to
  check. A guessed cause in an alert is how a wrong diagnosis gets institutionalised — this
  platform has paid for that twice (#94, #103).

## NOT blocking — follow-ups instead

Naming, comment gaps, non-load-bearing duplication, a lint that exists but was not run when the
diff plainly does not touch its surface.

## Judge these carefully rather than by rule

- **`manifest-lint` SKIPS CRs it has no schema for** (Applications, AgentStacks,
  CiliumNetworkPolicies, PrometheusRules). A PR whose whole diff is one of those kinds passed a
  validator that checked *nothing*. That is acceptable if the author SAYS so and describes what
  they did instead; it is not acceptable dressed up as "CI green".
- **Documentation is load-bearing here.** `docs/` carries the FU tracker, the ADRs and the incident
  record — the things the next session reads as ground truth. A doc change that contradicts what
  shipped is a real defect, not a nit. `docs/follow-ups.md` is single-writer (operator/meta): a
  worker appending to it is blocking.
- **Path tier decides who merges, and the PR should say so.** Tier 1 (`argocd/resources/**`) merges
  on CI; `argocd/platform/**`, `tofu/`, `ansible/`, `opnsense/`, `machines/` need a human. If the
  diff needs a human and the body does not say it, that is a follow-up — someone will otherwise
  wait in silence for an auto-merge that cannot come.

Greenfield bias does NOT apply here: this repo is prod-serving and public. But "better than master"
still wins over "perfect" for a change that is contained, validated, and inside its tier.
