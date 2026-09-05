# Pattern: you are the next Python stack

> To find **what** services exist, grep [`../../SERVICES.md`](../../SERVICES.md). This doc is the
> **golden path for a Python/uv stack** on this platform — the sibling of
> [`observability.md`](observability.md) (same shape: the contract written down once, so the
> second consumer copies instead of re-learning). Written 2026-09-02 from the oracle jail's
> routed proposal: oracle-fleet was the first Python stack and paid for every lesson at retail —
> the receipts are its issues (#129, #314, #315, #316), cited inline so a claim can be re-checked
> against the incident that minted it.

**The one-line rule: devbox owns the interpreter, uv owns the venv, and neither ever writes into
the other's territory.**

## devbox.json shape

- `python@<pin>` + `uv@latest`. Node only ever as repo *tooling* (lint, docs), never as the
  chassis of a Python stack.
- The toolchain layer is warm everywhere already: the ARC image bakes the devbox closure + the
  LAN nix substituter — you inherit that for free.

## The `UV_PROJECT_ENVIRONMENT` rule (the fleet#316 scar)

devbox's python plugin exports `UV_PROJECT_ENVIRONMENT` pointing at **its** venv and
identity-checks it on entry. Any script that runs `uv sync` / `uv run` **outside** `devbox run`
MUST export `UV_PROJECT_ENVIRONMENT=.venv` first — otherwise uv syncs into the plugin's venv and
the collision presents as unrelated breakage two tools later. uv-owned venv, devbox-owned
interpreter, always. (Three fixes to learn this: fleet#314 → #315 → #316 found the root cause.)

## Venvs and caches, by runner class

| Runner class | Venv | Wheel cache |
|---|---|---|
| **Long-lived** (proxmox VM) | keyed by `sha256(devbox.lock)` — `VENV_SUFFIX`, fleet#314 — with warmup self-heal (fleet#315) | local, persists naturally |
| **Ephemeral** (ARC `homelab-ephemeral`) | rebuilt EVERY job — **persist wheels, never venvs** (a persisted venv on ephemeral pods reimports exactly the staleness class #314 keyed away) | `UV_CACHE_DIR=/uv-cache`, a shared Longhorn RWX PVC (`arc-uv-cache`, 20Gi, `argocd/resources/github-runner/uv-cache-pvc.yaml`) mounted by every runner pod (homelab#1299, LIVE); uv's cache is lock-guarded + content-addressed, concurrent pods are supported |

Placement note (#1299): the ephemeral pool's nodes are the same kata laptops whose bulk/scratch
partition already shares with the image store (the PR#1193 disk-floor class), so the cache PVC is
Longhorn RWX rather than a hostPath on that partition — one extra moving part (share-manager)
buys isolation from that contention. On this RWX mount uv's normal hardlink install degrades to a
copy (still LAN-local, never WAN).

**Isolation rule (MUST):** agent-worker *sandboxes* never share a writable wheel cache — a
poisoned unpacked wheel is a cross-ride tampering vector. Writable shared cache = trusted CI
lane only; the `arc-uv-cache` PVC above is never mounted into a sandbox pod. Sandboxes get speed
from the read-through PyPI proxy instead (homelab#1300), via `UV_DEFAULT_INDEX`, when it exists.

Why the cache and the proxy are complementary, not redundant: uv's cache stores wheels already
**unpacked** and installs by hardlink — a hit skips download *and* unpack (~1–3 s). A proxy hit
still pays unpack per job (~10–20 s) but serves the untrusted lane and the miss path, and removes
the WAN/PyPI-429 dependency (the FU-196 argument, transplanted).

**Endpoint:** the PyPI cache is at `http://192.168.40.34` (BGP VIP, kata-reachable) or
in-cluster `http://pypi-cache.pypi-cache.svc`. Agent-worker sandbox rides set
`UV_DEFAULT_INDEX=http://192.168.40.34/simple/` (the launcher env plumbing wires this when the
cache is LIVE). The `/packages/` prefix is resolved automatically by uv from the index URL —
no separate config needed.

## Internal Python tools ship as WHEELS — images optional

The default publishing rail (ghcr image per tag) produces an artifact the tool's actual
consumers cannot run: CI jobs on ARC ephemeral runners have **no docker daemon**. Ship a release
wheel instead and consume it with uv. Worked example (allure-behavior-snippets v0.3.1,
2026-09-02): a 21s `release-wheel` workflow (`pipx run build` + `gh release create`), consumed as
`uv run --no-project --with <release-wheel-url> <console-script>` — one cacheable artifact, deps
resolve with it, existing git/ghcr tags untouched.

## `docker build` and non-Hub `FROM`s

dockerd's `registry-mirrors` is **Hub-only** — a `FROM ghcr.io/...` in your Dockerfile pulls
direct WAN on every layer-cache miss, whatever the mirror family covers for containerd. Don't
absorb that with per-repo retry loops or `ARG`-parameterized FROMs: the fleet fix is BuildKit
per-registry mirrors in the runner's `buildkitd.toml` (homelab#1308). Until it lands, know the
flake class exists.

## S3 publishing against Garage

- Always set explicit `--max-workers` on mc transfers — autodetect serializes to ~1 object/s
  against Garage's replica-fsync PUTs (fleet#129).
- Promote identical trees by **server-side copy**, never re-upload.

## CI job shape

Gate (fast, ephemeral) **in parallel with** artifact/e2e (long-lived runner); evidence/report
publishing in a trailing non-required job. The merge-blocking wall is `max(gate, e2e)`, never the
sum. If the e2e half runs **kind**, its own contract is [`kind-ci.md`](kind-ci.md).