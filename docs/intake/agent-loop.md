# Island facts — the agent loop

> The §Island facts block for the **agent-loop** island. The rules are ONE home —
> [`islands/intake/rules/intake.md`](../../islands/intake/rules/intake.md); this file holds only the island's facts, under
> `## Sources` the island's own rows of its §What you read table, and under `## What a ride can do`
> the recipe, write tier, gates and reach. Island list + owning docs:
> [`spikes/context-and-autonomy.md`](../spikes/context-and-autonomy.md) §C7.

Body shape: edit

- **Repo** `teststuffstash/homelab`; island root `agents/` (+ `docs/agents/`, `.agents/`,
  `tofu/github/`, `argocd/resources/openrouter-proxy/`, `argocd/resources/agentstack/`). Its sibling
  repos (`agent-runtime`, `openrouter-operator`) are outside the selector's reach — a sitting on
  them is the seat's.
- **Membership** — `island_members agent-loop` in
  [`intake-select.sh`](../../islands/intake/scripts/intake-select.sh): title `scan:` / `coordinator` /
  `reviewer:` / `ride:` / `arbitrate` / `responder` / `dig` / `fixer` / `epic dispositions` /
  `agent-session` / `model scout` / `ADR-103` …, or every `Touches` entry under the prefixes. Last
  in precedence: a `garage:` title touching `agents/` is the substrate's.
