# Control-plane HA — the endpoint, the VIP, and the issuer riding on it

**Tracked by:** FU-243.

The mechanism behind [ADR-133](adr.md) (three control planes behind a Talos shared VIP) and
[ADR-136](adr.md) (freeze the ServiceAccount issuer). Phasing and the fleet-role reasoning live in
[`../ROADMAP.md`](../ROADMAP.md) §HA model; the address ruling in [`ip-plan.md`](ip-plan.md)
§"The control-plane endpoint VIP"; the node-level install/upgrade recipes in
[`provisioning.md`](provisioning.md). This page owns what neither of those does: **what
`cluster_endpoint` actually decides, why moving it was an outage, and the order that makes the
rest of the program boring.**

## CP1. What `cluster_endpoint` decides

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

## CP2. Why the issuer is frozen rather than migrated

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

## CP3. The order — pin, join, flip

1. **Pin the issuer.** One apiserver restart per control plane; tokens survive because the value is
   unchanged. **Applied on cp-01 2026-09-20 19:08Z and it played out as rehearsed:** the apiserver
   restarted once, a token minted *before* the apply still authenticated afterwards, and `tofu plan`
   went clean. The restart's collateral was the known list and nothing else — FU-258 dropped the
   backend on **10 of 12** agents (one `rollout restart ds/cilium` restored all 12), `kube-scheduler`
   and `kube-controller-manager` on cp-01 crashlooped while the API was down and recovered on their
   own within ~6 min, and three scrape targets followed them down and back. The Argo controller did
   **not** flood this time (FU-260 stayed quiet at ~2 lines/s). Verify live before moving on:
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

## CP4. The rehearsal — what a disposable lab control plane settles

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

## CP5. Promoting a running worker to a control plane

`machine_type` is baked at install, so the `controlplane: true` flag is only half of it: the node
must be **reset to maintenance and reinstalled**. Landing the flag on a running worker and applying
would push a control-plane config at a worker instead — which is why the flag and the reinstall
belong in one sitting. The whole sequence runs inside a
[declared window](glossary.md) (`/maintenance-window`); the generic onboarding steps it reuses are
the [`onboard-metal-node`](../.claude/skills/onboard-metal-node/SKILL.md) skill's.

