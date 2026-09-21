# Spike — rotating the Talos API CA under a tofu-declared cluster

**Tracked by:** FU-264. **Status:** design only — nothing run, not even a dry run.
**Why now:** a talosconfig carrying the `os:admin` certificate **and its private key** was
committed to public master on 2026-09-21
([incident](../incidents/2026-09-21-talosconfig-committed-to-public-master.md)). Talos has no CRL,
so that identity is valid until **2027-05-29** and only a CA rotation invalidates it.
**Operator ruling (2026-09-21):** rotate, but *after* the three-control-plane rollout is stable —
every apply that week taught something new, and a PKI rotation mid-rollout compounds.

## What is actually exposed

| | leaked | consequence |
|---|---|---|
| `os:admin` client certificate + **private key** | yes | full Talos API admin on the LAN until 2027-05-29: machine config read/write, reset, reboot, and `talosctl kubeconfig` → cluster-admin on Kubernetes |
| Talos CA **certificate** | yes | public by nature; it is what clients verify against |
| Talos CA **private key** | **no** | a talosconfig never carries it — so no NEW identity can be minted from what was published |
| Kubernetes CA / the k8s admin key | no | not in a talosconfig; reachable only *through* the Talos API with the leaked identity |

The API is LAN-only (`192.168.2.0/24`) plus WireGuard peers; nothing in
[`cloudflare.md`](../cloudflare.md) publishes it. So the exposure is bounded by network position,
not by the credential — which is why "rotate, but finish the rollout first" is a defensible call
and "do not rotate at all" is not.

## What `talosctl rotate-ca` does

`talosctl rotate-ca` (v1.13, `--dry-run` defaults to **true**) generates new CAs and applies them
gracefully across the cluster, writing a new talosconfig to `-o`. It rotates **both** the Talos API
CA (`--talos`) and the Kubernetes API-server issuing CA (`--kubernetes`) unless one is disabled;
the rest of the Kubernetes PKI is rotated by ordinary machine-config changes on the control planes.

## The problem this spike exists for: tofu holds the old bundle

`talos_machine_secrets.this` is the declared PKI, and every machine config, the talosconfig data
source and `talos_cluster_kubeconfig` derive from it. After a live rotation the state still holds
the **old** CA, so:

- the next `talos_machine_configuration_apply` pushes the OLD CA back onto every node — undoing the
  rotation, or breaking trust, depending on ordering;
- `plan` does not warn, because from tofu's side nothing changed;
- the resource is now `prevent_destroy` with a frozen `talos_version` (#1825, FU-263 (a)), so the
  "just let tofu regenerate it" path is closed on purpose — regenerating is a NEW PKI, not a
  rotation, and every live node would be left trusting certificates nothing holds.

**So the rotation is only half a Talos operation; the other half is making tofu's state agree.**
That half is the unknown, and it is what must be settled before anything runs:

1. **Can `talos_machine_secrets` be imported from a secrets bundle** the rotation produces, or
   reconstructed from the control planes' own machine configs (`machine.ca`, `cluster.ca`)? The
   provider's import behaviour for this resource is **unverified** — probe it in the lab, do not
   assume.
2. **What does the rotation leave on disk** that can be turned into a bundle at all? `rotate-ca`
   writes a talosconfig (client material), not a secrets bundle (CA keys).
3. **Which client artefacts must be re-rendered afterwards** — `devbox run talosconfig` and
   `devbox run kubeconfig` both read from the box's state (`scripts/client-configs.sh`), so they
   are only correct once step 1 is.

## How to answer it without touching the cluster

The vehicle already exists: **`scripts/controlplane-lab-install.sh`** builds a disposable one-node
control plane on nx-02 — the same rig that settled the v1.13.2 → v1.13.10 nocloud upgrade question
on 2026-09-19 ([`controlplane-ha.md`](../controlplane-ha.md) §CP4). Stand one up from a tofu root
that declares it exactly as `main` declares the real cluster, then:

1. `talosctl rotate-ca --dry-run` → read the plan it prints.
2. `talosctl rotate-ca --dry-run=false` → confirm the node stays up and the new talosconfig works.
3. Try each state-reconciliation candidate from §1 above and record which one leaves `plan` clean
   with the NEW material — that is the whole deliverable.
4. Re-render the client configs and check `plan` once more.

Only then write the runbook recipe for the real cluster, and only then schedule it — three control
planes, so the blast radius of a bad step is one member at a time, which is itself an argument for
doing it *after* the rollout rather than during.

## What must NOT be done

- **Do not `-replace` `talos_machine_secrets.this`.** That is a new cluster PKI, not a rotation:
  every node would keep trusting the old CA and nothing would hold valid certificates for the new
  one. The `prevent_destroy` added in #1825 exists to make that a plan-time error.
- **Do not rotate to "clean up" the issuer.** `local.sa_issuer` is frozen by
  [ADR-136](../adr.md) and names `.51` for this cluster's lifetime; it is unrelated to the CA and
  moving it 401s every ServiceAccount token at once.
