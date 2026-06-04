#!/usr/bin/env bash
# Register the ThinkCentre's two Optane drives as Longhorn "fast"-tagged disks.
#
# Why a script and not tofu: Longhorn disk config lives in the node.longhorn.io CR, which
# Longhorn's own controller reconciles. Managing it with tofu kubernetes_manifest fights that
# controller (it writes status + derived spec fields). A merge-patch that only ADDS the two
# disk keys is non-destructive (never touches the existing default disk) and idempotent, so
# this is the reliable, re-runnable path. Prereq: Talos has mounted the disks at
# /var/lib/longhorn/optane{0,1} (tofu/metal.tf machine.disks).
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$(dirname "$0")/../tofu/kubeconfig}"
NODE="${1:-thinkcentre}"
export KUBECONFIG

kubectl -n longhorn-system patch nodes.longhorn.io "$NODE" --type=merge -p '{
  "spec": {
    "disks": {
      "optane0": {"path":"/var/lib/longhorn/optane0","allowScheduling":true,"evictionRequested":false,"storageReserved":0,"tags":["fast"],"diskType":"filesystem"},
      "optane1": {"path":"/var/lib/longhorn/optane1","allowScheduling":true,"evictionRequested":false,"storageReserved":0,"tags":["fast"],"diskType":"filesystem"}
    }
  }
}'

echo "patched. disk status:"
kubectl -n longhorn-system get nodes.longhorn.io "$NODE" -o json |
  python3 -c 'import sys,json;d=json.load(sys.stdin)
for n,s in sorted(d["status"]["diskStatus"].items()):
    cond=[c["status"] for c in s.get("conditions",[]) if c["type"]=="Schedulable"]
    print("  %-26s ready/sched=%s tags=%s" % (n, cond, d["spec"]["disks"].get(n,{}).get("tags")))'
