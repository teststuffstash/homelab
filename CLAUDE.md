# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repo.

## What this is

Infrastructure-as-code for a home network, built **boot-from-git**: every box is meant to be
recreatable from this repo, the only non-code thing is data (→ S3, bucket-id in git). No click-ops.
There's no build step or test suite — changes are applied directly to live machines via OpenTofu,
Ansible, and Talos. See `CONTEXT.md` for the guiding principles, `ARCHITECTURE.md` for the shape,
`ROADMAP.md` for what/when, and **`docs/runbook.md` for the operational recipes** (the most useful
day-to-day reference).

## Environment

Running inside a Docker jail — see `/workspace/CLAUDE.md` for container setup and permissions.
**All project CLI tooling is Devbox/Nix, not apt** (`devbox.json` at the repo root, shared host
`/nix`). Tools are NOT on the bare `$PATH` — reach them through devbox:

```bash
devbox run -- kubectl --kubeconfig tofu/kubeconfig get nodes
devbox run -- tofu -chdir=tofu plan
devbox run nodes        # convenience: kubectl get nodes -o wide
devbox run k9s          # cluster TUI on tofu/kubeconfig
```

Toolchain: opentofu, kubectl, talosctl, kubernetes-helm, cilium-cli, k9s, ansible, sops, age, jq,
yq, python3, openssl, awscli2, gh, argocd, argo (workflows), infisical, keepassxc, gitleaks,
kyverno, **dig/host (bind), nmap, curl, nc/ncat, cloudflared, kubeconform, hubble, promtool (prometheus), wireguard-tools, node/npm (nodejs_22)**. `nix` commands need
`export NIX_CONFIG="experimental-features = nix-command flakes"`. `devbox run` executes from the
repo root and runs scripts under **dash** — keep them simple, use absolute paths / `tofu -chdir=`,
avoid `bash -c '<multiline>'` (it mangles).

## Current state (2026-08)

A Talos Linux Kubernetes cluster, hybrid Proxmox VMs + bare-metal, with OPNsense managed as code.

<!-- BEGIN GENERATED hosts — do not edit; edit machines/machines.yaml and run `devbox run -- python3 machines/generate.py` -->
| Host | IP | Role |
|---|---|---|
| OPNsense ("Big Data", HP desktop) | 192.168.2.1 | Router/FW + DHCP (dnsmasq) + DNS (Unbound) + FRR/BGP + HAProxy + ACME |
| Proxmox `pve` (X99/Xeon, 64GB) | 192.168.2.3 | Hypervisor for the Talos VMs + Matchbox LXC |
| Matchbox LXC (CTID 210) | 192.168.2.30 | PXE provisioning (proxy-DHCP + TFTP + Matchbox) |
| `cp-01` (VM) | 192.168.2.51 | k8s control plane |
| `wk-01` (VM) | 192.168.2.61 | k8s worker |
| `wk-02` (VM) | 192.168.2.62 | k8s worker + Longhorn (bulk tier) |
| `wk-03` (VM) | 192.168.2.63 | k8s worker, ephemeral/CI-runner tier (tainted; removable — no Longhorn disks, no kata) |
| `thinkcentre` (metal, PXE) | 192.168.2.53 | k8s worker + Longhorn (+ 2×Optane fast tier) |
| `hp-01` (metal, PXE) | 192.168.2.54 | k8s worker + Longhorn (WoL-capable) |
| `wk-metal-01` (ThinkPad X240, PXE) | 192.168.2.182 | k8s worker, ephemeral/compute tier (tainted; kata node, 8GB) + Longhorn bulk tier |
| `wk-metal-02` (ThinkPad X250, PXE) | 192.168.2.183 | k8s worker, ephemeral/compute tier (tainted; kata node, 8GB) |
| `wk-metal-03` (laptop i5-6200U, PXE) | 192.168.2.184 | k8s worker, ephemeral/compute tier (tainted; kata node) |
| `wk-metal-04` (desktop i5-3570K 16GB, PXE) | 192.168.2.186 | k8s worker, ephemeral/compute tier (tainted; kata node, no AVX2) + Longhorn bulk tier |
| `ci-runner-01` (VM) | 192.168.2.55 | GitHub Actions runner VM — Docker/binfmt builds (ADR-082) |
| Droplet (ESP32) | 192.168.2.245 | ESPHome plant-irrigation node |
| pop-os | 192.168.2.10 / .57 | the Docker host running this jail |
<!-- END GENERATED hosts -->

