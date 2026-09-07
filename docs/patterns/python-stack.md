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

**⚠ homelab is NOT an example of this pattern** — it has no `pyproject.toml`, no `uv.lock` and no
`uv` in `devbox.json` (bare `python3` for scripts), and its AgentStack claim carries
`egress.profile: none`. The reference implementation is **oracle-fleet** (the first Python stack —
it paid for every lesson below); **sleep-tracking** is the smallest complete one and the better
donor to copy. Read a claim before citing it: `kubectl get agentstacks -o json`.

## Ownership — platform vs stack

| Piece | Owner | Where |
|---|---|---|
| the interpreter pin + `uv` | **stack** | its `devbox.json` |
| the project venv (`.venv`) and `uv.lock` | **stack** — committed, canonical, PyPI URLs | its repo |
| `ci.sh` / the CI job shape | **stack** | its repo |
| the shared wheel cache on the TRUSTED CI lane | **platform** | `arc-uv-cache` PVC + `UV_CACHE_DIR=/uv-cache`, mounted into every ARC runner pod (homelab#1299) |
| the PyPI pull-through proxy | **platform** | `pypi-cache` (VIP `192.168.40.34`), [`../../SERVICES.md`](../../SERVICES.md) |
| the ride env that consumes it (`UV_DEFAULT_INDEX` + `UV_FROZEN` + `PIP_*`) | **platform** — rendered by the launcher from the claim | `agents/agent-session.sh`, keyed on `fixer.egress.profile: python` |
| the pypi/pythonhosted egress legs | **platform** — rendered from the claim | `argocd/resources/agentstack/composition.yaml` |

## What a Python stack must do (the whole list)

1. **`devbox.json`: `python@<pin>` + `uv@latest`** — §devbox.json shape below.
2. **Commit `uv.lock` — libraries included.** Not optional on this platform: a python-profile
   ride runs with `UV_FROZEN=1`, so a repo without a committed lock fails at `uv sync` (§the
   proxy caveat). *"We publish a wheel, we don't lock"* is the objection to pre-empt and it is
   wrong here: `uv.lock` pins the **development** environment, while a consumer of your wheel is
   constrained by `pyproject.toml`'s ranges — publishing is unaffected. (The live case:
   `allure-behavior-snippets` has a `pyproject.toml` and no lock. It is not exposed **today**
   only because its claim entry carries no `fixer` block, so it never rides — the day it gains
   one, every ride fails at `uv sync` until a lock is committed.)
3. **Install from the lock — `uv sync --frozen` in `ci.sh`.** Bare `uv sync` lets a stale lock
   update silently instead of failing the build, which is the whole point of committing one.
4. **`export UV_PROJECT_ENVIRONMENT=.venv`** in any script that runs `uv` *outside* `devbox run`
   — §the `UV_PROJECT_ENVIRONMENT` rule.
5. **Give the long-lived VM runner a venv it cannot share by accident** — either key
   `VENV_DIR` (lock hash **+ runner slot**) or keep the venv repo-local. §Venvs and caches, by
   runner class.
6. **Declare `fixer.egress.profile: python`** on the AgentStack claim. That one field is what
   earns the proxy env AND its egress legs; the stack sets nothing else.
