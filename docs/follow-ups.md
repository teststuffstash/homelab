# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-099**.
- **This file is the only tracker.** Everywhere else — docs, code comments, commit messages —
  reference the id (e.g. `FU-007`), never a free-floating `TODO`. Detailed context may stay near
  the code/doc it concerns; the item here carries the one-liner and links to the detail.
- **Don't file what's faster to do:** if it takes ≲5 minutes, the context is already in hand, and
  it's safe to do now — just do it. An entry costs more than the fix; file only genuine deferrals.
- **Resolving an item:** move it to [`follow-ups-archive.md`](follow-ups-archive.md) in the same
  commit as the fix, trimmed to the grep residue (what shipped / when / acceptance evidence /
  gotcha — a few lines) with an *(archived YYYY-MM-DD)* stamp. References elsewhere stay legal
  while the id is archived; when the entry expires out of the archive (≈a month, once stable),
  delete it and scrub remaining references in living code/docs — TICK-LOG/ADR references are
  historical and exempt. `devbox run follow-ups-lint` checks all of this.
- **Adding an item:** next free id, into the fitting theme section (ids don't encode theme), bump
  the counter above.
- **Single-writer contract (2026-07-10):** this file is operator/meta-edited ONLY — agents never
  append here. The sequential ids + the counter line make it a guaranteed merge conflict under
  parallel writers, and it doesn't scale past platform loose-ends anyway. Agent-discovered
  shortfalls go to the governing repo's `specs/` as id-free `⚑ gap` flags (ADR-086, oracle-fleet
  ADR-OF-003); coordinator session findings go to the TICK-LOG.

_Last updated: 2026-07-16._

## Secrets (the "secret cleanup" track)

- [ ] **FU-005** — Decide whether an Infisical break-glass second admin is worth codifying (one
      super admin today, signups disabled).

## GitOps & platform

- [ ] **FU-073** — **Pull-through OCI registry mirrors — CORE LIVE 2026-07-14 (ADR-091):**
      `registry-cache` ns, registry:3 pair (docker.io + ghcr), longhorn-bulk cache PVCs, BGP
      VIPs `.40.20/.21`; docker-mode agent rides wired (dind `registry-mirrors` + the
      `REGISTRY_MIRROR_*` env contract) and the docker.io FQDNs dropped from the agentstack
      egress (E2E under enforced deny-all: alpine 2s cold / 1s warm from a kata ride).
      **Remaining consumers:** (a) ✅ DONE 2026-07-16 — `machine.registries.mirrors` on all 8
      nodes (`local.registry_mirrors_patch`, talos.tf + metal.tf; skipFallback default=false so
      a dead mirror/cold boot falls through to upstream). Restart semantics ANSWERED: applies
      in-place, no reboot (canary wk-01 stayed Ready; pull of uncached alpine:3.18.12 rode the
      mirror — containerd/v2.2.3 `?ns=docker.io` in the mirror log, cache-filled + served);
      (b) ✅ DONE 2026-07-25 (commit 4661de9): `daemon.json` in the ci-runner cloud-init;
      VM recreated same morning (boot 11:57Z — hence the rotated SSH host key), live-verified
      2026-07-25 via `qm guest exec`: dockerd runs with Registry Mirror `http://192.168.40.20/`;
      (c) ✅ DONE 2026-07-25 (commit a0e59f3): owned dind spec in `arc-runners.yaml` —
      `--registry-mirror` + `--insecure-registry` on the pinned `docker:dind`; (d) ✅ DONE 2026-07-16 — oracle-fleet#35: `e2e-kind.sh` writes a
      `certs.d/hosts.toml` per registry into the kind node when the ride exports
      `REGISTRY_MIRROR_*` (kindest/node ≥ kind 0.27 preconfigures containerd's `config_path`;
      no-op on the CI VM). Acceptance = the FU-081 r4 green in-pod gate (garage image pulled
      through the mirror under the enforced CNP); (e) ✅ DONE
      2026-07-16 — `nixcache` LB VIP `192.168.40.23` (+ CNP belt in the agentstack Composition);
      the launcher passes `NIX_CACHE_URL=<VIP>` on docker rides (the agent-base entrypoint
      already honored the env — no agent-runtime change needed). Verify on the next kata ride:
      `devbox install` should be LAN-speed, not the ~4-min WAN fallback observed 2026-07-14.
- [ ] **FU-076** — **Re-check the metal reinstall mystery on the next metal (re)install**: a
      maintenance-mode reinstall of wk-metal-03 applied config verifiably carrying the
      metal_kata installer URL yet produced the plain-metal schematic (fixed via `talosctl
      upgrade`; likely also the origin of the kata `/dev/kmsg` regression, see
      `docs/spikes/kata-ci-gate.md`). Verify install.image is honored from maintenance mode.
