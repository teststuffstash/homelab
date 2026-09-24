# ---- Proxmox (infra layer) ------------------------------------------------
variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, incl. scheme and port."
  type        = string
  default     = "https://192.168.2.3:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token 'user@realm!tokenid=uuid'. Set via TF_VAR_proxmox_api_token or SOPS — never commit."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (default Proxmox cert is self-signed)."
  type        = bool
  default     = true
}

variable "proxmox_ssh_private_key_file" {
  description = "Path to the SSH private key bpg uses to reach the Proxmox node (disk import). Lives outside the repo."
  type        = string
  default     = "/home/node/.claude/homelab-pve-ssh/id_ed25519"
}

variable "proxmox_node" {
  description = "Proxmox node name."
  type        = string
  default     = "pve"
}

variable "datastore_vms" {
  description = "Datastore for VM disks."
  type        = string
  default     = "local-lvm"
}

variable "datastore_images" {
  description = "Datastore that holds downloaded images/ISOs."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Proxmox bridge to attach VMs to."
  type        = string
  default     = "vmbr0"
}

# ---- nx-02, the second hypervisor (providers.tf alias `nx02`, tofu/nx02.tf) ------------------
variable "nx02_endpoint" {
  description = "Proxmox API endpoint of nx-02 (NX-6035-G5 node 2)."
  type        = string
  default     = "https://192.168.2.59:8006/"
}

variable "nx02_api_token" {
  description = "nx-02 Proxmox API token 'user@realm!tokenid=uuid'. KeePass `nx-02-api-token-tofu`; via TF_VAR_nx02_api_token / main.tfvars — never commit."
  type        = string
  sensitive   = true
}

variable "nx02_node" {
  description = "Proxmox node name on nx-02."
  type        = string
  default     = "nx-02"
}

variable "nx02_datastore_vms" {
  description = "Datastore for VM disks on nx-02 — the Micron NVMe thin pool. Named for the pool, not the device: the VG was renamed off `nvme1n1-thin` on 2026-09-15 because /dev/nvmeXn1 shifts when a drive is added or moved."
  type        = string
  default     = "nvme-thin"
}

# ---- Cluster (provider-agnostic layer) ------------------------------------
variable "cluster_name" {
  description = "Kubernetes / Talos cluster name."
  type        = string
  default     = "homelab"
}

# Two Talos versions, by ROLE (operator, 2026-09-16): control planes move as one deliberate act
# (the three-CP program, ADR-133/FU-243), workers roll one node at a time — metal via
# `talosctl upgrade`, VMs via the image.tf recreate — so a rollout always shows a declared-vs-live
# gap for the nodes not yet done; that gap is the rollout's progress bar, not drift. The secrets
# bundle follows the control-plane version. First use: FU-246 (the page_table_check reboots —
# workers must be ≥ v1.13.4).
variable "talos_version_controlplane" {
  description = "Talos Linux version for control-plane nodes (CP machine configs, the plain nocloud image). NOT the secrets bundle — that is frozen at the version it was generated with, FU-263 (a)."
  type        = string
  default     = "v1.14.1"
}

variable "talos_version_worker" {
  description = "Talos Linux version for worker nodes (worker machine configs, metal installer images, the longhorn nocloud image)."
  type        = string
  default     = "v1.14.1"
}

variable "kubernetes_version" {
  description = "Kubernetes version to install."
  type        = string
  default     = "v1.36.1"
}

variable "cilium_version" {
  description = "Cilium chart/version (CNI)."
  type        = string
  default     = "1.19.1"
}

variable "kube_prometheus_stack_version" {
  description = "prometheus-community/kube-prometheus-stack chart version (Prometheus + Grafana + Alertmanager + operator)."
  type        = string
  default     = "86.1.0"
}

variable "ha_prometheus_token" {
  description = "Home Assistant long-lived access token for /api/prometheus scraping. Set via TF_VAR_ha_prometheus_token — never commit. Create in HA: Profile → Security → Long-lived access tokens."
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Set via TF_VAR_grafana_admin_password — never commit."
  type        = string
  sensitive   = true
}

variable "gateway" {
  description = "Default gateway for the node static IPs."
  type        = string
  default     = "192.168.2.1"
}

variable "nameservers" {
  description = "DNS servers for the nodes (sorted)."
  type        = list(string)
  default     = ["192.168.2.1"]
}

