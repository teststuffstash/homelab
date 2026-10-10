#!/usr/bin/env python3
"""version-set-probe — the DRIFT BELT for the cross-repo version SETS (homelab#2014, S9 #1985).

docs/dependency-upgrades.md §Version SETS: claude-code must agree across the worker (agent-base),
the coordinator + reviewer (agent-coordinator) and the seat (claude-jail); kubectl must stay inside
the skew window of the fleet's Kubernetes minor. Before this probe nothing checked either — the
belt lands BEFORE the stamp mechanism (detection before fix, operator 2026-09-09), so it measures
what RUNS, never what a build was asked for.

Two modes, one script (mounted from a ConfigMap into every step of version-set-probe-argo.yaml):

  pins  [--consumers-out FILE]   (python:3.14-slim, the workflow's first step)
        reads homelab MASTER: agents/images.env (which images the cluster runs), the stamp file
        version-sets/devbox.lock (the set's ONE source once #2014's stamp lands — absent until then,
        pushed as version_set_pin_present 0), and devbox.lock (the jail's kubectl: the seat runs
        homelab's devbox toolchain). Reads the LIVE apiserver /version for the fleet minor. Writes
        the consumer list (the next step's withParam) and pushes the `pins` + `jail` groups.
  probe CONSUMER                 (runs INSIDE the consumer's own pinned image)
        `claude --version`, `kubectl version --client`, `kind version` (when bundled) — the binaries
        the image actually ships — and pushes group consumer=CONSUMER.
  --self-test                    parsing + exposition assertions, no network.

The jail's claude-code is NOT probed here: the seat is host-built, and its sessions already report
their version over the OTLP rail (claude_code_* `otel_scope_version`, role=jail) — the
PrometheusRule beside this file records it into the same series.

Pushgateway contract (docs/patterns/observability.md §Batch jobs push): fixed grouping key
(job=version_set_probe, consumer=<pins|jail|coordinator|worker>), PUT-replace, byte-identical
HELP/TYPE, a freshness gauge per group. Stdlib only: the consumer images carry python3 (Debian's in
agent-coordinator, devbox's python@3.11 in agent-base) and nothing else is installed.
"""
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

PUSHGATEWAY = os.environ.get("PUSHGATEWAY", "http://prometheus-pushgateway.monitoring.svc.cluster.local:9091")
JOB = "version_set_probe"
RAW = os.environ.get("HOMELAB_RAW", "https://raw.githubusercontent.com/teststuffstash/homelab/master")
STAMP_PATH = "version-sets/devbox.lock"
# images.env variable → consumer name. The coordinator image serves BOTH the coordinator and the
# reviewer roles (one image, two launchers); agent-base is every worker ride.
CONSUMERS = {"AGENT_COORDINATOR_IMAGE": "coordinator", "AGENT_BASE_IMAGE": "worker"}

HELP = {
    "version_set_running_info": ("gauge", "A tool version a consumer actually ships (1 per consumer/tool/version) — version-set-probe"),
    "version_set_kubectl_minor": ("gauge", "The kubectl client MINOR a consumer ships (major 1 assumed; skew rule input)"),
    "version_set_pin_info": ("gauge", "The version SET's stamped version per tool, from homelab master version-sets/devbox.lock"),
    "version_set_pin_present": ("gauge", "1 when homelab master carries the version-set stamp file, 0 before #2014's stamp lands"),
    "version_set_fleet_kubernetes_minor": ("gauge", "The live apiserver's Kubernetes MINOR (the skew rule's reference)"),
    "version_set_probe_generated_timestamp_seconds": ("gauge", "Unix time this version-set-probe group was last pushed (freshness)"),
}


# ── parsing (pure; covered by --self-test) ──────────────────────────────────────────────────────
def parse_env(text):
    out = {}
    for line in text.splitlines():
        m = re.match(r"^([A-Z0-9_]+)=(.*)$", line.strip())
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def consumers_from_images_env(text):
    env = parse_env(text)
    return [{"consumer": name, "image": env[var]} for var, name in sorted(CONSUMERS.items()) if env.get(var)]


def lock_versions(lock_text, tools=None):
    """devbox.lock → {tool: version} keyed by the package base name (`kubectl@1.36` → kubectl)."""
    pkgs = json.loads(lock_text).get("packages", {})
    out = {}
    for key, val in pkgs.items():
        name = re.sub(r"@[^@]*$", "", key)
        if (tools is None or name in tools) and isinstance(val, dict) and val.get("version"):
            out[name] = val["version"]
    return out


