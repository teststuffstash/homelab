# Provider-agnostic cluster definition. Nothing here knows about Proxmox — in a
# DR rebuild this file is reused unchanged; only proxmox.tf/providers.tf change.

locals {
  # FU-073a: node-level image pulls ride the pull-through mirrors (ADR-091,
  # argocd/resources/registry-cache/ — BGP VIPs, git-pinned like the agent-ride wiring in
  # agents/agent-session.sh). skipFallback stays at its default (false): a dead mirror — or a
  # cold cluster boot, where the VIP needs Cilium+BGP up first — falls through to the upstream
  # registry, so pulls get slower, never broken. Applied to VM (talos.tf) + metal (metal.tf)
  # nodes alike; registry config is config_path-based in Talos, expected to apply in-place.
  registry_mirrors_patch = yamlencode({
    machine = {
      registries = {
        mirrors = {
          "docker.io" = { endpoints = ["http://192.168.40.20"] }
          "ghcr.io"   = { endpoints = ["http://192.168.40.21"] }
        }
      }
    }
  })

  # ADR-136's issuer pin (local.sa_issuer, locals.tf). Control planes only — a worker config has
  # no cluster.apiServer. extraArgs REPLACES Talos's derived flag rather than adding to it, which
  # is what makes this a pin and not a second issuer (Talos cannot express two; see locals.tf).
  # Applied at its CURRENT value, so it invalidates no token — rehearsed on the disposable nx-02
  # lab control plane before the live apply (docs/controlplane-ha.md §CP4).
  sa_issuer_patch = yamlencode({
    cluster = {
      apiServer = {
        extraArgs = {
          "service-account-issuer" = local.sa_issuer
          "api-audiences"          = local.sa_issuer
        }
      }
    }
  })

  # The CLUSTER-scoped control-plane patch — carried by EVERY control plane, VM (below) and metal
  # (metal.tf) alike. A CP missing it is not inert: as a control plane it applies Talos's DEFAULT
  # bootstrap manifests (flannel beside Cilium, on every node) and serves an apiserver without the
  # kata PodSecurity exemption. That is what wk-metal-02 did from its 2026-09-21 reinstall until
  # this became a shared local (homelab#1845) — the VM-only inline copy never reached metal.
  cp_cluster_patch = yamlencode({
    cluster = {
      # CNI is cluster-scoped. "none" disables the default Flannel so Cilium can be installed
      # instead (see ROADMAP service-exposure).
      network = { cni = { name = "none" } }
      # kube-proxy disabled — Cilium does service routing via eBPF
      # (kubeProxyReplacement). Fixes NodePort hairpin drop on the backend
      # node and preps for Cilium LB. Cilium uses Talos KubePrism (:7445).
      proxy = { disabled = true }
      # Expose scheduler + controller-manager metrics on the node IP (Talos binds them
      # to 127.0.0.1 by default, so kube-prometheus-stack can't scrape them → false
      # "InstanceUnreachable"/"TargetDown" alerts). LAN-only; :10259/:10257 still need auth.
      # Applied in-place (static-pod restart, no reboot). monitoring.tf points the chart's
      # ServiceMonitors at the control-plane IP.
      scheduler         = { extraArgs = { "bind-address" = "0.0.0.0" } }
      controllerManager = { extraArgs = { "bind-address" = "0.0.0.0" } }
      # PSS can't see runtime classes, so privileged-inside-a-microVM (kata dind rides —
      # root in the GUEST only) forced docker-worker namespaces to enforce: privileged
      # wholesale. Exempting the kata runtimeClass lets those namespaces return to
      # baseline (FU-077). Talos MERGES this with its built-in PodSecurity entry by plugin
      # name — carry ONLY the new field: restating the defaults crashes the apiserver
      # ("Duplicate value: kube-system", learned live 2026-07-16 — list merge concatenates).
      # Applied in-place: brief apiserver static-pod restart, one control plane at a time.
      apiServer = {
        admissionControl = [{
          name = "PodSecurity"
          configuration = {
            apiVersion = "pod-security.admission.config.k8s.io/v1alpha1"
            kind       = "PodSecurityConfiguration"
            exemptions = {
              runtimeClasses = ["kata"]
            }
          }
        }]
      }
    }
  })

  # Every control plane carries these — VM (below) and metal (metal.tf) consume this ONE list, so a
  # new CP patch cannot reach one config and not the other (homelab#1845: the cluster patch lived
  # inline in the VM config only, and the metal CP ran without it). The VIP patch stays out: it
  # has a per-platform variant (cp_vip_patch vs cp_vip_patch_dhcp).
  cp_common_patches = [local.sa_issuer_patch, local.cp_cluster_patch]

  # ADR-133's control-plane endpoint VIP (local.cp_vip, ruled in docs/ip-plan.md). Carried by
  # EVERY control plane — VM (below) and metal (metal.tf) alike — because a Talos shared VIP is
  # elected through etcd: the CP that wins the campaign puts the address on its own NIC and
  # gratuitous-ARPs it, and it moves to another member when that one goes away. A worker never
  # gets this patch; it has no vote.
  #
  # `deviceSelector` rather than a named interface ON PURPOSE: cp-01 (nocloud VM) is `eth0`,
  # wk-metal-03 (ThinkPad) is `enp0s31f6`. `physical: true` matches the one real NIC on either
  # and leaves the cilium_*/lxc*/bond0/dummy0 links alone.
  #
  # certSANs is here and not inferred: the kube-apiserver cert must NAME the VIP or kubectl fails
  # TLS against it. Talos adds the endpoint host itself once cluster_endpoint points at the VIP —
  # but the SAN has to be in place BEFORE that cutover, not with it, or the cutover is the outage.
  #
  # ⚠ Verified additive on cp-01 in `--mode=try` (2026-09-20): the VIP appears as a SECOND address
  # (192.168.2.50/32) beside the platform's 192.168.2.51/24, which the nocloud datasource keeps
  # owning — machine.network was absent from the config until now and this creates it. The certSAN
  # half regenerates the apiserver cert and restarts the static pod: ~2 min of API downtime on a
  # single control plane, and none once there are three.
  #
  # ⚠ THAT VERIFICATION COULD NOT SEE THE METAL CASE, and wk-metal-02 paid for it (2026-09-20,
  # docs/controlplane-ha.md §CP6). Naming a link here moves it into Talos's
  # ConfigMachineConfiguration layer, and the DEFAULT-layer dhcp4 operator is emitted only for
  # physical links that NO layer configures ("interface is configured explicitly, don't run
  # default dhcp4" — siderolabs/talos network/operator_config.go). A nocloud VM never had that
  # default operator to lose (its address is ConfigPlatform, already "configured"), so cp-01 was
  # additive exactly as measured. A PXE metal node's ONLY address source IS that default operator
  # — `talos.platform=metal` supplies no network config and the disk-boot cmdline carries no `ip=`
  # — so the same patch silently took its address away, and the reinstalled node came up with no
  # IP, no DHCP-supplied resolver, and Talos's compiled-in 8.8.8.8 failing NTP on the console.
  # Hence TWO variants below: the address source a node relies on has to be RESTATED the moment
  # this patch claims its interface. Upstream's own VIP example carries `dhcp: true` for this
  # reason.
  cp_vip_interface = {
    deviceSelector = { physical = true }
    vip            = { ip = local.cp_vip }
  }

  # Platform-addressed control planes (the nocloud VMs — cp-01, cp-02). No `dhcp`: their address
  # comes from the Proxmox datasource, and asking dnsmasq for one would add a SECOND, dynamic
  # address on eth0 — the VM MACs have no reservation, so a lease would come from the .100–.245
  # pool (opnsense/dnsmasq-dhcp.py) and the node address would be a coin flip.
  cp_vip_patch = yamlencode({
    machine = {
      network = {
        interfaces = [local.cp_vip_interface]
      }
    }
    cluster = {
      apiServer = { certSANs = [local.cp_vip] }
    }
  })

  # DHCP-addressed control planes (the PXE metal boxes — metal.tf). Identical but for `dhcp: true`,
  # which restates the default operator this patch would otherwise suppress. Their addresses are
  # dnsmasq reservations, so the lease is the declared one (wk-metal-02 → .183).
  cp_vip_patch_dhcp = yamlencode({
    machine = {
      network = {
        interfaces = [merge(local.cp_vip_interface, { dhcp = true })]
      }
    }
    cluster = {
      apiServer = { certSANs = [local.cp_vip] }
    }
  })
}

