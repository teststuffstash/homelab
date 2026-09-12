#!/usr/bin/env bash
# Longhorn disk tags + bulk-disk registration (ADR-089 storage tiers) — idempotent, like
# scripts/longhorn-register-optane.sh (disk config on a live Longhorn node isn't cleanly
# tofu-managed; the node CR is the authority).
#
# Tiers (tofu/longhorn.tf has the StorageClasses):
#   std  — the three original default disks (thinkcentre, hp-01, wk-02) + hp-01's second SATA
#          (`hg5d`, 2026-08-25) + **m70s's default disk (2026-09-12**, once the Garage zone moved
#          off it onto the dedicated PM961 — see its block below). wk-02's is still TAGGED std but
#          `allowScheduling=false` since 2026-09-12: it is a thin volume on the pve pool and must
#          not take NEW replicas. The DEFAULT class is fenced to std via
#          persistence.defaultDiskSelector, so the scheduler can't drop platform replicas onto the
#          huge/wipe-prone bulk disks.
#   bulk — wk-metal-01's 500G MX500 + wk-metal-04's 500G SATA, registered here explicitly
#          (bulk-ONLY, generously reserved for the container/kata image store they share the
#          partition with). wk-02 left this tier on 2026-08-07 — see the note below.
#   fast — the ThinkCentre Optane pair (longhorn-register-optane.sh, untouched here).
#
# hp-01 carries a SECOND std disk since 2026-08-25 (`hg5d`, a 128G Toshiba HG5d) — this node was
# the ledger's "the one place where the honest answer is buy a disk" (104% of allocatable, under
# Longhorn's 25% floor). Talos mounts it at /var/lib/longhorn/hg5d from machines.yaml's
# `longhorn_disks`; this script is what makes Longhorn aware of it.
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

# m70s's DEFAULT disk joins std, 2026-09-12 — the fleet direction's "Micron → std". It became a
# real std candidate the moment garage-1's meta+data rotated onto the dedicated PM961 (below):
# 474.6G with 416G free, DRAM-cached, and on a box that is NOT the pve thin pool. Before the
# rotation this disk held the zone's 180G and tagging it would have put platform replicas on the
# Garage spindle — the 2026-09-01 collision, by choice instead of by accident.
tag m70s "$(default_disk m70s)" '["std"]'

# hp-01's second std disk. Skipped when already registered — re-patching mid disk-sync trips the
# longhorn validator (same guard as wk-metal-01/mx500 below). storageReserved is 0 on purpose:
# unlike the default disks this one holds nothing but Longhorn data (no container image store),
# and the 25% minimal-available floor still applies globally.
if kubectl -n longhorn-system get nodes.longhorn.io hp-01 -o jsonpath='{.spec.disks.hg5d.path}' 2>/dev/null | grep -q .; then
  echo "  hp-01/hg5d already registered — skip"
else
  kubectl -n longhorn-system patch nodes.longhorn.io hp-01 --type=merge -p '{
    "spec": {
      "disks": {
        "hg5d": {"path":"/var/lib/longhorn/hg5d","allowScheduling":true,"evictionRequested":false,"storageReserved":0,"tags":["std"],"diskType":"filesystem"}
      }
    }
  }' >/dev/null
  echo "  hp-01/hg5d registered (std)"
fi
# hp-01's THIRD disk — the Intel 7600p NVMe (2026-09-12), registered `std` like hg5d. Talos mounts
# it at /var/lib/longhorn/intel7600p from machines.yaml's `longhorn_disks`. storageReserved 0 for
# the same reason as hg5d: it holds nothing but Longhorn data (no Talos, no container image store).
# Why it exists: thinkcentre leaves cluster duty, so std drops to two schedulable nodes and hp-01's
# 127G hg5d cannot hold its mandatory copy of a ~141G tier. Anti-affinity is SOFT here, so without
# the capacity Longhorn silently co-locates both replicas of a volume on m70s.
# Skip when already registered: re-patching mid disk-sync trips the longhorn validator.
if kubectl -n longhorn-system get nodes.longhorn.io hp-01 -o jsonpath='{.spec.disks.intel7600p.path}' 2>/dev/null | grep -q .; then
  echo "  hp-01/intel7600p already registered — skip"