- **Attribution inputs** (`kind: attribution`): this sitting also receives every bot-filed issue no
  island claims (the loop's own filings leave component attribution to intake) — name its
  island(s) first, then rule your part and `split` the rest out to their islands
  ([`intake.md`](../../islands/intake/rules/intake.md) step 0, outcome `split`).
- **Read set = the item's SLICE**: the owning doc SECTION the item names + the script it changes —
  never `docs/agents/` as a corpus (the design-agents read is operator-typed only;
  [`agents/jail-seat-card.md`](../../agents/jail-seat-card.md) §Design questions). A fact outside the
  slice that the decision stands on is read with the narrowest GET (intake.md §What you read);
  any other goes under `Unverified`, never a wider read.
- **New or re-grouped loop machinery** (a coordinator clause, a responder lane, a dig, a reviewer
  change of shape) is **`seat`**, never `queue`/`goal` — it is designed against the component's
  slice by the seat (same card, "a proposed change to a LOOP component IS the stop-and-ask trigger").
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

## Sources

`<ns>` is the repo's ride namespace — the repo name (`homelab`). How a sitting runs a Prometheus
query or a kube read: the LIVE READS block of
[`sitting.sh`](../../islands/intake/scripts/sitting.sh).

| question | read | note |
|---|---|---|
| A repo namespace's storage quota, as declared | [`agents/fixer/openrouter-operator/agentstack.yaml`](../../agents/fixer/openrouter-operator/agentstack.yaml), the repo's `storage:` block (`spec.repos[].storage`) | one size per storage class; `scratch` is what a docker ride's volume draws on. The other stacks' claims are in their `-iac` repos (not this island's) |
| The same, as deployed | Prometheus `kube_resourcequota{namespace="<ns>",resourcequota="agentstack-storage"}` | `type="hard"` is the cap, `type="used"` the draw, one series per storage class. The object: `kubectl -n <ns> get resourcequota agentstack-storage -o json`; **experiment** |
| The claim as the cluster holds it (has the merge synced?) | `kubectl get agentstacks.platform.teststuff.net platform -o json` | cluster-scoped; `.spec.repos[]` is the file above once ArgoCD has applied it |
| Concurrent rides allowed per repo | [`agents/coordinator-scan.sh`](../../agents/coordinator-scan.sh), `REPO_MAX_WIP` (`grep -n 'REPO_MAX_WIP=' agents/coordinator-scan.sh`) | a launcher default: an env override would be in the scan's workflow, `kubectl -n <stack>-agents get cronworkflows -o json` |
| How long a finished ride pod (and its scratch volume) stays | `agents/coordinator-scan.sh`, the "deleting terminal ride pod" block and `RIDE_ENDED_JANITOR_S` | the block's comment gives the grace per phase and why |
| Bulk-disk room (the scratch class rides `bulk`) | `kubectl -n longhorn-system get nodes.longhorn.io -o json` — the disks tagged `bulk`, `storageMaximum` / `storageScheduled` / `storageAvailable` under `.status.diskStatus` — and [`storage-ledger.md`](../storage-ledger.md) §Current shape | the ledger owns the committed sum and §The scratch class rides `bulk`; the live read owns today's numbers |
| Ride pods over time | Prometheus `kube_pod_status_phase{namespace="<ns>",pod=~"agent-.*"}` | value 1 on the pod's current phase; a range query gives how many ran at once; **experiment** |
| Ride pods and their volumes now | `kubectl -n <ns> get pods -l app=agent-session -o json`; `kubectl -n <ns> get pvc` | a terminal pod still holds its `*-docker-lib` claim until the janitor row above |
| The loop's schedules, as deployed | `kubectl get cronworkflows -A` | declared in `agents/coordinator/*-argo.yaml` and the Composition ([`argocd/resources/agentstack/composition.yaml`](../../argocd/resources/agentstack/composition.yaml)) |
| The loop's alert rules | `argocd/resources/{pushgateway,agentstack,openrouter-proxy,github-exporter,argo-workflows-alerts}/prometheusrule.yaml`; as deployed `kubectl get prometheusrules -A` | the file is the proposal, the deployed object is what fires |
| What a GitHub App may do (the grants register) | [`docs/github-apps.yaml`](../github-apps.yaml) | declared; a quiet `GithubAppPermissionDrift` means declared == live. A change to it is operator-only |

Never: `docs/agents/` as a corpus, Secrets and ConfigMaps (the sitting's identity reads neither).

## What a ride can do

- **Recipe**: [`.agents/fix.yaml`](../../.agents/fix.yaml) (a `task/build` item: [`.agents/build.yaml`](../../.agents/build.yaml)).
  Both refuse `.github/**`, `.agents/**`, `devbox.json|lock`, `mgmt/scripts/**` and the three box
  verbs; `docs/follow-ups.md` is never a ride's file.
- **Write tier** (`classify_touches` in [`agents/footprint.sh`](../../agents/footprint.sh), run 2026-11-20):
  `agents/**` (incl. `agents/coordinator/README.md`, `agents/replay/**`, the claim file) and
  `tofu/github/**` = `codeowner-merge`; `.agents/**` = `codeowner-author` (a `seat` surface);
  `docs/agents/**`, `argocd/resources/openrouter-proxy/**`, `argocd/resources/agentstack/**`,
  `argocd/platform/agent-coordinator.yaml`, `argocd/platform/agent-fixer.yaml` = `machine-merge`.
- **Gates**: `pr-open` runs `devbox run pr-gate` — the CI gates the diff selects plus
  `scan-secrets`. The map is [`scripts/diff-ci.sh`](../../scripts/diff-ci.sh)
  (`bash scripts/diff-ci.sh --ci-outputs <file of changed paths>` prints it per path). `agents/**`
  selects the replay and self-test suites (`clause-replay`, `deep-dig-test`,
  `responder-behaviour-test`, `footprint-test`, `merge-path-lint`, …); `argocd/resources/**`
  selects `manifest-lint`, `argocd-validate-pins`, `component-check`, `prometheus-rules-lint`,
  and for the Composition `xr-render` + `agentstack-rbac-lint`. Then CI and the code reviewer.
- **Reach** — the tiers of [`agentstack.md`](../agents/agentstack.md) §The egress dial that this
  repo's `fixer.egress` block in the claim turns on (`profile: python`, three `extraFQDNs`,
  `enforce: true`; no `spec.mcp`, no `ownServices`). This list serves every island of the repo:
  - baseline: the kube API, kube-dns, the registry mirrors (docker.io, ghcr, mcr, pypi, npm), the
    egress proxy and git-credential broker (`agent-egress`), nix-cache, devbox-search, Garage, the
    `monitoring` namespace (Pushgateway; Prometheus and Alertmanager by service DNS), `github.com`,
    `*.githubusercontent.com`, `cache.nixos.org`;
  - profile `python`: `pypi.org`, `files.pythonhosted.org`;
  - `extraFQDNs`: `raw.githubusercontent.com`, `ghcr.io`,
    `results-receiver.actions.githubusercontent.com`;
  - docker rides only (`fixer.dockerPaths` — `Touches` reaching `gateway/**`, or none declared):
    the kata LAN-VIP belt and `ghcr.io` for the daemon's own pulls;
  - kube reads: `agent-read-infra`, bound in namespace `homelab` only
    ([`agents/coordinator/agent-read-rbac.yaml`](../../agents/coordinator/agent-read-rbac.yaml)).
- **Not reachable, so intake reads it and writes it into the body**: any kube object outside
  namespace `homelab` — every row above that names another namespace or a cluster-scoped kind
  (the quota of another repo, the Longhorn node disks, the claim object, the cron workflows, the
  deployed rules) — plus resource quotas, Secrets and ConfigMaps anywhere, Loki, and any host not
  listed.