# The cluster PKI — every CA, and the client certs derived from it. Created once at bootstrap
# (2026-05-29) and never since.
#
# ⚠⚠ `talos_version` here is FROZEN at the value the bundle was generated with, and must NOT
# follow var.talos_version_controlplane. The provider treats it as RequiresReplaceIfConfigured,
# and this resource's replacement is not a version bump — it is a NEW cluster PKI: every CA and
# every client cert goes `(known after apply)`, and applying it would leave the live machines
# trusting certificates nothing holds. It read `var.talos_version_controlplane` until 2026-09-21,
# which meant the routine act of bumping the control-plane version to a patch release planned a
# full PKI regeneration as a side effect — found while trying to move the CPs off the
# page_table_check kernel (FU-263; the same shape ADR-136 froze `sa_issuer` for).
#
# The string affects the FORMAT of the generated secrets bundle, not the version any node runs —
# nodes take their version from data.talos_machine_configuration.node / the install image. It
# therefore only ever wants changing at a deliberate PKI rotation, which is a rebuild-class act:
# drop the lifecycle block, in its own window, knowing every node needs the new config.
resource "talos_machine_secrets" "this" {
  talos_version = "v1.13.2"

  lifecycle {
    prevent_destroy = true
  }
}

# The machine-config CONTRACT every node's config is rendered against — the VMs here, metal in
# metal.tf. Deliberately NOT the install version (var.talos_version_controlplane/_worker and the
# per-node `talos_version` canary override): those move the installer image and the node's
# declared version, and a version bump must stay exactly that. Until 2026-09-22 the data sources
# read the ROLE version, so bumping a role to a new MINOR would have re-rendered every node of
# that role against the new minor's contract in the same apply — its new defaults included, which
# is where FU-033 (b)'s `SecurityProfileConfig.workloadIsolation` would come from (longhorn.tf
# header). A newer Talos runs an older contract by design.
#
# Same shape as the `talos_machine_secrets` "v1.13.2" pin above: moving this is a deliberate act
# with its own PR and plan (every node's config re-renders — read the diff; the no_reboot apply
# refuses any part that would need a reboot), taken only once EVERY node runs at least this version.
locals {
  talos_config_contract = "v1.13.10"
}

