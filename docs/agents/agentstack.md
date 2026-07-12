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
| `agentstack-proxy-session-keys` Role+RoleBinding (ADR-087 leg A) | the hand-list in `agents/coordinator/openrouter-proxy-rbac.yaml` |

The composed Role is deliberately named `agentstack-*` (not `openrouter-proxy-session-keys`) so a
stack's migration never collides with the hand-list's same-named Role — the hand-list entry is
deleted *after* the claim is Ready, with no RBAC gap.

A repo entry **without** `fixer` is context-only: the coordinator watches/clones it, agents never
run pods in it (the `-iac` deploy targets, per the FU-052 exclusion).

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
finding), so watch `hubble_drop_total{reason=POLICY_DENIED}` for the namespace. Harvest prereq
still open: `hubble.relay` is not enabled (flows are per-node + ring-buffered) — one line in
`tofu/cilium.tf` when the second stack onboards.

## Consumption + migration state

`coordinator-scan.sh`'s `stacks_json()` (the ONE swap-point, FU-045) now reads
`kubectl get agentstacks -o json` **merged over** `agents/stacks.json` — cluster claims win per
stack name; a PROBE-FAILED read warns and falls back to the file alone. A migrated stack keeps a
belt entry in stacks.json (marked `_migrated`) until the in-cluster coordinator-reflex path is
verified reading claims; the reflex SA has `agentstacks` get/list
([`agents/coordinator/rbac.yaml`](../../agents/coordinator/rbac.yaml)).

| Stack | State |
|---|---|
| oracle | **claim** — `oracle-iac//oracle-fleet/agent/agentstack.yaml` (reference); hand files deleted |
| sleep, platform | stacks.json + `agents/fixer/` / ApplicationSet dirs (migrate = write a claim, delete the dirs) |

Still per-repo, OUTSIDE the XR (the fuller FU-048 endgame): `.agents/` recipes, the GitHub side
(repos/labels/rulesets/merge-path callers — `tofu/github` + the registration lint), namespaces.
Not rendered per-stack yet: the coordinator CronJob (one global reflex iterates claims; a
per-stack control plane is a Composition decision deferred until a second coordinator is needed).

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
