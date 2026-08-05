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
}

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "node" {
  for_each = var.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.role
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = trimprefix(var.kubernetes_version, "v")
  talos_version      = var.talos_version

  # hostname comes from the Proxmox nocloud datasource (the VM name); setting it
  # here too makes Talos reject the config as a conflict.
  config_patches = concat(
    [yamlencode({
      machine = {
        install = { disk = "/dev/sda" }
        # (Stateful services moved to Longhorn — the old /var/mnt/* hostPath kubelet
        # extraMounts were removed. Longhorn uses /var/lib/longhorn, not an extraMount.)
      }
    })],
    [local.registry_mirrors_patch],
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
          }
        }
      }
    })],
    # AVX2 node label (boot-from-git, replaces the imperative `kubectl label`). Talos applies
    # machine.nodeLabels to the kubelet registration live — safe on a running node, no reboot.
    contains(local.avx2_nodes, each.key) ? [yamlencode({
      machine = { nodeLabels = { "homelab.io/cpu-avx2" = "true" } }
    })] : [],
    # CNI is cluster-scoped → only patch control-plane nodes. "none" disables the
    # default Flannel so Cilium can be installed instead (see ROADMAP service-exposure).
    each.value.role == "controlplane" ? [
      yamlencode({
        cluster = {
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
          # Applied in-place: brief apiserver static-pod restart on the single control plane.
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
    ] : []
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

  depends_on = [proxmox_virtual_environment_vm.node]
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