data "talos_machine_configuration" "node" {
  for_each = var.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.role
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = trimprefix(var.kubernetes_version, "v")
  talos_version      = local.talos_config_contract # the contract, NOT the install version (above)

  # hostname comes from the Proxmox nocloud datasource (the VM name); setting it
  # here too makes Talos reject the config as a conflict.
  config_patches = concat(
    [yamlencode({
      machine = {
        install = {
          disk = local.vm_install_disk
          # FU-253: the VMs used to declare NOTHING here, so the provider's bundled default
          # (`ghcr.io/siderolabs/installer:v1.13.0`) landed on all five — the GENERIC image, which
          # reinstalls a nocloud VM as `platform: metal` and ghosts it (ADR-014, probed on wk-03).
          # Harmless while nothing read it; a loaded gun for anything that upgrades a node to its
          # DECLARED image, which is exactly what an upgrade controller does. Now it names the same
          # factory URL `node_install_targets` hands `node-maintenance.sh upgrade`, so declared ==
          # what the verb passes == what the node installs. Metal has done this since birth
          # (metal.tf); with the disk image demoted to a seed (proxmox.tf), this is where a VM's
          # running substrate is declared.
          image = data.talos_image_factory_urls.vm[local.vm_image_key[each.key]].urls.installer
        }
        # (Stateful services moved to Longhorn — the old /var/mnt/* hostPath kubelet
        # extraMounts were removed. Longhorn uses /var/lib/longhorn, not an extraMount.)
      }
    })],
    [local.registry_mirrors_patch],
    # Extra Longhorn disks on a VM node — the same patch metal.tf renders from machines.yaml, and
    # for the same reasons (mount under /var/lib/longhorn because longhorn-manager host-mounts only
    # that path; the entry's `name` is ALSO its node.longhorn.io disk key, so never rename one that
    # holds replicas). Empty for every VM but wk-04, whose disk is a PASSED-THROUGH physical NVMe
    # (variables.tf `hostpci_mapping`) rather than pool storage — which is the only reason a VM is
    # allowed to carry one at all. ⚠ Talos refuses a device that already has a partition table;
    # `talosctl wipe disk <dev>` first.
    length(each.value.longhorn_disks) > 0 ? [yamlencode({
      machine = {
        disks = [for d in each.value.longhorn_disks : {
          device     = d.device
          partitions = [{ mountpoint = "/var/lib/longhorn/${d.name}" }]
        }]
      }
    })] : [],
    # FU-139: the VM tier gets kubelet reservations too. FU-112(b) fixed only the kata metal nodes
    # ("desktops/VMs use different math and aren't urgent"); wk-02 then proved the VMs need them —
    # 2026-08-04 18:34:28 Talos's OOMController SIGKILLed the Longhorn instance-manager cgroup,
    # which killed CSI → iSCSI `conn error 1020` → EXT4 I/O errors → a 5-pod SandboxChanged storm
    # (homelab#101, #63, #65). The OOMAction record is the evidence and it shapes these numbers:
    #   * it fired on PSI, not exhaustion — `memory_full_avg10: 6.04` with ~9.3G of 12G in use.
    #     So `node_memory_MemAvailable` looking flat at 5.73Gi proves nothing; pressure ≠ free RAM.
    #   * the VICTIM was Longhorn's instance-manager (Burstable, 42 pids, the biggest cgroup).
    #     That is the worst possible victim on a storage VM: every volume on the node goes with it.
    # A kubelet reservation does not tune PSI, but it changes WHO acts first: with allocatable cut
    # and a HARD eviction threshold, the kubelet evicts an ordinary Burstable pod before the
    # OOMController starts scoring cgroups — and Longhorn/Cilium are system-node-critical, hence
    # eviction-exempt. VM math vs the kata nodes' (50m/512Mi + 256Mi + 512Mi): the same shape with
    # more kubeReserved and a higher wall, because these VMs host the Longhorn DATA plane, whose
    # per-attach engine/replica processes arrive in chunks rather than smoothly.
    # Maps are written in FULL: Talos kubelet.extraConfig can REPLACE a nested map, so the cpu/pid/
    # ephemeral + disk-pressure defaults are restated or they are lost (verify via .../proxy/configz).
    # Applied in-place — kubelet restart, no reboot; it does not evict what is already running.
    [yamlencode({
      machine = {
        kubelet = {
          extraConfig = {
            systemReserved = {
              cpu                 = "100m"
              memory              = "512Mi"
              "ephemeral-storage" = "512Mi"
              pid                 = "100"
            }
            kubeReserved = {
              memory = "512Mi"
            }
            evictionHard = {
              "memory.available"   = "768Mi"
              "imagefs.available"  = "15%"
              "imagefs.inodesFree" = "5%"
              "nodefs.available"   = "10%"
              "nodefs.inodesFree"  = "5%"
            }
            # The metal nodes' image-GC floor (metal.tf) for the VMs too (operator, 2026-09-14):
            # the kubelet default (85/80 %) let wk-02's image store grow to 89 GB of 299 images on
            # its 236 G /var — 60/50 % keeps the store bounded on any disk size, and on wk-03 (the
            # dind tier, 40 G) it is the belt the #1657/#1659 evictions were missing.
            imageGCHighThresholdPercent = 60
            imageGCLowThresholdPercent  = 50
          }
        }
      }
    })],
    # AVX2 node label (boot-from-git, replaces the imperative `kubectl label`). Talos applies
    # machine.nodeLabels to the kubelet registration live — safe on a running node, no reboot.
    contains(local.avx2_nodes, each.key) ? [yamlencode({
      machine = { nodeLabels = { "homelab.io/cpu-avx2" = "true" } }
    })] : [],
    # Ephemeral node LABEL (2026-08-18, wk-03): the ARC runner scale set selects on
    # homelab.io/ephemeral=true — which until now existed only as an IMPERATIVE kubectl label on
    # wk-metal-01/-02 (the taint is tofu'd in metal.tf, the label never was). Same avx2 pattern:
    # boot-from-git, applied live. VM path only, deliberately — labeling wk-metal-03/-04 here
    # would silently widen the runner pool onto the kata-headroom nodes, a policy change with its
    # own decision (their taint stands regardless via metal.tf).
    contains(local.ephemeral_nodes, each.key) ? [yamlencode({
      machine = { nodeLabels = { "homelab.io/ephemeral" = "true" } }
    })] : [],
    # FU-033 (a): Talos 1.14 mounts EPHEMERAL (/var) noexec, which kills Longhorn v1's
    # instance-manager (longhorn.tf). Carried by every VM DECLARED at ≥ v1.14, so it lands (in the
    # human apply) before the reconciler's upgrade — the verb refuses the upgrade without it.
    tonumber(split(".", trimprefix(local.node_talos_version[each.key], "v"))[1]) >= 14 ? [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "VolumeConfig"
      name       = "EPHEMERAL"
      mount      = { secure = false }
    })] : [],
    # The endpoint VIP — control planes only (see local.cp_vip_patch).
    each.value.role == "controlplane" ? [local.cp_vip_patch] : [],
    # The patches EVERY control plane carries, VM and metal alike (local.cp_common_patches).
    each.value.role == "controlplane" ? local.cp_common_patches : []
  )
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.controlplane_ips
  nodes                = sort(values(local.node_ip))
}

