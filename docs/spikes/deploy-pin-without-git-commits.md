# Spike — deploying an in-repo image without a pin commit on master

_Opened 2026-11-12 (operator, from the #3262 investigation). Status: **options recorded, nothing
built, no decision** — parked until Kargo has rolled out in the oracle stack (oracle-fleet
ADR-OF-006); the operator decides for homelab after that. Tracked by FU-321._

## The problem

An image built from this repo is deployed by a second commit: the build workflow opens an
auto-merge PR that edits one `newTag` line. One change is therefore two master commits, two CI
runs, and a second base move every open PR has to absorb.

Measured on `origin/master`, 2026-11-12: of 949 commits in 30 days, 141 were auto-bumps — 127 for
`agent-gateway` (`.github/workflows/gateway-image.yaml` → `argocd/resources/agent-gateway/kustomization.yaml`)
and 14 for the ARC runner image (`.github/workflows/runner-image.yaml`).

Operator constraint (2026-11-12): if the platform stays a monorepo, version bumps must not land in
the same repo as the change. Git submodules are not wanted.

## Options

| | Where the pin lives | Master commits per deploy | Cost |
|---|---|---|---|
| A. Kargo patches the ArgoCD Application | on the Application; history in Kargo Freight | 0 | "what is deployed" is answered by the cluster, not `git log` |
| B. A separate pins repo | a small deploy repo the build writes to (the `-iac` shape) | 0 here, 1 there | one more repo; the Application reads two sources |
| C. Content-addressed tag | here, in the same commit as the change | 0 extra | every open PR for that image edits the same line; the image must exist before the rollout |
| D. Floating tag | nowhere | 0 | no record, no revert, no rollout trigger |

- **A** — a Warehouse watches ghcr for the image's tags; a Stage promotes each by setting the image
  override on the named Application ([`SERVICES.md`](../../SERVICES.md) — the Kargo row: "promoting by
  git writes / patching NAMED ArgoCD Applications"). Verification (`AnalysisRun`) and
  revert-by-promoting-older come with it. A rebuilt cluster re-resolves the newest tag from the
  registry, so boot-from-git holds.
- **C** — the pin dir (`argocd/resources/agent-gateway/`) is outside the build context (`gateway/`),
  so the tag can be the git tree hash of the build context, known before the commit; a gate checks
  pin == hash. No bot at all.
- **D** is ruled out by evidence: Kubernetes does not re-pull a moved tag, and the registry mirrors
  revalidate a tag pull against upstream on every request (the floating-tag incident, FU-255).

Leaning (seat, not ruled): **A**, with **B** as the fallback if every deploy must stay a git commit.

## What A needs — not verified against the cluster

1. A Kargo Project for the platform. One exists today (`oracle-kargo`); a Project is
   platform-created.
2. `kargo-write-guard` admitting that Project's patch of the target Application.
3. The app-of-apps ignoring the image field on that Application, so self-heal does not undo a
   promotion.

## What would settle it

- Oracle's Kargo rollout has run long enough to show promotion, verification and revert working
  unattended.
- One homelab image moved to the chosen option for a week: zero bump commits on master, a revert
  exercised, and a cold `argocd app sync` landing on the right tag.

## Related, still open with the operator

Whether the gateway stays an in-repo island or becomes its own repo, and how its rides get a
docker daemon (`fixer.docker` is one switch per repo). Option A and B work either way. Rides and
CI must run the same gates, so a ride-side skip (#3262) is not the route; #3088 holds the
chart-fetch half.
