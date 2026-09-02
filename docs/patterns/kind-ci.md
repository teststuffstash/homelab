# Pattern: kind in your CI — the golden way

> The consumption contract for **ephemeral kind clusters in a stack's CI gate** — the sibling of
> [`python-stack.md`](python-stack.md) and [`observability.md`](observability.md) (same shape:
> written once so the next consumer copies instead of re-learning). Two stacks paid for these
> lessons — **oracle** (`oracle-fleet/scripts/e2e-kind.sh`) and **sleep**
> (`sleep-tracking/scripts/test-integration.sh`) — and the platform ate two incidents
> (oracle-fleet#228 2026-08-09, the 2026-09-02 fleet-wide e2e outage) before this page existed.
> Every claim cites its receipt.

**The one-line rule: the cluster is run-scoped, self-sweeping, and mirror-wired — and it runs on
a SHARED docker daemon you must assume is dirty.**

## Where it runs

Two environments execute the same script (`devbox run <your-gate>`, same command locally and in
CI — the OOTB principle):

- **The VM runner** (`ci-runner-01`, `runs-on: [self-hosted, proxmox-vm]`, ADR-082): **two
  runner slots on ONE docker daemon**. Concurrent runs share everything — names, ports, image
  tags, the inotify budget.
- **Docker-mode agent rides** (kata + dind, `fixer.docker: true`): egress-enforced — direct
  registry pulls are policy-DENIED; only the mirror path works. ⚠ The two environments can
  disagree on the same gate (FU-153 — the truth-revealing lever is an open platform item).

## The rules

1. **Run-scoped names, everywhere.** Cluster `\<stack>-e2e-${GITHUB_RUN_ID:-$$}`, image tags,
   namespaces — all carry the run id. A SHARED name plus a pre-create `kind delete` kills the
   *other* slot's live cluster (sleep, 2026-08-30, runs 33324589665/33324231312 tore each other
   down). **Local ports stride by run id** too (sleep's `$((20000 + (RUN_TAG % 5000) * 2))`).
2. **Sweep STALE clusters before creating, never the shared name.** Teardown traps do NOT run
   when CI cancels or times out the job — leaks accumulate until the daemon starves (six leaked
   clusters exhausted 512 inotify instances on 2026-09-02; two exhausted 128 in #228; the leak
   reaches ANY limit eventually). Pre-create, remove *own-prefix* containers that are hours old
   (`docker ps -a --filter name=<stack>-e2e-` + an age check) — self-healing beats trap-based
   cleanup on a runner where jobs get cancelled. The platform runs an hourly `kind-janitor` on
   the VM as the belt (`tofu/templates/ci-runner-cloud-init.yaml.tftpl`); your pre-create sweep
   is the cause-side half.
3. **Keep the teardown trap anyway** (`trap cleanup EXIT`, `kind delete cluster --name
   "$CLUSTER"`), with a `KEEP=1` escape for local poking. It covers the normal path; rule 2
   covers the cancel path.
4. **Wire the kind NODE at the mirrors** — the node's containerd pulls registries directly,
   which hangs under enforced egress (rides) and burns WAN + ghcr limits (VM). The donor
   snippet is oracle's `kind_mirror()` (copied by sleep): write a
   `/etc/containerd/certs.d/<registry>/hosts.toml` into the node container per
   `REGISTRY_MIRROR_DOCKER_IO` / `REGISTRY_MIRROR_GHCR` / `REGISTRY_MIRROR_MCR` (the ADR-091
   env contract — rides export it; on the VM default the LAN VIPs, `SERVICES.md` §Registry
   mirrors). `kindest/node` preconfigures containerd's `config_path`, so hosts.toml just works.
5. **Retry the image *build*, not the cluster create.** Registry manifest HEADs flake
   (docker.io 500s) — a bounded retry on `docker build`/pull is honest (oracle does 3). A
   failing `kind create` is NOT a flake to retry: it means the daemon is sick (inotify, disk)
   — fail loudly and let the janitor/alerting own it.
6. **inotify is the invisible budget.** A kind node consumes dozens of instances; symptoms are
   maddeningly indirect — CoreDNS starving with green pod status (#228), or the node never
   reaching `Multi-User System` (2026-09-02). The VM carries raised limits
   (`fs.inotify.max_user_instances=1024`, watches 524288) as code; if you see either symptom
   class, count instances before debugging your app
   (`find /proc/*/fd -lname anon_inode:inotify | wc -l`).
7. **Python stacks: mind the devbox↔uv seam** — `export UV_PROJECT_ENVIRONMENT=.venv` before
   any `uv` use inside the script ([`python-stack.md`](python-stack.md), the #316 scar; oracle's
   e2e header documents the exact failure).
8. **Evidence out, cluster gone**: write per-round logs/assertions to an `e2e-evidence/<ts>/`
   dir and publish in a trailing non-required job; the cluster itself is never the artifact.

## Reference implementations

- `oracle-fleet/scripts/e2e-kind.sh` — rounds-against-spec shape, `kind_mirror()`, build retry.
- `sleep-tracking/scripts/test-integration.sh` — the concurrency lessons (run-scoped ports,
  the shared-name teardown incident), pinned-plugin trust anchor, assert-by-reading-the-graph.
