# Spike — change hotspots, 2026-08-04 → 2026-09-11 (git, master, no merges)

**Question (operator, 2026-09-11):** what changes the most in `argocd/resources/` — deployment
configuration or the python code itself (github-exporter "looks like a project")? What in
`agents/**` changes the most, and could some codeowner responsibility there be given up, together
with refactoring? Rollout/rollback is not done yet either.

**Method.** `git log origin/master --since=2026-08-04 --no-merges --numstat` (962 commits: seat
693 — two author spellings —, `homelab-agents` bot 231, deploy bot 27, renovate 11). "Churn" =
lines added + deleted. Class by extension: code (`.py`/`.sh`), config (`.yaml`/`.json`/`.env`),
rule-test (`*.promtool-*`). Bot vs seat = commit author. Companion: the codeowner-catches census
([`codeowner-catches.md`](codeowner-catches.md), same window).

## Repo-wide (commits touching the path · churn)

| path | commits | churn |
|---|---|---|
| `agents/` | 483 | 81,613 |
| `docs/agents/` | 301 | 17,598 |
| `docs/` (top: tracker, ADR, runbook) | 221 | 12,962 |
| `argocd/resources/` | 156 | 46,994 |
| `scripts/` | 68 | 25,057 |
| `argocd/platform/` | 47 | 3,145 |
| `tofu/` | 29 | 27,671 |
| `.github/` | 22 | 1,712 |
| `machines/` · `ansible/` | 12 · 6 | 741 · 2,038 |

## `argocd/resources/` — the two "projects" are 51 % of the churn, and it is CODE

| service | commits (bot/seat) | churn | of which code | config | rule-test |
|---|---|---|---|---|---|
| `openrouter-proxy` | 37 (29/8) | 13,868 | **9,981** | 2,299 | 1,588 |
| `github-exporter` | 29 (20/9) | 10,046 | **3,958** | 2,986 | 3,102 |
| `pushgateway` (agent-run rules) | 10 (4/6) | 3,716 | — | 2,355 | 1,361 |
| `cloudflare-exporter` | 4 | 3,392 | 1,212 | 496 | 1,684 |
| `garage-alerts` | 14 (6/8) | 3,044 | — | 1,977 | 1,067 |
| `agentstack` (XRD + Composition) | 21 (9/12) | 2,843 | — | 2,843 | — |
| `registry-cache` | 7 | 2,024 | — | 1,092 | 932 |
| `loki` | 9 (0/9) | 1,271 | — | 1,130 | 141 |
| `registry` | 12 (2/10) | 554 | — | 499 | 55 |
| everything else (14 dirs) | ≤5 each | <800 each | | | |

- **github-exporter is a project:** `github-exporter.py` alone took 24 commits / +3,771 lines
  (the goal registry, blocking-park, queued-age, rail accounting, model-drift feeds); its
  `deployment.yaml` took 3. The exporter's PrometheusRules + promtool fixtures are a second, real
  surface (3,102 lines) — those belong with the platform, the python does not.
- **Five services ship code as a ConfigMap-mounted script on `python:3.13-slim`** — no image, no
  tag, no pin: `openrouter-proxy` (4 scripts, 9.4k lines), `github-exporter`, `cloudflare-exporter`
  (edge-probe), `garage-meta-rotation`, `garage-write-probe`. A merge rolls the pod on the
  ConfigMap hash; the only gate is the in-process `--self-test` in `ci`.
- **Rollout/rollback consequence:** the FU-044 deterministic revert chain on homelab covers ONLY
  first-party IMAGE-PIN bumps (iac-lane.md §Auto-revert does NOT generalize; 8 manifests carry a
  `ghcr.io/teststuffstash` pin today). The two highest-churn services are structurally OUTSIDE
  that class. Extracting them into image-producing repos (the agent-runtime / agent-coordinator
  shape: deploy-pin PR into `agents/images.env` or the manifest) puts them INTO the existing
  revert class with no new machinery, and gives each a contract test on the built artifact.
- The rest of `argocd/resources/` is alert rules + promtool fixtures + Applications — config
  churn in the 1–4k range per service, mostly seat-authored, mostly belt work.

## `agents/**` — where the codeowner reads land

| file | commits | +/− | bot / seat |
|---|---|---|---|
| `coordinator/TICK-LOG.md` (journal) | 188 | +8,401 | 0 / 188 |
| `replay/README.md` (generated index) | 123 | +1,147 −446 | 85 / 38 |
| `coordinator-scan.sh` | 66 | +5,922 −502 | **47 / 19** |
| `agent-session.sh` | 53 | +3,324 −234 | **37 / 16** |
| `coordinator/README.md` (the brief) | 36 | +1,732 −72 | 20 / 16 |
| `replay/families.tsv` (generated) | 36 | | 27 / 9 |
| `images.env` (deploy pins, carved out) | 21 | | 20 / 1 |
| `reviewer-session.sh` | 19 | +1,310 −62 | 9 / 10 |
| `coordinator/responder-argo.yaml` | 16 | +943 | 8 / 8 |
| `coordinator/fix-debounce-argo.yaml` | 11 | +567 | 3 / 8 |
| `ledger.py` + `ledger-emitter-test.sh` | 10 + 10 | | 8 / 2 each |
| `coordinator-session.sh` | 10 | +706 | 4 / 6 |
| the other `coordinator/*-argo.yaml` | 47 commits total | | ≈ 1:1 |
| `replay/fixtures/**` | 183 commits | | bot-heavy |

- `agents/**` excluding the journal and the replay tree: **270 commits, 172 bot / 98 seat**. The
  loop authors most of its own machinery; the seat's share is mostly gate reads + direct
  quickfixes.
- **Three files carry the code churn:** `coordinator-scan.sh` (5,420 lines, bash, +5.9k in the
  window), `agent-session.sh` (3,090 lines, +3.3k), `reviewer-session.sh` (1,248, +1.3k). All
  three are ADR-113's "logic that grew inside glue" and all three are where the census put
  every outage-class catch (`set -u` abort, throttle refusal, argv fallback).
- **Already machine-safe, still owned:** `agents/replay/**` (183 commits — every clause PR
  compels a fixture; CI executes them; the rubric's worlds-are-extraordinary rule + the
  pin-vacuity gate are the guards), `agents/*-test.sh`, the generated `replay/README.md` index
  and `families.tsv`, and the journal. None of these needed a human read in the census.
- **Not safe to release as-is:** `agents/coordinator/*-argo.yaml` (47 commits) — ArgoCD syncs
  them on merge into `agent-coordinator`, and no schema/behaviour gate covers Sensors and
  EventSources (`argo lint --offline` covers Workflow kinds only; iac-lane.md §L0b residue).

## Observations (facts, no recommendation)

- The two "projects" (proxy 9.4k + exporter python) are 14k of the 47k `argocd/resources` churn
  and 49 of 156 commits; 29 + 20 of those commits are bot rides — the loop already develops
  them as software, shipped as config.
- `agents/**` bot share is 64 %; the three bash entry points absorb 138 of the 270 non-journal
  commits.
- The replay tree is the single most-touched code path in the repo after the journal and the
  scan, and it has never produced a codeowner catch.
- No first-party service under `argocd/resources` has a rollout gate (rung 0 smoke hook,
  iac-lane.md §IAC-G05) or a rollback path other than `git revert` + the ConfigMap re-roll.