# Node inventory. Map key = node/VM name (for_each over a map is deterministic).
# Keep entries sorted by key; IPs must be free / OPNsense-reserved addresses.
variable "nodes" {
  description = "Talos node inventory keyed by name."
  type = map(object({
    role      = string # "controlplane" | "worker"
    vm_id     = number
    ip_cidr   = string # e.g. "192.168.2.51/24"
    cores     = number
    memory_mb = number
    disk_gb   = number
    # Boot the iscsi/util-linux image (image.tf `longhorn` schematic). The flag means "this VM
    # TOUCHES Longhorn volumes", NOT "this VM serves replicas" — mounting a volume needs
    # iscsiadm + nsenter on the node just as much as hosting one does. See the wk-01 note below.
    longhorn = optional(bool, false)
    # Attach a serial console (`serial0: socket`, the ci-runner.tf shape). Talos already boots
    # with `console=ttyS0`, so the kernel's last words on a panic land in the host-side log the
    # pve-serial-log Ansible role tails (/var/log/qemu-serial/<vmid>.log) instead of dying with
    # the ring buffer. Takes effect at the next full stop/start of the VM (a guest-initiated
    # reboot keeps the qemu process, so pending hardware never applies that way). #882.
    serial = optional(bool, false)
    # Which hypervisor runs this VM: "pve" (tofu/proxmox.tf, the default provider) or "nx-02"
    # (tofu/nx02.tf, the `nx02` provider alias). A provider cannot be chosen per for_each key,
    # so each value gets its own resource block; the cluster layer (talos.tf) spans both and
    # never learns which is which. Changing this on a live node REPLACES the VM.
    hypervisor = optional(string, "pve")
    # Per-node Talos version override — the CANARY lever (FU-033, 2026-09-22): the node's installer
    # image + declared version (node_install_targets, which the box reconciler syncs to) move ahead
    # of its role's version, one node at a time. Unset = the role version. It does NOT move the
    # machine-config contract (talos.tf `local.talos_config_contract`, pinned apart from every
    # install version): a newer Talos runs an older contract by design, and a 1.14 contract is where
    # FU-033 (b)'s workloadIsolation default lives. Nor does it move the seed disk images (image.tf,
    # FU-275): those follow the role version only.
    talos_version = optional(string)
    # PCIe passthrough of one host device to this VM (bpg `hostpci0`), named by its **cluster
    # mapping**, never a raw PCI address. Used for an NVMe that must
    # be REAL inside the guest rather than a slice of the hypervisor's thin pool — the pool is the
    # third sum the storage ledger tracks, and the 2026-08-24 incident (pve pool at 100%, wk-01
    # frozen, Garage's meta LMDB back with empty tables) is why Longhorn capacity does not live on
    # it. Passthrough also keeps the guest's `/dev/disk/by-id/nvme-eui.*` name identical to the
    # host's, so machines.yaml-style by-id pinning works, and leaves SMART readable to the
    # in-cluster smartctl-exporter (FU-284) — neither is true of a thin-pool LV or a raw-block
    # `-scsiN` passthrough.
    # ⚠ WHY A MAPPING NAME. Proxmox refuses a raw BDF from anyone but `root@pam` — an apply with
    # `id = "0000:82:00.0"` returned HTTP 500 *"only root can set 'hostpci0' config for non-mapped
    # devices"* (2026-09-24). A non-root identity may attach only a mapping someone else declared,
    # which is exactly the split we want: `TerraformProv` gained `Mapping.Audit` + `Mapping.Use`
    # and deliberately **NOT `Mapping.Modify`** (operator, 2026-09-24), so the automation identity
    # can attach declared hardware but cannot invent a mapping exposing any host device to any
    # guest. Creating the mapping is a Phase-0 bootstrap step (tofu/README.md) beside the role,
    # the user and the SSH seed.
    # ⚠ Requires VT-d/IOMMU on the host and the device ALONE in its IOMMU group (nx-02: group 15
    # holds only 0000:82:00.0, verified 2026-09-24). Applying it needs a full VM stop/start —
    # hostpci is not hot-pluggable — so it rides a node-maintenance window. It also pins the VM to
    # that host, which is free here: nothing live-migrates in this fleet.
    hostpci_mapping = optional(string)
    # Extra Longhorn disks for a VM node, same shape and same rules as machines.yaml's
    # `longhorn_disks` for metal (locals.tf `metal_nodes`): [{device, name, tags}], mounted at
    # /var/lib/longhorn/<name> because longhorn-manager host-mounts only that path, and <name> is
    # ALSO the node.longhorn.io disk key — renaming one orphans its replicas. Rendered into
    # machine.disks by talos.tf; registered + tagged by scripts/longhorn-tag-disks.sh.
    # ⚠ This directive PARTITIONS the device, so name it by /dev/disk/by-id/*, never /dev/nvmeXn1.
    # Until 2026-09-24 only metal nodes could carry one; wk-04 is the first VM to, and only because
    # its disk is a PASSED-THROUGH physical NVMe (hostpci_mapping above), not pool storage.
    longhorn_disks = optional(list(object({
      device = string
      name   = string
      tags   = list(string)
    })), [])
  }))
  default = {
    # memory 8→12 GiB (2026-09-14, #1687): kube-apiserver alone holds ~4.1 GiB (10 nodes, the
    # agent-platform CRDs + list-watches), all pods ~4.9 GiB of 5.98 allocatable — ~1.1 GiB above
    # the 768Mi allocatable eviction line, so any blip evicts the DaemonSets (22 evictions in
    # 100 s at 11:17Z). Funded by wk-03's 16→8 GiB the same day; host at 17.6 GiB available.
    cp-01 = { role = "controlplane", vm_id = 8101, ip_cidr = "192.168.2.51/24", cores = 4, memory_mb = 12288, disk_gb = 40 }
    # wk-01 keeps longhorn=true although it is in NEITHER longhorn.tf zone map (no
    # create-default-disk label, no disk on its nodes.longhorn.io CR, no replica). That looks
    # stale and is not: wk-01 is the untainted general-purpose worker, so it is the busiest
    # volume CONSUMER in the cluster — 15 Longhorn volumes were attached with
    # currentNodeID=wk-01 (2026-08-11), more than any other node. Mounting needs the same
    # iscsi-tools + util-linux-tools as serving, so dropping the flag would repoint `file_id`
    # in proxmox.tf, REPLACE the VM, and bring it back unable to mount any Longhorn PVC.
    # Asked and settled twice now (#296 round 2, #302) — leave it alone.
    wk-01 = { role = "worker", vm_id = 8111, ip_cidr = "192.168.2.61/24", cores = 4, memory_mb = 16384, disk_gb = 80, longhorn = true }
    # disk 240→80 (2026-09-14, operator): the 240 G was the ADR-089 bulk pairing with wk-metal-01;
    # wk-02 left the bulk tier and then std altogether (PR#1683 — the pve box is compute-only, its
    # volumes are mounted, never served). XFS cannot shrink and Talos never re-partitions, so this
    # is a VM RECREATE (`mgmt-tf apply -replace=` on the VM AND its talos_machine_configuration_apply
    # — the apply resource has no attribute keyed on the VM, so it will not re-run on its own),
    # inside a node-maintenance window; 80 G = wk-01's size for the same workload class, image
    # store bounded by the 60/50 kubelet GC (PR#1681). Grow-only from here.
    wk-02 = { role = "worker", vm_id = 8112, ip_cidr = "192.168.2.62/24", cores = 4, memory_mb = 12288, disk_gb = 80, longhorn = true }
    # Ephemeral CI/runner tier VM (2026-08-18): 8 cores is deliberate CPU overprovision (host was
    # 20/28 vCPU allocated at load ~4; CI is burst work, throttling is safe) — memory is the
    # careful number (host had ~12Gi free; 8Gi leaves ~4Gi buffer). 2026-09-08: 8→16Gi + 8→12
    # cores for ARC burst capacity (a dind runner requests 2.5Gi; 8Gi fit ONE runner, 16Gi fits
    # ~5) — funded by ci-runner-01 16→12Gi, so the host's allocation grows +4Gi against ~9Gi
    # available + KSM (~10Gi shared); Talos guests have no virtio_balloon, so this is the
    # overcommit ceiling until the second hypervisor. Disk stays 40G: the thin pool is the
    # binding constraint (81% on 2026-09-08). No longhorn flag = plain
    # image, nothing stateful; removable via drain + destroy when the RAM is needed elsewhere.
    # longhorn=true added same day (#534): the longhorn-manager DS tolerates the ephemeral
    # taint (metal ephemeral nodes serve bulk replicas + kata scratch), so it lands here too and
    # crashlooped on the base image. The flag is PLUMBING (iscsi/util-linux in the image), not a
    # storage role — wk-03 gets no disk registration and serves nothing; the flip replaces the VM
    # (file_id change), which is fine: the node is cattle by design.
    # serial=true (2026-09-14): five silent self-reboots in a week with the qemu process untouched
    # (#882, NodeRebootingRepeatedly) — the serial console is the instrument that catches the panic.
    # Cause found 2026-09-16: the kernel page_table_check bug under ARC jobs, fixed by Talos ≥ v1.13.4
    # (docs/incidents/2026-09-16-page-table-check-reboots.md, FU-246) — not the pve overcommit.
    # 16Gi/12c → 8Gi/6c (2026-09-14, operator): the pve host sat at 0.5–1 GiB MemAvailable with
    # 64.5 GiB dedicated across five VMs (no balloon in Talos guests, KSM ~6 GiB), 30 vCPU on 28
    # threads; and wk-03's RAM was what packed ~4 concurrent dind runners onto its one 40 G thin
    # LV (#1659/#1657 disk-pressure wave). Half the box = ~2 runners; arc-runners.yaml maxRunners
    # follows (6 → 4, a direct master push — the file is pin-only-guarded). The reboot cause is NOT this (IO/memory PSI ≈ 0 before every boot) — that
    # is the serial console's job.
    # disk 40→80 (2026-09-14, operator): the dind tier's imagefs evictions (#1657/#1659) were a
    # 36 G /var under ~4 concurrent runners; 80 G with maxRunners 4 (≤2 here) + the 60/50 image
    # GC. Grow-only in place; Talos grows EPHEMERAL into it on the next reboot (a stop/start —
    # the VM's pending disk resize lands at qemu start, not at a guest reboot).
    wk-03 = { role = "worker", vm_id = 8113, ip_cidr = "192.168.2.63/24", cores = 6, memory_mb = 8192, disk_gb = 80, longhorn = true, serial = true }
    # The first VM on the SECOND hypervisor (nx-02, 2026-09-15) — the untainted batch-compute
    # worker the fleet-role table (ROADMAP §Hardware strategy) wants from Xeon-class boxes. 16 of
    # nx-02's 40 threads and 32 of its 64 GiB, deliberately half the box: the other half is the
    # headroom the three-CP move needs (a cp VM here later — ONE only: nx-01 and nx-02 share a
    # chassis, a backplane and 1+1 PSUs, so they are not independent failure domains).
    # longhorn = true is PLUMBING, not a storage role (the wk-01/wk-03 note above): an untainted
    # worker MOUNTS Longhorn PVCs, which needs iscsi-tools + util-linux-tools in the image.
    # It SERVES none — nx-02 is not in longhorn.tf's zone maps and gets no disk registration,
    # and the box is on a noise/idle trial (private hardware register R11) that may end with the
    # whole chassis leaving. serial stays false: the pve-serial-log Ansible role only tails pve.
    # wk-04 carries the WD SN530 that was fitted to nx-02 on 2026-09-24, by PCIe passthrough
    # (0000:82:00.0, alone in IOMMU group 15) rather than as a thin-pool LV — see `hostpci_mapping`.
    # It joins `bulk` and is the tier's capacity for FU-280's registry trial. The drive was raw
    # and unallocated when this landed (no PV, no holders); the `nvme-thin` pool is the OTHER
    # NVMe, the Micron 2200S at 0000:83:00.0, and is untouched by this.
    # ⚠ ZONE, the per-service call the 2026-09-23 deferral asked for: wk-04's zone is `nx-02` and
    # nx-01/nx-02 are one 2U twin (shared backplane + 1+1 PSUs), so two replicas inside the chassis
    # would not be two failure domains. It is safe here BY CONSTRUCTION, not by luck: `bulk`'s only
    # member in that chassis is this disk (nx-01 carries `fast` alone, PR#1956), so `longhorn-bulk`
    # can never place both replicas of a volume inside the twin. Re-ask this if a SECOND bulk disk
    # ever lands on an nx node — that is the moment the zone names must collapse.
    wk-04 = { role = "worker", vm_id = 8114, ip_cidr = "192.168.2.64/24", cores = 16, memory_mb = 32768, disk_gb = 80, longhorn = true, hypervisor = "nx-02",
      hostpci_mapping = "wk04-sn530",
      longhorn_disks  = [{ device = "/dev/disk/by-id/nvme-eui.e8238fa6bf530001001b448b49e4a8d0", name = "sn530", tags = ["bulk"] }]
    }
    # ADR-133's THIRD control plane, on the second hypervisor — one CP per chassis (pve, the X250,
    # the Nutanix twin), so no single box can take two of the three. Sized like cp-01 rather than
    # smaller: a CP's footprint is its own apiserver + etcd, and cp-01's 8→12 GiB bump (#1687) was
    # paid for exactly that. nx-02 had 26 GiB free of 62 when this landed, and the nvme-thin pool
    # 175 GiB of 244 — read the POOL, not the guest FS, before adding a disk here.
    # ⚠ The key must sort AFTER cp-01: local.first_cp_key is sort(keys(controlplane))[0], and it
    # picks the bootstrap/kubeconfig host — a key sorting first would silently move it.
    cp-02 = { role = "controlplane", vm_id = 8102, ip_cidr = "192.168.2.65/24", cores = 4, memory_mb = 12288, disk_gb = 40, hypervisor = "nx-02" }
  }

  validation {
    condition     = length([for n in var.nodes : n if n.role == "controlplane"]) >= 1
    error_message = "At least one controlplane node is required."
  }

  # A typo puts a node in NEITHER hypervisor map, so no VM resource is created for it — while
  # talos.tf still iterates every entry and blocks applying a machine config to an IP with nothing
  # behind it. Silent at plan time; a long hang at apply time. Fail at plan instead.
  validation {
    condition     = alltrue([for n in var.nodes : contains(["pve", "nx-02"], n.hypervisor)])
    error_message = "nodes[*].hypervisor must be \"pve\" (tofu/proxmox.tf) or \"nx-02\" (tofu/nx02.tf) — a value with no provider block creates no VM."
  }
}

