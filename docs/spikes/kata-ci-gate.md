# Kata CI-gate spike — k3d/kind inside agent microVMs (SOLVED 2026-07-14)

_Goal: `devbox run ci` (with a nested k8s cluster) works for agent pods via `runtimeClassName:
kata` (wk-metal-03) AND on GitHub Actions runners — fast, and **without hitting the internet**
(pull-through caches, the nix-cache precedent). Context: docs/slsa.md Phase-3 convergence note;
FU-072/FU-073. Acceptance manifest: [`kata-k3d-acceptance.yaml`](kata-k3d-acceptance.yaml)._

## Verdict: WORKS, repeatably (FU-074 resolved)

**Root cause of every post-reinstall hang: kata guests have no `/dev/kmsg`, and kubelet
(cadvisor's OOM watcher) hard-requires it.** k3s comes up fully — apiserver serving, caches
synced — then the embedded kubelet exits (`failed to create kubelet: open /dev/kmsg: no such
file or directory`), k3s shuts down *after* the point where k3d has seen "k3s is up and running",
and k3d times out on `waiting for log line 'cluster dns configmap' … stopped returning log
lines`. On a normal host privileged containers always get `/dev/kmsg`; the kata-agent doesn't
create it. (The pre-reinstall kata build evidently did — hence attempt 4's lone success.)

**Fix (one line, in the pod script before dockerd):** `mknod /dev/kmsg c 1 11` — inner
privileged containers then inherit it. With that:

- **k3d**: cluster created in **21–38s** from pod start; acceptance manifest passed clean
  **twice back-to-back** (2026-07-14, `KATA-K3D-ACCEPTANCE-PASSED`), node Ready, coredns +
  metrics-server Running, smoke pod schedules.
- **kind** (v0.32.0, kindest/node v1.36.1): control-plane **Ready in 19s** in the same pod.
  Without the fix it fails identically (kubelet crash-loop, 73 restarts).

The four accommodations, final list: (1) `dnsPolicy: None` + LAN resolver (FU-072 service-VIP
gap), (2) inner-docker MTU clamp 1350, (3) docker storage off the virtiofs rootfs (tmpfs or
loopback-ext4), (4) `mknod /dev/kmsg c 1 11`. Image now **digest-pinned** in the manifest.

## k3d vs kind — error-message quality (2026-07-14 comparison)

Same root cause hit both; the *diagnosability* differed a lot:

- **k3d**: worst case. k3s logs to the container's stdout only; when k3s dies the stream just
  stops and k3d reports a generic wait-timeout, then **rolls the cluster back, destroying the
  evidence** (use `--no-rollback` when debugging). The fatal kubelet line is present in
  `docker logs` but buried mid-stream between endless entrypoint kubectl retry noise.
- **kind**: `kubeadm init` failure is also generic at the surface (wait-control-plane deadline),
  BUT `--retain` keeps the node, systemd inside it keeps a **journal** — `docker exec
  spike-control-plane journalctl -u kubelet` shows the crash-loop cause in one line, and
  `kind export logs` bundles it. Meaningfully better postmortem story for CI.

Conclusion: keep k3d as the gate runtime (faster, lighter), but debug new environments with
kind's retained-node + journal, or run k3d with `--no-rollback`.

## Kata debugging gotchas (hard-won, will bite again)

- **`kubectl exec` into a dind kata container fails with cgroup EBUSY** once dockerd has child
  cgroups (cgroup-v2 no-internal-process rule; kata-agent attaches execs to the container root
  cgroup). Workaround: a second `ctl` container in the pod sharing `/run` (docker socket) —
  execs land in its clean cgroup, full `docker` access from there.
- The container's `/dev` is per-container; to touch the dockerd container's `/dev` from ctl:
  `docker run --privileged -v /dev:/hostdev … mknod /hostdev/kmsg c 1 11`.
- Raw `dockerd` (bypassing `dockerd-entrypoint.sh`) loses the dind cgroup-nesting preamble →
  inner containers get only threaded controllers (`cpuset cpu pids`, no `memory`) → k3s fatals
  with `failed to find memory cgroup (v2)`. The entrypoint's nesting works fine under kata.
- Attempts 9–11's "zero log lines" was an artifact of the tail-capture loop racing k3d's
  rollback; the k3s container did log — the fatal was sitting in it.

## Attempt matrix (15 runs, closed)

| # | Config | Result |
|---|---|---|
| 1–3 | defaults / MTU clamp / LAN DNS | vfs + no egress → DNS fixed by attempt 3 |
| 4 | 5Gi VM, 3Gi tmpfs | cluster UP in 36s, then guest-OOM (tmpfs too big) |
| 5 | 6Gi VM | hypervisor refused the memory hotplug (8G host ceiling) |
| 6 | 5Gi, 2Gi tmpfs, `--k3s-arg` disables | node NotReady — confounded by a disturbed cable |
| 7–8 | 4Gi (+ loopback ext4 in 8) | k3s wait timeout (flags still present) |
| 9–11 | no flags; tmpfs; +inotify sysctls | k3d timeout; post-hoc: the /dev/kmsg kubelet fatal |
| 12 | debug pod, raw dockerd + ctl sidecar | exposed cgroup-nesting + exec-EBUSY mechanics |
| 13 | dind entrypoint + live inspection | **found `/dev/kmsg` root cause; mknod → UP in 21s**; kind −kmsg fails identically / +kmsg Ready in 19s |
| 14–15 | clean acceptance manifest (digest-pinned, mknod) | **PASSED ×2** |

## Open mystery: the reinstall installed the WRONG image (→ FU-076)

The UEFI reinstall (`tofu apply -replace` of the config apply, state verifiably carrying the
metal_kata installer URL) produced a node running the PLAIN metal schematic — kata restored via
`talosctl upgrade --image factory.../f1aa29f1...` (metal nodes upgrade fine). Unexplained;
re-check on the next metal (re)install whether install.image is honored from maintenance mode.
(Likely also the origin of the /dev/kmsg regression: the upgrade pulled a newer kata extension
whose agent no longer creates it.)

## The caching design (FU-073) — LANDED 2026-07-14 as ADR-091

_Below is the spike-time design; the build (registry:3 pair, `registry-cache` ns, BGP VIPs
`.40.20/.21`, docker-mode rides wired, docker.io FQDNs dropped from the agent egress) is
recorded in ADR-091 + SERVICES.md; the remaining consumers live in FU-073._

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
  (mutable `:5-dind` burned this spike; the acceptance manifest is digest-pinned now).

`devbox run ci` contract: the gate script detects the mirror endpoints via env (set by the
runner/pod), falls back to direct pulls only outside the platform (laptops).