7. **Never hard-code the LAN index in the repo.** `UV_DEFAULT_INDEX`/`PIP_INDEX_URL` exist only
   inside agent pods — a repo script that reads one MUST supply a default, because the same
   script runs in GitHub CI and on a laptop (the env card's pod-only caveat).

Everything below is the *why* behind those seven, plus the publishing/CI shapes.

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
| **Long-lived** (proxmox VM) | **two valid shapes, and the choice is not cosmetic** — see below | local, persists naturally |
| **Ephemeral** (ARC `homelab-ephemeral`) | rebuilt EVERY job — **persist wheels, never venvs** (a persisted venv on ephemeral pods reimports exactly the staleness class #314 keyed away) | `UV_CACHE_DIR=/uv-cache`, a shared Longhorn RWX PVC (`arc-uv-cache`, 20Gi, `argocd/resources/github-runner/uv-cache-pvc.yaml`) mounted by every runner pod (homelab#1299, LIVE); uv's cache is lock-guarded + content-addressed, concurrent pods are supported |

**The long-lived row, spelled out (corrected 2026-09-07 — the fleet sweep found the short
version misleading).** ci-runner-01 has **two slots**, so two of a repo's PR jobs can run at once.
What matters is whether they can reach the same venv directory:

- **Repo-local venv** — `export UV_PROJECT_ENVIRONMENT=.venv` (circles' `scripts/test-system.sh`).
  Each runner slot has its own workspace and `actions/checkout` runs `git clean -ffdx`, so the
  venv is per-slot AND rebuilt every job: no collision, no staleness, at the price of never being
  warm.
- **Keyed shared venv** — a `VENV_DIR` under `$HOME/.cache` is *outside* the workspace, so
  checkout never wipes it and every job on the VM shares it. That directory MUST be keyed by
  **`sha256(devbox.lock)` AND the runner slot** (`$RUNNER_NAME`) — oracle-fleet's
  `.github/workflows/ci.yaml` is the donor. The lock half alone is not enough: PR#310 vs PR#311's
  `devbox-update` e2e jobs corrupted each other on 2026-08-31 (ensurepip died mid-recreate), which
  is what added the slot half. Pair it with oracle-fleet's **warmup self-heal** step — a venv can
  break with no lock change (nix GC, a run cancelled mid-create), and devbox then prompts
  `overwrite? (y/n)`, which a non-tty CI answers by dying at exit 1.

The trap is the unkeyed middle: a `$HOME/.cache` venv with no suffix, which looks like the warm
option and behaves like a shared mutable global.

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
cache is LIVE). The `/simple/` location rewrites upstream `https://files.pythonhosted.org` links
to point back at this proxy, so artifact fetches land on `/packages/` and are cached.

### ⚠ The proxy is NOT client-config-free for a project that commits a lockfile

**uv records the resolving index inside `uv.lock`** — `source = { registry = … }` on every
package plus every artifact URL — so resolving through the LAN proxy REWRITES a committed lock to
`http://192.168.40.34/…`: same versions, same hashes, URL-only, and unusable by anyone off this
LAN (`CONTEXT.md` #1c sharable / #2 no autogenerated churn / #6 `git clone → it runs`). This
shipped with the consumer wiring (homelab#1413/PR#1457) and blocked oracle-fleet PR#504 on a
137-line lock diff. Measured on uv 0.12.10 while choosing the fix:

| what you might reach for | what it actually does |
|---|---|
| `uv sync --frozen` in the repo's `ci.sh` | keeps the lock clean **for that command only** — a plain `uv run` afterwards re-locks and rewrites all 137 lines. oracle-fleet already ran `--frozen` and was hit anyway, so a per-command repo fix does not close this |
| `uv sync --locked` | hard error (`the lockfile … needs to be updated`) — not a usable ride default |
| **`UV_FROZEN=1` (chosen)** | covers every project entry point: `sync`/`run` install from the committed lock, `lock` no-ops with a warning, the lock is never written |

So **python-profile rides set `UV_FROZEN=1` beside `UV_DEFAULT_INDEX`, and the two are one
decision** (`agents/agent-session.sh`, pinned by `agents/replay/fixtures/python-profile-env/`).
What that costs and what it keeps:

- **Locked installs bypass the proxy.** `--frozen` fetches the URLs the lock carries, i.e.
  `files.pythonhosted.org` over the WAN (allowed by the `python` egress profile). The cache still
  serves every *unlocked* path — `uv pip install`, `uvx`, `uv run --with`, pip — verified against
  the live VIP. Recovering the locked path needs a transparent cache (DNS + TLS interception);
  that is **FU-220**, not this wiring.
- **A python-profile repo with no committed `uv.lock` fails loudly** (`Unable to find lockfile …
  but UV_FROZEN=1 was provided`) rather than silently poisoning one. Commit a lock.
- **`uv add` in a ride edits `pyproject.toml`, leaves the lock stale and exits 0** — the venv then
  lacks the package and CI reds. To change a dependency, re-lock explicitly against canonical
  PyPI: `UV_FROZEN=0 UV_DEFAULT_INDEX=https://pypi.org/simple uv add <pkg>`. The env card states
  this so a worker acts on it rather than rediscovering it.

If a lock has already been rewritten, the substitution is byte-for-byte reversible (verified):
`s|http://192.168.40.34/simple/|https://pypi.org/simple|` and
`s|http://192.168.40.34/packages/|https://files.pythonhosted.org/packages/|`.

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
absorb that with per-repo retry loops or `ARG`-parameterized FROMs: the fix is BuildKit
per-registry mirrors via a `buildkitd.toml` + a **docker-container** builder (homelab#1308) —
the default `docker` driver builds inside dockerd and never sees the file. Both docker-capable
runner classes carry it: ci-runner-01's cloud-init creates a `homelab-mirrors` builder for the
`runner` user at boot; a docker-mode agent ride gets the config written to
`$BUILDKITD_TOML` (`/docker-run/buildkitd.toml`) by its dind sidecar and must create its own
builder before a `docker build` with a non-Hub `FROM` — `docker buildx create --driver
docker-container --driver-opt default-load=true --config $BUILDKITD_TOML --use --bootstrap`
(the env card states this). `--driver-opt default-load=true` (buildx ≥0.14) is what keeps
`docker build && docker run`/`kind load docker-image` working unmodified — without it a
docker-container builder's result never reaches the local image store.

## S3 publishing against Garage

- Always set explicit `--max-workers` on mc transfers — autodetect serializes to ~1 object/s
  against Garage's replica-fsync PUTs (fleet#129).
- Promote identical trees by **server-side copy**, never re-upload.

## CI job shape

Gate (fast, ephemeral) **in parallel with** artifact/e2e (long-lived runner); evidence/report
publishing in a trailing non-required job. The merge-blocking wall is `max(gate, e2e)`, never the
sum. If the e2e half runs **kind**, its own contract is [`kind-ci.md`](kind-ci.md).

## What this page does not promise

- **Nothing here is rendered from your claim except items 6's consequences.** The platform does
  not lint your `devbox.json`, does not check that you committed a lock, and does not run
  `uv sync` for you — the first four items are yours, and their failure mode is your CI.
- **The proxy is a speed/WAN-independence optimization, never a correctness dependency.** Every
  path it serves also works straight from PyPI on the `python` egress profile; a stack must never
  ship a lock, a script or a Dockerfile that only resolves on this LAN.
- **Retention and sizing of the shared caches are platform capacity, not a stack contract** — a
  stack that needs more asks through the capability-request lane
  ([`../agents/platform-and-stacks.md`](../agents/platform-and-stacks.md) §Cross-stack demand).
