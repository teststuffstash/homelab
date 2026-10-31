# Island facts — the agent loop

> The §Island facts block for the **agent-loop** island. The rules are ONE home —
> [`gateway/intake.md`](../../gateway/intake.md); this file replaces only its §Island facts and the
> island rows of its §What you read table. Island list + owning docs:
> [`spikes/context-and-autonomy.md`](../spikes/context-and-autonomy.md) §C7.

- **Repo** `teststuffstash/homelab`; island root `agents/` (+ `docs/agents/`, `.agents/`,
  `tofu/github/`, `argocd/resources/openrouter-proxy/`, `argocd/resources/agentstack/`). Its sibling
  repos (`agent-runtime`, `openrouter-operator`) are outside the selector's reach — a sitting on
  them is the seat's.
- **Membership** — `island_members agent-loop` in
  [`intake-select.sh`](../../gateway/scripts/intake-select.sh): title `scan:` / `coordinator` /
  `reviewer:` / `ride:` / `arbitrate` / `responder` / `dig` / `fixer` / `epic dispositions` /
  `agent-session` / `model scout` / `ADR-103` …, or every `Touches` entry under the prefixes. Last
  in precedence: a `garage:` title touching `agents/` is the substrate's.
- **Read set = the item's SLICE**: the owning doc SECTION the item names + the script it changes —
  never `docs/agents/` as a corpus (the design-agents read is operator-typed only;
  [`agents/jail-seat-card.md`](../../agents/jail-seat-card.md) §Design questions). A fact outside the
  slice is a `seat` finding, not a wider read.
- **New or re-grouped loop machinery** (a coordinator clause, a responder lane, a dig, a reviewer
  change of shape) is **`seat`**, never `queue`/`goal` — it is designed against the component's
  slice by the seat (same card, "a proposed change to a LOOP component IS the stop-and-ask trigger").
- **Write tier** (`classify_touches`, run 2026-10-31): `agents/**` (incl. `agents/coordinator/README.md`)
  and `tofu/github/**` = `codeowner-merge`; `.agents/**` = `codeowner-author` (a `seat` surface);
  `docs/agents/**`, `argocd/resources/openrouter-proxy/**`, `argocd/resources/agentstack/**`,
  `argocd/platform/agent-coordinator.yaml` = `machine-merge`.
- **Codeowner-merge still queues**: the PR parks for the seat's ADR-110 read
  ([`adr.md`](../adr.md) ADR-110). Say so in the body (`## Out of scope` or a note: "lands through the
  ADR-110 seat read"), so nobody reads the park as a stall.
- **Clause edits ship a replay fixture in the same PR** (ADR-103's ratchet — `agents/replay/**`;
  CI reds without it). A queue-ready body that touches a clause file (`coordinator-scan.sh`,
  `agent-session.sh`, `review-reflex.sh`, …) names the fixture in `Touches` and an acceptance line
  for it. Body grammar: [`agents/coordinator/README.md`](../../agents/coordinator/README.md)
  §Authoring an issue body.
- **Gate / deploy**: CI + the code reviewer; the coordinator/worker pods `git clone --depth 1 master`,
  so a merge IS the deploy for scripts; ArgoCD syncs `argocd/**` on merge.
- **Operator-only**: Goal admission (breaker #1 — a Goal is the human's to queue),
  credential/App-permission changes (`docs/github-apps.yaml`, minted tokens), model/rail rulings
  (subscription order, worker model — the tracker marks them), anything `.agents/**` or
  `.github/**`.
