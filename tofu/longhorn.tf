# Longhorn distributed block storage. Replicated PVs across the always-on, real-disk
# nodes so stateful services no longer need hostPath + node-pinning (ROADMAP storage).
#
# Failure domains = physical boxes (topology zones): the two standalone desktops
# (thinkcentre, hp-01) are truly independent; wk-02 shares the single Proxmox NVMe.
# replica=2 + zone soft-anti-affinity => the two copies always land in different zones,
# with the third zone free to rebuild onto.
#
# Talos: needs the iscsi-tools + util-linux-tools extensions on every storage node
# (baked into the metal install image + the wk-02 'longhorn' VM image). The namespace
# must be PodSecurity=privileged (Talos enforces baseline; Longhorn's instance-managers
# are privileged), same as monitoring.tf.
#
# ⚠️ BEFORE upgrading Talos to v1.14+: 1.14 mounts EPHEMERAL (/var) `noexec`, which breaks
# Longhorn v1 — instance-manager exec's engine binaries the engine-image DaemonSet drops in
# /var/lib/longhorn/engine-binaries/ (=> "permission denied", storage dies on the post-upgrade
# reboot). We run the v1 data engine (v2-data-engine=false), so we're affected. Apply this
# patch (machine config, all nodes) FIRST, then upgrade:
#     apiVersion: v1alpha1
#     kind: VolumeConfig
#     name: EPHEMERAL
#     mount: { secure: false }   # re-enables exec (also drops nosuid/nodev on /var)
# (Longhorn v2 / SPDK runs the data plane in-process and is NOT affected — moot if we migrate.)
# Ref: Talos v1.14.0-alpha.1 release notes ("noexec on EPHEMERAL").
variable "longhorn_version" {
  description = "Longhorn Helm chart version."
  type        = string
  default     = "1.12.0"
}

# zone per physical box; wk-02's disk lives on the Proxmox host (one failure domain)
locals {
  longhorn_zones = {
    "wk-02"       = "proxmox"
    "thinkcentre" = "thinkcentre"
    "hp-01"       = "hp-01"
  }
}

# Label the storage nodes: Longhorn creates a default disk only on create-default-disk
# nodes (createDefaultDiskLabeledNodes below), and uses the zone label for anti-affinity.
resource "kubernetes_labels" "longhorn_storage" {
  for_each    = local.longhorn_zones
  api_version = "v1"
  kind        = "Node"
  metadata { name = each.key }
  labels = {
    "node.longhorn.io/create-default-disk" = "true"
    "topology.kubernetes.io/zone"          = each.value
  }
}

resource "kubernetes_namespace" "longhorn" {
  metadata {
    name = "longhorn-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
    }
  }
}

resource "helm_release" "longhorn" {
  name       = "longhorn"
  namespace  = kubernetes_namespace.longhorn.metadata[0].name
  repository = "https://charts.longhorn.io"
  chart      = "longhorn"
  version    = var.longhorn_version

  # Wait for the storage nodes to be labelled first so default disks land on them only.
  depends_on = [kubernetes_labels.longhorn_storage]

  values = [yamlencode({
    defaultSettings = {
      # storage only on labelled nodes; everything else stays compute-only
      createDefaultDiskLabeledNodes      = true
      defaultDataPath                    = "/var/lib/longhorn"
      defaultReplicaCount                = 2
      replicaSoftAntiAffinity            = true
      replicaZoneSoftAntiAffinity        = true # spread the 2 replicas across zones
      defaultDataLocality                = "best-effort"
      storageOverProvisioningPercentage  = 100
      orphanAutoDeletion                 = true
      # Let Longhorn read the Metrics Server (metrics-server.tf) so it populates the
      # longhorn_*_cpu/memory_* metrics behind the dashboard's "CPU & Memory" panels.
      kubernetesMetricsServerMetricsEnabled = true
    }
    persistence = {
      defaultClass             = true # make `longhorn` the default StorageClass
      defaultClassReplicaCount = 2
      defaultDataLocality      = "best-effort"
    }
    # single replica of the UI/manager bits is plenty for a homelab
    longhornUI = { replicas = 1 }
    # Prometheus ServiceMonitor for longhorn-manager (:9500 longhorn_* metrics: volume
    # robustness/state, node storage, replica counts). Scraped via the relaxed selector
    # (monitoring.tf); alerts on degraded/faulted volumes + low storage live there.
    metrics = { serviceMonitor = { enabled = true } }
  })]
}

# ---- Fast (Optane) tier --------------------------------------------------
# The ThinkCentre's two Intel Optane M10 16GB drives are mounted (Talos machine.disks,
# metal.tf) at /var/lib/longhorn/optane{0,1} and registered into Longhorn with the "fast"
# tag (scripts/longhorn-register-optane.sh — disk registration on an existing Longhorn node
# isn't cleanly tofu-managed, so it's an idempotent kubectl-patch script, not a resource).
#
# This StorageClass targets those disks. replica=1 + strict-local = lowest latency, no
# redundancy: pure scratch/cache. Both Optane live on ONE node (thinkcentre), so a
# longhorn-fast volume is bound to thinkcentre's availability and its consumer pod must be
# schedulable there. NOT the default class — opt in by setting storageClassName: longhorn-fast.
resource "kubernetes_storage_class" "longhorn_fast" {
  metadata { name = "longhorn-fast" }
  storage_provisioner    = "driver.longhorn.io"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "Immediate"
  parameters = {
    numberOfReplicas    = "1"
    diskSelector        = "fast"
    dataLocality        = "strict-local"
    staleReplicaTimeout = "30"
    fsType              = "ext4"
  }
  depends_on = [helm_release.longhorn]
}
