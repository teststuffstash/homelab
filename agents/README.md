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

# interactive but spawned by a non-TTY caller: prep the pod + print the attach cmd, don't exec.
# Attach the TUI from a REAL terminal afterwards (re-attachable; pod stays up until you delete it).
bash agents/agent-session.sh sleep-tracking --harness opencode --model openrouter/deepseek/deepseek-v4-flash --no-attach

# non-interactive: run a recipe to a branch+PR, stream logs, post a stats comment, pod self-terminates
bash agents/agent-session.sh sleep-tracking --harness goose --model openrouter/deepseek/deepseek-v4-flash \
    --run "goose run --recipe .agents/fix.yaml --params issue=42"
```

Flags: `--run "<cmd>"` · `--ref <base>` · `--repo <url>` · `--harness goose|opencode` ·
`--model <provider/model>` · `--no-attach`. The image must exist in ghcr first — build/push it from
the `agent-runtime` repo.

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
- **Cold start (mitigated, not gone)** — the in-cluster [nix pull-through cache](../SERVICES.md)
  (`nixcache.nix-cache.svc`) + a **common toolchain baked into `agent-base`** (python/uv/kubectl/
  gitleaks, as a cache-warm) cut the first `devbox install`; the per-project delta still installs at
  runtime. A shared/persistent `/nix` store would remove the rest. ⚠️ Bake hits only land for
  *version-pinned* packages — `@latest` tools (kubectl/uv) drift vs the project lock and re-fetch;
  pin a minor (`kubectl@1.36`) in both `agent-base` and the project to get the cache hit.
- **opencode → homelab plugin (future UX)** — a thin opencode plugin could spawn the scoped pod the
  way Daytona's spawns a Daytona sandbox, replacing the launcher.

## Operational findings (2026-06-29)

- **opencode needs AVX2; goose runs anywhere.** opencode's Bun runtime SIGILLs (`Illegal
  instruction`) on the non-AVX2 nodes (`hp-01`, `thinkcentre`). The launcher pins the **opencode**
  harness to nodes labelled `homelab.io/cpu-avx2=true` (the Xeon VMs + the Haswell/Broadwell
  ThinkPads); the label is codified in Talos `machine.nodeLabels` (`tofu/locals.tf` `avx2_nodes`).
- **Run observability.** Agent pods are Loki-labelled `app=agent-session` + `pod`/`node`. Review any
  run in Grafana Explore: `{app="agent-session", namespace="<project>"}`, narrow by `pod`, `| json`
  to parse the structured final line. Every headless run also drops an `AGENT_RUN_STATS {json}` line
  (via `agent-finalize`) and the launcher posts a **PR comment** with the stats + a Grafana deep-link
  to that pod's logs — so a PR review is one click from both the numbers and the full run.
- **Cost is provider-routing + request-count, not output.** Autopsy of a real run (qwen3-coder paid,
  $5.79): output was negligible ($0.03); the spend was **all input** = OpenRouter routing to a
  pricier provider (AtlasCloud ~$1.15/M vs the $0.22 model-page headline) × **0% prompt caching**
  (the ~27K context re-sent on all 187 requests) × **looping** (187 req vs owl's 72; it never read
  the issue). Owl's provider cached 83% → near-free input. **Estimate:**
  `cost ≈ requests × avg_context_tokens × effective_$/M_input × (1 − cache_hit)`. Levers, ranked:
  route to a **caching** provider > pin a **cheaper** provider > **fewer requests**. Check the
  *effective* provider price in the OpenRouter activity export, not the model-page headline.
- **Model strategy (updated 2026-06-30).** **Don't chase free/cloaked.** `:free` tiers cap at ~8 rpm
  → useless for a tool loop, and **cloaked** models (the former `openrouter/owl-alpha`, which solved
  issue #2 → PR #6) get **rotated out and 404 mid-run** — exactly what happened. Default to a cheap,
  *multi-provider, cached* PAID model bounded by the per-session cap: **`deepseek/deepseek-v4-flash`**
  (~$0.09–0.10/M in, ~$0.02/M cached, ~12 providers @ 99%+ uptime). The per-session ephemeral key is
  the real guardrail now (hard `budgetUSD`), so paid-but-bounded beats free-but-flaky. The standing
  per-project key stays the weekly funding ceiling.

## Follow-ups

- **Per-session budget — landed (2026-06-29).** The cost autopsy traced the $5.79 to the *weekly*
  key (one session can eat the window). Built: (1) the `openrouter-operator` mints **ephemeral
  session keys** (hard `budgetUSD`, no reset, `expiresAt`) — `ephemeral: true` + `session`; (2)
  `agents/estimate_budget.py` sizes the pre-flight cap into a tier and `--emit-cr`s the CR; (3)
  `agent-session.sh --openrouter-secret <name>` binds a worker to a per-session key instead of the
  shared `<project>-openrouter`. The **coordinator** (`agents/coordinator/`) ties them together per
  dispatch. Remaining: the coordinator's own dispatch loop is still hand-driven (by design, v1).
- **OpenRouter provider routing — root cause found (2026-06-29), not yet wired.** The playground
  **"Cost/Quality Tradeoff" slider is UI-only — it does NOT touch API-key requests**, so the pod sent
  *no* `provider` field → default routing (filter ~30s-outage providers, then load-balance weighted
  by **1/price²** — a lottery, not a floor) drew AtlasCloud and stuck. Fix = send `provider` per
  request: `{order:["DeepInfra"], max_price:{prompt:0.3,completion:0.5}, ignore:["AtlasCloud"]}`.
  Inject via `opencode.json` `options.provider` (goose won't carry it) or — the real home — the
  **ADR-081 egress proxy** rewriting the body for every harness. Prefer a *caching* provider over
  blind `sort:"price"` (cheapest is often 0% cache). Biggest cost lever.
- **Recipe `gh issue view` + incremental push** — landed in `sleep-tracking/.agents/fix.yaml`;
  replicate when other repos get a fixer recipe.
- **Stats v2** — token breakdown (prompt/completion/cached/requests) needs the OpenRouter *activity*
  API (the in-pod inference key can self-report cost but not the per-request token split). The
  `AGENT_RUN_STATS` lines in Loki also enable a cross-run Grafana dashboard (`{app="agent-session"}
  | json`) — not built yet.
- **goose retry policy** — it retried a budget-exhausted `403` 812×; configure it to hard-stop on
  auth/limit errors.
- **Pin tool versions** in `agent-base` + project `devbox.json` so the baked-toolchain cache hits.
- **Live PR-comment demo** — both halves of the stats collector are validated independently; a real
  comment on a real PR still needs one fresh-issue owl run (~$0).
- **Wire `guardrail` in the openrouter-operator** so `only-free` is enforced, not just declared.
