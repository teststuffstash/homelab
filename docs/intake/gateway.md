# Island facts — the gateway

> The §Island facts block for the **gateway** island (the agent-gateway: sessions, rails, the
> catalog, tier evidence). The rules are ONE home —
> [`islands/intake/rules/intake.md`](../../islands/intake/rules/intake.md); this file holds only the
> island's facts and, under `## Sources`, the island's own rows of its §What you read table.

Body shape: spec

- Repo `teststuffstash/homelab`; island root `gateway/`; specs `gateway/specs/` (`GW-` ids, pages
  under `specs/endpoints/`, worlds under `specs/worlds/`, each row names its world); tests
  `gateway/tests/`; the deploy surface `argocd/resources/agent-gateway/` (an image bump rolls the pod).
- Membership: `Touches` entirely under `gateway/**`, or a title starting `gateway` / naming a
  `GW-` id. `.github/workflows/gateway-image.yaml` is `codeowner-author` (entry (d)).
- The specs reviewer is the second required approval on `gateway/specs/**` + `gateway/tests/**`
  (ADR-155); the `Spec changes:` PR-body heading, ⚖ on judgment rows, per-row OBSERVED values —
  the review classes that cost rounds.
- Pinned process: `allure-behavior-snippets` RULES.md/CONVENTIONS.md, at the version
  `gateway/specs/README.md` §Rules pins (no number here — it drifted). "Rule N" means rule N there.
- Sibling sets (step 3's parity check): the rails — `opencode`, `openrouter`, `anthropic`,
  `codex`. A per-rail facility is a `/catalog/<rail>` view, a catalog read leg, a headroom
  reading, a metric family.
- **A new upstream read is the island's to decide** (no entry) when it is public and
  credential-free, on a vendor the source already reads, a machine-readable endpoint (never a
  scrape of a rendered app), on the existing refresh cadence with the gateway's identifying
  User-Agent, declared as a row under `specs/endpoints/catalog.md` §What a fetch sends, its
  fixture recorded from the wire, and failing to the last good snapshot. A vendor wire answer
  nobody recorded is such work (a recorder, a declared read) — never a hand-copied fixture.
- The operator's ruling, pinned into any Goal that touches it: a read on a subscription
  credential (entry (a)), or an account-bound value reaching a committed file — such a
  declaration lives in a file of its own on a codeowner path, never in a machine-merged one.
- Assemblies: `gateway/**` has no codeowner, so a gateway-only assembly merges on the two bot
  approvals; the Goal's verdict is the operator's point.
- An entry canary is the loop's to launch, on every rail, capped at ONE ride per rail per catalog
  refresh: the trigger that launches it is island work like any other, never a `seat`.
- Operator-only: (a) the Go key mint (FU-313), the codex login (seed); (b) a window on an `attended` or `manual` surface;
  (e) any ruling the tracker marks "ruling pending" (FU-270 names them).

## Sources

How a sitting runs a Prometheus query or a kube read: the LIVE READS block of
[`sitting.sh`](../../islands/intake/scripts/sitting.sh). The gateway's own views are in the same block (the caller token and the URL).

| question | read | note |
|---|---|---|
| What the island is and which process it runs | [`gateway/README.md`](../../gateway/README.md) + [`gateway/specs/README.md`](../../gateway/specs/README.md) + the pinned `RULES.md` it names (a `gh api` GET of the pinned tag) | "Rule N" means rule N of that pinned text |
| Does the page still say what the item claims | the spec page(s) the item names under `gateway/specs/` — the requirement section + the page's index row, nothing more | is the flag still there, does the row still say that |
| Where the gateway's limits are declared (callers, rails, tiers, context sizes, session lifetime, the outcome window) | [`argocd/resources/agent-gateway/policy.json`](../../argocd/resources/agent-gateway/policy.json) — its top-level keys (`jq keys argocd/resources/agent-gateway/policy.json`) | the tier evidence the picks stand on: `benchmarks.json` and `benchmarks-manual.json` beside it |
| The same, as the running gateway serves it | the views `GET /healthz`, `/catalog/opencode`, `/catalog/openrouter`, `/sessions?task=<task>` on `agent-gateway.agent-egress.svc.cluster.local:8080` | a sitting's caller lists only the sessions it admitted itself: an empty `sessions` for a worker's task is not absence |
| Which build is running | `kubectl -n agent-egress get deploy agent-gateway -o jsonpath='{.spec.template.spec.containers[0].image}'` | an image bump rolls the pod; a claim about behaviour is about this build |
| The gateway's gauges | Prometheus `{__name__=~"gateway_.*",namespace="agent-egress"}` — e.g. `gateway_db_mode{namespace="agent-egress"}`, `gateway_go_catalog_age_seconds{namespace="agent-egress"}`, `gateway_tier_evidence_age_seconds{namespace="agent-egress"}` | tests a `standing` outcome's own trigger; **experiment** |
| The gateway's alert rules | [`argocd/resources/agent-gateway/prometheusrule.yaml`](../../argocd/resources/agent-gateway/prometheusrule.yaml) (fixtures: the `*.promtool-test` files beside it); as deployed `kubectl -n agent-egress get prometheusrule agent-gateway -o json` | the selector reads the same file for which dig findings are the island's |
| Which rulings are still pending | [`follow-ups.md`](../follow-ups.md) FU-270 | entry (e) |

Never: the gateway's `src/` (you judge the contract, not the code).

## What a ride can do

- **Recipe**: [`.agents/fix.yaml`](../../.agents/fix.yaml) (a `task/build` item: [`.agents/build.yaml`](../../.agents/build.yaml)).
  A `Touches` reaching `gateway/specs/**` or `gateway/tests/**` gets the pinned spec process
  mounted; the recipe refuses `.github/**`, `.agents/**` and `devbox.json|lock`.
- **Write tier** (`classify_touches` in [`agents/footprint.sh`](../../agents/footprint.sh), run 2026-11-20):
  `gateway/**` (`gateway/specs/**` included — an issue body that says it is a codeowner path is
  wrong) and `argocd/resources/agent-gateway/**` = `machine-merge`;
  `.github/workflows/gateway-image.yaml` = `codeowner-author` (entry (d)).
- **Gates**: `pr-open` runs `devbox run pr-gate` — the CI gates the diff selects plus `scan-secrets`; the map is
  [`scripts/diff-ci.sh`](../../scripts/diff-ci.sh).
  `gateway/**` selects `gateway-ci` (the suite, the spec gate and both ratchets),
  `gateway-evidence`, `gateway-specs-publish` and, for a spec page, `gateway-specs-site-e2e`
  (it needs a docker daemon); the deploy dir adds `manifest-lint`, `argocd-validate-pins`,
  `component-check`, `prometheus-rules-lint`. Then CI, the code reviewer and the specs reviewer.
- **Reach**: the repo's one claim block — the list is [agent-loop.md §What a ride can do](agent-loop.md#what-a-ride-can-do).
  A ride whose `Touches` reaches `gateway/**` (or declares none) is a docker ride
  (`fixer.dockerPaths`), so the site gate can run; `profile: python` is what lets the uv-locked
  suite install.
- **Not reachable, so intake reads it and writes it into the body**: the gateway's views and its
  deployed objects in `agent-egress` (the ride's kube reads end at namespace `homelab`, and the
  gateway shows a caller only its own sessions), Loki, and a vendor endpoint the catalog reads —
  a wire answer the item turns on is recorded by intake or is the item's own recorder work.
