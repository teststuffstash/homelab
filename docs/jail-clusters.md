# Jail clusters — a throwaway kind/k3d run on nx-01 for jail sessions

> Decision: [ADR-167](adr.md) (`### ADR-167`). This page is the mechanism. The verb is
> `scripts/jail-cluster.sh` (`devbox run jail-cluster -- …`); the cluster side is
> `argocd/resources/jail-clusters/` (Application `argocd/platform/jail-clusters.yaml`).

A jail has no Docker daemon and runs on a 16 GB laptop, so it cannot run a gate that starts kind or
k3d. CI's VM runners ([ADR-082](adr.md)) and docker-mode rides (a kata microVM pod with a dind
sidecar, [`spikes/kata-ci-gate.md`](spikes/kata-ci-gate.md)) can. A **jail cluster** is the
docker-mode ride's pod shape without the agent, started by the jail on demand: the gate runs inside
the pod and the jail needs only kubectl.

**Optional by rule** (ADR-167, from ADR-108's "the jail must be able to fix the cluster, so nothing in
its toolchain may require it"): no pre-push gate and no required check depends on a jail cluster.
When it is down, full or refused, push and let CI run the gate.

## Use

```sh
devbox run jail-cluster -- run --name smoke -- bash scripts/jail-cluster-smoke.sh   # the rig's proof
devbox run jail-cluster -- run --name kgate --deadline 1800 -- devbox run <gate>    # any gate
devbox run jail-cluster -- run --tree ../other-clone -- <command…>                  # another tree
devbox run jail-cluster -- list
devbox run jail-cluster -- reap [--all | <name>]     # bare: this session's pods
devbox run jail-cluster -- run --name x --dry-run    # print the pod manifest, touch nothing
```

`run` creates the pod, waits for Ready, ships the tree, runs the command and streams its output, copies
`$JAIL_EVIDENCE_DIR` back, deletes the pod (also on failure; `--keep` leaves it for poking) and exits
with the command's exit code. Log and evidence land in `$JAIL_CLUSTER_EVIDENCE_DIR`
(default `$TMPDIR/jail-cluster/<pod>-<ts>/`).

**What is shipped** — the working tree, not a pushed branch: tracked files plus untracked files that
`.gitignore` does not exclude, read from `git ls-files`, minus a never-ship set (`.devbox/`, `.git/`,
tofu state and vars, `kubeconfig`/`talosconfig`, `.env`, key files). No `.git` directory goes in, so a
gate that needs git history (diff-ci) does not work there yet.

**Inside the pod** — cwd is the shipped tree; `docker`, `k3d` (and `kubectl` when the dind image
carries it) are on PATH, copied from the pinned dind image by an init container; `DOCKER_HOST` points
at the sidecar; the docker ride's mirror env (`REGISTRY_MIRROR_*`, `BUILDKITD_TOML`) and the nix
cache (`NIX_CACHE_URL`, set as the only substituter) are present. Gate scripts follow
[`patterns/kind-ci.md`](patterns/kind-ci.md): mirror-wire the kind/k3d node, run-scoped names.

## Who may start one

The seat uses its admin kubeconfig (`tofu/kubeconfig`, the fallback). Subagents and stack jails get a
**namespace-scoped token** instead, minted by the seat:

```sh
devbox run jail-cluster -- token --out /path/in/the/subagents/clone/.jail-kubeconfig --duration 2h
# the subagent: JAIL_CLUSTER_KUBECONFIG=<that file> devbox run jail-cluster -- run …
```

The ServiceAccount `jail-clusters/jail-cluster` may create, exec into, read and delete pods in that
namespace, nothing else (`rbac.yaml`). What the pod may BE is the admission policy's job, below.
Pods carry `jail-cluster/session` (`$JAIL_CLUSTER_SESSION`, default the jail's hostname) and
`jail-cluster/name` labels; the pod name is `jc-<session>-<name>`, so concurrent subagents pick
distinct `--name`s.

## The bounds

| Bound | Where | What it does |
|---|---|---|
| Cap | `resourcequota.yaml` | at most **2** pods (+ their scratch PVCs, memory belt 10Gi); over it `create` fails and the verb says "cap is reached" |
| Priority | `priorityclass.yaml` | value −1000, `preemptionPolicy: Never`: below every workload (no other class is set on rides or CI, ADR-159), so the scheduler preempts a jail pod for a pending ride/CI pod and the kubelet evicts it first; a pending jail pod never preempts |
| Admission | `admission-policy.yaml` | **mandatory**: every pod in the namespace is kata, on nx-01, carries the pinned dind, runs only the pinned dind or agent-base images, privilege only on the dind, no host namespaces/ports/hostPath, no ephemeral containers, a deadline ≤ 4 h, the jail-clusters priority class. Without it the privileged-dind grant is root on nx-01 |
| Egress | `egress-cnp.yaml` | DNS, the registry mirrors (docker.io/ghcr/mcr, PyPI, npm), the nix cache + devbox search, and `ghcr.io:443` — the docker-mode ride's legs; ingress denied |
| Leak | the verb + pod spec | `activeDeadlineSeconds` (default 3600, max 14400) on every pod, delete on exit, `reap`; the dind layer store is an ephemeral block PVC that dies with the pod |

PodSecurity stays at baseline: the apiserver exempts the kata runtimeClass (FU-077), which is exactly
why the admission policy must exist.

## Sizing

One pod requests ~4 GiB: dind 2560Mi (the standard docker ride's envelope, extracted from
`agents/agent-session.sh` REPLAY:ride-size) + runner 1Gi + kata overhead 512Mi. **This is an
estimate**: the first real run records the true peak, and the runner's 1Gi is the number most likely
to move (a cold `devbox install` evaluates nix in the runner). nx-01 has ~61.5 GiB allocatable; two
jail pods are ~8 GiB beside the ride/ARC tier.

## One home for the pod fragments

The verb does not carry a copy of the ride's dind sidecar. At run time it extracts two spans of
`agents/agent-session.sh` — the sentinel-delimited `REPLAY:ride-size` block (the replay harness's
extraction contract) and the docker-mode block between the bare `ride_size_envelope` call and the
`REPLAY:fu088-gates` sentinel — and evaluates them with `DOCKER=1`, `RIDE_SIZE=standard`. A change to
the ride's dind (mirrors, mknod, the block PVC) reaches jail clusters with no edit here; a change that
breaks the extraction fails the verb loudly. The one duplicated fact is the dind image pin, which CEL
cannot read from `agents/images.env`: `scripts/jail-cluster-test.sh` fails when the policy's pin and
`AGENT_DIND_IMAGE` differ.

## Checks

`devbox run jail-cluster-self-test` — no cluster: the render against the contract, the rendered pod
plus a decision table of one-violation patches (`scripts/fixtures/jail-cluster/vap-cases.tsv`)
through `kyverno apply` of the live admission policy (each refusal asserted by its clause letter),
and the verb's run/list/reap/token paths against a fake kubectl.
