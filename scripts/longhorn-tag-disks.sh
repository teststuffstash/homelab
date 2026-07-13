#!/usr/bin/env bash
# Longhorn disk tags + bulk-disk registration (ADR-089 storage tiers) — idempotent, like
# scripts/longhorn-register-optane.sh (disk config on a live Longhorn node isn't cleanly
# tofu-managed; the node CR is the authority).
#
# Tiers (tofu/longhorn.tf has the StorageClasses):
#   std  — the original three default disks (thinkcentre, hp-01, wk-02); the DEFAULT class
#          is fenced to these via persistence.defaultDiskSelector, so the scheduler can't
#          drop platform replicas onto the huge/wipe-prone bulk disks.
#   bulk — wk-metal-01's 500G MX500 (registered here explicitly, bulk-ONLY, 100Gi reserved
#          for OS/compute-tier scratch) + wk-02's grown disk (dual std+bulk: it's the
#          second replica's home for longhorn-bulk volumes).
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
tag wk-02 "$(default_disk wk-02)" '["std","bulk"]'
# wk-02's reservation was auto-sized (30%) against the ORIGINAL 81G disk; after the 240G grow,
# 15Gi is still generous for a dedicated Talos-VM /var (images+logs) and frees the headroom the
# 150Gi bulk grant needs (253 - 15 - ~86 scheduled ≈ 152G).
kubectl -n longhorn-system patch nodes.longhorn.io wk-02 --type=merge \
  -p "{\"spec\":{\"disks\":{\"$(default_disk wk-02)\":{\"storageReserved\":16106127360}}}}" >/dev/null
echo "  wk-02 storageReserved -> 15Gi"

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

echo "disk status:"
kubectl -n longhorn-system get nodes.longhorn.io -o json | python3 -c '
import sys,json
for i in json.load(sys.stdin)["items"]:
    n=i["metadata"]["name"]
    for k,v in sorted(i.get("spec",{}).get("disks",{}).items()):
        st=i.get("status",{}).get("diskStatus",{}).get(k,{})
        mx=int(st.get("storageMaximum",0))//10**9
        print("  %s/%s: tags=%s sched=%s max=%dG" % (n, k, v.get("tags"), v.get("allowScheduling"), mx))'