1. **Take it out of the ride pool first**, as its own change (#1814's shape), so nothing new lands
   on the node while you are draining it.
2. **Measure etcd fsync before the join** — etcd's own probe, on the node, through a pod:
   `dd if=/dev/zero of=/tmp/etcdtest bs=2300 count=1000 oflag=dsync`. Under ~10 ms per write is
   what etcd wants. A CP that cannot fsync quickly is a cluster-wide latency problem, and this
   costs three minutes *before* the box is load-bearing (wk-metal-02's X250: 1.60 s ⇒ ~1.6 ms).
3. `kubectl cordon` + `kubectl drain --ignore-daemonsets --delete-emptydir-data`.
4. **Flag the MAC** in `tofu/provisioning/matchbox.tf` and apply that root (its own S3 backend —
   `keepass-env.sh` *and* `tofu-state-env.sh`, per the onboarding skill's step 1).
5. `kubectl delete node <name>` — the join recreates the object; the worker-era one would otherwise
   carry stale labels and taints into its CP life.
6. `talosctl reset --graceful=false --reboot --wipe-mode all` → it PXE-boots into maintenance.
7. `devbox run mgmt-tf -- apply -target='talos_machine_configuration_apply.metal["<name>"]'` —
   installs with `machine_type: controlplane`, and `metal.tf` conditions the VIP patch and the
   issuer pin on the same flag, so the new CP gets both at birth.
8. **Unflag** (destroy the matchbox group) so the post-install reboot comes off disk, then
   **watch it take its DHCP lease** before trusting the install: the box is only reachable while
   the router hands it `.183`, and a config that claims its interface can take that away silently
   (§CP6). `dnsmasq/leases/search` on OPNsense is the check that does not need the node.
9. **Post-install, none of which `Ready` gates:** re-apply the zone label
   (`kubernetes_labels.node_zone` — the Node object is new); **add the node IP to `bgp_node_ips`
   and run the BGP play** ([`provisioning.md`](provisioning.md) step 8) *before* confirming
   `cilium bgp peers` is `established` — a new address peers with nothing until OPNsense lists it,
   and this list has now been the miss four times (wk-03, wk-metal-04, nx-01, cp-02 — the last
   caught 2026-09-21 an hour after creation, `idle` with 0 routes); and confirm etcd membership
   grew by exactly one.
10. Finish with a **full** `mgmt-tf apply`: a targeted apply does not stamp the box's apply-loop
    baseline.

⚠ **Do not stop here.** Two etcd members is the one state worse than one — go straight on to the
next join.

## CP6. The VIP patch takes the interface — and with it, the address

`wk-metal-02` was reinstalled as a control plane on 2026-09-20, the apply ran clean, and the box
never came back: no ARP on `.183`, no DHCP lease on the router, 7.3 W at the plug. The console (read
by the operator the next morning) showed Talos up and healthy, failing NTP lookups against
**8.8.8.8** — Talos's compiled-in fallback resolver, i.e. *nothing had handed it a DNS server*.

**Cause — the VIP patch, and it was not a fluke.** A VIP has to hang off an interface, so
`local.cp_vip_patch` writes `machine.network.interfaces`. Naming a link there moves it into Talos's
`ConfigMachineConfiguration` layer, and the **default-layer `dhcp4` operator is emitted only for
physical links that no layer configures** (`internal/app/machined/pkg/controllers/network/operator_config.go`:
*"interface is configured explicitly, don't run default dhcp4"*). `dhcp` itself defaults to false.
So the patch quietly withdrew the node's only address source:

| | Address source | Effect of the patch |
|---|---|---|
| cp-01, cp-02 (nocloud VM) | `ConfigPlatform` — the Proxmox datasource | none: the link was *already* configured, so there was no default `dhcp4` operator to lose |
| wk-metal-02 (PXE metal) | the **default** `dhcp4` operator | fatal: `talos.platform=metal` supplies no network config and the disk-boot cmdline carries no `ip=`, so the node has no address at all |

Verifiable without the box, on any live node — `talosctl get operatorspecs` reads `layer: default`
for a metal worker's `dhcp4/enp0s31f6`, while cp-01 lists **only** `vip/eth0`, and
`talosctl get addressspecs` shows cp-01's `.51/24` as `layer: platform` against wk-metal-03's
`.184/24` as `layer: operator`.

**The fix** is one line, and it is what upstream's own VIP example has always carried:
`tofu/talos.tf` now keeps two variants of the patch off one `cp_vip_interface` — the
platform-addressed one for the VMs and `cp_vip_patch_dhcp` (`dhcp: true`) for metal, which
`metal.tf` uses. The VMs deliberately do **not** get `dhcp: true`: their MACs have no dnsmasq
reservation, so a lease would come from the `.100–.245` pool and give `eth0` a second, arbitrary
address.

**The lesson is about the verification, not the YAML.** The patch *was* rehearsed —
`--mode=try` on cp-01, confirmed additive (§CP3's note). That rehearsal was structurally incapable
of catching this: it ran on the one address source the patch cannot disturb. **A config patch that
claims a network interface must be rehearsed on a node whose address comes from the layer it is
about to displace** — for this fleet, that means a metal node, and the cheap version is
`talosctl patch --mode=try --timeout 1m` against a metal *worker*, which reverts itself if the node
goes silent.

Two adjacent findings from the same night, both filed: the BIOS PXE chainload was broken
(`undionly.kpxe` missing on the Matchbox LXC — [FU-261](follow-ups.md)), which is why three reboots
read as "PXE just doesn't take"; and nothing alerts on a **declared node that is simply absent**
from the cluster — the extreme case of [FU-235](follow-ups.md)'s declared-vs-live diff.

## CP7. When the broken config is the installed one

§CP6's defect left `wk-metal-02` unable to network *from its own install*, and that is a state the
§CP5 recipe cannot re-enter: PXE does not force maintenance mode (Talos reads its config from the
STATE partition) and `talosctl reset` needs the network the node just lost. The way back is to wipe
STATE from the kernel command line — **recipe, caveats and the measured timings in
[`provisioning.md`](provisioning.md) §"Recovering a node whose INSTALLED config is broken"**, which
owns it because it is a node-level procedure, not a control-plane one.

Done on 2026-09-21: wipe 05:47:42Z → maintenance 05:49:20Z → corrected config applied → `Ready` as
a control plane 05:52:09Z, `.183` held at `layer: operator` (the default DHCP operator restored),
etcd 2 members, BGP `established` with 25 routes. cp-02 followed immediately, taking the cluster to
**three control planes and three etcd members**.

⚠ **One thing this episode is NOT evidence of.** The Matchbox PXE assets were pinned at v1.13.2
while `var.talos_version_worker` had moved to v1.13.10, and that drift was fixed mid-recovery — but
it caused none of this. Both kernel versions chainloaded and booted fine; the config on disk was
the whole story. The lockstep fix stands on [FU-246](follow-ups.md)'s own merits, and the first
diagnosis that blamed the kernel was wrong.
