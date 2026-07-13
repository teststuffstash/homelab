# Kata CI-gate spike — k3d/kind inside agent microVMs (status 2026-07-13/14)

_Goal: `devbox run ci` (with a nested k8s cluster) works for agent pods via `runtimeClassName:
kata` (wk-metal-03) AND on GitHub Actions runners — fast, and **without hitting the internet**
(pull-through caches, the nix-cache precedent). Context: docs/slsa.md Phase-3 convergence note;
FU-072/FU-073/FU-074. Acceptance manifest: [`kata-k3d-acceptance.yaml`](kata-k3d-acceptance.yaml)._

## What is PROVEN

- The kata primitive works: microVM pods with their own kernel on wk-metal-03 (i5-6200U/KVM).
- dockerd runs inside the microVM (privileged-in-VM, node untouched).
- **A full k3d cluster came up inside the microVM in 36s** (attempt 4) — the concept is viable.
- Networking needs two accommodations: inner-docker MTU clamp (1350) and **external DNS via
  `dnsPolicy: None`** (FU-072: service VIPs unreachable from kata guests).
- Storage: overlayfs can't stack on the virtiofs rootfs → docker falls back to `vfs` (unusable).
  Working options: tmpfs emptyDir at `/var/lib/docker` (RAM cost) or loopback-ext4 on a
  disk-backed emptyDir (no RAM cost; etcd/kine latency suspect).

## Attempt matrix (11 runs)

| # | Config | Result |
|---|---|---|
| 1–3 | defaults / MTU clamp / LAN DNS | vfs + no egress → DNS fixed by attempt 3 |
| 4 | 5Gi VM, 3Gi tmpfs | **cluster UP in 36s**, then guest-OOM (tmpfs too big) |
| 5 | 6Gi VM | hypervisor refused the memory hotplug (8G host ceiling) |
| 6 | 5Gi, 2Gi tmpfs, `--k3s-arg` disables | node NotReady — confounded by a disturbed cable |
| 7–8 | 4Gi (+ loopback ext4 in 8) | k3s wait timeout (flags still present) |
| 9–11 | no flags; tmpfs; +inotify sysctls | k3s container starts, **emits zero log lines**, k3d times out waiting for `cluster dns configmap`; memory abundant (6G+ free) |

Attempts 1–6 ran on the original legacy-BIOS install; 7–11 after the UEFI reinstall (+ in-place
`talosctl upgrade` to restore the kata extension — see the reinstall mystery below). The only
full success predates the reinstall; suspicion list for 9–11: something in the re-pulled
`:5-dind` image (mutable tag — pin it next time), a subtle kata/containerd interaction with the
upgraded install, or a real k3s hang whose logs we haven't captured (the container logs nothing).
Next session: run the acceptance pod, `kubectl exec` in DURING the wait, and inspect
`docker inspect`/`ps` inside the guest directly instead of trusting `docker logs`.

## Open mystery: the reinstall installed the WRONG image

The UEFI reinstall (`tofu apply -replace` of the config apply, state verifiably carrying the
metal_kata installer URL) produced a node running the PLAIN metal schematic — kata restored via
`talosctl upgrade --image factory.../f1aa29f1...` (metal nodes upgrade fine). Unexplained;
re-check on the next metal (re)install whether install.image is honored from maintenance mode.

## The caching design (FU-073) — no internet in CI, both consumer shapes

Adopt the nix-cache pattern (ADR-083) for OCI images: **pull-through registry mirrors as a
platform service** (`registry-cache` ns). One mirror per upstream (registry:2 proxy mode is
single-upstream): `mirror-docker-io`, `mirror-ghcr` (evaluate zot/spegel if a single
multi-upstream instance is preferred). Storage: cache-semantics PVCs (re-warmable — replica-1 is
fine); NOTE the std Longhorn pool is capacity-crunched (ADR-089) — size small (≤8Gi each) or
wait for the next disk.

Consumers, all pointed at the mirrors instead of the internet:
- **k3d**: `--registry-config` mirrors block (`docker.io` → mirror svc, `ghcr.io` → mirror svc).
- **kind**: `containerdConfigPatches` registry mirrors in the cluster config.
- **agent kata pods**: inner dockerd `daemon.json` `registry-mirrors` (docker.io) + the k3d/kind
  config above; the pod's egress allowlist then needs NO registry FQDNs (good — FU-020 tightens).
- **ARC runners (in-cluster)**: same in-cluster mirror endpoints.
- **ci-runner-01 VM**: host docker `daemon.json` `registry-mirrors` via the LAN VIP.
- The **k3d/kind node images themselves** (`rancher/k3s`, `kindest/node`) come through the same
  mirrors — that's the bulk of the CI-gate pull time. Pin image TAGS in the gate config
  (mutable `:5-dind` burned this spike).

`devbox run ci` contract: the gate script detects the mirror endpoints via env (set by the
runner/pod), falls back to direct pulls only outside the platform (laptops).
