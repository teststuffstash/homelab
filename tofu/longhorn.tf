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
    }
    persistence = {
      defaultClass             = true # make `longhorn` the default StorageClass
      defaultClassReplicaCount = 2
      defaultDataLocality      = "best-effort"
    }
    # single replica of the UI/manager bits is plenty for a homelab
    longhornUI = { replicas = 1 }
  })]
}