- [ ] **FU-072** — **Kata guests can't reach cluster-service VIPs** (Cilium 1.19, kubeProxyReplacement,
      `bpf-lb-sock=false`). Diagnosed 2026-07-13 on wk-metal-03: from a kata pod, pod-to-pod
      (incl. cross-node coredns POD IP, UDP+TCP) and external-by-IP all work; ANY 10.96.x service
      VIP (UDP and TCP) black-holes — per-packet service translation isn't happening for
      kata-veth traffic even though it works for runc pods on the same node.
      `socketLB.hostNamespaceOnly=true` applied (tofu/cilium.tf) — no effect (socket LB was
      already off). Next probes: hubble verdicts on the kata endpoint for 10.96/16 traffic,
      cilium-dbg bpf lb list from the node agent, upstream cilium+kata issues. Workaround in
      place: kata CI-gate pods run `dnsPolicy: None` + the LAN resolver (192.168.2.1) — fine for
      k3d/registry work, blocks in-cluster consumers (garage transcripts upload from kata pods).
      2026-07-18 (meta-8): the launcher's endpoint-IP rewrites additionally need endpoints-read
      for IN-CLUSTER dispatchers — granted (agent-coordinator + agentstack-claims-read
      ClusterRoles); before that, coordinator-dispatched kata rides shipped raw svc URLs and the
      claude harness died ConnectionRefused (oracle-fleet#52 r1 strike).

- [ ] **FU-007** — **ArgoCD → Forgejo cutover** (offline-resilience goal). Prereq: pull-mirror the
      **homelab** repo itself into Forgejo (the `sleep-lab` org mirrors exist since 2026-06-21).
      Then flip `var.argocd_repo_url` + child-app `repoURL`s and deliver the Forgejo read cred via
      ESO. Procedure: `argocd/README.md` → "Forgejo cutover".
- [ ] **FU-010** — Infisical↔CNPG uses `sslmode=disable` (node-pg rejects CNPG's self-signed
      cert). Fine pod-to-pod; revisit if Cilium transparent encryption lands.
- [ ] **FU-011** — Pin the Crossplane `provider-terraform` package to a digest (currently the
      `:v1.1.1` tag).
- [ ] **FU-012** — Remote/encrypted tofu state backend (every root is local, gitignored state).
- [ ] **FU-013** — Home Assistant `/config` (and other stateful data) backup → Garage S3 with the
      bucket-id in git — the missing "boot-from-git" DR leg (Longhorn replicates in-cluster, it
      doesn't DR). `tofu/homeassistant.tf`.
- [ ] **FU-039** — **Platform self-service via Crossplane** (the "homelab as AWS/Civo" gap): a
      project can already IaC its S3 buckets/keys (ADR-076 Workspaces), OpenRouter keys
      (`OpenRouterKey` CR) and Postgres (CNPG `Cluster` CR) — but **not** its git repos
      (`tofu/github/`, admin PAT outside the jail), HTTPS names (OPNsense ansible), or its own
      ArgoCD AppProject/namespace. Decide per resource: Crossplane provider vs a thin homelab PR
      seam. Prereq for the FU-025 per-stack IaC-repo model.
      **HTTPS-names leg DELIVERED (ADR-092, 2026-07-15):** per-stack subdomain delegation —
      homelab wires `*.<stack>.teststuff.net` ONCE (wildcard cert + one `3.0/24` VIP + a dumb
      HAProxy TLS terminator → the stack's in-cluster Cilium Gateway; `stack_gateways` in
      `group_vars/opnsense.yml`, opt-in), then the stack adds hostnames as HTTPRoutes in its own
      `-iac` repo, zero homelab change. Opt-in is still a thin homelab PR *once per stack*; making
      that an XRD claim (ADR-085) is the residual. **Still open:** the git-repos + AppProject/namespace
      legs (both still `tofu/github` + `argocd/platform` operator PRs).
- [ ] **FU-055** — Flip the `oracle-fleet` repo `private` → `public` when that stack reaches its
      planned open-sourcing milestone ("P3" in its design doc, kept out-of-repo). The flip is a
      `tofu/github/repos.tf` visibility change + `allow_forking = true` (GitHub forces forking on
      public repos), applied outside the jail. `oracle-iac` stays private permanently.

## CI & dependency automation

- [ ] **FU-051** — **Deploy path per repo so an auto-merged bump reaches prod** (each project owns its
      test+CI+deploy; auto-merging a bump that never deploys is a footgun). BUILT per shape (2026-07-06),
      each via a first-party **deploy-pin PR** — CI-opened, NOT Renovate (Renovate = external deps only) —
      that auto-merges on a CI gate. All use the same readable **`2026.<m>.<d>-g<sha>`** version:
      • **app + chart** → the FU-025 `-iac` bump (sleep-tracking → sleep-iac).
      • **operator / controller** → **Helm chart to ghcr OCI** (ADR-084 shape, NOT the raw-manifest digest-pin
        that was first tried): openrouter-operator packages a chart (version==appVersion==image) to
        `oci://ghcr.io/teststuffstash/charts`; `deploy.yaml` opens a bump PR in **homelab/argocd** (the app
        is multi-source: OCI chart + homelab `$values` for the Infisical store, since the chart is generic).
        homelab `ci` = **`argocd-validate-pins`** proves the pinned chart renders with the values before
        auto-merge. LIVE (`argocd/platform/openrouter-operator.yaml`).
      • **image consumed by pods** (agent-base, agent-coordinator) → pinned by version in
        **`agents/images.env`** (sourced by the session scripts) + `review-reflex.yaml`, off `:latest`
        (no pullAlways, cacheable, traceable); each build's deploy-pin bumps images.env → pods use it on next
        spawn (the review-reflex CronJob rolls via the `agent-coordinator` ArgoCD app). PRs: agent-runtime#5,
        agent-coordinator#4.
      • **snore-recorder** → rides the Renovate flow; ansible→Pi deploy automation DECIDED 2026-07-24:
        **ArgoCD PostSync hook Job** in sleep-iac (ansible-playbook in-cluster; failed playbook = failed
        sync = red app; `syncPolicy.retry` = backoff; nightly CronJob belt for the offline-Pi gap) +
        digest-pinned `alpine/ansible` image + self-service ESO ExternalSecret. Platform half DONE:
        DHCP reservation `snore-recorder` b8:27:eb:fc:e8:7c → 192.168.2.185 (applied), private key in
        Infisical `SNORE_DEPLOY_SSH_KEY` (needs the arc-github-app `replace "\\n" "\n"` un-escape
        template). Remaining (sleep-iac side): move `snore-recorder/infra/ansible` + compose into
        sleep-iac, hook Job + ExternalSecret + CronJob + committed known_hosts, version-pin wiring;
        plant the deploy pubkey in the Pi's authorized_keys via the existing manual ansible access.
      • **homelab** → a CI-gated deploy TARGET (`require_approval=false`, `ci=argocd-validate-pins`).
      Prereqs (done): all agent repos are `github_repository` resources (→ `allow_auto_merge=true`), the
      `homelab-deploy` App installed on homelab, `DEPLOY_APP_*` scoped to the deploy-opening repos.
      **Remaining:** prove a dep bump flows E2E for the operator-chart and pod-image shapes — the
      app+chart shape is proven (sleep-tracking digest bump 2026-07-05 → sleep-iac deploy PR
      auto-merged; caller PRs agent-runtime#5 / agent-coordinator#4 merged 2026-07-06; the Renovate
      rollout itself is archived as FU-014).
- [ ] **FU-097** — **Homelab's own deploy path: the surfaces NOT reconciled by ArgoCD/tofu**
      (operator 2026-07-25, split out of FU-051 — "homelab needs its own follow-up with
      everything not covered by iac"). A merged change to these trees deploys NOTHING today;
      each needs either an automated apply or an explicit human-applied ruling + a drift belt:
      • **OPNsense** — `ansible/opnsense-*.yml` applied manually via
        `scripts/opnsense-playbook.sh`; merged group_vars changes sit until someone runs it.
        Candidate shape = the FU-051 snore precedent (in-cluster ansible Job; PostSync or
        CronJob), creds via ESO; a nightly `--check` diff → alert is the minimum drift belt.
      • **Proxmox host (pve)** — host-level config (storage, network bridges, LXC shell)
        beyond what `tofu/provisioning/` owns; currently pure hands-on-SSH.
      • **Home Assistant** — `homeassistant/` config applied imperatively (CLAUDE.md).
      • **Matchbox** — `ansible/matchbox*.yml`, same manual-apply gap as OPNsense.
      • **`tofu/` roots** — plan/apply from the jail is the DELIBERATE human gate (keep), but
        nothing detects live-vs-state drift between applies (`tofu plan` cron → alert?).
      First deliverable: per-surface ruling table (automate / human-applied + belt) in
      docs, then implement the automated ones one surface at a time. Relates FU-051 (per-repo
      bump-deploy), ADR-093 (Argo as the orchestration engine — candidate runner for the
      ansible Jobs).
- [ ] **FU-052** — **Onboard every APP repo to the agentic loop by DEFAULT** (direction 2026-07-06: the
      full flow — merge-path auto-merge **and** fixer (NL issue → worker → PR → review → merge) — should be
      the default for all app repos, not bespoke per-repo). A repo needs two layers: **(1) merge-path**
      (mostly covered by `new-agent-repo.sh`): managed `github_repository` (allow_auto_merge), agent labels,
      required-checks `ci`, the renovate-approve + update-pr-branch callers, a PR-triggered `ci`.
      **(2) fixer flow** (only sleep-tracking has it today): the `homelab-agents` App installed, an
      `agent-git-token` ExternalSecret, an **OpenRouterKey CR** (per-project budget key → `<project>-openrouter`
      Secret), `.agents/{fix.yaml,review.md}` recipes, a worker namespace, and the repo in
      `agents/stacks.json` (so `coordinator-scan` sees it). **Make it repeatable — DONE for layer-2 k8s
      infra (2026-07-06):** the `agent-fixer` ApplicationSet (git directory generator over
      `agents/fixer/*`, `argocd/platform/agent-fixer.yaml`) auto-emits the per-repo Application, so that
      part of onboarding is just adding `agents/fixer/<repo>/{openrouter-key,git-token}.yaml` —
      **since 2026-07-12 (FU-048): ONE AgentStack claim per stack instead (fixer block per repo);
      see docs/agents/agentstack.md.**
      **Expanded 2026-07-10 (1b4fa54 + agent-fixer fixes):** the *-iac* fixer dirs (`oracle-iac//*/agent`,
      `sleep-iac//*/agent`) are GitOps-owned via per-repo git generators (NB: generator `values` must
      nest INSIDE the git generator block — sibling placement is CRD-pruned; generator-template
      precedence doesn't bind, use uniform spec template + values); registration-lint v2 requires both
      merge-path callers per stack repo (probe-first: repo-visibility check before the callers check,
      -iac deploy targets exempt) — found + fixed snore-recorder's missing renovate-approve caller
      (snore-recorder e8bb33b) on first run. Still per-repo shell/manual: the `.agents/` recipes, the
      `stacks.json` entry, and the GitHub-side
      (`new-agent-repo.sh` merge-path) — the `AgentStack` XRD (FU-048) is the full collapse. The
      `homelab-agents` App is already installed on all four to-onboard repos (matrix in
      the exporter `/apps` page). **Onboarded so far:** sleep-tracking (reference), openrouter-operator (fixer
      infra + `.agents` PR #5). **Still to onboard:** snore-recorder, agent-runtime, agent-coordinator.
      **EXCLUDED — different workflow (per Rasmus):** sleep-iac (CI-only deploy repo, no
      fixer) and homelab (platform/base-infra, dep policy unresolved). Unattended running still needs the
      per-stack reflex (FU-050). Relates FU-014/FU-045/FU-050.
- [ ] **FU-070** — **`stack-template` org repo — collapse new-stack's step E (main-repo content).**
      The one onboarding step still done by copying oracle-fleet's shapes by hand: CLAUDE.md
      skeleton (read order / gate / invariants / related-repos-as-GitHub-URLs), `.agents/` recipe
      skeletons, devbox `ci`+`scan-secrets`, merge-path caller workflows. Make it a template repo
      (`is_template = true` in repos.tf), instantiate via `gh repo create --template` before
      `new-agent-repo.sh` (which then emits the adopt-import). stack-lint's REPO-03/04/05 already
      verify the result. Relates FU-052.
- [ ] **FU-015** — Custom ARC runner image: bake `xz`/`gh`/devbox + a warm nix store (kills the
      per-job `apt-get` and the ~5 min cold start), and wire the in-cluster nix cache as a
      substituter for runner pods. `docs/ci.md` → "residual costs".
      **Measured 2026-07-24 (oracle-fleet ci, run 30101073645): Install devbox = 454s of a 610s
      job — actual tests 43s. Toolchain tax ≈ 475s × every ARC workflow.**
      **Phase 1 LIVE 2026-07-25**: `docker/arc-runner/` image (runner 2.336.0 + xz/gh/jq +
      single-user nix 2.35.1 + devbox 0.17.5 + nixcache-VIP substituter), built by
      `runner-image.yaml` on ubuntu-latest (bootstrap: must not depend on the scale set it
      provisions), scale-set pin in `arc-runners.yaml` (replaces unpinned `:latest`).
      homelab ci: 70s vs ~180-210s baseline, green. install-nix-action proved idempotent on
      the baked image (0s) → unslimmed repos keep working. Slimming PRs: oracle-fleet#120,
      oracle-iac#178, sleep-tracking#28, sleep-iac#20, openrouter-operator#7.
      **Phase 2 warm store 2026-07-25**: workflow stages each repo's devbox.{json,lock} into
      the build (App-token fetch — repos are private, anonymous raw 404s silently) and bakes
      the closures (image 586→2260MiB with homelab's alone). NOT lockfile-coupled: stale store
      degrades to LAN-mirror delta fetches. **OPERATOR ACTION: install the homelab-renovate
      App on oracle-fleet + oracle-iac + agent-coordinator** (jail PAT can't, 403 by design) —
      then add them to runner-image.yaml's `repositories:` list so the hot-path oracle-fleet
      closure warms too. agent-coordinator ci needs no slim (docker verification build, no devbox).
      Warm image live+measured: homelab ci 38s (baseline 180-210s, slim-only 70s) — ~5x.
      **Oracle trio warmed 2026-07-25** (App installed by operator, github-apps.md regenerated;
      image `2026.7.25-g171a704c735d` built+pinned; oracle-fleet/oracle-iac added to the
      devbox-update.yaml matrix same day). **oracle-fleet ci warm-measured (16:33Z run): job
      297s vs 437s slim-only vs 610s baseline.** Decomposition: 94s devbox ensure-packages
      (nix profile REALIZATION, CPU-bound — store paths ARE baked; homelab's smaller closure
      realizes in 28s), ~12s gates+uv, 87s pytest (real work), 87s evidence+specs-site publish
      (real S3 I/O). **The 94s root-caused by experiment (2026-07-25): nix EVALUATION, not
      fetching** — cold `~/.cache/{nix,devbox}` costs 127s wall/84s CPU even on a fast desktop
      with a complete store (warm cache: 7.7s; warm `.devbox` project: 0.09s). The image was
      deleting its own eval cache post-warming; fixed (keep the cache, commit ddbd9d9) —
      expect ensure ~10-20s on the ThinkPads. The other two hot spots are queued to the loop:
      fleet#129 (publish uploads at ~1 obj/s — 87s) + fleet#130 (pytest 72s, 36s undecomposed
      in collection+test_build). Agent-base gets the same eval-cache treatment = FU-096.
      **Re-measured 2026-07-25 (fleet ci run 30169969318, eval-cache image + fleet#131's
      parallel uploads): job 127s — ensure 94s→~5s, publish 87s→31s. Target met.** Pin
      automation closed same day: runner-image.yaml self-bumps the arc-runners.yaml pin after
      every build + Monday 06:00 cron rebuild (3h after devbox-update's lock bump — without it
      every weekly bump silently staled the warm store); DEVBOX_VERSION/NIX_VERSION ARGs
      renovate-tracked via customManagers in renovate-global.json. **Remaining: watch one
      scheduled Monday cycle E2E (locks → rebuild → self-bump → roll), then archive.**
- [ ] **FU-098** — **GitHub App permissions: declared-state + drift verification (operator
      2026-07-26, prompted by the F1 workflows-scope block).** Permissions live in FOUR
      unsynchronized places today: the 7 bootstrap scripts' inline `default_permissions`
      (creation only), github-setup.md §2's hand table (holds the per-permission WHYs),
      the live App settings (truth, UI-only — the API can READ via `GET /app` JWT but never
      WRITE, so verify-only IaC is the honest ceiling), and every MINT SITE that requests
      permissions (Composition `GithubAccessToken` blocks, `create-github-app-token` steps —
      a request ⊄ App grant 422s in prod, which is exactly how F1 surfaced). Design:
      (a) ONE declared file `github-apps.yaml` — per App: ids, purpose, permissions each
      with `why:` naming its consumer, events, install scope; bootstrap scripts template
      their manifest FROM it; setup.md §2's permission column becomes generated.
      (b) `github-apps.sh` grows the verify leg: per-App JWT → `GET /app` (+ installation
      permissions) → diff vs declared → github-apps.md gains a permissions matrix with ⚠
      drift marks → nonzero exit = `devbox run github-apps-lint`.
      (c) **the ⊆-invariant lint**: statically collect every mint site's requested
      permissions (composition.yaml, workflows, agents/coordinator/*.yaml) and check
      request ⊆ declared per App — tonight's class fails in CI, not as a prod 422.
      (d) **continuous belt via github-exporter** (holds App keys in-cluster already,
      FU-084): collector emits live-vs-declared drift gauge → symptoms-only alert ("App
      <x> permissions differ from github-apps.yaml"). Change flow inverts to: PR the yaml
      (why included) → alert fires until the UI click + install approval land → clears —
      BOTH hope-paths (click-without-PR, PR-without-click) become visible. Install repo
      selection stays click-only (user-to-server API, tried+removed 2026-07-01 — setup.md).
      Relates FU-017 (over-grant trimming falls out of the per-permission why), FU-084.
      **BUILT 2026-07-26** (same session): `docs/github-apps.yaml` (8 apps, per-permission
      why, decided ABSENCES — incl. renovate's no-vulnerability_alerts per the renovate.md
      OSV ruling), `scripts/github-apps-lint.py` (⊆-invariant over 7 mint sites + exporter
      JSON-copy sync; in devbox + ci), verify leg in `scripts/github-apps.sh` (per-App JWT →
      GET /app → drift matrix in github-apps.md, --lint exits nonzero), exporter
      `collect_app_permission_drift` (agents+reviewer keys mounted; openssl-subprocess JWT)
      + `GithubAppPermissionDrift` alert (30m for). `workflows: write` DECLARED for
      homelab-agents — the inaugural grant landed 2026-07-26 (drift 1→0 confirmed live);
      workflows:write on the composition worker gens; fleet#134 queued.
      **Single-source completion (operator direction 2026-07-26):** ONE creation entrypoint
      `scripts/github-app-bootstrap.sh <slug>` builds the manifest FROM the yaml (the six
      per-App scripts' creation subcommands are retired stubs; they keep only app-specific
      secrets/verify plumbing, delegated via `bootstrap.legacy`); the per-App markdown is
      GENERATED — **final form (operator direction 2026-07-26): SERVED, never committed.**
      The CI-auto-commit route was rejected (a GITHUB_TOKEN push triggers no workflows → the
      PR head loses its required ci check; an App-token push re-triggers but invites updater
      ping-pong); instead the github-exporter renders the declared-vs-live page per poll at
      **GET /apps** (in-cluster `github-exporter.monitoring.svc:9504/apps`) including the
      keyed Apps' live install-repo enumeration (the git-token.yaml "verify coverage BEFORE
      adding" guard). docs/github-apps{-declared,}.md + the md generator DELETED — the yaml
      is the readable declared source; github-apps.sh remains the outside-jail deep verify
      (report to /tmp). Remaining: port the six secrets/verify flows into the single script
      as each App next needs them; fill the null app_ids (next deep-verify run); consider
      adding merge/renovate/deploy keys to the exporter belt; optionally a LAN name for
      /apps (rides the next opnsense change).
- [ ] **FU-016** — SLSA Phase-1: cosign signing + SBOM + scan on the hosted runners (both tiers).
      Plan: `docs/slsa.md`.
- [ ] **FU-017** — Merge the two runner GitHub Apps (`homelab-arc-…` + `homelab-runner-registrar`)
      — both need only org self-hosted-runners R/W. `docs/github-setup.md` §2.

## Agents

- [ ] **FU-086** — **Item-scoped coordinator dispatch (ADR-094 build): the scan emits work units,
      the session judges one item.** **CORE SHIPPED 2026-07-17, E2E-verified:**
      `coordinator-scan.sh` emits `(clause, repo, item)` units (queued-dispatch | c4c5-redispatch
      | changes-requested | merge-conflict | unarmed-major) and `--spawn` dispatches the single
      highest-priority unit (in-flight before new; WIP=1 kept) via `coordinator-session.sh --item`
      with the stack's `coordinatorModel`; `SCAN_ITEM_MODE=0` = whole-stack rollback (also the
      janitor/manual path). Scheduling predicates in the scan: deps closed (FU-087), lane free
      (`track/*` ≤1 in-progress per lane), repo dispatchable (claim `fixerRepos` — context-only
      repos report as visible ⚠, never dispatch), capacity (subscription-latch pre-spawn).
      Acceptance: a deliberately stale unit (merged PR#53 as changes-requested) re-read live,
      exited clean, fixed only its own item's label drift (#42 → agent/done). STILL OPEN: the
      `arbitrate` clause (rounds-exhausted/flip-flop detection as a unit), the FU-085 compound
      (Sensor submits item units directly; cron sweep emits only missed units), the coordinator
      cron relax `*/10 → */30` (edge proven through meta-9/10; consolidated here from FU-084(b)
      2026-07-25), red-beyond-T as a scan predicate (inherited from FU-050 on its archival —
      the github-exporter's CI metrics carry the out-of-band half), lifting WIP>1
      (lane-parallel dispatch — FU-088 gates are in), janitor-tick cron demotion. Original spec:
      scheduling predicates were: lane free, deps closed (FU-087), repo dispatchable (claim
      fixer block — makes context-only `oracle-iac` a visible predicate), capacity (FU-088 — a
      PREREQUISITE before WIP goes above 1). Keep a ~daily report-only **janitor tick** for
      board-level judgment (direction-change sweeps, orphans, cross-PR smells). Explicitly
      skipped: multi-dispatch TICK_PROMPT (prompt-level parallelism, obsoleted by this). FU-085's
      edge then submits units directly (events are item-shaped); the cron sweep emits missed
      units. Relates FU-050/FU-080/FU-085, ADR-094, oracle-fleet `specs/TRACKS.md`.
- [ ] **FU-080** — **Per-stack coordinator/reviewer rendered from the AgentStack claim → the stack
      jail controls its whole loop.** Decided direction 2026-07-16 (session with the operator; the
      revisit trigger foreseen by agentstack.md §Decisions fired): the oracle stack jail's
      `oracle-workbench` SA (namespace-admin, oracle-iac//oracle-fleet/agent/workbench.yaml) can
      spawn fixer workers but cannot touch coordinator/reviewer (ns `agent-coordinator`) — on
      oracle-fleet#22 the mono jail had to drive the loop. REJECTED: broadening the workbench SA
      into agent-coordinator (pod-create there ⇒ can mount `coordinator-git` — the airlock dies)
      and moving the agents while they held the raw token (retired by FU-066(d), the prereq that
      is now in). The build: the Composition renders per-stack coordinator/reviewer
      identity+launch RBAC (and optionally a per-stack reflex CronJob) INTO the stack's fixer
      namespace — pods there hold only `ref:` creds, so the workbench SA controls the loop by
      construction, zero broadening. Include the two cross-ns leftovers found 2026-07-16:
      (a) ✅ DONE 2026-07-17 (first brick) — `agent-transcripts` ClusterSecretStore (ESO
      kubernetes provider, scoped SA; argocd/resources/agentstack/transcripts-store.yaml) +
      per-fixer-ns ExternalSecret in the Composition; worker pods secretKeyRef the key IN-NS,
      agent-session.sh reads no key material, and the rbac.yaml "one deliberate exception" is
      REMOVED — the coordinator SA now has zero secret access;
      (b) ✅ DONE 2026-07-17 — `oracle-workbench-orkeys` Role+Binding in oracle-iac
      workbench.yaml (openrouterkeys R/W, mint→observe→delete; oracle-iac#34, CI-only merge).
      **Identity+launch-RBAC render DONE + VERIFIED 2026-07-17:** the Composition renders per fixer
      repo a NAMESPACED `agentstack-loop` SA + Role (pods/exec/pvc/openrouterkeys) + Binding — the
      in-namespace equivalent of the global coordinator's cluster-scoped grant, ready for a
      per-stack coordinator/reviewer to run as. Additive (nothing binds a pod to it yet). Verified
      live across all 3 fixer namespaces: loop SA CAN create pods+openrouterkeys in-ns, CANNOT
      create pods cross-ns or read cluster secrets. ⚠ Gotcha (agentstack/rbac.yaml header): k8s
      privilege-escalation prevention blocks Crossplane from COMPOSING a Role that grants verbs it
      doesn't itself hold — the pods/exec/pvc verbs had to be mirrored into the
      crossplane-aggregated ClusterRole (the proxy Role slipped by on core's secrets access).
      Airlock pattern documented in docs/agents/platform-and-stacks.md §"The credential-airlock pattern".
      **`reviewer.enabled` knob CONSUMED 2026-07-17 (first slice):** the global `review-reflex.sh`
      now reads the claims each tick and drops every repo of a stack with `reviewer:
      {enabled: false}` (probe-first: a failed read warns + keeps the full list). Found live: the
      oracle claim's disable had synced but the schema-only knob gated nothing — reviews kept
      firing. The full per-stack CronWorkflow render below stays the real fix.
      **Loop-home brick DONE 2026-07-17:** the Composition renders the per-stack
      `<stack>-agents` Namespace + its `agentstack-loop` SA and adds that SA to every fixer ns's
      loop RoleBinding — cross-ns dispatch on namespaced grants only, verified live (oracle's
      loop SA: pod-create YES in oracle-fleet, NO in sleep-tracking; all three namespaces
      rendered). Cred note: coordinator-claude needs NO per-stack rail — the opaque
      `ref:agent-coordinator/coordinator-claude` resolves at the egress proxy from any ns.
      **PER-STACK LOOP BUILT 2026-07-18 (operator-confirmed decisions):** (1) broker-only creds
      in `<stack>-agents` — the workbench MAY hold pod-create there because no cross-boundary
      Secret exists in the ns (one documented exception: the write-only transcripts S3 key);
      (2) loop git tokens minted CENTRALLY in agent-coordinator (App keys never enter a
      stack-reachable ns), stack-repo-scoped, both Apps (`loop-git-<stack>` coordinator /
      `loop-reviewer-git-<stack>` reviewer — distinct identity, self-approval stays blocked);
      (3) served ONLY by the egress proxy `/loop-git-token` with MANDATORY TokenReview (caller
      must BE `<ns>:agentstack-loop`; the proxy's only cluster-scoped grant; `/git-token` verifies
      an offered SA token, legacy tokenless stays worker-scope-only); (4) Argo Events stay GLOBAL
      (bus+Sensors — dumb pipe; per-stack JetStream = 3×1Gi for ~zero volume); (5) per-stack
      capacity = subscription-latch only (ConfigMap semaphores can't cross ns; DB locks not
      worth it). Render (claim `loop.perStack`, default off): `coordinate-<stack>` CronWorkflow
      in `<stack>-agents` as `agentstack-loop` (broker-fetch preamble, `SCAN_STACK`-scoped scan,
      item dispatch via `coordinator-session.sh --loop-ns`), workflowtaskresults RBAC, transcripts
      PVC+key. E2E 2026-07-18: broker 200-as-loop-SA / 403-foreign-ns / 403-unauthenticated with
      DISTINCT per-App tokens; oracle graduated (`oracle-iac` claim) — see the tick acceptance in
      the session log. **STILL REMAINING:** per-stack REVIEW backstop (reviewer-session.sh needs
      the broker-fetch plumbing its coordinator sibling got; the loop-reviewer token leg is
      already minted+served), retiring a graduated stack from the GLOBAL scan/reflex after soak
      (today both run — the belt), sleep/platform graduation, and the FU-089 fixer-ns key hole
      found during this build. model-scout + ledger stay GLOBAL; docker-ride dispatch from the
      jail additionally waits on FU-072. ADR-094 note: this leg carries NO scheduling semantics.
      Relates FU-045/FU-048/FU-050/FU-066, ADR-093/ADR-094.

- [ ] **FU-094** — **Tiered spec gate — PROPOSAL ONLY (operator 2026-07-24: "will consider
      once I have more data and cleaned up the specs").** Write-up:
      `docs/agents/spec-gate-tiering.md`. Kernel: meta-9 measured 16 codeowner spec gates/72h
      with 0 rejections — the gate's value migrated to issue-time ⚖ pre-decision; ~half the
      gates were mechanical diffs (marker flips, event-list syncs, provenance notes). Do NOT
      implement before the operator re-opens this.
- [ ] **FU-093** — **Bulk-tier storage ledger is double-booked — one ledger should own the
      tier (found 2026-07-22 closing oracle-iac#40).** ADR-089 says every bucket claim states
      its cap, but nothing owns the SUM: oracle-iac `infra/garage-workspace.yaml` counts
      loki 40 + agent-transcripts 20 + ert-snapshots 90 = 150Gi against the ~150Gi bulk tier,
      while oracle-iac#40's accounting counted allure-reports 20 + snapshots + artifact bucket
      against the same tier — and the Phase-1 `argo-artifacts` 10Gi + the per-repo
      `argo-artifacts-oracle-fleet` 2Gi (AgentStack `argo.artifacts` knob, 2026-07-22) appear
      in neither. Live caps to reconcile: `kubectl get workspaces.tf.upbound.io` (8 garage
      workspaces). Candidate shape: one ledger table in docs (ip-plan.md-style) or a lint that
      sums `max_size` across workspace manifests vs the tier budget; per-tier not per-repo.
      **Extended 2026-07-22 (the live-meter half):** Garage exports NO metrics to Prometheus at
      all (checked: zero `garage_*` series) — cap breaches surface only as faulted writes, and
      the same blindness class hit longhorn-scratch the same day (the #41/#63 Init wedge).
      Enable Garage's admin-API metrics (:3903) + a ServiceMonitor; per-bucket usage-vs-cap
      panels + a >80% alert are the ledger's enforcement half.
      **Third sighting 2026-07-25 (the blindness class again, twice in one day):** (a) Garage
      LMDB-full at 03:42 surfaced only as a failed sleep-ingester Job (meta volume since 10Gi);
      (b) the bulk-tier LONGHORN cap: 9 retro rides' 20Gi scratch allocations pushed both bulk
      disks past storageScheduled cap → new scratch PVCs faulted (ReplicaSchedulingFailure) and
      wedged all ride/worker Inits. Immediate fixes: scan janitor grace 2h→30min + launcher-side
      pod self-clean in the retro orchestrator. The ledger/metrics this FU wants must include
      LONGHORN per-disk storageScheduled-vs-cap (kubelet metrics exist: longhorn_disk_* — add
      the >80% alert alongside the Garage one). Relates ADR-089, oracle-iac#40
      closing comment, oracle-iac#95.
- [ ] **FU-092** — **Reviewer dispatch lacks its deterministic-name idempotency key
      (merge-path-fsm MP-G02).** Found by MODELING the merge path as an FSM (2026-07-21): the
      design (merge-path.md §Concurrent triggers) specifies `review-<repo>-<pr>-<headsha8>` as
      the atomic create key; implemented today = pod-label idempotency + the STEP-0 self-guard
      (probabilistic, and a STEP-0 catch burns a session). Workers got their key 2026-07-21
      (`agent-<project>-<task>-r<round>`, atomic `kubectl create`); apply the same to
      `reviewer-session.sh` — name from (repo, pr, head-sha8), terminal same-key reap, live
      holder refuses. Relates FU-069, merge-path-fsm.yaml MP-G02.
- [ ] **FU-090** — **Coordinator-authored issues: harvest + authoring surfaces behind the
      breaker-#1 gate (design 2026-07-18, operator-flagged: "coordinators don't create issues
      themselves yet").** Today issue AUTHORING is a jail-LLM practice (workflow.md §Triggers
      emitter table) and the coordinator files issues only inside meta-4 arbitration — an
      APPROVED PR's `Follow-ups:` section (the rubric REQUIRES issue-ready bullets) has no owner
      and dies in the review comment. Design, two surfaces one gate: (a) **follow-up harvest** —
      the C6/merged item session files each `Follow-ups:` bullet as an issue (provenance links,
      `Depends-on:` lines per FU-087, track label inherited) — BOT-AUTHORED → INERT per TICK-LOG
      §Loop-safety breaker #1 (no agent-fix/agent/queued); (b) **spec-driven authoring** — the
      ADR-094 janitor tick MAY draft issues from specs/TRACKS gaps, same inert gate.
      **Visibility slice SHIPPED 2026-07-18**: the scan reports 🌱 bot-authored issues lacking
      `agent-fix` per repo, so harvested drafts surface for human triage instead of rotting.
      Graduation knob (NOT built): claim `issueAuthoring.selfQueue` (default off) letting the
      coordinator self-label harvested issues, bounded by the existing breakers + a per-day rate
      cap — flipping it is the operator's per-stack trust call (it retires breaker #1 for that
      stack). Relates FU-086/FU-087, ADR-094, TICK-LOG §Loop safety.
      **Leg (c), goal-budget decomposition (operator direction 2026-07-24 — the meta-9
      prototype ran 3 days live):** a human-authored+queued `goal` issue (breaker #1 moves UP,
      not away) carries budgetUSD + acceptance; its item session MAY author+queue child issues
      citing the parent, with Σ(child estimator budgets) ≤ parent budget enforced in the
      LAUNCHER pre-flight (deterministic, beside WIP=1 — never LLM-honored). The child-issue
      set is the reviewable decomposition artifact ("review the result" applied to planning).
      Scan surfaces children-of-closed-parents as orphans (goal-drift belt). Existing
      containment (lane WIP, capacity gates, pod-name keys, FSM, agent/error) carries over.
      **Operator 2026-07-24: leg (c) NOT YET — rollout continues the old-fashioned way (human
      goal decomposition) until the current arc settles; revisit when a real goal candidate
      appears.**
- [ ] **FU-089** — **Fixer-ns `agents-github-app` private key = workbench escalation hole.**
      Found 2026-07-18 during the FU-080 loop-token build: the Composition renders the
      homelab-agents App PRIVATE KEY (`agents-github-app` ExternalSecret) into EVERY fixer
      namespace so the per-repo `agent-git-token` generator can run in-ns — but a stack
      workbench SA is namespace-admin there, so it can read the key and mint tokens for ALL
      repos the App covers (cross-stack contents/PR/issues write — exactly the escalation the
      airlock exists to prevent). Fix = the loop-token pattern applied to worker tokens: mint
      per-repo tokens CENTRALLY in agent-coordinator (generators+ES there), serve via the
      proxy's TokenReview-verified `/git-token` (worker pods already fetch per-op — flip them
      to send their SA token and make verification mandatory), delete the per-ns key ES from
      the Composition. Until then the App's blast radius IS the trust boundary between stacks.
      **CORE SHIPPED + E2E-VERIFIED 2026-07-25: the key is out of the fixer namespaces**
      (in-cluster probe: /git-token?ns=oracle-fleet serves from the central secret; bogus ns
      404s; old in-ns ES/generators GC'd). Migration lesson: a composed resource cannot MOVE
      namespaces — rename its composition-resource-name so Crossplane creates-new + GCs-old
      (first attempt left the old ES stuck with its key already collected). Second live lesson
      (issue-135 r1×2, same night): deleting the standing in-ns Secret broke CLAUDE-harness
      rides — the cred-inject gate was goose/opencode-only, so claude rides had silently relied
      on the optional Secret fallback the whole time; fixed 6c3fd88 (claude rides get
      GIT_CRED_BROKER_URL too). Audit-the-fallback-CONSUMERS, not just the resource's named
      readers, before deleting a Secret. Composition now
      renders `agent-git-<repo>-gen`+`agent-git-<repo>` into agent-coordinator (worker-ns
      label binds token↔ns; the key Secret is the hand-applied coordinator one) + an
      `agentstack-worker` SA per fixer ns (TokenReview identity, no grants);
      `_resolve_git_token` reads central + label-checked; worker pods run as the SA
      (agent-session.sh). (1) ✅ agent-runtime#19/#20 merged + pin rolled — the credential
      helper sends the SA bearer; (2) ✅ **ENFORCED 2026-07-26 01:30Z**:
      `GIT_TOKEN_REQUIRE_AUTH=1` flipped at an idle window on live ride evidence; anonymous
      probe verified HTTP 403 on the ROLLED pod (first probe hit the old pod mid-rollout and
      read 200 — probe the pod, not the deploy). **Remaining:** drop the dead standing-Secret
      fallback lines in agent-session.sh (reference the deleted Secret, optional:true —
      inert), then archive. Relates FU-080, FU-020, ADR-087.
- [ ] **FU-019** — Migrate the worker plain `Pod` → agent-sandbox `Sandbox` CR (ADR-078).
      `agents/agent-session.sh`.
- [ ] **FU-067** — **Hubble flow EXPORT → Alloy → Loki (denied-flows event drill-down) — only if
      the drop `destination` label proves insufficient.** Context (2026-07-12): the FU-020 ride's
      ~150 POLICY_DENIED drops were unclassifiable post-hoc (flow ring buffer rotates in minutes);
      fixed at the METRIC level (`drop:…destinationContext=dns|ip` + `dns:query` — Prometheus now
      names denied destinations and attempted lookups, panels on the `agent-issue` dashboard). If
      per-flow detail (pod/port/timing) is ever needed durably: Hubble's built-in
      `hubble.export` (static filter verdict=DROPPED → node file) tailed by the existing Alloy
      DaemonSet into Loki — ALL maintained components. Explicitly REJECTED: the `hubble-otel`
      OTLP adapter (blog-circulated pattern) — the project is archived/unmaintained; Cilium has
      no supported native OTel emitter. Relates FU-020.
- [ ] **FU-058** — **Retro P3: the scheduled retro session** (`docs/agents/observability-and-retro.md`
      §B2). **Multi-model pilot direction (operator 2026-07-25):** run the retro as the FIRST
      multi-large-model tryout — N models over the SAME worst-K ledger slice in parallel, then a
      cross-review round (each critiques the others' reports; the human reads the critiques).
      Safest arena for it: read-only inputs, human-gated outputs; task shape = the FU-095
      reasoning/audit tier (dual-model spend ruled worth it there). v1 needs NO MCP transcript
      tools — ledger + issue/PR stats/strike comments suffice; reuse model-scout's ephemeral
      capped-key mint. What v1 teaches (prompt shape, cross-review structure, convergence vs
      anchoring) de-risks the FU-095 sleep spec-creation pass. First run hand-supervised.
      **Runs 1+2 DONE 2026-07-25** (docs/agents/retros/2026-07-25-*): mechanism proven, 9 models
      compared repo-verified, cross-review landed (deepseek-v4-pro critic). Routing data for
      FU-095: audit tier = deepseek-v4-pro/hy3 (opus-adjacent grounding, $0.02-0.08); kimi =
      wide-net second reader; gpt-oss-120b + nemotron-super = fabricators on evidence work.
      Remaining for P3 proper: ~~schedule it (cron)~~ ✅ 2026-07-25: `retro-session`
      CronWorkflow (agents/coordinator/retro-argo.yaml, BORN SUSPENDED — Mon 05:00 declared,
      hand-fired via `argo submit --from` until proven; level-triggered guard + WIP refusal +
      harvest-PR; cross-review legs manual in v1); still remaining: MCP transcript slices,
      act on the reports' queued-issue candidates, unsuspend after clean runs. **Brief v2 (from runs 1+2 evidence, 2026-07-25):** (a) ✅ DONE
      2026-07-25: run-1 brief recovered VERBATIM from the transcript bucket → committed as
      `docs/agents/retros/BRIEF.md` (v3 template: ledger-blind-spots block, harness-source
      excerpts, task-granularity/wins/predecessor-score sections) + `CROSS-REVIEW.md` +
      `agents/retro-session.sh` (assembles per-cell, delegates to agent-session.sh
      --harness/--model; ownership ruling → observability-and-retro.md §B2: platform-owned,
      homelab-resident, graduates to an AgentStack knob); (b) the cross-run "could not verify" items are mostly LEDGER
      gaps, not access gaps — reviewer_rounds=0 despite real review rounds, wall_time_s not
      decomposed active/idle (contradicted by PR lifetimes), retry_storms taxonomy undefined,
      haiku cost $0.00-vs-untracked ambiguity — fix the emitter before adding tools; (c) give
      the retro read access to the harness source it's asked to improve (coordinator-scan.sh,
      estimate_budget.py excerpts in the brief, or a homelab checkout) — 6/9 models flagged
      naming-targets-they-cannot-read; fabricators invented APIs exactly there; (d) add a
      task-granularity section to the report contract: "which of these worst-K tasks should
      have been ONE bigger-model task (or a subagent fan-out) instead of chunks; which chunks
      needed rework at integration" — operator hypothesis 2026-07-25: a large model + subagents
      might one-shot a project this size in ~48h; the retro should produce the evidence either
      way. Prometheus/Grafana access NOT needed yet (no report was blocked on metrics).
      **Run-3 shape (operator direction 2026-07-25, composition-axes frame):** two retro
      rides off the SAME agent-base image + SAME committed BRIEF.md — A = claude harness +
      opus (subscription via the ADR-081 proxy, FU-088-gated), B = goose harness +
      deepseek-v4-pro (ephemeral capped key, provider-pinned) — then CROSS-review with the
      cells SWAPPED (A reviews B's report, B reviews A's). Tooling parity is already
      structural: agent-base ships claude-code@latest alongside goose/opencode + the full
      toolkit (gh/git/jq/python/uv/kubectl/s5cmd), so retro-er and reviewer are freely
      mixable; rotating cells run-over-run separates harness effect from model effect on the
      FU-057 ledger axes — this doubles as FU-095(b) evidence. Repo scope for the retro
      token = the stack jail's REPOS boundary (tools/stack-jail.sh: oracle-fleet oracle-iac
      allure-behavior-snippets), read-only, App-minted. Standing guardrails: outside the
      fixer ns/WIP slot (P3 constraint), $0.05 key floor, GOOSE_MAX_TOKENS=16384, reports
      land in docs/agents/retros/ via PR. Budget-capped batched LLM retro over the worst-K ledger tasks: transcript slices via the
      MCP tools (not yet built), dated report in `docs/agents/retros/`, process-file PRs only
      (human-gated), scores its predecessor first. The FU-057 ledger it needs is LIVE (archived
      2026-07-16) and accumulating; first run hand-supervised. Absorbs FU-057's small residue:
      ledger-reflex consuming `key_hash` for the OpenRouter activity-API per-request backfill.

- [ ] **FU-059** — **W1 DECIDED + built (2026-07-10, ADR-086): coordinator commits ⚑ spec gap-flags
      to open agent PR branches during merge-forward arbitration (record-in-git; issues = work
      pointers only). Remaining scope = W2+ (direct fixes/seeds), still needs design.** Original:
      **Coordinator write tiers (W1/W2) — needs its own ADR first.** Today the coordinator's
      stack-repo clones (`/work/<repo>`, landed with the FU-045 first brick) are **read-only reference**: its
      only writes are labels/comments/merge-state via `gh`. A future tier could let the coordinator write
      *directly* to a stack repo (open a PR from the clone, push a trivial fix, seed a spec) instead of always
      dispatching a worker — but that blurs the coordinator(orchestrator) vs worker(builder) split and touches
      budget/credential/review-gate assumptions, so it must be designed in an ADR before any code. Relates
      FU-045/FU-048 (the `AgentStack` claim would carry the tier as policy) and the merge-path reflexes.

- [ ] **FU-044** — **LLM oversight of the deploy path: auto-rollback / roll-forward on a broken
      deploy.** The FU-025 deploy pipeline (app-repo build → chart+image at `<calver>-g<sha>` →
      auto-bump PR in `sleep-iac` → ArgoCD sync, see `docs/sleep-iac.md` §Deploy pipeline) merges on
      CI-green but has **no post-deploy health gate** — a chart that renders + passes kubeconform can
      still break at runtime (bad migration, crashlooping CronJob, failing probe). Add a
      coordinator-style overseer that watches the ArgoCD app health after a deploy PR merges and, on
      a broken sync/degraded health: **roll back** (revert the `sleep-iac` bump PR — deterministic,
      no LLM needed for this half) or, better, **roll forward** — dispatch a worker against the app
      repo to fix the breakage. Prereq the operator is doing first: **harden app CI so prod breakages
      are rare** (the roll-back is the safety net, not the primary control). **Direction: do this
      IN-CLUSTER off ArgoCD app-health events, NOT in the GitHub Actions deploy run** — the deploy job
      now ends at "auto-merge armed" (deploy-pin.sh), so post-deploy health/rollback is decoupled from
      CI (e.g. ArgoCD notifications / a small controller watching `Application` health → revert the
      bump PR or dispatch a fixer). Relates to FU-041 (deterministic merge path) and the agent platform
      direction; the ArgoCD-health signal + that in-cluster reactor are the missing pieces.
- [ ] **FU-049** — **Platform services published as XRDs supersede `SERVICES.md` as the source of truth.**
      Provisionable capabilities (S3/Postgres/…) become typed Crossplane XRDs; discovery is a cluster query
      (`kubectl get xrd`) and the human catalog is *generated* from them rather than hand-curated. Open:
      build-time discovery for an app repo with no cluster creds may still want a generated static catalog.
      Design: [`docs/agents/platform-and-stacks.md`](agents/platform-and-stacks.md) §2, ADR-085. Relates
      [[service-discovery]], ADR-076 (app-owned resources via Crossplane).

- [ ] **FU-046** — **Agentic dependency upgrades: reviewable dep bumps flow through the merge path, no
      human, no coordinator tick.** Renovate's reviewable bumps (major versions, runtime deps) should NOT
      be assigned to a human; they **arm auto-merge** and get a `deps-review` label, so the existing
      **merge-path review reflex** (`docs/agents/merge-path.md` §Scenario S — a deterministic CronJob,
      NOT a coordinator LLM tick) picks them up like any agent PR and dispatches the **LLM reviewer**.
      The reviewer's verdict drives everything (context = Renovate's embedded changelog/release-notes):
      **harmless → APPROVE → auto-merge** (major upgrade lands, no human); **needs adaptation →
      CHANGES_REQUESTED**, which is the merge path's `changes-requested → round N+1` transition — it
      spawns a **worker to adapt the code on the same renovate branch** → loop → merge. The **coordinator
      only tie-breaks** exceptions (flip-flop / rounds exhausted), per the escalation table. This
      **resolves the merge-path open question** ("review dep PRs or CI-only?") as a *split*: trivial/digest
      → mechanical CI-only approval (the `renovate-approve` reflex, FU-014); reviewable → LLM reviewer.
      **Integration work:** (1) ✅ **DONE** — the review reflex (`agents/review-reflex.sh`) now skips
      `automerge`-labelled PRs (the mechanical path) and reviews the rest, so `deps-review` bumps get the
      LLM reviewer while digest noise doesn't burn a reviewer run; (2) the changes-requested worker must
      fix on a `renovate/*` branch, and **Renovate must not clobber its commits** — set `rebaseWhen:
      conflicted` (done) so the updater owns freshness and Renovate only rebases its own conflicts;
      **verify on the first real major bump** that Renovate leaves a manually-edited branch alone and the
      worker pushes to `renovate/*` (not a new `agent/*`). **P3 (later):** a longer cooldown on majors so a
      human CAN opt into an interactive LLM session for the riskiest. Relates to FU-041, FU-044, FU-014.
      **Status (2026-07-05):** the MECHANICAL sibling leg is proven live — sleep-tracking#14 (docker digest,
      `automerge`) rode `renovate-approve` → auto-merge with no LLM (that's the FU-014 half). The
      *analogous* reviewable-with-a-worker pattern is proven via the **coordinator major lane** (FU-047,
      #18: reviewer investigates → worker adapts → merge). **STILL UNPROVEN — the FU-046-specific path:** an
      armed `deps-review` Renovate PR flowing through the **review reflex** (not the coordinator) →
      CHANGES_REQUESTED → a worker adapting on the **`renovate/*` branch** (verify Renovate doesn't clobber
      its commits) → loop → merge. Awaits a real reviewable Renovate bump; keep open until one flies.
- [ ] **FU-068** — **Labels move into the AgentStack claim via `provider-upjet-github` (the
      GitHub-side permission-tier split).** Administration tier (repos/rulesets/org secrets) stays in
      out-of-jail `tofu/github` permanently — that credential never enters jail or cluster. Issues
      tier (labels, `Issues:R/W` only) becomes stack self-service: `spec.repos[].labels` on the
      claim; the Composition renders the composed label set (platform taxonomy + stack extras) per
      repo. **MECHANISM BUILT 2026-07-16** (trigger: the tofu-apply "pollution" complaint —
      label noise drowning the permission diffs): provider-upjet-github v0.19.1 installed via
      `argocd/resources/crossplane/github-provider.yaml`; creds ES + ProviderConfig
      (`github-providerconfig.yaml` — inert/SecretSyncedError until the App exists); XRD
      `repos[].labels` + Composition `IssueLabels` block with the platform taxonomy inline
      (GitHub defaults + agent state machine + Renovate lanes; mirrors labels.tf until it dies);
      `scripts/github-app-bootstrap.sh homelab-labels` (check|manifest|catch|convert|secrets|verify —
      mints the three `LABELS_GH_APP_*` Infisical keys). **FIRST MIGRATION LIVE 2026-07-16**
      (same day): homelab-labels App installed org-wide (All repositories), creds chain green,
      and FIVE repos claim-owned — oracle-iac + oracle-fleet + allure-behavior-snippets
      (oracle claim, track/* extras; verified on GitHub: allure 9→27 labels, oracle-fleet
      complete incl. the previously-missing deps-review, nothing deleted) and agent-runtime +
      agent-coordinator (platform claim, taxonomy-only). Gotchas found live: bare hex colors
      parse as YAML scientific notation (`5319e7` → 5.319e10 — QUOTE them; XRD description
      warns), and `labels: {}` gets server-stamped to `{extra: []}` (explicit `extra: []` per
      the drift convention). **SLEEP MIGRATED 2026-07-25** (sleep-iac#19 + homelab 0cc2380,
      state rm + apply same day): all three sleep repos claim-owned via `labels: {extra: []}`
      (pre-migration diff: live == taxonomy exactly); IssueLabels Ready+Synced verified before
      the label_repos trim; state rm scoped to `^github_issue_label\.` ONLY (the broad grep
      also matched rulesets — do NOT rm those). **Remaining:** homelab has no claim — decide
      its home (label_repos=[homelab] keeps labels.tf alive until then). The generated resource
      is AUTHORITATIVE `github_issue_labels` — it deletes unmanaged labels; two managers fight.
      Design: [`docs/agents/agentstack.md`](agents/agentstack.md) §"The GitHub side". Relates
      FU-048, ADR-085.

- [ ] **FU-095** — **Sleep stack pilots: task-class model routing + multi-harness evidence**
      (operator direction 2026-07-25; downstream consumer = the IdP project's REASONING agents —
      auditing, requirements, monitoring, NOT coding). **Operator corrections 2026-07-25:**
      • **Sleep specs+evidence are a prerequisite, not optional** — comparable model results
        across projects need the same evidence discipline; without specs the loop can't run
        reliably on sleep. Sequencing: specs discipline (oracle-style, adapted) lands WITH or
        BEFORE graduation.
      • **The router's candidate source is a maintained ROTATION** (OpenRouter top-weekly or
        similar), not the scout's new-model diff — the scout missed `nemotron-3-ultra-550b:free`
        (verified: the registry snapshot predates it AND kimi-k3; diff-only + tools/price filter
        ≠ "what's currently good"). The rotation feeds chains continuously; the scout's canary
        leg is kept as the safety probe for rotation entrants.
      • **Reasoning tier for audit/review/research task types** — coordinator README currently
        BARS reasoning models (a worker-coding rule); the audit/research lane needs its own
        rule, including **dual-model review** (two models on one audit is worth the tokens for
        review/audit tasks, unlike coding). Budget shape for IdP pre-build (EITS/best-practices
        requirements research): a few review rounds on a large model (e.g. kimi-k3), never
        N full designs from scratch.
      Three legs, all riding the sleep stack once FU-080 graduates it:
      (a) **task-class-aware model choice at dispatch** — today the model is static-chain +
      strike-walk (`agents/stacks.json`, coordinator README §MODEL); availability+price already
      exist (registry `estimate_budget.py` §M3, provider pinning §M4). The NEW axis: resolve the
      chain per task class (first approximation: `agent-budget/*` × `track/*` labels) against the
      registry + the strike/ledger history — the exact gap model-routing.md:50 notes ("failure
      classes are task-shaped… should carry a task-size/class dimension"; FU-057 pivot is the
      data seam). No prior art beyond that note (grep 2026-07-25: no FU matches task-type router).
      (b) **multi-harness evidence** — same task classes across `--harness goose|opencode|claude`,
      compared on the FU-057 ledger axes {success-rate, harness-death-rate, $/successful-issue}.
      This IS the recorded ADR-077 trigger ("add Omnigent's meta-harness only if governing
      multiple harnesses becomes real") — the pilot supplies the evidence that decision awaits.
      (c) **free-model probing of goose error handling** — extend the model-scout canary shape
      (ephemeral only-free capped keys) from trivial closed rides to real sleep xs tasks; resolves
      the live tension between model-routing.md §M2 ("free entries fine anywhere — failure = one
      strike") and `stacks.json` `_chain_policy` ("free tiers never fix-chain entries").
      Renovate-majors piloting on sleep is NOT this item — that's FU-046's existing lane.
      Prereqs: FU-080 sleep graduation (+ FU-044 before unattended deploys); relates ADR-077,
      ADR-081, FU-057, FU-062 (model-routing.md is the umbrella doc).
      **Spec-creation directive (operator 2026-07-25):** the FIRST sleep specs are authored AND
      reviewed by multiple large LLMs — the point of that pass is finding bugs/gaps in the
      system, not documenting existing behavior; this is the natural first consumer of the
      dual-model review leg. Test-tier terminology ruled: **"system testing"** = logic against
      real components in kind (Garage + ingester + Grafana + Playwright, ADR-082 shape);
      "e2e" reserved for the actual target environment (synthetic production traffic). Record
      the terms in sleep's process docs when the specs land (cf. Fowler microservice-testing:
      our "system" ≈ his out-of-process component / limited e2e).
- [ ] **FU-096** — **Warm the agent-base ride bring-up the FU-015 way — it's the EVAL CACHE,
      not the store** (measured 2026-07-25 closing FU-015): with a fully-warm /nix store,
      `devbox install` still costs 127s wall / 84s CPU when `~/.cache/{nix,devbox}` is cold
      (7.7s warm, 0.09s with `.devbox` project state) — nix evaluation is the tax, fetching
      isn't. The arc-runner image now keeps the cache (this closed the runner side); agent-base
      (agent-runtime repo) pays the same eval per RIDE pod on top of the LAN-substituter store
      fetch, and retro run 1 flagged bring-up dwarfing task time (opencode attempt 3 spent
      ~35min of wall on devbox bring-up). **⚖ Fix shape RULED by the composition-axes
      direction (operator 2026-07-25, platform-and-stacks.md §Composition axes): harness
      images stay STACK-AGNOSTIC — do NOT bake repo closures into agent-base** (that couples
      harness×stack). Target: the stack repo's CI publishes its own devbox closure cache as
      an OCI artifact versioned with `devbox.lock`; the launcher mounts it via ImageVolume
      (verified on this cluster, fleet#106) as a read-only local nix substituter
      (`file://` store in substituters) + eval-cache seed copied at entrypoint. NOT a
      volume-share across pods (single-user nix locking + RWX risk — image layers ARE the
      share). CoW note (operator asked 2026-07-25): the k8s ImageVolume API is READ-ONLY by
      design (KEP-4639, no writable option) — but kata rides own their guest kernel, so an
      in-guest overlayfs (lower=image volume, upper=scratch) gives a true writable CoW /nix
      if substitution overhead ever proves real; costs a CAP_SYS_ADMIN entrypoint step in the
      guest (FU-077 exemption territory). Substituter+seed first; overlay only on evidence. Scoping: agent-base already bakes its HARNESS closure (`/opt/agent`) and keeps
      `~/.cache`; the gap is the TARGET repo's eval in `/work/<repo>` (partial cache overlap;
      VERIFY the build-user cache survives to the runtime `USER 1000:1000` HOME). The
      claude/coordinator image needs nothing (no nix/devbox; repo cloned read-only). Relates
      FU-058, FU-015 (numbers), FU-073e (substituter = fetch half; this = eval half),
      FU-095(b) (multi-harness evidence).

- [ ] **FU-084** — GitHub API rate-limit metrics — **CORE DELIVERED 2026-07-25**: exporter
      `collect_rate_limits` (`/rate_limit` is free) emits `github_rate_limit_{remaining,limit,
      reset_timestamp}{token,resource}` for the exporter PAT + per-installation probe tokens
      (ESO GithubAccessToken pattern, `rl-tokens.yaml` — coordinator-git App 4150968 install
      142724430, THE pool from the 2026-07-17 incident, + reviewer-git); graphql/core split
      visible. Dashboard panel (remaining % per token+resource) + `GithubRateLimitLow`
      (<10% for 5m, warning, symptoms-only). Also fixed the operator-reported SKU-panel bug
      (private+public minutes summed — split by visibility; public is free).
      **Remaining:** add merge/deploy/labels/arc installations by the rl-tokens.yaml
      copy-block pattern. (The inherited cron-relax leg moved to FU-086's open list 2026-07-25.)

## Hardware & nodes

- [ ] **FU-032** — Watch: thinkcentre's one 1Gbps link blip since the cable fix (2026-06-11) and
      wk-metal-02's one unexplained reboot. On recurrence: chase cable/switch-port
      (thinkcentre) resp. battery/power (wk-metal-02, plug `laptop4`).
- [ ] **FU-033** — Before any Talos 1.14 upgrade: apply the `VolumeConfig secure:false` /
      `noexec` patch or `/var` breaks Longhorn v1 (warning in `tofu/longhorn.tf`).
- [ ] **FU-034** — Buy a network Zigbee coordinator (SLZB-06 class) — unblocks local radios
      (ADR-041, Open).

## One-time ops

- [ ] **FU-036** — AWS cleanup: delete the orphaned Route53 hosted zone `ZCGRPARGVE3CW` (+ the
      leftover ACM/Sectigo certs its `_*` validation records imply). Needs admin SSO (the jail key
      is read-only). Recipe: `docs/cloudflare.md`. Optionally do it as the first `tofu/aws/` root
      (which would also adopt the audit user, `scripts/aws-bootstrap-audit-user.sh`).
- [ ] **FU-038** — Tuya plugs: drop the cloud dependency for local-API polling; then the `/10`
      power correction can go away (`homeassistant/ha-config/packages/power.yaml`).

---

See also `ROADMAP.md` → "Backlog / parked features" (self-hosted SLSA L3 build-out, bare-metal node
suspend/resume, the caching-tier image mirror ADR-070, the edge tier).
