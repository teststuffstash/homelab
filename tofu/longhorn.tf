# Longhorn distributed block storage. Replicated PVs across the always-on, real-disk
# nodes so stateful services no longer need hostPath + node-pinning (ROADMAP storage).
#
# Failure domains = physical boxes (topology zones): the two standalone desktops
# (thinkcentre, hp-01) are truly independent; wk-02 shares the single Proxmox NVMe.
# replica=2 + zone soft-anti-affinity => the two copies always land in different zones,
# with the third zone free to rebuild onto.
#
# Talos: needs the iscsi-tools + util-linux-tools extensions on every node that MOUNTS a
# Longhorn volume, not merely on the ones that serve replicas — so the set is wider than the
# zone maps below (baked into both metal install images for every metal node, and into the
# 'longhorn' VM image for the wk-01/wk-02 VMs via var.nodes.*.longhorn). The namespace
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
    "wk-metal-04" = "wk-metal-04" # 500G SATA; same tier/shape (2026-08-07) — the third bulk zone.
    # Added because the bulk tier was a PAIR, and one half (wk-02) is a thin-provisioned VM disk on
    # a pve pool that had run to 99.14%. Two disks also meant every 2-replica bulk volume pinned one
    # copy to each, so wk-02 carried 298.5G of promises on 253.3G. A third zone gives the scheduler
    # somewhere to put a replica that is neither wk-02 nor the other laptop.
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

# Every other cluster member gets its zone label from machines.yaml (ADR-114): the two Longhorn
# resources above already own the label for their nodes (same values — machines.yaml is the
# source both agree with), this covers the rest so zone-spread rules can't treat unlabeled
# nodes as one implicit zone (cp-01/wk-01/wk-03 are all the SAME pve failure domain).
resource "kubernetes_labels" "node_zone" {
  for_each = {
    for n, z in local.machine_zones : n => z
    if !contains(keys(local.longhorn_zones), n) && !contains(keys(local.longhorn_bulk_zones), n) && n != "ci-runner-01"
  }
  api_version = "v1"
  kind        = "Node"
  metadata { name = each.key }
  labels = {
    "topology.kubernetes.io/zone" = each.value
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
      createDefaultDiskLabeledNodes = true
      defaultDataPath               = "/var/lib/longhorn"
      defaultReplicaCount           = 2
      # least-effort, not best-effort (2026-08-04, homelab#94): rebalance only when a node is
      # genuinely under-used, rather than continuously chasing an even spread — every move is a
      # replica REBUILD, real IO across disks that are already tight (homelab#56 was
      # NodeDiskIOSaturation on wk-02's disk). Standing belt, not the fix: it balances replica
      # COUNT, and #94's imbalance is bytes-and-tiers — thinkcentre already carries 19 replicas to
      # wk-02's 15. Enabled only now that the metering exists (argocd/resources/longhorn-alerts).
      replicaAutoBalance          = "least-effort"
      replicaSoftAntiAffinity     = true
      replicaZoneSoftAntiAffinity = true # spread the 2 replicas across zones
      defaultDataLocality         = "best-effort"
      # 100 → 200 (2026-08-04, homelab#94's SECOND firing). At 100 Longhorn may promise only
      # `max - reserved` per disk, and the std tier hit that wall with real free space sitting
      # unused: thinkcentre had 87.3G free but 0.7G of provisioning headroom, wk-02 99.8G free and
      # -0.1G headroom. A 2Gi transcripts volume could not place ANYWHERE, which stalled the
      # platform coordinator.
      # ⚠ This does NOT create disk. It trades a loud early failure (cannot schedule) for a late
      # destructive one (volume fills mid-write → read-only). It is only safe with metering, and
      # the Longhorn per-disk alert is still an unbuilt item in docs/storage-ledger.md — that is
      # now a prerequisite, not a nice-to-have.
      storageOverProvisioningPercentage = 200
      # Longhorn ≥1.9 renamed the boolean `orphanAutoDeletion` to this semicolon list
      # (`replica-data`, `instance`); the old key was silently dropped from the rendered
      # default-setting ConfigMap, so auto-deletion was OFF while tofu said `true`. Found
      # 2026-09-06: wk-metal-04's maintenance window left four orphaned replica dirs on its
      # bulk disk, and the 141G stale Garage copy blocked the Garage volume's own rebuild
      # onto that disk ("insufficient storage") until the orphans were deleted by hand
      # (scripts/node-maintenance.sh `up` now reports them). Grace period stays at the
      # 300 s default. Orphans on nodes that are down/unknown are never auto-deleted.
      orphanResourceAutoDeletion = "replica-data"
      # Let Longhorn read the Metrics Server (argocd/platform/metrics-server.yaml) so it populates the
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
    # FU-112(b): GUARANTEED (req==limit) so the OOMController evicts the ~5Gi tenant ride, not
    # Longhorn's control/CSI plane (homelab#66/#65). BestEffort longhorn-manager/csi died first in the
    # #48 kata-ride OOM → block-device attach broke (FU-116a). Limits ~2× observed peaks (manager
    # ~352Mi, csi small). ⚠ VERIFY post-apply the pods actually gained the resources — if the chart
    # ignores these keys, instance-manager/engine-image also stay BestEffort (Longhorn-managed; a
    # residual needing a Longhorn setting/patch — see FU-116).
    longhornManager = { tolerations = [{ key = "homelab.io/ephemeral", operator = "Equal", value = "true", effect = "NoSchedule" }], resources = { requests = { cpu = "150m", memory = "512Mi" }, limits = { cpu = "150m", memory = "512Mi" } } }
    longhornDriver  = { tolerations = [{ key = "homelab.io/ephemeral", operator = "Equal", value = "true", effect = "NoSchedule" }], resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "100m", memory = "256Mi" } } }
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
# ---- Single-replica standard tier (homelab#94) ------------------------------
# For volumes whose durability already lives somewhere else — the coordinator transcript stores
# are synced to Garage by transcripts-sync, so the second replica buys re-attach convenience, not
# safety. It costs more than it looks: a 2-replica volume needs TWO schedulable std disks, and on
# 2026-08-04 there was exactly one (hp-01 under the 25% minimal-available floor, wk-02 at the
# storageOverProvisioningPercentage=100 ceiling) — so the janitor pod hung 40min on a volume that
# could not place. Same std fence as the default class, half the disks required.
# FU-132 migrates the existing coordinator-transcripts PVCs onto this (storageClassName is
# immutable — it needs a delete+recreate, and the live volumes are patched to 1 replica already).
resource "kubernetes_storage_class" "longhorn_single" {
  metadata { name = "longhorn-single" }
  storage_provisioner    = "driver.longhorn.io"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "Immediate"
  parameters = {
    numberOfReplicas    = "1"
    diskSelector        = "std"
    dataLocality        = "best-effort"
    staleReplicaTimeout = "30"
  }
  depends_on = [helm_release.longhorn]
}

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