<!-- BEGIN GENERATED versions — do not edit; edit machines/machines.yaml and run `devbox run -- python3 machines/generate.py` -->
Cluster: **Talos v1.13.2 / Kubernetes v1.36.1**, **Cilium 1.19.1** CNI (kube-proxy-free).
<!-- END GENERATED versions -->

(Both blocks above are generated — `machines/machines.yaml` + the `tofu/variables.tf` version
defaults, rendered by `machines/generate.py`. Edit the source, re-run the generator.)

### Service exposure

> **The canonical catalog of platform services (status + endpoints + how to consume) is
> [`SERVICES.md`](SERVICES.md).** Apps in other repos discover services by grepping it — keep it
> current when you deploy/remove a service. The table below is the BGP/HAProxy mechanics.

In-cluster Services get **LoadBalancer VIPs from `192.168.40.0/24`** via Cilium BGP peering
OPNsense FRR (cluster ASN 64513 ↔ OPNsense 64512). Only Services labelled `bgp=advertise` are
advertised. L2 auto-discovery does NOT cross this L3/BGP boundary. LAN HTTPS names
(`<name>.teststuff.net`) ride OPNsense HAProxy IP-alias VIPs + Unbound overrides — recipe in
`docs/runbook.md`. **The per-service VIP/hostname assignments live in `SERVICES.md`** (don't
duplicate them here); **which range a NEW address comes from is `docs/ip-plan.md`** (ADR-088:
HAProxy VIPs from `192.168.3.0/24`, cluster LB VIPs from `192.168.32.0/19` — a VIP never lives
inside a real-host range).

OPNsense web UI: `https://opnsense.teststuff.net`. Storage is **Longhorn** (default StorageClass,
replicated) + a `longhorn-fast` node-local tier on the ThinkCentre's Optane.

**Remote access (live):** Home Assistant is reachable from anywhere at **`https://ha.teststuff.net`**
via a **Cloudflare Tunnel** (`cloudflared` in-cluster) gated by **client-certificate mTLS** — see
`tofu/cloudflare/` + `docs/cloudflare.md`. The `teststuff.net` zone now lives on **Cloudflare**
(moved off Route53), so OPNsense **ACME is DNS-01 via Cloudflare** (`ansible/opnsense-acme.yml`), not
Route53. LAN HTTPS names above stay on the local HAProxy path; only `ha.teststuff.net` is public.
**Full-LAN remote access** is WireGuard on OPNsense (`wg.teststuff.net:51820/udp`, ADR-090,
`ansible/opnsense-wireguard.yml`) — VPN clients (`192.168.64.0/24`) see LAN + VIPs + Unbound DNS
as if at home; recipe in `docs/runbook.md`.

## Repo layout

- `tofu/` — main cluster root (Talos VMs, Cilium + BGP, Longhorn, Home Assistant, UniFi,
  monitoring, bare-metal nodes `metal.tf`, image factory). State is local + gitignored.
  Run via `devbox run -- tofu -chdir=tofu <cmd>`. **Always `plan` and review before `apply`.**
- `tofu/provisioning/` — Matchbox LXC + PXE content (separate root/state).
- `tofu/cloudflare/` — remote access (tunnel, `cloudflared` Deployment, DNS, mTLS cert + WAF rule;
  separate root/state). `tofu/cloudflare-token/` mints the scoped CF tokens (run once with an admin
  token, outside the jail). See `docs/cloudflare.md`.
- `ansible/` — OPNsense + Matchbox as code, **thin playbooks → `roles/`** with config in
  `group_vars/` (`opnsense-bgp`, `-acme`, `-haproxy`, `-unbound`; `matchbox*`). Run OPNsense playbooks via
  **`bash scripts/opnsense-playbook.sh ansible/opnsense-<play>.yml`** (handles the httpx
  interpreter + creds + `ANSIBLE_CONFIG` — see `ansible/readme.md`, `docs/runbook.md`).
- `opnsense/` — `dnsmasq-dhcp.py` (LAN DHCP config-as-code, applied via the OPNsense API).
- `agents/` — the agent platform: session launchers (`agent-session.sh`, `coordinator-session.sh`,
  `reviewer-session.sh`), the deterministic scan (`coordinator-scan.sh` + `footprint.sh`),
  `stacks.json` (claims mirror), reflex/cron manifests (`coordinator/*-argo.yaml`), fixer claims
  (`fixer/`). Design docs in `docs/agents/`.
