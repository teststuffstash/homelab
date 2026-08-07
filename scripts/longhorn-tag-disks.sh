#!/usr/bin/env bash
# Longhorn disk tags + bulk-disk registration (ADR-089 storage tiers) — idempotent, like
# scripts/longhorn-register-optane.sh (disk config on a live Longhorn node isn't cleanly
# tofu-managed; the node CR is the authority).
#
# Tiers (tofu/longhorn.tf has the StorageClasses):
#   std  — the original three default disks (thinkcentre, hp-01, wk-02); the DEFAULT class
#          is fenced to these via persistence.defaultDiskSelector, so the scheduler can't
#          drop platform replicas onto the huge/wipe-prone bulk disks.
#   bulk — wk-metal-01's 500G MX500 + wk-metal-04's 500G SATA, registered here explicitly
#          (bulk-ONLY, generously reserved for the container/kata image store they share the
#          partition with). wk-02 left this tier on 2026-08-07 — see the note below.
#   fast — the ThinkCentre Optane pair (longhorn-register-optane.sh, untouched here).
#
# Safe to run any time; tags on disks with live replicas are metadata-only. Run BEFORE the
# tofu apply that enables defaultDiskSelector (untagged disks + selector = unschedulable PVCs).
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$(dirname "$0")/../tofu/kubeconfig}"
export KUBECONFIG
# kubectl via devbox profile when not on PATH (same trick as reviewer-session.sh)
command -v kubectl >/dev/null 2>&1 || {
  PATH="$(cd "$(dirname "$0")/.." && pwd)/.devbox/nix/profile/default/bin:$PATH"
  export PATH
}

# default_disk <node> → the disk key whose path is exactly /var/lib/longhorn
default_disk() {
  kubectl -n longhorn-system get nodes.longhorn.io "$1" -o json |
    python3 -c 'import sys,json; d=json.load(sys.stdin); print(next(k for k,v in d["spec"]["disks"].items() if v["path"]=="/var/lib/longhorn"))'
}

tag() { # node disk tags-json
  kubectl -n longhorn-system patch nodes.longhorn.io "$1" --type=merge \
    -p "{\"spec\":{\"disks\":{\"$2\":{\"tags\":$3}}}}" >/dev/null
  echo "  $1/$2 tags=$3"
}

for n in thinkcentre hp-01; do tag "$n" "$(default_disk "$n")" '["std"]'; done
# thinkcentre's reservation was auto-sized at 30% (35.3G) against a node whose container image
# store is 4.1G — it was fencing off a third of the disk from a tier that had 10.5G of scheduling
# room left, which is why nine std replicas sat PENDING with 67G physically free (2026-08-07).
# 15Gi still covers the images + the kubelet's 10% nodefs eviction floor (11.8G).
kubectl -n longhorn-system patch nodes.longhorn.io thinkcentre --type=merge \
  -p "{\"spec\":{\"disks\":{\"$(default_disk thinkcentre)\":{\"storageReserved\":16106127360}}}}" >/dev/null
echo "  thinkcentre storageReserved -> 15Gi"
# wk-02's tier, third and final revision — STD-ONLY since 2026-08-07. The history matters because
# each step was right about the problem in front of it:
#   dual std+bulk  → the only disk in two tiers. Longhorn places on the disk with the most room and
#                    wk-02 was the largest, so it won std placements AND absorbed bulk demand until
#                    it sat at 104% of its physical size while thinkcentre idled at 18% (#94).
#   bulk-only      → fixed that, at the cost of dropping std from three zones to two. The bill came
#                    due immediately: hp-01 reached 105% of allocatable, nine std replicas hung
#                    PENDING with nowhere to go, and a 2Gi transcripts PVC could not place (#98).
#   std-only (now) → wk-metal-04 joining bulk made wk-02 unnecessary THERE, and std is where the
#                    scarcity actually is. Its 221G is the third std zone; the nine strays that
#                    were already sitting here stopped being strays without moving a byte.
# ⚠ The trade this locks in: bulk is now two tainted, wipe-on-PXE compute nodes with no always-on
# member, so Garage's only two copies live there. Judged acceptable — and arguably an upgrade —
# because they are two INDEPENDENT physical disks in two independent boxes, where wk-02's disk is
# a thin volume on a single consumer NVMe shared with three other VMs, on a pool that reached
# 99.14% (2026-08-07). "Always-on" was never the same property as "durable".
tag wk-02 "$(default_disk wk-02)" '["std"]'
# wk-02 reservation. Auto-sized at 30% of the ORIGINAL 81G disk, then cut to 15Gi for the
# 150Gi bulk grant. 15Gi was a fiction: this node's container image store alone measured 38.6G
# (2026-08-07), i.e. the reservation did not even cover what was already on the disk, and Longhorn
# happily promised 298.5G on a 253.3G disk. 30Gi covers the kubelet's 10% nodefs eviction floor
# (25.3G) with margin; the image store's remainder is covered by physical headroom, not by the
# reservation (wk-02 lands at ~41% physical once the mirror + nix-cache/HA replicas leave).
# ⚠ This disk is ALSO an LVM thin volume on pve, whose pool ran to 99.14% — the byte sum here is
# not the only one that binds. See docs/storage-ledger.md §"A third sum: the hypervisor".
kubectl -n longhorn-system patch nodes.longhorn.io wk-02 --type=merge \
  -p "{\"spec\":{\"disks\":{\"$(default_disk wk-02)\":{\"storageReserved\":32212254720}}}}" >/dev/null
