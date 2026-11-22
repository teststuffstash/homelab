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

`run` first deletes every FINISHED rig pod (Succeeded/Failed — e.g. one killed at its deadline,
which otherwise stays as an object holding its scratch PVC and the PVC quota), then creates the pod,
waits for Ready, ships the tree, runs the command and streams its output, copies
`$JAIL_EVIDENCE_DIR` back, deletes the pod (also on failure; `--keep` leaves it for poking) and exits
with the command's exit code. Log and evidence land in `$JAIL_CLUSTER_EVIDENCE_DIR`
(default `$TMPDIR/jail-cluster/<pod>-<ts>/`).

**What is shipped** — the working tree, not a pushed branch: tracked files plus untracked files that
`.gitignore` does not exclude, read from `git ls-files`, minus ONE never-ship predicate
(`never_ship` in the verb, whatever `.gitignore` says): `.devbox/`, `.git/`, any `*kubeconfig*` /
`*talosconfig*` name, ssh keys (`id_rsa`, `id_ed25519`, …), `.netrc`, `.git-credentials`, `.npmrc`,
`.pypirc`, `.env*`, `*.tfstate*`, `*.tfvars*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.kdbx`, `*.keyx` —
and the kubeconfig the verb is using, under any name. No `.git` directory goes in, so a gate that
needs git history (diff-ci) does not work there yet. Evidence coming back is untrusted: a tar with an
absolute or `..` member is refused whole, and every symlink is deleted after extraction.

**Inside the pod** — cwd is the shipped tree; `docker`, `k3d` (and `kubectl` when the dind image
carries it) are on PATH, copied from the pinned dind image by an init container; `DOCKER_HOST` points
at the sidecar; the docker ride's mirror env (`REGISTRY_MIRROR_*`, `BUILDKITD_TOML`) and the nix
cache (`NIX_CACHE_URL`, set as the only substituter) are present. Gate scripts follow
[`patterns/kind-ci.md`](patterns/kind-ci.md): mirror-wire the kind/k3d node, run-scoped names.

## Who may start one

The seat uses its admin kubeconfig (`tofu/kubeconfig`, the fallback). Subagents and stack jails get a
**namespace-scoped token** instead, minted by the seat:

```sh
devbox run jail-cluster -- token --duration 2h     # → $HOME/.jail-cluster/<session>-<ts>.kubeconfig (0600)
# the subagent: JAIL_CLUSTER_KUBECONFIG=<that file> devbox run jail-cluster -- run …
```

The file is written OUTSIDE any git work tree — `token` refuses an `--out` inside one, because `run`
ships work trees. `--duration` is 10m..4h, enforced by the verb: the apiserver here sets no
`--service-account-max-token-expiration` (none in `tofu/talos.tf`), so it honours whatever duration a
TokenRequest asks for, and the admin kubeconfig could mint longer by hand.

The ServiceAccount `jail-clusters/jail-cluster` may create, exec into, read and delete pods in that
namespace, nothing else (`rbac.yaml`). Pods never run as it: they run as `jail-cluster-runner`, an SA
with no bindings and no mounted token, so a token holder cannot turn a pod into a longer-lived copy of
the token (no automount, no `projected` volumes, no other SA — admission policy (g), (k), (l)). What
the pod may BE is the admission policy's job, below.
Pods carry `jail-cluster/session` (`$JAIL_CLUSTER_SESSION`, default the jail's hostname) and
`jail-cluster/name` labels; the pod name is `jc-<session>-<name>`, so concurrent subagents pick
distinct `--name`s.

## The bounds

| Bound | Where | What it does |
|---|---|---|
| Cap | `resourcequota.yaml` | at most **2** pods (+ their scratch PVCs, memory belt 10Gi); over it `create` fails and the verb says "cap is reached" |
| Priority | `priorityclass.yaml` | value −1000, `preemptionPolicy: Never`: below every workload (no other class is set on rides or CI, ADR-159), so the scheduler preempts a jail pod for a pending ride/CI pod and the kubelet evicts it first; a pending jail pod never preempts |
| Admission | `admission-policy.yaml` | **mandatory**: every pod in the namespace is kata, on nx-01, labelled `app=jail-cluster` (so `list`/`reap` see it), carries the pinned dind, runs only the pinned dind or a release-tagged agent-base, privilege only on the dind, no host namespaces/ports/hostPath, no `projected` volume, no API token (automount off, SA `jail-cluster-runner`), no ephemeral containers, every emptyDir ≤ 1Gi, a deadline ≤ 4 h, the jail-clusters priority class. Without it the privileged-dind grant is root on nx-01 |
| Egress | `egress-cnp.yaml` | DNS, the registry mirrors (docker.io/ghcr/mcr, PyPI, npm), the nix cache + devbox search, and `ghcr.io:443` — the docker-mode ride's legs; ingress denied |
| Disk | `resourcequota.yaml`, `limitrange.yaml`, policy (n) | ephemeral-storage requests/limits on every container (LimitRange default 256Mi/1Gi, max 10Gi; the runner asks 2Gi/10Gi), namespace cap 8Gi requests / 24Gi limits, every emptyDir `sizeLimit` ≤ 1Gi; the dind layer store is the 20Gi scratch PVC (quota 40Gi) |
| Leak | the verb + pod spec | `activeDeadlineSeconds` (default 3600, max 14400) STOPS a pod — it goes Failed, but the object and its scratch PVC stay until something deletes them. The verb deletes its pod on exit, the next `run` (anyone's) deletes every finished rig pod first, and `reap` does it by hand; the PVC is the pod's ephemeral volume, so the garbage collector removes it after the pod. No CronJob: a leaked pod only matters when someone wants to run, and that run clears it |

PodSecurity stays at baseline: the apiserver exempts the kata runtimeClass (FU-077), which is exactly
why the admission policy must exist.

## Limits — what the bounds do NOT give

- **The kata boundary is an assumption until the smoke's step 0 passes.** The policy guarantees the
  privileged dind runs in a kata microVM; that a privileged container in that guest cannot reach
  nx-01 is a property of the kata build (the Talos extension's default config) nobody has checked on
  this cluster. `scripts/jail-cluster-smoke.sh` step 0 lists what a privileged container sees and
  fails on any block device that is not the guest's own; no token is handed out before it passes.
- **Exfiltration channels stay open, as on rides:** DNS (the kube-dns leg allows any name, so data can
  leave in queries) and `ghcr.io:443` (an authenticated push is possible with a credential brought
  in). The egress policy limits *where*, not *what*. The shipped tree is therefore filtered, and it
  must never contain a credential.
- **agent-base is pinned by tag shape, not one tag** — release tags from the authenticated-push
  registry only; the exact pin would need a second copy of the auto-bumped `agents/images.env` line.
- **Nothing enforces that `jail-cluster-runner` stays unbound** — admission cannot see RBAC; a
  binding to it is a review finding.

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
the verb's run/list/reap/token paths against a fake kubectl (never-ship tree, in-use kubeconfig,
reap-before-create, evidence symlink and `..` member, token bounds), and the smoke's step 0 against a
fake docker (guest-only devices pass; a host-sized disk, a big virtio disk, an empty probe fail).
