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
- Worker-writable: `gateway/**` is `machine-merge` (`classify_touches` — an issue body that says
  `gateway/specs/**` is a codeowner path is wrong).
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

The island's own rows of the brief's §What you read table:

| Read | Why |
|---|---|
| [`README.md`](../../gateway/README.md) + [`specs/README.md`](../../gateway/specs/README.md) + the pinned `RULES.md` it names (a `gh api` GET of the pinned tag) | the island and its process (the pinned rules) |
| The spec page(s) the item names — the requirement section + the page's index row, nothing more | live-verify the claim (is the flag still there? does the row still say that?) |
| The gateway's own read-only views: `GET /healthz`, `/catalog/opencode`, `/catalog/openrouter`, `/sessions?task=<task>` on `agent-gateway.agent-egress.svc:8080`; the deployed `policy.json` and `benchmarks.json` under `argocd/resources/agent-gateway/` | live-verify a claim about the catalog, the store, a session's outcome; test a `standing` outcome's own trigger |

Never: the gateway's `src/` (you judge the contract, not the code).