else
  kubectl -n longhorn-system patch nodes.longhorn.io hp-01 --type=merge -p '{
    "spec": {
      "disks": {
        "intel7600p": {"path":"/var/lib/longhorn/intel7600p","allowScheduling":true,"evictionRequested":false,"storageReserved":0,"tags":["std"],"diskType":"filesystem"}
      }
    }
  }' >/dev/null
  echo "  hp-01/intel7600p registered (std)"
fi

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
# ⚠ NO NEW std REPLICAS ON THE POOL (operator direction, 2026-09-12). wk-02's std disk is an LVM
# thin volume on pve, the pool that has filled to 100% four times (FU-093), so once m70s's Micron
# joined std above there is no reason for the scheduler to keep choosing a pooled disk — Longhorn
# places on the disk with the most available space, and wk-02 was winning by being large.
# allowScheduling=false is NOT an eviction: its 27 existing replicas stay, keep serving, and leave
# organically — a rebuild or a PVC re-cut now lands on m70s/hp-01/thinkcentre instead. std keeps
# three schedulable nodes (m70s, hp-01, thinkcentre), i.e. r=2 plus a rebuild target.
# thinkcentre therefore STAYS in the tier for now (operator: retire it only when the replacement
# box arrives, so the pool can be freed in the same move) — one field flips this back.
kubectl -n longhorn-system patch nodes.longhorn.io wk-02 --type=merge \
  -p "{\"spec\":{\"disks\":{\"$(default_disk wk-02)\":{\"allowScheduling\":false}}}}" >/dev/null
echo "  wk-02 allowScheduling -> false (no new std replicas on the pve pool)"

# m70s: register the PM961 (the ADR-114 zone's DEDICATED data disk, fitted 2026-09-12 on a
# Gembird PEX-M2-01 in the x16 LP slot — the box's only x4-capable slot). Talos mounts it at
# /var/lib/longhorn/pm961 from machines.yaml's `longhorn_disks`; this is what makes Longhorn aware
# of it. Deliberately UNTAGGED: `persistence.defaultDiskSelector=std` then fences the default
# class off this disk, while `longhorn-local-xfs` (no diskSelector — the consumer's node affinity
# is its fence) can still place garage-1's meta+data here. storageReserved 0: unlike the node's
# default disk this one carries nothing but Longhorn data — no Talos, no container image store,
# which is the whole point of buying it (the 2026-09-01 collision, ledger §2026-09-07).
# Skip when already registered: re-patching mid disk-sync trips the longhorn validator.
if kubectl -n longhorn-system get nodes.longhorn.io m70s -o jsonpath='{.spec.disks.pm961.path}' 2>/dev/null | grep -q .; then
  echo "  m70s/pm961 already registered — skip"
else
  kubectl -n longhorn-system patch nodes.longhorn.io m70s --type=merge -p '{
    "spec": {
      "disks": {
        "pm961": {"path":"/var/lib/longhorn/pm961","allowScheduling":true,"evictionRequested":false,"storageReserved":0,"tags":[],"diskType":"filesystem"}
      }
    }
  }' >/dev/null
  echo "  m70s/pm961 registered (untagged — the zone disk)"
