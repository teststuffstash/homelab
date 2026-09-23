#!/usr/bin/env python3
"""smart-textfile-metrics — per-drive SMART for the HYPERVISORS (FU-284).

The in-cluster smartctl_exporter DaemonSet (argocd/resources/smartctl-exporter/) covers every
Talos node. It cannot cover pve and nx-02: they are not Kubernetes nodes. They are also the two
boxes where an unwatched disk is worst — every VM on a hypervisor shares its pool, and nx-02's
Proxmox root still sits on a single 2011-era WD5000AAKX spinner underneath cp-02 (SMART read
2026-09-23: PASSED, 20,620 h, zero reallocated/pending/uncorrectable — healthy, hence watched
rather than replaced).

WHY THE FOREIGN METRIC NAMES. This deliberately emits `smartctl_device_*`, the upstream
exporter's vocabulary, so ONE PrometheusRule group covers metal and hypervisors alike
(argocd/resources/smartctl-exporter/prometheusrule.yaml selects `job=~"smartctl-exporter|pve-node"`).
The alternative — Debian's `smartmon.sh` and its `smartmon_*` namespace — would have meant writing
every belt twice and keeping the two in step forever. The shapes are pinned by the fixture in that
directory and the exporter image is pinned by digest, so the two cannot drift silently.

`node` is written into the labels HERE, not attached at scrape time: the pve ScrapeConfig labels
its targets `host`, and that label belongs to the thin-pool belts. The rules report by `node`.

Shell-adjacent by design, like its sibling pve-textfile-metrics.sh: python3 + smartmontools, both
already on every Proxmox host (smartctl is part of the PVE base install). Atomic write (tmp + mv)
so node_exporter never reads a half file; a failure leaves the previous file in place and
node_textfile_mtime_seconds stops advancing.
"""
import json
import os
import socket
import subprocess
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "/var/lib/prometheus/node-exporter/smart.prom"
NODE = socket.gethostname().split(".")[0]


def smartctl(args):
    """Run smartctl and return parsed JSON, or None. Exit status is a BITFIELD, not a failure:
    bits 0-2 mean 'command failed / open failed / some SMART command failed', anything above is
    a health finding (bit 3 = failing now). So a non-zero exit still carries usable JSON."""
    try:
        p = subprocess.run(["smartctl", "--json=c"] + args,
                           capture_output=True, text=True, timeout=60)
        return json.loads(p.stdout) if p.stdout.strip() else None
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        return None


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def lbl(**kw):
    inner = ",".join('%s="%s"' % (k, esc(v)) for k, v in sorted(kw.items()) if v is not None)
    return "{%s}" % inner


scan = smartctl(["--scan-open"]) or {}
devices = [d for d in scan.get("devices", []) if d.get("name")]

lines = []


def emit(name, labels, value):
    lines.append("%s%s %s" % (name, labels, value))


for dev in devices:
    path, dtype = dev["name"], dev.get("type", "auto")
    short = os.path.basename(path)
    info = smartctl(["-a", "-d", dtype, path])
    if not info:
        continue
    base = dict(node=NODE, device=short)

    emit("smartctl_device", lbl(
        model_name=info.get("model_name", ""), serial_number=info.get("serial_number", ""),
        firmware_version=info.get("firmware_version", ""),
        interface=(info.get("device") or {}).get("protocol", ""), **base), 1)

    status = (info.get("smart_status") or {}).get("passed")
    if status is not None:
        emit("smartctl_device_smart_status", lbl(**base), 1 if status else 0)

    poh = (info.get("power_on_time") or {}).get("hours")
    if poh is not None:
        emit("smartctl_device_power_on_seconds", lbl(**base), int(poh) * 3600)

    temp = (info.get("temperature") or {}).get("current")
    if temp is not None:
        emit("smartctl_device_temperature", lbl(temperature_type="current", **base), temp)

    # SATA/ATA: the vendor attribute table. raw + normalized value, matching the exporter's
    # attribute_value_type split — the belts read `raw` for defect counters.
    for a in ((info.get("ata_smart_attributes") or {}).get("table") or []):
        aname = a.get("name")
        if not aname:
            continue
        al = dict(attribute_name=aname, attribute_id=a.get("id"), **base)
        raw = (a.get("raw") or {}).get("value")
        if raw is not None:
            emit("smartctl_device_attribute", lbl(attribute_value_type="raw", **al), raw)
        for k in ("value", "worst", "thresh"):
            if a.get(k) is not None:
                emit("smartctl_device_attribute", lbl(attribute_value_type=k, **al), a[k])

    # SATA link speed — the degraded-link detector (the wk-metal-04 signature).
    iface = info.get("interface_speed") or {}
    for key, stype in (("current", "current"), ("max", "max")):
        bits = (iface.get(key) or {}).get("bits_per_unit")
        units = (iface.get(key) or {}).get("units_per_second")
        if bits and units:
            emit("smartctl_device_interface_speed", lbl(speed_type=stype, **base), bits * units)

    # NVMe health log.
    nv = info.get("nvme_smart_health_information_log") or {}
    for field, metric in (("percentage_used", "smartctl_device_percentage_used"),
                          ("available_spare", "smartctl_device_available_spare"),
                          ("available_spare_threshold", "smartctl_device_available_spare_threshold"),
                          ("critical_warning", "smartctl_device_critical_warning"),
                          ("media_errors", "smartctl_device_media_errors"),
                          ("num_err_log_entries", "smartctl_device_num_err_log_entries")):
        if nv.get(field) is not None:
            emit(metric, lbl(**base), nv[field])

body = "\n".join([
    "# HELP smartctl_device Device information (labels only; value is always 1).",
    "# TYPE smartctl_device gauge",
    "# HELP smartctl_device_smart_status SMART overall-health self-assessment (1 = passed).",
    "# TYPE smartctl_device_smart_status gauge",
    "# HELP smartctl_device_attribute SATA/ATA vendor attribute, split by attribute_value_type.",
    "# TYPE smartctl_device_attribute gauge",
    "# HELP smartctl_device_interface_speed Negotiated and maximum link speed in bits/second.",
    "# TYPE smartctl_device_interface_speed gauge",
    "# HELP smartctl_devices Number of devices this collector read.",
    "# TYPE smartctl_devices gauge",
] + lines + ["smartctl_devices%s %d" % (lbl(node=NODE), len(devices))]) + "\n"

tmp = OUT + ".%d" % os.getpid()
try:
    with open(tmp, "w") as fh:
        fh.write(body)
    os.chmod(tmp, 0o644)
    os.rename(tmp, OUT)
except OSError:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
