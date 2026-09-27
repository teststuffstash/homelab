#!/bin/sh
# pve-textfile-metrics — the pve thin-pool meter (FU-093). Writes the LVM thin-pool level, VG free
# extents, per-thin-LV allocation, every guest's qmpstatus and every guest's memory placement
# (per host NUMA node / swapped / pinned — FU-289) into node_exporter's textfile collector, once a
# minute from a systemd timer (pve-textfile-metrics.timer).
#
# WHY. The pool filled to 100 % four times (2026-08-07, 08-18, 08-24, 09-03) and not one fill
# alerted: nothing outside the hypervisor could see the pool, and at 100 % every VM on it pauses
# on io-error TOGETHER — control plane included, so Prometheus/Alertmanager were down for the one
# event they exist for (docs/incidents/2026-09-03-pve-thin-pool-fourth-fill-prepull.md). The
# in-cluster fstrim belt (argocd/resources/node-fstrim/) proves the reclaim path runs; this is
# the level itself. Consumed by argocd/resources/pve-metrics/ (ScrapeConfig + PrometheusRule)
# and by the runner-image-prepull gate that refuses a 4.9 GiB pull onto a pool VM while the pool
# is high.
#
# Shell + coreutils only (dash-safe); no dependencies beyond lvm2 and qm, both on every pve host.
# Atomic write (tmp + mv) so node_exporter never reads a half file. A failure inside leaves the
# previous file in place and node_textfile_mtime_seconds stops advancing — that staleness is
# alerted on (PveMetricsStale), so a broken collector cannot masquerade as a calm pool.
set -u
OUT="${1:-/var/lib/prometheus/node-exporter/pve.prom}"
TMP="$OUT.$$"
trap 'rm -f "$TMP"' EXIT

