# agents/ — the session launcher (cockpit side)

**How to run an agent session.** Design, roles and trust boundaries are
[`../docs/agents/README.md`](../docs/agents/README.md) — this file is the tool reference for the
scripts sitting next to it. It spawns and attaches per-project agent sessions on the cluster; it
needs `../tofu/kubeconfig` and knows the per-project namespaces/secrets, so it lives here in homelab
rather than with the image.

The same launcher serves the autonomous loop: `coordinator-session.sh` and `reviewer-session.sh`
delegate to `agent-session.sh`, so an in-cluster dispatch and a hand-run session take the same path.
The coordinator's own brief is [`coordinator/README.md`](coordinator/README.md).

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

# interactive but spawned by a non-TTY caller: prep the pod + print the attach cmd, don't exec.
# Attach the TUI from a REAL terminal afterwards (re-attachable; pod stays up until you delete it).
bash agents/agent-session.sh sleep-tracking --harness opencode --model openrouter/deepseek/deepseek-v4-flash --no-attach

# non-interactive: run a recipe to a branch+PR, stream logs, post a stats comment, pod self-terminates
bash agents/agent-session.sh sleep-tracking --harness goose --model openrouter/deepseek/deepseek-v4-flash \
    --recipe /work/sleep-tracking/.agents/fix.yaml --task issue-42
```

Flags: `--run "<cmd>"` · `--ref <base>` · `--repo <url>` · `--harness goose|opencode|claude` ·
`--model <provider/model>` · `--recipe <path>` (goose + claude — the launcher-owned path, FU-114; opencode uses `--run`) ·
`--task issue-N|pr-N` + `--round N` (idempotency key + transcript prefix) · `--work-branch <br>`
(resume a PR branch) · `--docker` (kata+dind; auto-derived from the claim's `fixer.docker`) ·
`--openrouter-secret <name>` · `--no-arm` (human-gated PR, FU-105 researcher; auto-derived from a
`research*` recipe) · `--no-attach`. The image must exist in ghcr first — build/push it from
the `agent-runtime` repo.

Every ride also mounts the stack's CI-published **devbox-cache** (eval seed + `file://` store)
via ImageVolume when its ghcr package is anonymously pullable — FU-096 / platform-and-stacks.md
§Composition axes; `AGENT_STACK_CACHE=0` opts out, absence degrades to a loud cold ride.

## Per-session budget (the breaker)

The shared `<project>-openrouter` key has a *soft per-week* cap, so one runaway session can eat the
whole window — which is exactly what happened (a qwen3-coder run spent $5.79 before the 403). The fix
is a **per-session hard cap**: mint a fresh, single-shot, self-expiring OpenRouter key sized to a
**pre-flight estimate**, used only by that pod.

1. **Estimate** the cost and pick a budget tier (`estimate_budget.py`, pure + `--self-test`):

   ```sh
   gh issue view 42 --repo teststuffstash/sleep-tracking --json title,body \
       -q '.title+"\n"+.body' \
     | devbox run estimate-budget -- --model qwen/qwen3-coder \
           --project sleep-tracking --session issue-42-round-1 --emit-cr
   ```

   It bands the issue by size (`cost ≈ rounds × requests/round × context_tokens × eff_$/M ×
   (1−cache)`), applies a buffer, and maps to a tier — `xs $0.25 / sm $0.50 / md $1 / lg $2` (force
   one with `--label agent-budget/sm`; an estimate above `lg` sets `escalate` for a human to eyeball).
   `--emit-cr` prints an **ephemeral `OpenRouterKey`** sized to the cap.

2. **Mint** it by applying that CR — the [`openrouter-operator`](https://github.com/teststuffstash/openrouter-operator)
   creates a key with a HARD `budgetUSD` (no reset window) + `expiresAt`, and writes a per-session
   Secret (`<project>-session-<id>-openrouter`). The pod consumes that Secret instead of the shared
   key; the key 403s the moment the session hits its cap and self-destructs at `expiresAt`.

The standing project key stays as the **funding ceiling**; the session key is the actual breaker.

## Launcher gotchas

Facts about *running* a session. Design lives in `../docs/agents/`; open work lives in
[`../docs/follow-ups.md`](../docs/follow-ups.md) — deliberately **not** restated here (this file
used to carry its own "Known gaps" and "Follow-ups" lists, and by 2026-08-01 eight of the nine ids
in them had shipped and been archived while the text still called them open).

- **opencode needs AVX2; goose runs anywhere.** opencode's Bun runtime SIGILLs (`Illegal
  instruction`) on the non-AVX2 nodes (`hp-01`, `thinkcentre`, `wk-metal-04`). The launcher pins the **opencode**
  harness to nodes labelled `homelab.io/cpu-avx2=true` (the Xeon VMs + the Haswell/Broadwell
  ThinkPads); the label is codified in Talos `machine.nodeLabels` (`tofu/locals.tf` `avx2_nodes`).
- **Run observability.** Agent pods are Loki-labelled `app=agent-session` + `pod`/`node`. Review any
  run in Grafana Explore: `{app="agent-session", namespace="<project>"}`, narrow by `pod`, `| json`
  to parse the structured final line. Every headless run also drops an `AGENT_RUN_STATS {json}` line
  (via `agent-finalize`) and the launcher posts a **PR comment** with the stats + a Grafana deep-link
  to that pod's logs — so a PR review is one click from both the numbers and the full run.
- **⚠ Cold-start cache hits need *pinned* versions.** The in-cluster
  [nix pull-through cache](../SERVICES.md) + the toolchain baked into `agent-base` cut the first
  `devbox install`, but `@latest` tools (kubectl, uv) drift against the project lock and re-fetch
  anyway. Pin a minor (`kubectl@1.36`) in **both** `agent-base` and the project to get the hit.
- **⚠ Don't hand-reconstruct a session Secret name.** It is `<project>-session-<id>-openrouter`;
  deriving it from the CR's `metadata.name` (`<project>-<session>`) omits `-session-` and the worker
  crash-loops on `secret … not found`.
- **Model choice is not a launcher concern.** `--model` is an override, not the policy: chains,
  strikes, provider pinning and the live registry are
  [`../docs/agents/model-routing.md`](../docs/agents/model-routing.md), and the router/budgeter is
  ADR-096. In particular the old "don't chase free/cloaked, hardcode one cheap paid model" doctrine
  that used to live in this file is **superseded** — model-routing.md §"The problem, from evidence"
  records why (reliability is a measurement, not a constant).
- **Still a plain `Pod`, not [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)** —
  the controller isn't installed (ADR-078); migrate to the `Sandbox` CR when it lands (FU-019).
- **opencode → homelab plugin (idea, unbuilt)** — a thin opencode plugin could spawn the scoped pod
  the way Daytona's spawns a Daytona sandbox, replacing this launcher.
