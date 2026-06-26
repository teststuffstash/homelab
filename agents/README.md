# agents/ — the session launcher (cockpit side)

Operational tooling for the agent platform (design: [`../docs/agents/README.md`](../docs/agents/README.md),
ADR-077/078/081). This is the **cockpit**: it spawns and attaches per-project agent sessions on the
cluster. It needs `../tofu/kubeconfig` and knows the per-project namespaces/secrets, so it lives here
in homelab rather than with the image.

The two other pieces live elsewhere, by design:

| Piece | Repo | Why |
|---|---|---|
| **Harness image** (`agent-base`: goose + opencode) | [`agent-runtime`](https://github.com/teststuffstash/agent-runtime) | Artifact-producing; one-job CI (push→build→ghcr), own versioning/Renovate. Kept out of this IaC monorepo so the build rules stay trivial. |
| **Per-app recipes** (`.agents/fix.yaml`) | each app repo | They know `parser.py`, `devbox run ci`, the coverage gate. |

## The one-image, two-modes model

`agent-base` (built in `agent-runtime`) bundles the harnesses; the project toolchain is materialized
at runtime from the cloned repo's own `devbox.json`. The same image serves both modes — only the
launch differs:

| Mode | Launch | Output |
|---|---|---|
| **non-interactive** | coordinator runs a recipe headless | branch + PR |
| **interactive** | you `exec` a shell, drive goose/opencode with model overrides | branch + PR |

Same scope, same per-project key, same ephemeral lifecycle. You don't watch the work — you get a PR
and clone the branch locally if you want to inspect it. The only seam in/out is **git**.

## Why this *is* the jail

The shared Docker jail can see every project and every secret — no jail at all for a per-project
agent. Here the agent runs in its **own pod**: one repo, that project's `<project>-openrouter` key
(operator-minted, budget-capped), its own egress. The jail demotes to a cockpit that only spawns +
attaches; the blast radius collapses to a single project.

## Usage

```sh
# interactive: prep the repo, drop into a shell, run goose/opencode by hand
bash agents/agent-session.sh sleep-tracking

# non-interactive: run a recipe to a branch+PR, stream logs, pod self-terminates
bash agents/agent-session.sh sleep-tracking \
    --run "goose run --recipe .agents/fix.yaml --params issue=42"
```

The image must exist in ghcr first — build/push it from the `agent-runtime` repo.

## Known gaps (v1)

- **Plain Pod, not [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)** — controller
  not installed yet (ADR-078). Migrate `Pod` → `Sandbox` CR when it lands.
- **Git token (wired; needs the App)** — a low-priv `homelab-agents` GitHub App mints a ~1h
  installation token via the ESO `GithubAccessToken` generator (per-project, scoped to one repo +
  contents/PR), delivered as `GH_TOKEN`; the entrypoint uses it for private clone+push and `gh pr
  create`. Bootstrap with `scripts/github-agents-app-bootstrap.sh` (one Create + one Install click,
  rest scripted) + apply `<project>/infra/agent/git-token.yaml`. **v1**: pod holds the 1h token;
  **v2/ADR-081**: the egress proxy injects it, never held in the pod.
- **Egress not locked down** — once the Cilium policy lands it must allow the nix cache
  (`cache.nixos.org` / a self-hosted **attic**) or the project `devbox install` will hang.
- **Cold start** — first project `devbox install` pulls the full closure; a shared nix store / attic
  cache (the in-cluster analog of the jail's bind-mounted `/nix`) makes it near-instant.
- **opencode → homelab plugin (future UX)** — a thin opencode plugin could spawn the scoped pod the
  way Daytona's spawns a Daytona sandbox, replacing the launcher.
