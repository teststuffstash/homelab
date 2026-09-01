# AgentStack — the agents framework as a platform API (FU-048 / ADR-085)

**This doc owns the `AgentStack` claim** — what a stack declares and what the platform renders
from it. homelab publishes a cluster-scoped Crossplane XRD `agentstacks.platform.teststuff.net`; a
stack declares ONE `AgentStack` in its `-iac` repo (its POLICY), and the platform's Composition
renders the per-repo fixer MECHANISM from it. **Mechanism = platform, policy = stack** — the
ADR-084/ADR-085 lens. Which stacks are on claims today is a cluster query, not a doc:
`kubectl get agentstacks`.

Two documentation surfaces, one story:

- **This file** — design, migration state, operational notes (the human/git surface).
- **In-cluster** — for an agent whose only tool is kubectl (the ADR-085 discovery direction,
  FU-049's pattern): the XRD schema descriptions render via
  `kubectl explain agentstacks.spec --recursive`, and the quickstart lives in a ConfigMap
  discovered from the XRD itself:

      kubectl get xrd agentstacks.platform.teststuff.net \
        -o jsonpath='{.metadata.annotations.platform\.teststuff\.net/docs-configmap}'
      # → crossplane-system/agentstack-docs
      kubectl get cm -n crossplane-system agentstack-docs -o jsonpath='{.data.USAGE\.md}'

  Convention (extend to every future platform XRD): the XRD carries
  `platform.teststuff.net/docs-configmap` + `platform.teststuff.net/docs-url` annotations, and the
  doc ConfigMap is labeled `platform.teststuff.net/docs=true` — so
  `kubectl get cm -A -l platform.teststuff.net/docs=true` enumerates every capability's usage doc.

## What a claim renders

Files: [`argocd/resources/agentstack/`](../../argocd/resources/agentstack/) (XRD + Composition +
docs ConfigMap; the `agentstack` platform Application, wave 5). Composition functions
(go-templating + auto-ready) install with the providers
([`argocd/resources/crossplane/functions.yaml`](../../argocd/resources/crossplane/functions.yaml)).

Per `spec.repos[]` entry **with a `fixer` block**, into namespace `<repo>` (which must already
exist — it belongs to the repo's own deployment, never to the XR):

| Resource | Replaces (hand-written) |
|---|---|
| `agent-git-<repo>-gen` GithubAccessToken + `agent-git-<repo>` ExternalSecret — both rendered into **agent-coordinator** (FU-089: central mint, the App key never enters a stack ns) + the in-ns `agentstack-worker` ServiceAccount (TokenReview identity) | `agents/fixer/<repo>/git-token.yaml` / `<stack>-iac//<repo>/agent/git-token.yaml` |
| `OpenRouterKey <repo>` (standing budget key) | `<stack>-iac//<repo>/infra/openrouter-key.yaml` |
| `agent-worker-egress` CiliumNetworkPolicy with the **monitor→enforce dial** | `<stack>-iac//<repo>/agent/netpol.yaml` (FU-020) |
| `agentstack-proxy-session-keys` Role+RoleBinding (ADR-087 leg A) | the hand-list that lived in `agents/coordinator/openrouter-proxy-rbac.yaml` (deleted 2026-07-12 — all stacks on claims) |
| `claude-session` ExternalSecret — only with `fixer.claudeTier: true` (FU-066a): the subscription oauth token, session-key-labeled; claude rides hold only `ref:<ns>/claude-session` | the operator-imperative `kubectl create secret` (oracle-fleet was the only one) |
| `agentstack-storage` ResourceQuota (per-StorageClass caps from `spec.repos[].storage` — ADR-089 quota-as-contract; rendered for ANY repo with a `storage` block, fixer or not) | nothing — namespaces were quota-less; over-cap PVCs used to wedge unschedulable in Longhorn |
| `argo-workflow` ServiceAccount + `workflowtaskresults` Role/RoleBinding — only with `spec.repos[].argo.enabled: true` (bool, default false; opts the namespace in to run **Argo Workflows**, the ADR-093 platform orchestration engine). The DAG + step images are STACK POLICY (WorkflowTemplates/CronWorkflows in the stack's own `-iac`/app repos) — mechanism = platform, policy = stack (ADR-085). The S3 artifact repository renders per-namespace behind `argo.artifacts: {enabled: true, capGi: N}` (default 2Gi, ADR-089 cap-as-contract): a PER-REPO Garage bucket `argo-artifacts-<repo>` + own rw key (no cross-stack key reach) + connection Secret `argo-artifacts-s3` + the default `artifact-repositories` ConfigMap — small step outputs only, large objects pass by reference (ING-RT-STEP-CONTRACTS). First consumer: oracle-fleet's ingestion DAG (oracle-iac#40) | the hand-written Argo RBAC/artifact wiring a stack would otherwise carry |

The composed Role is deliberately named `agentstack-*` (not `openrouter-proxy-session-keys`) so
migration never collided with the hand-list's same-named Role — each hand-list entry was deleted
*after* its claim went Ready, with no RBAC gap.

A repo entry **without** `fixer` is context-only: the coordinator watches/clones it, agents never
run pods in it (the `-iac` deploy targets, per the FU-052 exclusion).

## Docker-capable workers (`fixer.docker`, 2026-07-14)

A repo whose CI gate needs a real Docker daemon (kind/k3d/testcontainers — first claim:
oracle-fleet's kind gate, oracle-fleet#15) sets `fixer.docker: true`. It is the agent-platform
**counterpart of a CI workflow choosing the Docker-capable VM runner (ci-runner-01/ADR-082) over
an ephemeral in-cluster runner** — same policy question, same per-project answer, one knob.

- **Dispatch:** `coordinator-scan.sh` surfaces `dockerRepos` per stack; the coordinator adds
  `--docker` to `agent-session.sh`, which renders the ride as a **kata microVM pod** (RuntimeClass
  `kata` → the three kata-labeled laptops, one ~5Gi VM per node — the 8G ceiling) with a
  **dind sidecar** (image pinned in `agents/images.env`); the agent container gets `DOCKER_HOST`
  and stays non-root — the repo brings its own docker/kind CLI via devbox.json. Every sidecar
  accommodation is a spike finding (`docs/spikes/kata-ci-gate.md`): mknod `/dev/kmsg`, cgroup
  nesting via the dind entrypoint, MTU clamp, tmpfs docker-lib.
- **Egress:** the composed CNP adds the docker-only legs — the kata LAN-resolver DNS leg
  (`dnsPolicy: None`, FU-072) and the `ghcr.io` FQDN (the dind's own ghcr pulls stay direct until
  the gate configs route ghcr through the mirror per-tool). The pull-through mirrors themselves are
  **baseline** tier — open to every ride (§The egress dial).
- **In-cluster services** (openrouter-proxy, garage, pushgateway) are rewritten to resolved
  endpoint IPs at dispatch (`resolve_ep` in agent-session.sh) — kata guests can't reach service
  VIPs (FU-072); delete the rewrites when that lands.

## The MCP knob (`spec.mcp`, #1039)

`spec.mcp` is a **stack-wide** knob declaring the stack's MCP (Model Context Protocol) tool server
endpoint. When present, the Composition renders the endpoint's HOST (derived from the URL) into
every fixer repo's worker egress CNP (`toFQDNs` leg) — the agent session connects to this server
for tool calls (statute, search, give_feedback, etc.). The knob holds a URL (scheme + host + path,
e.g. `https://mcp.oracle.teststuff.net/mcp`); the launcher passes it verbatim to each harness's
own attach interface (#1041 — claude: a `--mcp-config` JSON file in the CLI's `mcpServers` shape;
goose: `--with-streamable-http-extension <URL>`; the server is streamable HTTP), while the
Composition derives the bare HOST from it for the CNP `toFQDNs` leg. That host
must be an FQDN, never a service VIP (kata guests cannot reach service VIPs, FU-072); the pod
receives it as a reachable variable.

**NO default on the object** — an omitted defaulted object is stamped into the stored claim by the
API server and permanently OutOfSyncs every claim file that does not carry it (the 2026-07-16
claudeTier lesson). Absent = no MCP attached.

**Distinct from `spec.slo.endpoint`** (the FU-104 blackbox probe target). They may share a URL for
a given stack (oracle's `slo.endpoint` and `mcp.endpoint` both point at
`https://mcp.oracle.teststuff.net/mcp`) but serve different consumers — the SLO endpoint is a
probe target for availability monitoring, the MCP endpoint is a tool server for agent sessions.
Keeping them separate means a stack can have one without the other, and the schema for each
carries only its own concerns (`slo` has `module`/`availability`; `mcp` has `tools`).

The launcher's harness-attach rendering and env-card lines are a sibling child (#1041); this
issue delivers the claim knob + egress leg, born together.

## The egress dial (the FU-020 rollout, encoded)

`fixer.egress` renders the worker CNP from **five tiers** — baseline (every ride, every stack),
capability-gated (docker-mode rides only), the claim-selected ecosystem profile, harvest-earned
`extraFQDNs`, and the **stack-declared MCP endpoint** (`spec.mcp`). This table is the **audit surface**
a human or auditor reads; the claim stays the per-stack policy surface. Keep it in sync with the
composed legs
([`argocd/resources/agentstack/composition.yaml`](../../argocd/resources/agentstack/composition.yaml))
leg-by-leg.

| tier | legs | rule |
|---|---|---|
| **baseline** (every ride, every stack) | kube-apiserver (READ-RBAC visibility, homelab#97) · DNS (kube-dns) · **registry mirrors (docker.io `.40.20`, ghcr `.40.21` — moved here by homelab#520)** · egress proxy + git-cred broker (`agent-egress` — the only LLM+credential exit) · nix-cache · devbox-search · garage · monitoring/pushgateway · github.com + `*.githubusercontent.com` + cache.nixos.org | open to everybody; each leg carries a one-line rationale |
| **capability-gated** (`fixer.docker: true`) | kata LAN-resolver DNS leg (`192.168.2.1` — `dnsPolicy: None` mechanics, genuinely docker-only) · kata LAN-VIP belt (nix-cache `.40.23` / devbox-search `.40.27` — kata rides install via them) · upstream registry FQDN `ghcr.io` (dockerd's `registry-mirrors` is Hub-only, so the dind's own ghcr pulls go direct until the gate configs route ghcr through the mirror per-tool; then this leg is deleted — the recorded plan) | gated ONLY for risk, cost, or genuine capability-specificity — the gate's reason is written at the leg |
| **ecosystem profile** | `python` → pypi.org / files.pythonhosted.org · `node` → registry.npmjs.org | claim-selected |
| **harvest-earned** | `extraFQDNs` | per-stack, monitor-phase evidence, never speculation (unchanged) |
| **stack-declared MCP** (`spec.mcp`) | MCP endpoint HOST, derived from `spec.mcp.endpoint` (a URL — the launcher passes it verbatim to the harness's attach flag, #1041) — the agent session's tool server; the derived host must be an FQDN, never a service VIP (FU-072/kata) | present when the stack declares `spec.mcp`; the endpoint is rendered into EVERY fixer repo's CNP (stack-wide knob, per-repo leg) |

**Why the mirrors are baseline** (homelab#520): read-only in-cluster pull-through caches — no
exfil surface (nothing writable), content-in parity with baseline's existing github/pypi reach.
The docker-gate bought no security and cost three triage sessions + a chronically reopening alert
thread (#107 legs 3/5/8: every mirror pod roll mints a new denied pod IP for `docker: false`
namespaces).

`enforce: false` (the default — new stacks start here) attaches the policy with
`enableDefaultDeny.egress: false`: full DNS visibility for the Hubble harvest, nothing blocked.
Rollout per stack: monitor → harvest flows over ~3 real rides → diff against the allowlist
(three-valued: ALLOWED / WOULD-DROP / **PROBE-FAILED** — an empty harvest is a failed probe, not
"no misses"; github.com flows must appear since every ride clones) → flip `enforce: true` in a
one-line `-iac` PR. Under enforcement a miss manifests as a worker **hang** (the FU-020 nix-cache
finding), so the `AgentWorkerEgressDropped` alert
([`argocd/resources/pushgateway/prometheusrule.yaml`](../../argocd/resources/pushgateway/prometheusrule.yaml))
names the cause within minutes — extend its namespace regex when onboarding a stack. Both harvest
prereqs are LIVE (2026-07-12, `tofu/cilium.tf`): `hubble.relay` (cluster-wide
`hubble observe -n <ns> --verdict DROPPED`, e.g. via
`kubectl exec -n kube-system ds/cilium -- hubble observe --server <relay-clusterip>:80 …`) and
`drop:sourceContext=namespace` (the metric's `source` label). The whole chain carries a live
positive control: a deliberate forbidden egress from a labeled pod in oracle-fleet hung exactly
as predicted and landed as `hubble_drop_total{source="oracle-fleet",reason="POLICY_DENIED"}` in
Prometheus.

**Phone-home class: kill at the TOOL, never the allowlist** (codified 2026-08-18 — the third
instance crossed the ≥2-pattern bar). A bundled tool calling home — update checks, telemetry,
registry fetches — is not a workload dependency: the CNP denying it is the system *working*, and
widening `extraFQDNs` for it would codify noise as a dependency. The remedy is the tool's own
kill-switch in the launcher's always-on env block (`agents/agent-session.sh`, the
devbox/uv/opencode precedent block), set **unconditionally** — the image bundles every harness, so
the emitter rides along whichever harness a stack uses. Instances: devbox's update check; uv
fetching a managed CPython from releases.astral.sh (homelab#107, ~272 drops); opencode's
auto-update + model-registry pair (homelab#456). Auto-update is also a **pin violation**, not just
egress noise: ADR-107's harness monoculture is mitigated by version-pinned images, and a
self-updating binary defeats that even where egress would allow it.

**New-binary intake (spike-lite):** a new binary entering agent-base or the env card gets ONE
monitor-mode probe ride with a drop read (`hubble_drop_total{reason="POLICY_DENIED"}` by
destination) before fleet exposure — new destinations either earn their FQDN via the harvest rule
above or get killed at the tool. The `AgentWorkerEgressDropped` alert stays the regression belt
for the conditional paths a single probe misses (all three instances above were caught by the
belt, not by a probe — the belt is the reliable layer; the probe only buys the days of alert
noise back).

## Consumption + migration state

`coordinator-scan.sh`'s `stacks_json()` (the ONE swap-point) reads
`kubectl get agentstacks -o json` **merged over** `agents/stacks.json` — cluster claims win per
stack name; a PROBE-FAILED read warns and falls back to the file alone. The reflex SA has
`agentstacks` get/list ([`agents/coordinator/rbac.yaml`](../../agents/coordinator/rbac.yaml));
the in-cluster path was **verified 2026-07-12** (report-only Job, same SA/image/clone as
coordinator-reflex: all three stacks listed from claims, no fallback warning).

**All FOUR stacks are on claims (2026-07-12; circles joined 2026-08-03):**

| Stack | Claim |
|---|---|
| oracle | `oracle-iac//oracle-fleet/agent/agentstack.yaml` (reference; oracle-fleet egress ENFORCED, oracle-iac monitor) |
| sleep | `sleep-iac//sleep-tracking/agent/agentstack.yaml` (sleep-tracking egress ENFORCED; sleep-iac + snore-recorder monitor) |
| platform | `agents/fixer/openrouter-operator/agentstack.yaml` (no `-iac` repo — homelab IS its deployment truth; ALL fixer repos egress ENFORCED) |
| circles | `circles-iac//circles/agent/agentstack.yaml` (bootstrap 2026-08-03; egress monitor) |

(Enforce states re-read from the live claims 2026-08-30 — the claim, not this table, is the
authority; re-check before citing.)

**stacks.json is NOT deleted — it is the committed MIRROR of the claims.** Two consumers a
cluster claim cannot serve keep it alive: the registration lint's repo universe in CI (no cluster
access — ADR-085's build-time-discovery question, resolved as "keep the mirror") and the
probe-failed belt. Sync it when a claim changes; generating it *from* the claims is FU-049's
catalog problem.

## Decisions (2026-07-12)

- **One global reflex, per-stack control via claim flags (revisited 2026-07-17, FU-080).** The
  gate already iterates all claims for cents (deterministic, no LLM until work exists) and spawns
  *scoped* ticks; per-stack control planes would multiply idle wakes and pod churn. Rather than a
  reflex-per-stack, per-stack autonomy is now two claim knobs the ONE global reflex respects:
  - **`spec.coordinator.enabled`** (bool, default **false**) — the per-stack autonomy switch (the
    FU-050 global switch made per-stack). `coordinator-scan.sh --spawn` skips a stack whose
    `coordinator.enabled != true`, so a proven stack graduates to autonomous coordination while
    newer ones stay off. A supervised `coordinator-session --run-tick` still overrides for a
    one-off tick.
  - **`spec.reviewer.enabled`** (bool, default **true** = current behavior) — auto-review this
    stack's PRs. Safe to leave on: reviewing green, unapproved PRs never dispatches new work.
    Read in exactly ONE place — `agents/reviewer-optout.sh` — because there are THREE reviewer
    dispatch sites and for three weeks only one of them read it (homelab#204: the perstack Sensor
    approved + auto-merged agent-runtime#57 on an opted-out stack while the reflex tick logged the
    correct skip). All three converge on `agents/reviewer-session.sh`, which runs that helper as a
    shell guard before it creates anything. **Fail-CLOSED**: an unreadable claims read skips
    dispatch rather than reviewing — for a *disable* knob an unknown is not permission, and the
    review path is level-triggered, so a skipped tick costs minutes. A fourth dispatch site must
    route through `reviewer-session.sh`; never copy the read. Pinned by
    `agents/reviewer-optout-replay.sh`.

  These make suspend/unsuspend **per-stack** (delivered via the global reflex honouring the claim
  flags). The agent-loop reflexes are Argo **CronWorkflows** (ADR-093), not CronJobs.
  **Re-revisited 2026-07-18 — "one global reflex" flips to "one per stack jail", graduated by a
  third knob:** `spec.loop.perStack` (bool, default **false**) renders the stack's OWN
  `coordinate-<stack>` CronWorkflow into `<stack>-agents`, running as the `agentstack-loop` SA
  with **zero Secrets in the namespace** — git creds are fetched per-run from the egress proxy's
  TokenReview-gated `/loop-git-token` (the caller must *be* `<ns>:agentstack-loop`; tokens are
  minted centrally in `agent-coordinator`, scoped to the stack's repos; the one documented Secret
  exception in the loop home is the write-only transcripts S3 key). The scan runs `SCAN_STACK`-
  scoped; item sessions dispatch into the loop home (`coordinator-session.sh --loop-ns`) and
  reach the fixer namespaces through the cross-ns loop RoleBindings — no cluster-scoped grant.
  The GLOBAL reflex SKIPS graduated stacks (a fourth knob, `loop.graduated`, also renders the
  per-stack `review-<stack>` cron) — and since ADR-120 (2026-08-31) the global coordinate surface
  is the **[switchboard](../glossary.md)**: Sensor-edge-only resolver (repo-dumb rings + capacity fan-out), its
  cron retired, so an UNGRADUATED stack has NO scan path until its claim flips these knobs
  (the switchboard warns per ring); Argo Events (bus + Sensors) deliberately stay global —
  trigger plumbing is dumb pipe, and a per-stack JetStream bus is 3×1Gi of state for near-zero
  event volume; the global Sensors route graduated events INTO `<stack>-agents` data-driven
  (`body.loop_ns` — coordinate doorbell, and the review edge since FU-100, 2026-07-27). Oracle
  graduated first (oracle-iac claim, 2026-07-18); sleep + platform followed 2026-07-26, circles 2026-08-03 —
  **all four per-stack since**. Per-role machinery inventory: [`roles.md`](roles.md).
- **GitHub-side + `.agents/` recipes stay OUTSIDE the claim (deferred, shape decided) — refined
  same day by the permission-tier split below (FU-068):** the *Issues-tier* slice (labels) has a
  designed in-cluster path via `provider-upjet-github`; the *Administration-tier* slice
  (repos/rulesets/org secrets) stays in `tofu/github` deliberately, not as a deferral. `.agents/`
  recipes are repo CONTENT (versioned with the code they steer) — a cluster resource referencing
  them would only duplicate git. The registration lint + FU-052 checklist remain the stitch across
  the three surfaces (claim / tofu-github / repo content).

## The GitHub side: split by permission tier, not migrated wholesale (FU-068)

**Design set 2026-07-12.** `tofu/github` is not one thing — it spans two GitHub permission tiers,
and they belong on different sides of the cluster boundary:

- **Administration tier stays in out-of-jail tofu, permanently.** Repos (`repos.tf`), rulesets
  (org + per-repo), org Actions secrets — all need `Administration:write`, and the whole security
  model of the agent platform is that this credential exists only in the operator's hands, never
  in a jail or the cluster (the bypass asymmetry: owner pushes bypass rulesets, the agents App
  can't reach master). Moving this tier in-cluster would put an org-admin credential where agents
  run; that's an ADR-scale boundary change, and the default answer is no.
- **Issues tier (labels) moves into the claim.** Labels need only `Issues:R/W` — small blast
  radius (can vandalize issues/labels org-wide; can't touch code, settings, or protection). This
  is the slice where stacks get self-service: `spec.repos[].labels` on the `AgentStack` claim, and
  the Composition renders the label set per repo = **platform taxonomy (`agent-fix`, `agent/*`,
  `agent-budget/*`) merged with the stack's extras**. Stacks write claims, never raw GitHub
  managed resources — MRs are cluster-scoped, so a raw MR could target another stack's repo; the
  Composition keeps scoping by construction (`repository:` comes from `spec.repos[].name`).

**Mechanism: [`provider-upjet-github`](https://github.com/crossplane-contrib/provider-upjet-github)**
(crossplane-contrib community extension; v0.19.1 2026-05-23; wraps terraform-provider-github
**v6.6.0**). Checked 2026-07-12: the generated `repo` group includes `IssueLabels`, `Repository`,
`RepositoryRuleset`, `BranchProtection`; the ProviderConfig supports **GitHub App auth**
(`app_auth` with id + installation id + PEM as a `\n`-escaped single line). Not provider-terraform
`Workspace`s — those need a state backend, drift at workspace granularity, and can't be composed
per-repo from the claim.

⚠ **The authoritative-labels gotcha** (the migration is finished — kept because the property is
permanent). The provider generates `IssueLabels` (= `github_issue_labels`, plural) — it **owns the
repo's entire label set and deletes unmanaged labels**. The retired `labels.tf` deliberately used
the singular, non-authoritative `github_issue_label` ("other labels are left alone"). So the handoff
was never "add a second manager": label ownership moves **wholesale per repo** — add labels to the
claim → verify the composed `IssueLabels` synced → remove the repo from `label_repos` in
`tofu/github` (claim first, tofu second, same discipline as the proxy-RBAC hand-list migration).
Two managers on one repo will fight, and the authoritative one wins by deleting.

**Credential:** a dedicated **labels GitHub App** — `Issues:R/W` only, installed org-wide on *All
repositories* (new repos covered without a click; the install itself is the one click ever, per
the "only App installations are click-only" goal). Bootstrap like the other apps
(`scripts/github-app-bootstrap.sh <slug>` — one script, manifest from docs/github-apps.yaml), PEM → Infisical → ESO → the ProviderConfig
credential Secret. Do **not** widen the agents App with `Issues:write` — credentials stay
per-purpose.

**End state:** Administration tier = out-of-jail tofu with the fine-grained admin PAT; Issues tier
= claim-rendered via provider-upjet-github; clicks = App installations only.

**Mechanism BUILT + FIRST MIGRATION LIVE 2026-07-16**
(`argocd/resources/crossplane/github-provider{,config}.yaml`, the XRD's `repos[].labels` + the
Composition's `IssueLabels` block with the platform taxonomy inline,
`scripts/github-app-bootstrap.sh homelab-labels`; homelab-labels App installed org-wide same day). The
taxonomy = GitHub defaults + the agent state machine + the Renovate/merge-path
lanes (`dependencies`/`automerge`/`deps-review`). **COMPLETE 2026-08-04** (FU-068): homelab was the
last holdout, joined the platform claim via `devbox run labels-handoff` (16 resources forgotten, 27
labels intact), and `tofu/github/labels.tf` was deleted — the claim is now the only label source, so
there is nothing left to keep in sync. Migration gotchas, found live: QUOTE label colors (`5319e7` parses as scientific
notation), write `labels: { extra: [] }` not `labels: {}` (server-default stamping → ArgoCD
drift), and the tofu handoff is **`tofu state rm`** — a destroy apply deletes the labels on
GitHub and the authoritative claim fights it back.

## Operational notes

- **Ownership collisions during migration:** Crossplane will not adopt an existing resource it
  didn't compose — if ArgoCD still owns a same-named resource (e.g. the old `agent-git-token`),
  the composed copy errors until the old one is pruned, then self-heals on the next reconcile.
  Delete the hand-written files in the SAME commit that adds the claim; expect one transient
  reconcile round.
- **OpenRouterKey re-mint:** moving the standing key into the claim deletes + recreates the CR —
  the operator releases the upstream key and mints a fresh one into `<repo>-openrouter`. A
  non-event between runs; don't cut over while a worker ride is in flight.
- **Readiness:** composed resources without real Ready conditions (CNP, Role, OpenRouterKey) are
  annotated ready-on-apply; the `agent-git-token` ExternalSecret keeps its real condition — so
  `AgentStack` READY=True ⇒ the token minted, which is the one that matters.
- **⚠ Crossplane can't compose a Role granting verbs it doesn't itself hold.** Kubernetes
  privilege-escalation prevention blocks it, so every verb the Composition hands out must be
  mirrored into the **crossplane-aggregated ClusterRole** first. Found three times, each time as a
  new-stack failure rather than a code change (a new stack composes new Roles/Bindings, so latent
  gaps surface on onboarding, not on edit): the loop SA's `pods/exec/pvc` verbs (2026-07-17 — the
  proxy Role had slipped by on core's secrets access), `argoproj.io/workflows` **create** for the
  sensor Role, and `endpoints` get/list for the FU-072 claims-read binding (2026-07-26 — oracle's
  older ClusterRoleBinding had masked it). Header note lives in
  [`agentstack/rbac.yaml`](../../argocd/resources/agentstack/rbac.yaml).
- **⚠ Argo Events string data-filter values are REGEX**, not literals. `""` and `!=` are rejected;
  use `.+` to mean "present and non-empty" (this is how the graduated-loop routing selects on
  `body.loop_ns`).
- **⚠ Bare hex colors in claim label values parse as YAML scientific notation** (`5319e7` →
  5.319e10) — quote them. The XRD description warns. Also, `labels: {}` gets server-stamped to
  `{extra: []}`, so write `extra: []` explicitly per the drift convention.
- **The credential airlock** (why the loop home can hold pod-create at all) is written up in
  [`platform-and-stacks.md`](platform-and-stacks.md) §"The credential-airlock pattern": pods in
  `<stack>-agents` hold only `ref:` creds, so a stack's workbench SA can control its whole loop
  without any broadening — the alternatives (widening the workbench SA into `agent-coordinator`,
  or moving the agents while they still held a raw token) were both rejected because either one
  kills the airlock.
