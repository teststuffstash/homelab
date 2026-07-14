# AgentStack — the agents framework as a platform API (FU-048 / ADR-085)

**Status: BUILT 2026-07-12; first claim = the oracle stack (oracle-iac).** homelab publishes a
cluster-scoped Crossplane XRD `agentstacks.platform.teststuff.net`; a stack declares ONE
`AgentStack` in its `-iac` repo (its POLICY), and the platform's Composition renders the per-repo
fixer MECHANISM from it. Mechanism = platform, policy = stack — the ADR-084/ADR-085 lens.

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
| `agents-github-app` ExternalSecret + `agent-git-token-gen` GithubAccessToken + `agent-git-token` ExternalSecret (broker-labeled, ADR-087 leg B) | `agents/fixer/<repo>/git-token.yaml` / `<stack>-iac//<repo>/agent/git-token.yaml` |
| `OpenRouterKey <repo>` (standing budget key) | `<stack>-iac//<repo>/infra/openrouter-key.yaml` |
| `agent-worker-egress` CiliumNetworkPolicy with the **monitor→enforce dial** | `<stack>-iac//<repo>/agent/netpol.yaml` (FU-020) |
| `agentstack-proxy-session-keys` Role+RoleBinding (ADR-087 leg A) | the hand-list that lived in `agents/coordinator/openrouter-proxy-rbac.yaml` (deleted 2026-07-12 — all stacks on claims) |
| `agentstack-storage` ResourceQuota (per-StorageClass caps from `spec.repos[].storage` — ADR-089 quota-as-contract; rendered for ANY repo with a `storage` block, fixer or not) | nothing — namespaces were quota-less; over-cap PVCs used to wedge unschedulable in Longhorn |

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
- **Egress:** the composed CNP gains a LAN-resolver DNS leg (kata pods run `dnsPolicy: None`,
  FU-072) and the registry FQDNs — interim until the FU-073 mirrors land, then that block is
  deleted and the allowlist tightens back.
- **In-cluster services** (openrouter-proxy, garage, pushgateway) are rewritten to resolved
  endpoint IPs at dispatch (`resolve_ep` in agent-session.sh) — kata guests can't reach service
  VIPs (FU-072); delete the rewrites when that lands.

## The egress dial (the FU-020 rollout, encoded)

`fixer.egress` renders the worker CNP from **baseline + profile + extraFQDNs**:

- baseline: dns / agent-egress proxy+broker (the only LLM+credential exit) / nix-cache / garage /
  monitoring / github.com + `*.githubusercontent.com` + cache.nixos.org
- `profile: python` → + pypi.org, files.pythonhosted.org; `node` → + registry.npmjs.org
- `extraFQDNs`: earned from a monitor-phase harvest, never speculation

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

## Consumption + migration state

`coordinator-scan.sh`'s `stacks_json()` (the ONE swap-point, FU-045) reads
`kubectl get agentstacks -o json` **merged over** `agents/stacks.json` — cluster claims win per
stack name; a PROBE-FAILED read warns and falls back to the file alone. The reflex SA has
`agentstacks` get/list ([`agents/coordinator/rbac.yaml`](../../agents/coordinator/rbac.yaml));
the in-cluster path was **verified 2026-07-12** (report-only Job, same SA/image/clone as
coordinator-reflex: all three stacks listed from claims, no fallback warning).

**All three stacks are on claims (2026-07-12):**

| Stack | Claim |
|---|---|
| oracle | `oracle-iac//oracle-fleet/agent/agentstack.yaml` (reference; egress ENFORCED) |
| sleep | `sleep-iac//sleep-tracking/agent/agentstack.yaml` (egress MONITOR) |
| platform | `agents/fixer/openrouter-operator/agentstack.yaml` (no `-iac` repo — homelab IS its deployment truth; egress MONITOR) |

**stacks.json is NOT deleted — it is the committed MIRROR of the claims.** Two consumers a
cluster claim cannot serve keep it alive: the registration lint's repo universe in CI (no cluster
access — ADR-085's build-time-discovery question, resolved as "keep the mirror") and the
probe-failed belt. Sync it when a claim changes; generating it *from* the claims is FU-049's
catalog problem.

## Decisions (2026-07-12)

- **One global coordinator-reflex, not per-stack control planes.** The gate already iterates all
  claims for cents (deterministic, no LLM until work exists) and spawns *scoped* ticks; per-stack
  CronJobs would multiply idle wakes and pod churn while changing nothing about scoping. Revisit
  only if one stack's tick cadence must diverge or a stack needs isolation from another's queue —
  then it's a Composition addition (render a per-stack CronJob from the claim), not a redesign.
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

⚠ **The authoritative-labels gotcha.** The provider generates `IssueLabels` (=
`github_issue_labels`, plural) — it **owns the repo's entire label set and deletes unmanaged
labels**. `labels.tf` deliberately uses the singular, non-authoritative `github_issue_label`
("other labels are left alone"). So this is not "add a second manager": label ownership moves
**wholesale per repo** — add labels to the claim → verify the composed `IssueLabels` synced →
remove the repo from `label_repos` in `tofu/github` (claim first, tofu second, same discipline as
the proxy-RBAC hand-list migration). Two managers on one repo will fight, and the authoritative
one wins by deleting.

**Credential:** a dedicated **labels GitHub App** — `Issues:R/W` only, installed org-wide on *All
repositories* (new repos covered without a click; the install itself is the one click ever, per
the "only App installations are click-only" goal). Bootstrap like the other apps
(`scripts/github-*-app-bootstrap.sh` pattern), PEM → Infisical → ESO → the ProviderConfig
credential Secret. Do **not** widen the agents App with `Issues:write` — credentials stay
per-purpose.

**End state:** Administration tier = out-of-jail tofu with the fine-grained admin PAT; Issues tier
= claim-rendered via provider-upjet-github; clicks = App installations only.

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