{
  echo '# HELP pve_lvm_thin_pool_size_bytes Size of the LVM thin pool.'
  echo '# TYPE pve_lvm_thin_pool_size_bytes gauge'
  echo '# HELP pve_lvm_thin_pool_data_percent Data% of the LVM thin pool (lvs data_percent) — at 100 every VM on it pauses on io-error.'
  echo '# TYPE pve_lvm_thin_pool_data_percent gauge'
  echo '# HELP pve_lvm_thin_pool_metadata_percent Metadata% of the LVM thin pool (lvs metadata_percent).'
  echo '# TYPE pve_lvm_thin_pool_metadata_percent gauge'
  echo '# HELP pve_lvm_thin_lv_size_bytes Virtual size of a thin volume (its promise against the pool; sum = the overcommit).'
  echo '# TYPE pve_lvm_thin_lv_size_bytes gauge'
  echo '# HELP pve_lvm_thin_lv_data_percent Allocated share of a thin volume (lvs data_percent).'
  echo '# TYPE pve_lvm_thin_lv_data_percent gauge'
  # lvs: one row per LV, machine-readable. lv_attr[0] = 't' thin pool, 'V' thin volume.
  lvs --noheadings --units b --nosuffix --separator '|' \
      -o vg_name,lv_name,lv_size,data_percent,metadata_percent,pool_lv,lv_attr 2>/dev/null \
  | awk -F'|' '{
      for (i = 1; i <= NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
      vg = $1; lv = $2; size = $3; data = $4; meta = $5; pool = $6; attr = substr($7, 1, 1)
      if (attr == "t") {
        printf "pve_lvm_thin_pool_size_bytes{vg=\"%s\",lv=\"%s\"} %s\n", vg, lv, size
        if (data != "") printf "pve_lvm_thin_pool_data_percent{vg=\"%s\",lv=\"%s\"} %s\n", vg, lv, data
        if (meta != "") printf "pve_lvm_thin_pool_metadata_percent{vg=\"%s\",lv=\"%s\"} %s\n", vg, lv, meta
      } else if (attr == "V") {
        printf "pve_lvm_thin_lv_size_bytes{vg=\"%s\",lv=\"%s\",pool=\"%s\"} %s\n", vg, lv, pool, size
        if (data != "") printf "pve_lvm_thin_lv_data_percent{vg=\"%s\",lv=\"%s\",pool=\"%s\"} %s\n", vg, lv, pool, data
      }
    }'

  echo '# HELP pve_lvm_vg_size_bytes Size of the volume group.'
  echo '# TYPE pve_lvm_vg_size_bytes gauge'
  echo '# HELP pve_lvm_vg_free_bytes Free extents in the volume group — the only thing thin_pool_autoextend can consume.'
  echo '# TYPE pve_lvm_vg_free_bytes gauge'
  vgs --noheadings --units b --nosuffix --separator '|' -o vg_name,vg_size,vg_free 2>/dev/null \
  | awk -F'|' '{
      for (i = 1; i <= NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
      printf "pve_lvm_vg_size_bytes{vg=\"%s\"} %s\n", $1, $2
      printf "pve_lvm_vg_free_bytes{vg=\"%s\"} %s\n", $1, $3
    }'

  # Guests: qm's own status plus the QMP status, which is where "paused on a failed write" shows
  # (qmpstatus=io-error while status=running — the 2026-09-03 signature). Non-running guests carry
  # no qmpstatus; report their status verbatim.
  guests="$(qm list 2>/dev/null | awk 'NR > 1 { print $1, $2, $3 }')"
  echo '# HELP pve_qemu_status 1 for each guest, labelled with qm status and qmpstatus (io-error = paused on a failed write).'
  echo '# TYPE pve_qemu_status gauge'
  printf '%s\n' "$guests" | while read -r vmid name status; do
    [ -n "$vmid" ] || continue
    qmp="$(qm status "$vmid" --verbose 2>/dev/null | awk '/^qmpstatus:/ { print $2 }')"
    [ -n "$qmp" ] || qmp="$status"
    printf 'pve_qemu_status{vmid="%s",name="%s",status="%s",qmpstatus="%s"} 1\n' "$vmid" "$name" "$status" "$qmp"
  done

  # Guest memory PLACEMENT (FU-289): where each running guest's RAM physically sits (per host
  # NUMA node, summed from the qemu process's numa_maps — a hugetlb mapping counts in its own
  # page size), how much of it the host has swapped out (VmSwap), and how much is pinned
  # (VmLck: VFIO passthrough pins the whole guest, and pinned pages never move again). The
  # 2026-09-24 nx-02 event was invisible without this — wk-04's 32 GiB pinned 6/26 across the
  # two nodes left node 1 nothing evictable but the other guests, and kswapd swapped them to the
  # HDD while MemAvailable said 9 GiB (docs/spikes/nx-02-numa-placement.md). ~16 ms for a 32 GiB
  # guest; the numa_maps walk takes the mmap lock shared, harmless once a minute.
  echo '# HELP pve_qemu_numa_resident_bytes Resident guest memory per host NUMA node (from the qemu process numa_maps).'
  echo '# TYPE pve_qemu_numa_resident_bytes gauge'
  echo '# HELP pve_qemu_swap_bytes Guest memory the host has swapped out (qemu process VmSwap).'
  echo '# TYPE pve_qemu_swap_bytes gauge'
  echo '# HELP pve_qemu_locked_bytes Guest memory pinned in host RAM (qemu process VmLck — VFIO passthrough pins it all).'
  echo '# TYPE pve_qemu_locked_bytes gauge'
  printf '%s\n' "$guests" | while read -r vmid name status; do
    [ -n "$vmid" ] && [ -r "/var/run/qemu-server/$vmid.pid" ] || continue
    pid="$(cat "/var/run/qemu-server/$vmid.pid")"
    [ -r "/proc/$pid/numa_maps" ] || continue
    awk -v vmid="$vmid" -v name="$name" '
      {
        ps = 4096
        for (i = 1; i <= NF; i++) if ($i ~ /^kernelpagesize_kB=/) { split($i, k, "="); ps = k[2] * 1024 }
        for (i = 1; i <= NF; i++) if ($i ~ /^N[0-9]+=/) { split($i, a, "="); n[substr(a[1], 2)] += a[2] * ps }
      }
      END { for (x in n) printf "pve_qemu_numa_resident_bytes{vmid=\"%s\",name=\"%s\",node=\"%s\"} %.0f\n", vmid, name, x, n[x] }
    ' "/proc/$pid/numa_maps"
    awk -v vmid="$vmid" -v name="$name" '
      /^VmSwap:/ { printf "pve_qemu_swap_bytes{vmid=\"%s\",name=\"%s\"} %.0f\n", vmid, name, $2 * 1024 }
      /^VmLck:/  { printf "pve_qemu_locked_bytes{vmid=\"%s\",name=\"%s\"} %.0f\n", vmid, name, $2 * 1024 }
    ' "/proc/$pid/status"
  done
} > "$TMP" || exit 1

# Refuse to publish an empty pool section: the pool metric is THE series the alerts and the
# pre-pull gate read, so a collector that lost it must go stale, not report nothing quietly.
grep -q '^pve_lvm_thin_pool_data_percent' "$TMP" || { echo "pve-textfile-metrics: no thin pool row from lvs" >&2; exit 1; }
mv -f "$TMP" "$OUT"
