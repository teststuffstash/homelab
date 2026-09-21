locals {
  controlplane = { for k, n in var.nodes : k => n if n.role == "controlplane" }
  workers      = { for k, n in var.nodes : k => n if n.role == "worker" }

  # Split by hypervisor: one resource block per provider instance (a provider cannot be chosen
  # per for_each key). Only the INFRA layer splits — talos.tf still spans all of var.nodes.
  pve_nodes  = { for k, n in var.nodes : k => n if n.hypervisor == "pve" }
  nx02_nodes = { for k, n in var.nodes : k => n if n.hypervisor == "nx-02" }

  # Every Proxmox VM's Talos install disk (talos.tf) — one home, because node_install_targets
  # (outputs.tf) reports it as the VM half of the install-time declaration.
  vm_install_disk = "/dev/sda"

  # IP (without CIDR mask) per node.
  node_ip = { for k, n in var.nodes : k => split("/", n.ip_cidr)[0] }

  # Deterministic pick of the bootstrap control-plane (lowest key). This is a REAL node address
  # and stays one: talos_machine_bootstrap and talos_cluster_kubeconfig both have to talk to a
  # specific machine, not to the floating endpoint.
  first_cp_key = sort(keys(local.controlplane))[0]
  first_cp_ip  = local.node_ip[local.first_cp_key]

  # ADR-133's control-plane endpoint VIP, ruled in docs/ip-plan.md: a single address reserved in
  # 2.0/24 and assignable to no real host. Live on the control planes since #1801 (talos.tf
  # local.cp_vip_patch), with the apiserver cert naming it — which is what makes it safe to be
  # the endpoint below.
  cp_vip = "192.168.2.50"

  # ADR-136: the ServiceAccount issuer, FROZEN — declared here instead of derived from the
  # endpoint below. Talos otherwise computes BOTH --service-account-issuer and --api-audiences
  # from cluster_endpoint, and a token carries the `iss`/`aud` it was minted with: moving the
  # endpoint therefore 401s every ServiceAccount token already in the cluster, at once, with no
  # grace period. Measured live 2026-09-20 11:34Z — a cluster-wide control-plane outage within
  # one minute of the apply: cilium-operator, crossplane, cnpg-operator, longhorn csi-provisioner
  # and kube-state-metrics all CrashLoopBackOff; ARC runners stuck at Init:0/2 so CI stopped;
  # every kubelet, scheduler and controller-manager scrape 401 (48 -> 0 targets up). The data
  # plane never noticed and every node stayed Ready, which is why a node-health rehearsal passed
  # it — the check that catches it is a TOKEN-authenticated call, not a Ready column.
  #
  # kube-apiserver can carry two issuers across a rotation; Talos cannot express two (extraArgs is
  # a string map, a list is rejected), so the way out is for the value to stop moving at all —
  # extraArgs REPLACES the derived flag (local.sa_issuer_patch, talos.tf).
  #
  # ⚠⚠ THIS STRING IS FROZEN AND MUST NOT FOLLOW cluster_endpoint. It is what the live cluster has
  # minted tokens with since bootstrap; nothing dials it (no OIDC/JWKS consumer, no custom-audience
  # token, zero legacy service-account-token Secrets — checked 2026-09-20), so only its stability
  # ever had value. "Tidying" it to match the endpoint IS the outage above. Changing it for real
  # needs a cluster rebuild or a planned rotation of every token.
  sa_issuer = "https://192.168.2.51:6443"

  # The Kubernetes API endpoint — the VIP since 2026-09-21. Both preconditions the reverted
  # 2026-09-20 attempt lacked were verified live first: (a) the issuer pin above is LIVE on ALL
  # THREE control planes (`--service-account-issuer`/`--api-audiences` both read
  # https://192.168.2.51:6443 on cp-01, cp-02 and wk-metal-02), so moving this string is
  # token-neutral and does not even restart the apiserver (docs/controlplane-ha.md §CP4 phase 3);
  # and (b) there are three etcd members, so the VIP can actually move. The address itself was
  # proven end-to-end before the cutover: `.50:6443` served an AUTHENTICATED `kubectl get nodes`
  # and the apiserver cert already carries `IP Address:192.168.2.50` (#1801's certSANs).
  #
  # ⚠ Moving this does NOT re-render kubeconfig/talosconfig — `talos_cluster_kubeconfig` does not
  # re-read it and `plan` stays clean (FU-259). Run `devbox run kubeconfig` + `devbox run
  # talosconfig` (scripts/client-configs.sh) after, or the jail and the management box keep
  # dialling cp-01 and the whole point of the VIP is lost.
  #
  # ⚠⚠ local.sa_issuer above does NOT follow this string. That coupling is the outage. Tracked by FU-243.
  cluster_endpoint = "https://${local.cp_vip}:6443"

  # Both kinds of control plane: the VM ones in var.nodes and the metal ones flagged in
  # machines.yaml (ADR-133's laptop CP). This feeds the talosconfig's endpoint list, so leaving
  # the metal CPs out would hand every client a talosconfig that only knows the VM members —
  # exactly the single-point dependency the three-CP program exists to remove.
  controlplane_ips = sort(concat(
    [for k, n in local.controlplane : local.node_ip[k]],
    [for k, n in local.metal_nodes : n.ip if n.controlplane],
  ))

  # ---- machines/machines.yaml: the ONE inventory -----------------------------------------------
  # The repo-root inventory is the single source of truth for what boxes exist and how the metal
  # workers install; everything below is DERIVED from it, so a flag is edited in exactly one place
  # (machines/machines.yaml) and both tofu and the doc generator (machines/generate.py) follow.
  # Reading a file at plan time is pure data — no provider, no state, no ordering dependency.
  machines = yamldecode(file("${path.module}/../machines/machines.yaml")).machines

  # Failure-domain zones (ADR-114): machines.yaml `zone` → topology.kubernetes.io/zone.
  # Physical box = zone; every VM on the pve thin pool = "proxmox" (one pool took several VMs
  # at once, 2026-08-24 incident). Applied by tofu/longhorn.tf.
  machine_zones = { for m in local.machines : m.name => m.zone if can(m.zone) }

  # Bare-metal Talos workers (metal.tf). Booleans are compared to `true` (not just try()-defaulted)
  # so an explicit `kata: null` in YAML degrades to false instead of erroring in a conditional.
  metal_nodes = {
    for m in local.machines : m.name => {
      ip           = m.ip           # DHCP-reserved IP (maintenance-mode + ongoing node address)
      install_disk = m.install_disk # target disk for the install (NOT a longhorn_disks entry)
      # Extra Longhorn disks: [{device, name, tags}] — mountpoint AND node.longhorn.io disk key
      # are both <name>, so a rename orphans replicas. Tier comes from `tags` (ADR-089).
      longhorn_disks = tolist(try(m.longhorn_disks, []))
      pin_hostname   = try(m.pin_hostname, true) != false # HostnameConfig patch; default true
      kata           = try(m.kata, false) == true         # metal_kata install image + homelab.io/kata label
      # ADR-133's laptop control plane. Drives machine_type in metal.tf and nothing else: a metal
      # CP keeps the metal schematic, the metal installer image and every other per-node flag.
      # INSTALL-TIME — Talos bakes machine_type at install, so flipping this on a running node is
      # a no-op until it is reset to maintenance and reinstalled.
      controlplane = try(m.controlplane, false) == true
      # ARC runner-pool membership: the homelab.io/ephemeral LABEL (the scale set's nodeSelector),
      # which is NOT the homelab.io/ephemeral taint the `ephemeral` flag drives. Opt-in per node.
      arc = try(m.arc, false) == true
      # Longhorn on the EPHEMERAL partition (default disk) — the kubelet imageGC floor patch.
      longhorn_default_disk = try(m.longhorn_default_disk, false) == true
      # Install-disk partitioning (INSTALL-TIME ONLY — Talos never re-partitions a provisioned
      # volume, and XFS cannot shrink, so changing either needs a wipe + reinstall).
      ephemeral_max_size = try(m.ephemeral_max_size, null) # cap /var so user volumes get space
      # Put EPHEMERAL (containerd image store + ride scratch) on a disk OTHER than the system disk.
      # A Talos CEL disk expression, e.g. `disk.transport == "nvme"`. Default null = system_disk.
      # Why this exists rather than "install to the fast disk": these boards boot LEGACY, and a
      # passive M.2 adapter carries no option ROM, so an NVMe cannot be a boot device — but it can
      # carry EPHEMERAL, which is where the ride-host pressure actually lands (storage-ledger:
      # `<25 % free = no scratch PVC = every docker:true worker wedged`).
      ephemeral_disk_selector = try(m.ephemeral_disk_selector, null)
      user_volumes            = tolist(try(m.user_volumes, [])) # [{name, min_size, grow}] → /var/mnt/<name>
    } if try(m.talos_metal_node, false) == true
  }

  # Nodes whose CPU has AVX2 — set as a Talos machine.nodeLabels (homelab.io/cpu-avx2=true) so the
  # label travels with the node's machine config and survives a reinstall (boot-from-git), instead of
  # an imperative `kubectl label`. Used to schedule AVX2-only workloads (opencode's Bun runtime SIGILLs
  # without it; see agents/agent-session.sh). Verified via /proc/cpuinfo: the Xeon E5-2680v4 VMs and the
  # Haswell/Broadwell ThinkPads have AVX2; hp-01 (i3-3220) does NOT. Keyed by node name,
  # spanning both VMs and metal — membership-checked in talos.tf/metal.tf patches.
  avx2_nodes = toset([for m in local.machines : m.name if try(m.avx2, false) == true])

  # Compute/ephemeral-tier nodes — the homelab.io/ephemeral NoSchedule taint in metal.tf.
  ephemeral_nodes = toset([for m in local.machines : m.name if try(m.ephemeral, false) == true])
}
