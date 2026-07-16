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
  # Bulk-tier zones (ADR-089): nodes that carry ONLY tagged bulk disks — deliberately NOT in
  # longhorn_zones (no create-default-disk label; the disk is registered explicitly on the
  # Longhorn node CR with tags, like the Optane pattern) so no untagged default disk appears.
  longhorn_bulk_zones = {
    "wk-metal-01" = "wk-metal-01" # 500G MX500; ephemeral/compute-tier node (tainted, wipe-on-PXE)
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

# Bulk nodes get ONLY the zone label (anti-affinity), never create-default-disk.
resource "kubernetes_labels" "longhorn_bulk_zone" {
  for_each    = local.longhorn_bulk_zones
  api_version = "v1"
  kind        = "Node"
  metadata { name = each.key }
  labels = {
    "topology.kubernetes.io/zone" = each.value
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
      createDefaultDiskLabeledNodes     = true
      defaultDataPath                   = "/var/lib/longhorn"
      defaultReplicaCount               = 2
      replicaSoftAntiAffinity           = true
      replicaZoneSoftAntiAffinity       = true # spread the 2 replicas across zones
      defaultDataLocality               = "best-effort"
      storageOverProvisioningPercentage = 100
      orphanAutoDeletion                = true
      # Let Longhorn read the Metrics Server (metrics-server.tf) so it populates the
      # longhorn_*_cpu/memory_* metrics behind the dashboard's "CPU & Memory" panels.
      kubernetesMetricsServerMetricsEnabled = true
      # ADR-089: system components (instance-manager, CSI, engine-image DS) must run on the
      # bulk-tier node wk-metal-01, which carries the compute-tier taint. Format is Longhorn's
      # own "key=value:Effect" string, not a k8s toleration object.
      # ⚠ DANGER-ZONE setting: Longhorn saves it but leaves status.applied=false until ALL
      # volumes are detached — it will not roll the engine-image/CSI DaemonSets on a live
      # system. Found 2026-07-13: replicas couldn't schedule on wk-metal-01 (no engine image
      # there); bridged by patching the engine-image DS toleration directly (kubectl patch ds
      # engine-image-ei-* — same toleration as below). Same bridge applied 2026-07-16 to the
      # longhorn-csi-plugin DS (FU-081: scratch PVCs must ATTACH on the kata laptops, and the
      # setting didn't propagate to the already-deployed CSI driver either — without it CSINode
      # carries no longhorn driver there and every attach fails). Longhorn applies this setting properly
      # on the next full-detach window (e.g. a Longhorn upgrade); the manual patch is
      # equivalent and idempotent until then.
      taintToleration = "homelab.io/ephemeral=true:NoSchedule"
    }
    persistence = {
      defaultClass             = true # make `longhorn` the default StorageClass
      defaultClassReplicaCount = 2
      defaultDataLocality      = "best-effort"
      # ADR-089 tier fence: the scheduler picks the EMPTIEST disk, so without this every new
      # standard replica would land on the (huge, wipe-prone, maybe-powered-off) bulk disks.
      # All original disks are tagged "std" (see the tagging note below) — the default class
      # only ever uses those.
      defaultDiskSelector = { enable = true, selector = "std" }
    }
    # single replica of the UI/manager bits is plenty for a homelab
    longhornUI = { replicas = 1 }
    # The user-deployed components need the same taint tolerance as defaultSettings.taintToleration
    # (that setting only covers system-MANAGED pods).
    longhornManager = { tolerations = [{ key = "homelab.io/ephemeral", operator = "Equal", value = "true", effect = "NoSchedule" }] }
    longhornDriver  = { tolerations = [{ key = "homelab.io/ephemeral", operator = "Equal", value = "true", effect = "NoSchedule" }] }
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

# ---- Bulk tier (ADR-089) ---------------------------------------------------
# Big, cheap, replicated capacity for large volumes (Garage S3 data, backups, datasets):
# wk-metal-01's 500G MX500 + wk-02's grown 240G virtual disk, both tagged "bulk"
# (wk-02's disk is dual-tagged "std"+"bulk"; the MX500 is bulk-ONLY so nothing
# platform-critical lives on the wipe-on-PXE laptop). replica=2 across those two zones —
# survives the laptop being reprovisioned or powered off. Like the Optane tier, disk
# registration/tagging is a node-CR patch, not tofu (see scripts/longhorn-tag-disks.sh):
#   wk-metal-01: explicit default-path disk, tags ["bulk"]
#   wk-02/thinkcentre/hp-01 default disks: tags ["std"] (+ "bulk" on wk-02)
# Consumers do NOT pick this class directly — stacks get capacity via their claim's
# storage caps (ResourceQuota per StorageClass, docs/agents/agentstack.md).
resource "kubernetes_storage_class" "longhorn_bulk" {
  metadata { name = "longhorn-bulk" }
  storage_provisioner    = "driver.longhorn.io"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "Immediate"
  parameters = {
    numberOfReplicas    = "2"
    diskSelector        = "bulk"
    dataLocality        = "disabled" # consumer pods can't run on the tainted bulk node anyway
    staleReplicaTimeout = "30"
    fsType              = "ext4"
  }
  depends_on = [helm_release.longhorn]
}

# ---- Scratch tier (FU-081, ADR-089 addendum) --------------------------------
# Throwaway per-ride volumes: the docker-mode agent pods' /var/lib/docker (agent-session.sh
# mounts one as an ephemeral BLOCK PVC — kata hotplugs it as virtio-blk, the one disk shape
# where overlay2 works inside the microVM). replica=1 on the bulk disks: scratch data on the
# roomy pool, and losing a replica just kills a ride that dies with it anyway. No fsType —
# consumers take volumeMode: Block and mkfs themselves.
resource "kubernetes_storage_class" "longhorn_scratch" {
  metadata { name = "longhorn-scratch" }
  storage_provisioner    = "driver.longhorn.io"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "Immediate"
  parameters = {
    numberOfReplicas    = "1"
    diskSelector        = "bulk"
    dataLocality        = "best-effort" # a ride on wk-metal-01 can land next to its replica
    staleReplicaTimeout = "30"
  }
  depends_on = [helm_release.longhorn]
}