resource "talos_machine_configuration_apply" "node" {
  for_each = var.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  node                        = local.node_ip[each.key]
  endpoint                    = local.node_ip[each.key]
  # no_reboot (docs/management-box.md §MB4 layer 4): Talos applies the config only if every change
  # can take effect live (its CanApplyImmediate: install, network, kubelet, nodeLabels/Taints,
  # registries, sysctls, …); anything else is refused with InvalidArgument, which the provider does
  # not retry — so a reboot-needing change FAILS the apply and goes to a window, instead of the
  # provider default "auto" rebooting the node mid-apply. Caveat: Talos's check reads only the
  # v1alpha1 document — a change to another document (VolumeConfig, HostnameConfig, …) is never
  # refused here; when it takes effect is that document's own semantics (the volume and hostname
  # ones are INSTALL-TIME, annotated where declared).
  apply_mode = "no_reboot"

  depends_on = [
    proxmox_virtual_environment_vm.node,
    proxmox_virtual_environment_vm.nx02_node,
  ]
}

resource "talos_machine_bootstrap" "this" {
  node                 = local.first_cp_ip
  endpoint             = local.first_cp_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "this" {
  node                 = local.first_cp_ip
  endpoint             = local.first_cp_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_bootstrap.this]
}

# ⚠ This resource CAPTURES the kubeconfig at create time and never refreshes it. Nothing in its
# arguments mentions local.cluster_endpoint, so moving the endpoint leaves the rendered
# kubeconfig — and therefore `devbox run kubeconfig`, the jail's kubectl and the management box —
# dialling the OLD address while `plan` reports `No changes`. That is not hypothetical: the
# ADR-133 VIP cutover reached all 13 machine configs on 2026-09-21 and this output still served
# https://192.168.2.51:6443 (FU-259).
#
# The check below makes that divergence VISIBLE on every plan instead of silent. It is a warning,
# not a failure, on purpose: the condition is fixed by an apply that this very root cannot plan
# unscoped (the kubernetes/helm providers are configured FROM this resource, so a replacement
# puts their host/certs in `(known after apply)` and the whole plan errors out), so blocking
# would wedge the apply loop on a condition it cannot resolve. Recovery is the scoped pair,
# followed by a re-render of the client configs and a full apply to restamp the baseline:
#
#   devbox run mgmt-tf -- apply -replace=talos_cluster_kubeconfig.this -target=talos_cluster_kubeconfig.this
#   devbox run kubeconfig
#
# `replace_triggered_by` was considered instead and rejected for the same reason: it would turn
# every future endpoint move into a plan the root cannot apply at all, rather than a warning
# with a documented two-step.
check "kubeconfig_endpoint_current" {
  assert {
    condition     = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host == local.cluster_endpoint
    error_message = "The kubeconfig in state was captured against a different API endpoint than local.cluster_endpoint declares; clients rendered from it dial the old address. Recovery: apply -replace=talos_cluster_kubeconfig.this -target=talos_cluster_kubeconfig.this, then `devbox run kubeconfig` (FU-259, docs/controlplane-ha.md)."
  }
}