def parse_claude_version(text):
    m = re.search(r"(\d+\.\d+\.\d+)", text or "")
    return m.group(1) if m else None


def parse_kubectl_client(json_text):
    gv = (json.loads(json_text).get("clientVersion") or {}).get("gitVersion", "")
    return gv.lstrip("v") or None


def parse_kind_version(text):
    m = re.search(r"v?(\d+\.\d+\.\d+)", text or "")
    return m.group(1) if m else None


def minor_of(version):
    m = re.match(r"^v?(\d+)\.(\d+)", version or "")
    return int(m.group(2)) if m else None


def exposition(samples):
    """samples: [(metric, {labels}, value)] → Prometheus text, HELP/TYPE once per metric, stable order."""
    lines, seen = [], set()
    for metric, labels, value in sorted(samples, key=lambda s: (s[0], sorted(s[1].items()))):
        if metric not in seen:
            typ, hlp = HELP[metric]
            lines += [f"# HELP {metric} {hlp}", f"# TYPE {metric} {typ}"]
            seen.add(metric)
        lab = ",".join(f'{k}="{v}"' for k, v in sorted(labels.items()))
        lines.append(f"{metric}{{{lab}}} {value}" if lab else f"{metric} {value}")
    return "\n".join(lines) + "\n"


def tool_samples(versions):
    s = [("version_set_running_info", {"tool": t, "version": v}, 1) for t, v in versions.items()]
    if versions.get("kubectl") and minor_of(versions["kubectl"]) is not None:
        s.append(("version_set_kubectl_minor", {}, minor_of(versions["kubectl"])))
    return s


# ── I/O ─────────────────────────────────────────────────────────────────────────────────────────
def fetch(path):
    req = urllib.request.Request(f"{RAW}/{path}")
    tok = os.environ.get("GH_TOKEN", "")
    if tok:  # authenticated even on the public repo (git-preemptive-auth: no anonymous per-IP throttle)
        req.add_header("Authorization", f"token {tok}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read().decode()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def apiserver_version():
    sa = "/var/run/secrets/kubernetes.io/serviceaccount"
    ctx = ssl.create_default_context(cafile=f"{sa}/ca.crt")
    req = urllib.request.Request("https://kubernetes.default.svc/version")
    with open(f"{sa}/token") as f:
        req.add_header("Authorization", f"Bearer {f.read().strip()}")
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
        return json.loads(r.read().decode()).get("gitVersion", "")


def push(consumer, samples):
    samples = samples + [("version_set_probe_generated_timestamp_seconds", {}, int(time.time()))]
    body = exposition(samples).encode()
    req = urllib.request.Request(f"{PUSHGATEWAY}/metrics/job/{JOB}/consumer/{consumer}", data=body, method="PUT")
    req.add_header("Content-Type", "text/plain; version=0.0.4")
    with urllib.request.urlopen(req, timeout=30) as r:
        r.read()
    print(f"pushed consumer={consumer}:\n{body.decode()}")


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=True).stdout
    except (OSError, subprocess.SubprocessError) as e:
        print(f"  {cmd[0]}: not available ({e.__class__.__name__})", file=sys.stderr)
        return None


def mode_pins(consumers_out):
    images_env = fetch("agents/images.env")
    if images_env is None:
        sys.exit("agents/images.env not found on homelab master — refusing to probe nothing")
    consumers = consumers_from_images_env(images_env)
    if not consumers:
        sys.exit("no consumer image in agents/images.env — refusing to probe nothing")
    stamp = fetch(STAMP_PATH)
    pins = lock_versions(stamp) if stamp else {}
    fleet = apiserver_version()
    samples = [("version_set_pin_present", {}, 1 if stamp else 0)]
    samples += [("version_set_pin_info", {"tool": t, "version": v}, 1) for t, v in pins.items()]
    if minor_of(fleet) is not None:
        samples.append(("version_set_fleet_kubernetes_minor", {}, minor_of(fleet)))
    push("pins", samples)
    jail_lock = fetch("devbox.lock")
    if jail_lock:
        push("jail", tool_samples(lock_versions(jail_lock, {"kubectl"})))
    with open(consumers_out, "w") as f:
        json.dump(consumers, f)
    print(f"consumers: {json.dumps(consumers)}")