fi

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
# wk-metal-04's DEMOTE (2026-09-09): two Intel SSD Pro 7600p 256G (DRAM-cached — the buying
# criterion, docs/storage-ledger.md §2026-09-05) mounted by Talos at /var/lib/longhorn/intel{0,1}
# from machines.yaml `longhorn_disks`. They ARE the bulk tier on this node from now on; the
# DRAM-less SA400 (486 ms / 26 MB/s sustained) drops to `slow-bulk`: nothing new lands on it,
# what already sits there (registry mirrors, garage-0's zone volumes until the rotation) stays.
# storageReserved 0: Longhorn data only, no image store on these (the hg5d shape).
for d in intel0 intel1; do
  if kubectl -n longhorn-system get nodes.longhorn.io wk-metal-04 -o jsonpath="{.spec.disks.$d.path}" 2>/dev/null | grep -q .; then
    echo "  wk-metal-04/$d already registered — skip"
  else
    kubectl -n longhorn-system patch nodes.longhorn.io wk-metal-04 --type=merge -p "{\"spec\":{\"disks\":{\"$d\":{\"path\":\"/var/lib/longhorn/$d\",\"allowScheduling\":true,\"evictionRequested\":false,\"storageReserved\":0,\"tags\":[\"bulk\"],\"diskType\":\"filesystem\"}}}}" >/dev/null
    echo "  wk-metal-04/$d registered (bulk, 0 reserved)"
  fi
done
tag wk-metal-04 sata500 '["slow-bulk"]'
# `longhorn-local-xfs` (garage's zone class) is selector-less, so a tag alone does not keep the
# SA400 out of the candidate set on a three-disk node: it is UNSCHEDULABLE outright (2026-09-09,
# the garage-0 rotation onto the 7600p). Existing replicas stay; nothing new lands.
unschedule() { # node disk
  kubectl -n longhorn-system patch nodes.longhorn.io "$1" --type=merge \
    -p "{\"spec\":{\"disks\":{\"$2\":{\"allowScheduling\":false}}}}" >/dev/null
  echo "  $1/$2 allowScheduling=false"
}
unschedule wk-metal-04 sata500

# m70s: the ADR-114 third PHYSICAL Garage zone (2026-09-07). Whole-disk EPHEMERAL on a 512G
# Micron 2300 (DRAM-cached — it clears the data-disk criterion), so the Longhorn disk is the
# default one, shared with the containerd image store like the laptops.
# ⚠ TAGGING POLICY CHANGED 2026-09-12 (this disk is tagged `std` at the top of the script now).
# It was deliberately UNTAGGED while the zone lived here: the only class meant to land was
# `longhorn-local-xfs` (selector-less, replica-1, strict-local — tofu/longhorn.tf) placed by the
# consumer's zone affinity, and a std tag would have invited platform replicas onto the disk the
# zone existed for. That reason EXPIRED when garage-1's meta+data rotated onto the dedicated
# PM961 (`pm961` below): the zone no longer lives here, so the disk is now the node's std slice —
# 474.6G on a DRAM-cached drive that is NOT the pve pool, which is what lets wk-02's pooled disk
# stop taking new replicas. The fence that still matters is the OTHER direction: `pm961` stays
# untagged so std can never land on the zone's spindle.
# 100Gi reserved, re-checked 2026-09-12 and KEPT: the partition's non-Longhorn users measure
# 58.1G today (Talos + containerd image store + logs, with Longhorn at 0 scheduled after the
# rotation), so the reserve still covers them with ~42G of image-store growth before it binds —
# runner-image-prepull's working set + the kubelet's 10% nodefs floor (51G), with the imageGC
# 60/50 floor (metal.tf, longhorn_default_disk) keeping the rest honest. Revisit if the prepull
# set grows: the number to compare is `storageMaximum - storageAvailable - storageScheduled`.
if kubectl -n longhorn-system get nodes.longhorn.io m70s -o jsonpath='{.spec.disks.nvme.path}' 2>/dev/null | grep -q .; then
  echo "  m70s/nvme already registered — skip"
else
kubectl -n longhorn-system patch nodes.longhorn.io m70s --type=merge -p '{
  "spec": {
    "allowScheduling": true,
    "disks": {
      "nvme": {"path":"/var/lib/longhorn","allowScheduling":true,"evictionRequested":false,"storageReserved":107374182400,"tags":[],"diskType":"filesystem"}
    }
  }
}' >/dev/null
echo "  m70s/nvme registered (untagged, 100Gi reserved)"
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
