# 2026-10-06 — ci-runner-01's root disk filled unseen; oracle e2e red ~2 days, read as a reviewer outage; the runner App key surfaced in plans

**First symptom:** 2026-10-06 16:18:44Z — a snore-recorder `build-image` job on `ci-runner-01`
crashed on `No space left on device` (the runner's own diag log). Nobody saw it: neither runner VM
was scraped. **Noticed:** 2026-10-08 ~16:00Z, when the oracle jail reported that homelab-reviewer
had "stopped reviewing" oracle-fleet (#815 waiting ~20 h). **Class:** silent failure + cascade —
one full disk produced dead CI jobs, a poisoned registry login, and a misattributed outage; the
response then found the runner App's private key printed in clear by every plan touching the
runner cloud-init.

## Timeline (UTC)

| when | what |
|---|---|
| 2026-09-24 → | Anonymous docker volumes accumulate on ci-runner-01 (oldest 09-24 17:08Z, ~2.4 GB/day). |
| 10-06 16:18:44 | snore-recorder `build-image`: `docker/login-action` writes a ghcr.io login (job `GITHUB_TOKEN`) into `/home/runner/.docker/config.json`, then the worker dies on ENOSPC **before the action's post-step logout**. The expired login stays in the file both runner slots share. |
| 10-07 20:08 | oracle-fleet#815's `e2e` dies ~60 s in on ci-runner-01, no log blob (the runner could not write it). Nothing reruns it — the coordinator's ci-red clause serves agent PRs, #815 is seat-authored. |
| 10-08 05:27 | #816's first `e2e` attempt dies the same way (`_diag`: `IOException: No space left on device`); its rerun lands on a slot that gets through and #816 merges 05:46. |
| 10-08 ~16:00 | Oracle jail: "review-oracle pods start every 15 min but no review comes out". Seat: the reflex is correctly skipping a **red** PR; the red is the runner. |
| 16:06 | Seat reruns #815's e2e → dies again in 42 s, no log. ssh: `/` **100 %** (75G/79G), 698 dangling anonymous volumes = 33.6 GB. ci-runner-02 on the same curve (75 %, 173 volumes). **No series for either VM in Prometheus** — no node_exporter. |
| ~16:15 | `docker volume prune -f` on runner-01 → 57 % (images + build cache kept). Rerun → fails differently: `failed to fetch oauth token: denied` pulling `ghcr.io/astral-sh/uv` on the `default` builder. |
| ~16:20 | A/B on the VM reproduces it with the stale config and not with a clean one; mirror (.40.21) and ghcr itself both healthy. The expired ghcr.io entry removed; pull verified. |
| ~16:25 | #815's e2e green (attempt 4). |
| 16:32 | **#2379** merged — the detector: node_exporter in the runner cloud-init, static scrape job `ci-runner-node`, `CiRunnerRootFs{FillingUp,AlmostFull}` + `CiRunnerNodeExporterDown`, promtool fixture at the incident's slope. Live only after a VM recreate. |
| 16:54 | **#2381** merged — the cause side: `kind-janitor` reaps with `rm -f -v` + `docker volume prune -f`; per-slot `DOCKER_CONFIG` + a job-started hook clearing `auths`. Same recreate. |
| 17:09 | Building the runner verb (#2382), a subagent's scoped `mgmt-tf plan` printed the **runner-registrar App's private key** (PEM) to its terminal — `file(var.github_app_private_key_file)` passed into the cloud-init template unmarked. Also in the box's saved plan `.txt`. |
| 17:36 | **#2382** merged — `scripts/runner-maintenance.sh` (drain/verify/run) + `mgmt-tf summary`. |
| 17:50 | **#2384** merged — both key reads wrapped in `sensitive()`; verified on the box: same 4 replaces, 0 `PRIVATE KEY` lines in output or saved plan. The plan `.txt` holding the key shredded. |
| 17:50–17:53 | Rotation: operator mints a new key (GitHub console, the third-party-console class), stores it in the wallet; seat regenerates the jail cache, pushes it to the box (`mgmt-provision-secrets.sh --push`), new key mints a token. |
| 17:56:11 | Old key (`SHA256:dSMLt3…`) refused by GitHub (401) after the operator deleted it. |
| 17:55–17:58 | `runner-maint run` ci-runner-02 (scoped plan): replaced, but cloud-init's runner registration FAILED — "minimum runner version required to register … is now 2.329.0"; the install pin was 2.323.0 (a registered runner self-updates, so the stale pin only bites a fresh VM). Main state now stamped by tofu 1.13.1 (serial 376). Operator paged on `TargetDown{job="ci-runner-node"}`: the verb declared a window but opened no Alertmanager silence. Seat silenced by hand. |
| 18:24 | **#2388** merged (pin → 2.338.0); **#2387** merged 18:38 (the verb opens/expires owner-tagged silences). |
| 18:25–18:29 | ci-runner-02 re-run on the new pin → replaced, both slots online, node_exporter up, window closed clean. |
| 18:39–18:52 | ci-runner-01 via an UNSCOPED master plan (its pair was master's only change) → replaced and verified; the apply stamped the box's apply baseline at `31d0db06` (refused-rev cleared). The run's compare waited out `NodeRebooted` (Prometheus-side, `< 600 s` since boot — a silence does not hide it from `compare`). |
| 18:51 | Unscoped plan of master: **No changes**. Both `ci-runner-node` targets up, no runner alert firing; manual silences expired. |

## Root cause

**The disk:** `kind-janitor` — the hourly belt that reaps hung kind node containers
(`docs/patterns/kind-ci.md` rule 2) — removed them with `docker rm -f` **without `-v`**, so every
reap left the node's anonymous `/var` volume (2–2.8 GB each) behind; on runner-01 11 control-plane
reaps 09-21..10-05 account for ~28 GB of the 33.6. oracle-fleet's `registry:2` cleanup has the same
missing `-v` (~1 MB per run — most of the volume COUNT). **Why nobody saw it:** neither runner VM
ran node_exporter; the VMs predate the platform's metering of non-k8s hosts, and nothing alerted
on "a host we run that Prometheus has no series for".

**The poisoned login:** a persistent, shared runner lets a job's registry login outlive the job
when the job dies before its post-step — here the death was the full disk itself.

**The key in plans:** a secret file read passed into `templatefile()` without `sensitive()` — every
plan diff of the cloud-init file rendered it. It reached the box's saved plans (root-only, a box
that holds the key anyway) and the terminal of every jail session that planned a runner change —
today a subagent, i.e. a model context outside the jail/box trust boundary. Hence the rotation.
The sentinel's PR comment (addresses + counts only) never carried it.

**Ruled out:** a reviewer, review-reflex or GitHub fault (the reflex's skip of a red PR is by
design — `agents/review-reflex.sh` `green`); a ghcr/mirror outage (both answered; A/B on the
credential); random runner flakiness (every failure on runner-01 had a disk-full or stale-login
cause in `_diag`).

## Collateral

- oracle-fleet#815 red ~20 h and unreviewed; #816 lost one e2e attempt; snore-recorder's 10-06
  build. Unknown how many other jobs on runner-01 died between 10-06 and 10-08 — the failures left
  no log blob to count.
- A second, unrelated defect surfaced on #815 while it waited: the reflex's body-edit re-review leg
  has been inert since 2026-10-06 (`lastEditedAt` is not a `gh --json` field — quickfix 914b2b3c);
  fixed separately with a fake-`gh` field check so a bad field fails CI.

## Fixes

- **Detector** (belt + the missing metering): #2379.
- **Cause:** #2381 (janitor `-v` + anonymous prune; job-scoped registry logins). oracle-fleet's own
  `-v` fix handed to the oracle jail.
- **The key:** #2384 (`sensitive()`), the rotation above.
- **The procedure:** #2382 — `runner-maintenance.sh run <plan-id> <vm>`, the attended verb the
  management box will run later (`management-box.md` §Non-Talos VMs); the recreate of both VMs ran
  through it, ci-runner-02 first. Its first attended run found two gaps, both fixed the same hour:
  no Alertmanager silences (#2387) and a runner install pin below GitHub's registration floor (#2388).

## Probe lesson

- **"The reviewer is down" was a CI symptom.** Read the PR's checks before the reviewer: the reflex
  never dispatches on a red head, by design.
- **A job with no log blob** (`BlobNotFound` on the job logs API, steps with null conclusions) means
  the runner could not write — look at the runner's `_diag/Worker_*.log`, not the workflow.
- **"failed to fetch oauth token: denied"** on a healthy registry is a stale stored login, not the
  registry.
- **A host with no series is not a healthy host.** `up{instance=…}` returning nothing is the
  finding.
- **A declared window is not a silence.** It stops the responder's triage; Alertmanager still pages.
  A verb that takes something down owns its silences (node-maintenance did; the new runner verb did
  not until #2387). And `maintenance-window compare` reads Prometheus, so a silenced alert still
  counts as new there — a fresh boot holds a run for `NodeRebooted`'s 10 minutes.
- **An install pin a running thing self-updates past is invisible until the next fresh install.**
  The runner pin sat 14 versions behind with nothing failing — until a recreate.
- **Any plan text is a disclosure surface.** A `file()` of a secret into a resource argument needs
  `sensitive()`; grep the plan for `PRIVATE KEY` before it leaves the box.

## Residual

**FU-306** — the runner verb's box wiring (this attended run is its evidence) and the runner-pin
tracking decision. oracle-fleet's own `registry:2` / sweep `-v` fix is the oracle jail's.
