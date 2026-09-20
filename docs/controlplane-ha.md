# Control-plane HA — the endpoint, the VIP, and the issuer riding on it

**Tracked by:** FU-243.

The mechanism behind [ADR-133](adr.md) (three control planes behind a Talos shared VIP) and
[ADR-136](adr.md) (freeze the ServiceAccount issuer). Phasing and the fleet-role reasoning live in
[`../ROADMAP.md`](../ROADMAP.md) §HA model; the address ruling in [`ip-plan.md`](ip-plan.md)
§"The control-plane endpoint VIP"; the node-level install/upgrade recipes in
[`provisioning.md`](provisioning.md). This page owns what neither of those does: **what
`cluster_endpoint` actually decides, why moving it was an outage, and the order that makes the
rest of the program boring.**

## C1. What `cluster_endpoint` decides

`local.cluster_endpoint` (`tofu/locals.tf`) is one string doing three unrelated jobs:

| It becomes | Read by | Safe to move? |
|---|---|---|
| `cluster.controlPlane.endpoint` in every machine config | a node bootstrapping, KubePrism's seed list | yes |
| the kubeconfig `server:` URL | external `kubectl` — the jail and the [management box](management-box.md) | yes, but `talos_cluster_kubeconfig` does NOT re-render it and `plan` reads clean (FU-259) |
| `--service-account-issuer` **and** `--api-audiences` on kube-apiserver | **every ServiceAccount token ever minted** | **no — this is the one that bites** |

A token carries the `iss`/`aud` it was minted with, and the apiserver rejects one whose `iss` is not
among its configured issuers. Moving the string therefore 401s every token already in the cluster,
at once, with no grace period. Measured live 2026-09-20 11:34Z: cilium-operator, crossplane,
cnpg-operator, longhorn's csi-provisioner and kube-state-metrics all CrashLoopBackOff, ARC runners
wedged so CI stopped, `sum(up)` 48 → 0 — a cluster-wide control-plane outage inside a minute.

**The data plane never noticed.** Running pods kept running and every node read `Ready` throughout,
which is why a node-health rehearsal passed it and why the operator, not the session, found it. The
check that catches this class is a **token-authenticated call**, never a `Ready` column.

## C2. Why the issuer is frozen rather than migrated

Kubernetes supports issuer rotation: `--service-account-issuer` may be given more than once, the
first minting and all of them validating. **Talos cannot express that.** `cluster.apiServer.extraArgs`
is a string map, a list value is rejected (`unexpected type for yaml sequence: v1alpha1.ArgValue`),
and the upstream flag is a repeatable array — so a comma-joined value would be read as a single
issuer containing a comma. What Talos *does* do is let `extraArgs` **replace** the flag it derives,
and that is the whole of ADR-136:

```yaml
cluster:
  apiServer:
    extraArgs:
      service-account-issuer: https://192.168.2.51:6443   # the value it ALREADY has
      api-audiences: https://192.168.2.51:6443
```

Pinned at the value the cluster already issues with, the pin invalidates nothing — and
`cluster_endpoint` stops being token identity. The string keeps naming `.51` for this cluster's
lifetime. That costs nothing here: no OIDC/JWKS consumer, no custom-audience token, and **zero**
legacy `kubernetes.io/service-account-token` Secrets (checked 2026-09-20), so the issuer is an
opaque identifier whose only valuable property was ever stability.

⚠ The corollary is a rule: **the pinned value must never be "tidied" to match the endpoint.** That
sync is the outage above.

## C3. The order — pin, join, flip

1. **Pin the issuer.** One apiserver restart per control plane; tokens survive because the value is
   unchanged. Verify live before moving on:
   `kubectl -n kube-system get pod -l component=kube-apiserver -o jsonpath='{.items[*].spec.containers[0].command}' | tr ',' '\n' | grep -E 'service-account-issuer|api-audiences'`
2. **Join `wk-metal-02` and the nx-02 VM, back to back.** Never rest at two etcd members —
   [`ip-plan.md`](ip-plan.md) §VIP: at two the VIP is *less* available than at one.
3. **Flip `cluster_endpoint` to the VIP.** Token-neutral by then, and it does not even restart the
   apiserver (C4). Re-render the client configs afterwards (`devbox run kubeconfig` / `talosconfig`
   → `scripts/client-configs.sh`) or the jail and the box keep dialling the old address (FU-259).

**Steps 1 and 2 restart apiservers, and on this fleet that has three known fallouts:** Cilium drops
the `10.96.0.1:443` backend fleet-wide and does not re-sync
([FU-258](spikes/cilium-apiserver-restart-backend-loss.md) — `devbox run maint cilium-check`;
`cp-upgrade` gates on it by itself), the Argo Workflows controller hot-loops and floods Loki
(FU-260), and SA tokens die if the issuer moves (C1). Open a window first:
[`/maintenance-window`](../.claude/skills/maintenance-window/SKILL.md).

## C4. The rehearsal — what a disposable lab control plane settles

The 2026-09-20 rehearsal was run on a *worker*, where the flag that broke the cluster does not
exist. A one-node throwaway **control plane** answers it completely. On the second hypervisor:

```bash
ssh root@192.168.2.59 'qm create 8199 --name cp-upgrade-lab --memory 4096 --cores 2 --cpu host \
  --ostype l26 --scsihw virtio-scsi-pci --net0 virtio,bridge=vmbr0 --serial0 socket --tags "talos,lab"
qm set 8199 --scsi0 nvme-thin:0,import-from=/var/lib/vz/template/iso/talos-v1.13.2-nocloud-amd64.img,discard=on,ssd=1
qm disk resize 8199 scsi0 20G
qm set 8199 --ide2 nvme-thin:cloudinit --ipconfig0 ip=192.168.2.65/24,gw=192.168.2.1 --boot order=scsi0
qm start 8199'
bash scripts/controlplane-lab-install.sh 192.168.2.65 /tmp/cplab   # isolated creds, never committed
```

Read the thin pool before creating it (`pvesm status` on the hypervisor — the pve pool has filled
four times). `.65`/`.66` are **borrowed for an hour, not assigned**: a lab address is procedure
state, so nothing about it enters `machines.yaml`, dnsmasq or [`ip-plan.md`](ip-plan.md).
Tear down with `qm stop 8199 && qm destroy 8199 --purge` and the addresses are free again.

The probe: mint a token, move the endpoint, see whether the token still authenticates — with the
**control case first**, so a pass means something. Results, 2026-09-20 (Talos v1.13.2, k8s v1.36.1):

| Phase | Endpoint move | Token minted before the move |
|---|---|---|
| 1 — control, issuer DERIVED | `.65` → lab VIP `.66` | **401** — the production outage, reproduced on a throwaway |
| 2 — pin applied at the current value | none | **authenticated** (403 = authn ok, authz denied) |
| 3 — the real thing, issuer PINNED | `.65` → `.66` | **authenticated** — survived |

Two further readings from phase 3, both load-bearing: the apiserver's flags still showed the pinned
`.65` issuer (Talos really does replace, not merge), and the kube-apiserver container's `startedAt`
did **not** move across the flip or a second flip back — **with the issuer pinned, moving the
endpoint does not restart the apiserver at all**, so step 3 above carries none of the C3 fallout.