echo "  wk-02 storageReserved -> 30Gi"

# wk-metal-01: register the MX500 (system disk; 100Gi reserved for Talos + compute-tier
# scratch). The node CR exists even while longhorn-manager is still scheduling onto the
# tainted node — the disk mounts once the manager pod arrives (taintToleration, longhorn.tf).
# Skip when already registered: re-patching mid disk-sync trips the longhorn validator.
if kubectl -n longhorn-system get nodes.longhorn.io wk-metal-01 -o jsonpath='{.spec.disks.mx500.path}' 2>/dev/null | grep -q .; then
  echo "  wk-metal-01/mx500 already registered — skip"
else
kubectl -n longhorn-system patch nodes.longhorn.io wk-metal-01 --type=merge -p '{
  "spec": {
    "allowScheduling": true,
    "disks": {
      "mx500": {"path":"/var/lib/longhorn","allowScheduling":true,"evictionRequested":false,"storageReserved":107374182400,"tags":["bulk"],"diskType":"filesystem"}
    }
  }
}' >/dev/null
echo "  wk-metal-01/mx500 registered (bulk, 100Gi reserved)"
fi

# wk-metal-04: the THIRD bulk zone (2026-08-07). Same shape as wk-metal-01 — a tainted,
# wipe-on-PXE compute-tier node whose disk is bulk-ONLY — but the roomiest box in the fleet
# (477.6G partition, 16GB RAM) and it was carrying no Longhorn at all while the bulk tier was
# pinned to wk-02's 253G thin-provisioned VM disk.
#
# WHY 150Gi RESERVED (not the 100Gi wk-metal-01 got): on Talos, /var/lib/longhorn shares the
# EPHEMERAL partition with the containerd + kata image store, and these two genuinely compete —
# wk-metal-01's image store measured 137.5G on 2026-08-07, more than its whole reservation. The
# kubelet's own floor (evictionHard nodefs.available<10%, tofu/metal.tf) is another 47.8G here,
# and it evicts PODS, so losing that race takes rides down. 150Gi = ~100G image working set +
# the eviction floor. That leaves ~327G schedulable, which is what the per-ride 20Gi
# longhorn-scratch churn needs (worst observed: 9 concurrent = 180Gi, 2026-07-25).
if kubectl -n longhorn-system get nodes.longhorn.io wk-metal-04 -o jsonpath='{.spec.disks.sata500.path}' 2>/dev/null | grep -q .; then
  echo "  wk-metal-04/sata500 already registered — skip"
else
kubectl -n longhorn-system patch nodes.longhorn.io wk-metal-04 --type=merge -p '{
  "spec": {
    "allowScheduling": true,
    "disks": {
      "sata500": {"path":"/var/lib/longhorn","allowScheduling":true,"evictionRequested":false,"storageReserved":161061273600,"tags":["bulk"],"diskType":"filesystem"}
    }
  }
}' >/dev/null
echo "  wk-metal-04/sata500 registered (bulk, 150Gi reserved)"
fi

echo "disk status:"
kubectl -n longhorn-system get nodes.longhorn.io -o json | python3 -c '
import sys,json
for i in json.load(sys.stdin)["items"]:
    n=i["metadata"]["name"]
    for k,v in sorted(i.get("spec",{}).get("disks",{}).items()):
        st=i.get("status",{}).get("diskStatus",{}).get(k,{})
        mx=int(st.get("storageMaximum",0))//10**9
        print("  %s/%s: tags=%s sched=%s max=%dG" % (n, k, v.get("tags"), v.get("allowScheduling"), mx))'