def mode_probe(consumer):
    versions = {}
    v = parse_claude_version(run(["claude", "--version"]))
    if v:
        versions["claude-code"] = v
    out = run(["kubectl", "version", "--client", "-o", "json"])
    if out:
        versions["kubectl"] = parse_kubectl_client(out)
    v = parse_kind_version(run(["kind", "version"]))
    if v:
        versions["kind"] = v
    versions = {k: x for k, x in versions.items() if x}
    if "claude-code" not in versions:
        # every consumer of this set bundles claude — reading nothing is a probe failure, not a version
        sys.exit(f"{consumer}: claude --version yielded no version — refusing to push a partial group")
    push(consumer, tool_samples(versions))


def self_test():
    fails, n = [], [0]

    def check(name, got, want):
        n[0] += 1
        if got != want:
            fails.append(f"{name}: got {got!r}, want {want!r}")

    env = "# comment\nAGENT_BASE_IMAGE=ghcr.io/x/agent-base:2026.10.9-gaaa\nAGENT_COORDINATOR_IMAGE=ghcr.io/x/agent-coordinator:2026.10.5-gbbb\nAGENT_DIND_IMAGE=ghcr.io/k3d:5\n"
    # sorted by images.env variable name: AGENT_BASE_IMAGE < AGENT_COORDINATOR_IMAGE; dind is not a set consumer
    check("consumers", consumers_from_images_env(env), [
        {"consumer": "worker", "image": "ghcr.io/x/agent-base:2026.10.9-gaaa"},
        {"consumer": "coordinator", "image": "ghcr.io/x/agent-coordinator:2026.10.5-gbbb"}])
    lock = json.dumps({"packages": {"claude-code@latest": {"version": "2.1.291"}, "kubectl@1.36": {"version": "1.36.3"},
                                    "github:NixOS/nixpkgs/abc#talosctl": {}, "kind@latest": {"version": "0.31.0"}}})
    # the pin key carries a bounded spec (`kubectl@1.36`) — the base name is what the set compares
    check("lock all", lock_versions(lock), {"claude-code": "2.1.291", "kubectl": "1.36.3", "kind": "0.31.0"})
    check("lock filtered", lock_versions(lock, {"kubectl"}), {"kubectl": "1.36.3"})
    check("claude", parse_claude_version("2.1.289 (Claude Code)\n"), "2.1.289")
    check("claude empty", parse_claude_version(None), None)
    check("kubectl", parse_kubectl_client('{"clientVersion":{"major":"1","minor":"36","gitVersion":"v1.36.1"},"kustomizeVersion":"v5"}'), "1.36.1")
    check("kind", parse_kind_version("kind v0.31.0 go1.25.1 linux/amd64"), "0.31.0")
    check("minor v", minor_of("v1.36.1"), 36)
    check("minor bare", minor_of("1.37.1"), 37)
    check("minor junk", minor_of("latest"), None)
    expo = exposition(tool_samples({"claude-code": "2.1.289", "kubectl": "1.36.1"}))
    check("exposition", expo,
          "# HELP version_set_kubectl_minor The kubectl client MINOR a consumer ships (major 1 assumed; skew rule input)\n"
          "# TYPE version_set_kubectl_minor gauge\n"
          "version_set_kubectl_minor 36\n"
          "# HELP version_set_running_info A tool version a consumer actually ships (1 per consumer/tool/version) — version-set-probe\n"
          "# TYPE version_set_running_info gauge\n"
          'version_set_running_info{tool="claude-code",version="2.1.289"} 1\n'
          'version_set_running_info{tool="kubectl",version="1.36.1"} 1\n')
    if fails:
        print("version-set-probe self-test: FAIL\n  " + "\n  ".join(fails))
        return 1
    print(f"version-set-probe self-test: ok ({n[0]} assertions)")
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["--self-test"]:
        sys.exit(self_test())
    if a[:1] == ["pins"]:
        out = a[a.index("--consumers-out") + 1] if "--consumers-out" in a else "/tmp/consumers.json"
        mode_pins(out)
    elif len(a) == 2 and a[0] == "probe":
        mode_probe(a[1])
    else:
        sys.exit(__doc__)