- `argocd/` — the app-of-apps: `platform/` (ArgoCD Applications) + `resources/` (manifests per
  service — the AgentStack XRD/Composition, exporters, proxies, registry mirrors, loki, …).
- `policy/iac/` — the IAC-G04 sentinel's Kyverno policies (`scripts/iac-sentinel.sh` runs them).
- `docker/` — image build contexts (`arc-runner/` — the warm-store ARC runner image).
- `esphome/` — ESPHome device configs (`config/office-plants-irrigation.yaml`); flash with
  `devbox run flash-irrigation` (logs: `devbox run irrigation-logs`).
- `homeassistant/` — Home Assistant config kept in git (applied imperatively; see runbook).
- `scripts/` — wrappers + one-shots: `tf.sh` / `keepass-{env,init}.sh` (secret vars for tofu),
  `opnsense-playbook.sh`, `infisical-{secret,harden}.sh`,
  `github-runner-bootstrap.sh` + `github-app-bootstrap.sh` + `gh-app-runner-token.sh` (GitHub Apps),
  `github-exporter-pat-bootstrap.sh` (PAT for the GitHub→Prometheus poller),
  `ghcr-mirror-pat-bootstrap.sh` (upstream PAT for the ghcr mirror's private images, FU-196),
  `new-agent-repo.sh` (scaffold a repo into tofu/github), `garage-s3.sh`, `talos-usb.sh`,
  `longhorn-register-optane.sh`, `node-maintenance.sh` (single-worker cordon→drain→shutdown→wake window, runbook §Storage), `make-client-p12.sh` (phone mTLS cert, pinned openssl),
  `coordinator-logs.sh`/`render-transcript.py` (+ `--dialogue`), `follow-ups-lint.sh`,
  `claude-model-shim.py` + `claude-go.sh` (jail sessions with OpenCode Go models on the
  subagent slots — the claude-or pattern through a local model-splitting proxy),
  `prometheus-rules-lint.sh`, `skill-retro-scan.sh`, `doc-heat.py`, `aws-*.sh` (one-shot audit/cleanup).
- `.claude/skills/` — the jail skills, the GAPS ledger + improvement contract (ADR-105):
  [`.claude/skills/README.md`](.claude/skills/README.md).
- `machines/` — **the one machine inventory** (`machines.yaml`): consumed by `tofu/locals.tf`
  (`yamldecode` → the metal-node flags, the avx2 label, the ephemeral taint) AND by `generate.py`,
  which regenerates `machines/README.md` + `machines.html` and the marker-delimited host table +
  version line in `README.md`/`CLAUDE.md`. Edit the YAML, then `devbox run -- python3
  machines/generate.py`; never hand-edit a generated block.
- `docs/` — operations & design docs + per-service docs (entrypoint: `docs/office-plants/`);
  decision history in `docs/adr.md`, postmortems in `docs/incidents/`, open investigations in
  `docs/spikes/`. Which record gets what: the routing table below.

## Secrets

**The KeePass wallet is canonical** (`~/.claude/homelab-keepass/homelab.kdbx`, keyfile-unlocked —
`scripts/keepass-env.sh` exports string secrets, `scripts/wallet-files.sh` regenerates the file
caches; read one ad-hoc with `keepassxc-cli show -q --no-password -k …/homelab.keyx …/homelab.kdbx
<entry> -a Password`). File caches live under `~/.claude/<service>/` — **never `~/.ssh`**; a
missing cache means "re-run wallet-files.sh", not "host-side only" (a jail session concluded
exactly that about Forgejo, 2026-08-08, while `homelab-forgejo/id_ed25519` sat valid two
directories over). Current cache dirs: `homelab-pve-ssh/` (Proxmox+VM SSH), `homelab-matchbox/`
(gRPC certs), `homelab-forgejo/` (SSH + GPG keypairs; API token is a wallet STRING),
`cloudflare/` (read/write/acme/ingress tokens + the phone `.p12`), `tuya/` (device keys),
`homelab-garage/`, `homelab-github-{merge,reviewer}/`, `homelab-runner-app/`,
`homelab-wireguard/`, `homelab-tofu-state-backups/`, `homelab-cv-deploy/` (rasmus-soot-cv
write deploy key — tofu/github/deploy_keys.tf). (OPNsense/HA/droplet/AWS creds are
wallet strings now — the old per-service dirs are gone, FU-001.) Tofu state, `*.tfvars`,
`kubeconfig`, `talosconfig` are gitignored. The repo is **public** — keep secrets out of git
(values live in KeePass/Infisical, see `docs/secrets.md`; SOPS is NOT used, ADR-062).

**In-cluster agent secrets** (k8s Secrets, not `~/.claude/` files): per-project `<project>-openrouter`
(operator-minted OpenRouter key) + the worker `agent-git-token` (per-repo, ~1h, from the `homelab-agents`
GitHub App). The **coordinator** (`agents/coordinator/`) adds two in ns `agent-coordinator`:
`coordinator-claude` (`CLAUDE_CODE_OAUTH_TOKEN` — a ~1y `claude setup-token`, the operator's Pro/Max
subscription) and `coordinator-git` (`GH_TOKEN` — `issues:write`+`pull_requests:write`+`contents` across
the agent repos; prefer minting from the `homelab-agents` App over a new PAT — see
`agents/coordinator/README.md` §Git token). The coordinator **image** CI needs no token (ghcr push via
the built-in `GITHUB_TOKEN`). Imperative for now; fold into Infisical/ESO later (FU-001).

## Where things get written down (the routing table)

There are several long-lived records here and they are **not** interchangeable. Route by what the
thought *is*, not by which file you happen to have open:

| What you have | Goes to | Shape |
|---|---|---|
| A **decision** — a fork taken, with alternatives rejected | `docs/adr.md` | ≤20-line block: Decision / Considered / Why / Consequences |
| The **design** behind a decision (mechanism, phases, gap register) | a doc under `docs/` | The ADR links to it; the ADR does not contain it |
| A **loose end** — known, deferred, someone must act | `docs/follow-ups.md` | ≤10-line `FU-NNN` (see below) |
| A **program** — multi-phase, weeks+, several deliverables | `ROADMAP.md` → Backlog | Prose + phases; an FU tracks only its *next* deliverable |
| An **incident** — it broke, here's the timeline and root cause | `docs/incidents/YYYY-MM-DD-<slug>.md` | Postmortem; the FU carries only the residual action |
| An **investigation or experiment** with no decision yet | `docs/spikes/` | Findings + what would settle it |
| **What happened this session** (condition → command) | `agents/coordinator/TICK-LOG.md` | Append-only journal; never scrubbed |
| **What a fresh session must pick up** | `docs/agents/meta-state.md` | Tiny, transient, delete when done |
| **Agent-loop work items** | GitHub issues on the owning repo | `agent/*` labels; never hand-copied into the FU tracker |
| A **spec shortfall** found by an agent | `specs/` ⚑ gap flag in the stack repo | ADR-086 — never the FU tracker |
| A **service** that exists and can be consumed | `SERVICES.md` | The catalog other repos grep |
| A **skill shortcoming** (operator correction, improvised step) | `.claude/skills/GAPS.md` | FU-shaped sighting; extend-on-resight; ≥2 dates → promote (ADR-105) |

Two rules make the table hold:

- **One home per fact.** If detail belongs in a doc, the tracker/ADR links to it and does not
  restate it. A duplicated paragraph is a drift bug waiting to happen — the copy nobody edits is
  the one someone reads.
- **Status lives with the pointer; everything else lives with the detail.** The FU line owns "is
  this done, what's next"; the doc owns mechanism, evidence, history.
- **Link, don't restate — and link on first use.** The first time a doc leans on a term or
  concept whose home is another doc, it links that doc (this is what makes the reader-side link
  closure work); a new doc registers in its index (the `docs/agents/README.md` doc table for the
  agent platform). `devbox run docs-graph-lint` holds the mechanical half (links resolve, no
  orphan docs).

## Jail seat sessions — procedure lives in the seat card

**Everything above is repo-universal fact.** The SEAT's session procedure — design-skill
routing, the FU tracker discipline, apply safety, and how changes land (PR lane vs the
bookkeeping class) — lives in **[`agents/jail-seat-card.md`](agents/jail-seat-card.md)**,
composed by the MONO jail's entrypoint into `CLAUDE.local.md` in THIS checkout at container
start (gitignored, auto-loaded — homelab-scoped, so it never reaches a session seated in
another stack; mechanism live since 2026-08-23, teststuffstash/claude-jail#1). A seat session
missing that file is in a stale container (started pre-merge) or outside the jail — the card
is one read away. Stack jails and fixer-lane agents get no seat card by design: a stack jail's
homelab context is this file's facts via its shallow clone, and a worker's contract is its
recipe + the launcher's environment card (`agents/ground-rules.md`) — open a PR and let the
reviewer gate it, exactly as in a stack repo.