# ---- ArgoCD + Infisical bootstrap (the GitOps seam, tofu/argocd.tf) --------
# These are Tier-0/1 bootstrap secrets sourced from the KeePass wallet, not the
# cluster (the cluster can't decrypt them for itself yet — Infisical+ESO is what
# closes that loop). Load them with:  source scripts/keepass-env.sh

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (argoproj.github.io/argo-helm)."
  type        = string
  default     = "9.5.21"
}

variable "argocd_apps_chart_version" {
  description = "argocd-apps Helm chart version (root app-of-apps)."
  type        = string
  default     = "2.0.5"
}

variable "argocd_repo_url" {
  description = "Git source ArgoCD reconciles from. GitHub during bootstrap; cut over to Forgejo later (FU-007)."
  type        = string
  default     = "https://github.com/teststuffstash/homelab.git"
}

variable "argocd_github_pat" {
  description = "Fine-grained GitHub PAT (read-only contents) so ArgoCD can pull the private homelab repo. From KeePass."
  type        = string
  sensitive   = true
}

variable "ghcr_read_packages_token" {
  description = "CLASSIC GitHub PAT with read:packages (fine-grained PATs can't grant it) so ArgoCD can pull the PRIVATE oracle-fleet-ingester OCI chart from ghcr. From KeePass (homelab-github-actions-runner-read-packages)."
  type        = string
  sensitive   = true
}

variable "infisical_encryption_key" {
  description = "Infisical ENCRYPTION_KEY (32 hex chars / 128-bit). From KeePass; never auto-generate in the cluster (would rotate under it)."
  type        = string
  sensitive   = true
}

variable "infisical_auth_secret" {
  description = "Infisical AUTH_SECRET (base64). From KeePass."
  type        = string
  sensitive   = true
}

variable "infisical_db_password" {
  description = "Password for the Infisical Postgres app role. tofu sets it on the CNPG cluster AND builds the connection string from it. From KeePass."
  type        = string
  sensitive   = true
}

variable "infisical_admin_email" {
  description = "Infisical super-admin email — created declaratively by the chart's autoBootstrap job. From KeePass."
  type        = string
  default     = "admin@teststuff.net"
}

variable "infisical_admin_password" {
  description = "Infisical super-admin password. From KeePass; consumed by the autoBootstrap job via the bootstrap-credentials secret."
  type        = string
  sensitive   = true
}
