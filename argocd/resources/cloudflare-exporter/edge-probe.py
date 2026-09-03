#!/usr/bin/env python3
"""Cloudflare edge observability GraphQL poller → Prometheus (homelab#1306).

WHY this exists: the lablabs cloudflare_exporter v0.2.3 uses `httpRequests1mGroups`, which
answers "does not have access to the path" on FREE-plan zones (docs/cloudflare.md §Free-zone
GraphQL matrix, validated live 2026-08-08). Both product zones (teststuff.net, minutark.ee) are
free today. This poller uses `httpRequestsAdaptiveGroups` and `firewallEventsAdaptive` — both
✅ on free zones — to produce per-route edge series that the ORACLE stack's dashboards consume.

⚠ This is the FU-039 open leg: a ConfigMap-python GraphQL poller beside the lablabs exporter,
on the same ESO-delivered `CLOUDFLARE_OBSERVABILITY_READ` token, in the same namespace. NOT
routed through `cf-api-proxy`: that allowlist injects the ingress-write token and deliberately
403s settings paths; this is a direct read against `api.cloudflare.com/client/v4/graphql`, same
as the spend probe's direct REST reads.

⚠ Do NOT add minutark.ee to any batched zone query in the lablabs exporter's deployment.yaml.
homelab#132 round 3: a free zone riding into the batched zone-totals query makes Cloudflare
reject the *whole batch*, which killed the Pro zone's data. This poller queries one zone at a
time, so it cannot poison a batch.

Config (env): CF_API_TOKEN (observability-read token), CF_EDGE_ZONE_IDS (comma-separated zone
ids to poll), POLL_INTERVAL_SECONDS (120), LISTEN_PORT (9506).

Self-test (no network, no credential):
    python3 argocd/resources/cloudflare-exporter/edge-probe.py --self-test
It replays recorded API shapes — today's and a FLIPPED one — through the real collector AND
through the alert expressions scraped out of the committed prometheusrule.yaml.
"""

import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API = "https://api.cloudflare.com/client/v4/graphql"
API_REST = "https://api.cloudflare.com/client/v4"

TOKEN = os.environ.get("CF_API_TOKEN", "").strip()
# The product zone: minutark.ee (fa1b02951c29ee4828b8948d0dd7baaf).
# Zone ids are not secrets (the sibling deployment carries one in plain env too).
ZONE_IDS = [z.strip() for z in os.environ.get("CF_EDGE_ZONE_IDS", "").split(",") if z.strip()]
INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "120"))
PORT = int(os.environ.get("LISTEN_PORT", "9506"))

_lock = threading.Lock()
_body = "# probe has not completed a cycle yet\n"
_errors = 0
_last_success = 0
# Readiness gate: return non-200 when the last successful poll is older than this threshold.
# Set to 3× the poll interval (120s) so a single transient failure does not flap readiness,
# but a pod stuck for 3+ consecutive cycles becomes not Ready. At startup _last_success is 0,
# so a pod that has never polled is immediately not Ready.
HEALTHZ_STALE_SECONDS = 360

HEADERS = [
    "# HELP cloudflare_edge_requests_total Per-route request count by host and status.",
    "# TYPE cloudflare_edge_requests_total counter",
    "# HELP cloudflare_edge_cache_hit_ratio Per-route cache hit ratio (0-1).",
    "# TYPE cloudflare_edge_cache_hit_ratio gauge",
    "# HELP cloudflare_edge_rate_limit_events_total Per-route rate-limit/mitigation events.",
    "# TYPE cloudflare_edge_rate_limit_events_total counter",
    "# HELP cloudflare_edge_probe_ok 1 when the edge poll succeeded for the zone this poll. 0 or absent means the gauges above are unknown, NOT safe.",
    "# TYPE cloudflare_edge_probe_ok gauge",
]


def esc(value):
    return str(value).replace("\\", r"\\").replace('"', r"\"").replace("\n", r"\n")


def metric(name, labels, value):
    inner = ",".join(f'{k}="{esc(v)}"' for k, v in sorted(labels.items()))
    return f"{name}{{{inner}}} {value}"


def api_get(path):
    """GET a Cloudflare v4 path and return `result`. Raises on transport or envelope failure."""
    req = urllib.request.Request(
        API_REST + path,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/json",
            "User-Agent": "homelab-cloudflare-edge-probe",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"GET {path} → HTTP {exc.code}: {exc.read()[:300]!r}") from None
    if not payload.get("success"):
        raise RuntimeError(f"GET {path} → success=false: {payload.get('errors')}")
    return payload.get("result")


def graphql_query(zone_tag, start, end):
    """Build and execute a GraphQL query for httpRequestsAdaptiveGroups and firewallEventsAdaptive.

    Returns (requests_rows, firewall_rows) where each is a list of dimension-grouped records.
    """
    query = {
        "query": """
        query EdgeObservability($zoneTag: String!, $start: String!, $end: String!) {
          viewer {
            zones(filter: {zoneTag: $zoneTag}) {
              httpRequestsAdaptiveGroups(
                limit: 10000
                filter: {datetime_gt: $start, datetime_lt: $end}
                orderBy: [datetime_DESC]
              ) {
                dimensions {
                  datetime
                  clientRequestHTTPHost
                  edgeResponseStatus
                  cacheStatus
                }
                sum {
                  requests
                  bytes
                }
              }
              firewallEventsAdaptive(
                limit: 10000
                filter: {datetime_gt: $start, datetime_lt: $end}
                orderBy: [datetime_DESC]
              ) {
                dimensions {
                  datetime
                  clientRequestHTTPHost
                  action
                  source
                }
                sum {
                  occurrences
                }
              }
            }
          }
        }
        """,
        "variables": {
            "zoneTag": zone_tag,
            "start": start,
            "end": end,
        },
    }
    body = json.dumps(query).encode()
    req = urllib.request.Request(
        API,
        data=body,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "homelab-cloudflare-edge-probe",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"GraphQL query → HTTP {exc.code}: {exc.read()[:500]!r}") from None
    if not payload.get("success"):
        raise RuntimeError(f"GraphQL query → success=false: {payload.get('errors')}")
    zones = payload.get("data", {}).get("viewer", {}).get("zones", [])
    if not zones:
        raise RuntimeError(f"GraphQL query returned no zones for zoneTag={zone_tag}")
    zone = zones[0]
    requests_rows = zone.get("httpRequestsAdaptiveGroups", [])
    firewall_rows = zone.get("firewallEventsAdaptive", [])
    return requests_rows, firewall_rows


def collect(lines, fetch=None, zone_ids=None):
    """Emit per-zone edge metrics. Every configured zone emits `edge_probe_ok` no matter what
    failed, so a zone that silently stops answering is visible as a zone, not as a gap."""
    global _errors
    lines += HEADERS
    now = time.time()
    # Poll a short window: 5 minutes back. Adaptive retention is 1w1d; Prometheus owns history.
    start = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 300))
    end = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))

    for zone_id in (zone_ids if zone_ids is not None else ZONE_IDS):
        zone_name, failed = zone_id, 0
        try:
            # Resolve zone name via REST (same as spend-probe does for its zone label).
            # The GraphQL query doesn't return the zone name, so we need a separate lookup.
            if fetch is None:
                zone_result = api_get(f"/zones/{zone_id}")
                zone_name = str((zone_result or {}).get("name") or zone_id)
                requests_rows, firewall_rows = graphql_query(zone_id, start, end)
            else:
                # For self-test: fetch returns a pre-built (zone_name, requests_rows, firewall_rows) tuple
                zone_name, requests_rows, firewall_rows = fetch(zone_id, start, end)

            # Aggregate requests by host + status
            host_req = {}  # (host, status) -> count
            host_cache = {}  # host -> {hit: count, total: count}
            for row in requests_rows:
                dims = row.get("dimensions", {})
                host = dims.get("clientRequestHTTPHost", "unknown")
                status = str(dims.get("edgeResponseStatus", "0"))
                cache = dims.get("cacheStatus", "unknown")
                count = row.get("sum", {}).get("requests", 0)
                key = (host, status)
                host_req[key] = host_req.get(key, 0) + count
                if host not in host_cache:
                    host_cache[host] = {"hit": 0, "total": 0}
                host_cache[host]["total"] += count
                if cache and cache.lower() in ("hit", "stale", "revalidated"):
                    host_cache[host]["hit"] += count

            # Emit per-route request totals
            for (host, status), count in sorted(host_req.items()):
                lines.append(metric("cloudflare_edge_requests_total", {
                    "zone": zone_name,
                    "host": host,
                    "status": status,
                }, count))

            # Emit per-route cache hit ratio
            for host, counts in sorted(host_cache.items()):
                ratio = counts["hit"] / counts["total"] if counts["total"] > 0 else 0
                lines.append(metric("cloudflare_edge_cache_hit_ratio", {
                    "zone": zone_name,
                    "host": host,
                }, ratio))

            # Aggregate firewall events by host + action
            host_fw = {}  # (host, action) -> count
            for row in firewall_rows:
                dims = row.get("dimensions", {})
                host = dims.get("clientRequestHTTPHost", "unknown")
                action = dims.get("action", "unknown")
                count = row.get("sum", {}).get("occurrences", 0)
                key = (host, action)
                host_fw[key] = host_fw.get(key, 0) + count

            for (host, action), count in sorted(host_fw.items()):
                lines.append(metric("cloudflare_edge_rate_limit_events_total", {
                    "zone": zone_name,
                    "host": host,
                    "action": action,
                }, count))

        except Exception as exc:
            failed += 1
            _errors += 1
            print(f"zone {zone_id}: edge poll failed: {exc}", flush=True)

        lines.append(metric("cloudflare_edge_probe_ok", {"zone": zone_name}, 0 if failed else 1))


def poll_forever():
    global _body, _last_success
    while True:
        lines, before = [], _errors
        try:
            collect(lines)
        except Exception as exc:
            print(f"collect failed: {exc}", flush=True)
        if _errors == before and ZONE_IDS:
            _last_success = int(time.time())
        lines += [
            "# TYPE cloudflare_edge_probe_errors_total counter",
            f"cloudflare_edge_probe_errors_total {_errors}",
            "# HELP cloudflare_edge_probe_last_success_timestamp Epoch of the last poll where every configured zone read cleanly.",
            "# TYPE cloudflare_edge_probe_last_success_timestamp gauge",
            f"cloudflare_edge_probe_last_success_timestamp {_last_success}",
        ]
        with _lock:
            _body = "\n".join(lines) + "\n"
        time.sleep(INTERVAL)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/metrics", "/healthz", "/"):
            self.send_error(404)
            return
        with _lock:
            body = _body.encode()
        if self.path == "/healthz":
            if _last_success == 0 or time.time() - _last_success > HEALTHZ_STALE_SECONDS:
                self.send_response(503)
                body = b"stale\n"
            else:
                self.send_response(200)
                body = b"ok\n"
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


# ── the self-test ────────────────────────────────────────────────────────────────────────────────
# Same shape as spend-probe.py --self-test / router.py --self-test / github-exporter.py --self-test.
# See spend-probe.py's self-test header for the full honesty block — the same caveats apply here:
# this is NOT `promtool test rules`, it evaluates ONE instant, and it cannot see `for:` windows or
# scrape holes. What it DOES prove: the alert expressions are read out of the COMMITTED
# prometheusrule.yaml — not restated here — and evaluated against the exposition the REAL collector
# builds from recorded API shapes. A metric renamed on one side only, an inverted gauge polarity,
# a comparison against the wrong constant, or a zone that stops emitting all fail this.

_Z_PRODUCT = "fa1b02951c29ee4828b8948d0dd7baaf"  # minutark.ee

# Recorded response shapes. TODAY = quiet state (no traffic, no events).
_TODAY_REQUESTS = []
_TODAY_FIREWALL = []

# FLIPPED: traffic on the product zone with cache misses and a rate-limit event.
_FLIPPED_REQUESTS = [
    {
        "dimensions": {
            "datetime": "2026-09-02T18:50:00Z",
            "clientRequestHTTPHost": "mcp.minutark.ee",
            "edgeResponseStatus": 200,
            "cacheStatus": "miss",
        },
        "sum": {"requests": 42, "bytes": 16384},
    },
    {
        "dimensions": {
            "datetime": "2026-09-02T18:50:00Z",
            "clientRequestHTTPHost": "mcp.minutark.ee",
            "edgeResponseStatus": 429,
            "cacheStatus": "unknown",
        },
        "sum": {"requests": 5, "bytes": 512},
    },
    {
        "dimensions": {
            "datetime": "2026-09-02T18:50:00Z",
            "clientRequestHTTPHost": "minutark.ee",
            "edgeResponseStatus": 200,
            "cacheStatus": "hit",
        },
        "sum": {"requests": 100, "bytes": 40960},
    },
]
_FLIPPED_FIREWALL = [
    {
        "dimensions": {
            "datetime": "2026-09-02T18:50:00Z",
            "clientRequestHTTPHost": "mcp.minutark.ee",
            "action": "rate_limit",
            "source": "rateLimiter",
        },
        "sum": {"occurrences": 3},
    },
]

RULE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prometheusrule.yaml")

_ALERT_RE = re.compile(r"^\s*-\s*alert:\s*(\S+)\s*$")
_EXPR_RE = re.compile(r"^\s*expr:\s*(.+?)\s*$")
_SAMPLE_RE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)\{zone="([^"]*)"\}\s+(-?[\d.]+)$')
_CMP_RE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)\s*(==|!=|>=|<=|>|<)\s*(-?[\d.]+)$")
_ABSENT_RE = re.compile(r"^absent\(([a-zA-Z_:][a-zA-Z0-9_:]*)\)$")
_OPS = {"==": lambda a, b: a == b, "!=": lambda a, b: a != b, ">": lambda a, b: a > b,
        ">=": lambda a, b: a >= b, "<": lambda a, b: a < b, "<=": lambda a, b: a <= b}
_BRIDGE_CMP_RE = re.compile(
    r"^(max|min) by \(zone\) \((max|min)_over_time\(([a-zA-Z_:][a-zA-Z0-9_:]*)\[(\d+[smhdwy])\]\)\)"
    r"\s*(==|!=|>=|<=|>|<)\s*(-?[\d.]+)$")
_BRIDGE_ABSENT_RE = re.compile(
    r"^absent\((max|min)_over_time\(([a-zA-Z_:][a-zA-Z0-9_:]*)\[(\d+[smhdwy])\]\)\)$")


def unbridge(arm):
    """One expr arm → (the arm with any #334 bridge stripped, (direction, range) or None)."""
    match = _BRIDGE_ABSENT_RE.match(arm)
    if match:
        return f"absent({match.group(2)})", (match.group(1), match.group(3))
    match = _BRIDGE_CMP_RE.match(arm)
    if match:
        agg, over, name, window, op, threshold = match.groups()
        if agg != over:
            raise AssertionError(
                f"bridged arm mixes directions — `{agg} by (zone)` over `{over}_over_time` in "
                f"{arm!r}: the aggregation and the range function must agree")
        return f"{name} {op} {threshold}", (agg, window)
    return arm, None


def bridges(expr):
    """Every arm's (direction, range), None where an arm carries no #334 bridge at all."""
    return [unbridge(arm.strip())[1] for arm in expr.split(" or ")]


def rule_exprs(path=RULE_FILE):
    """alert name → expr, line-scanned out of the committed PrometheusRule."""
    found, current = {}, None
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            match = _ALERT_RE.match(line)
            if match:
                current = match.group(1)
                continue
            match = _EXPR_RE.match(line)
            if match and current:
                found[current] = match.group(1)
                current = None
    return found


def samples_of(lines):
    """exposition lines → {(metric, zone): value}, comments and unlabelled self-metrics ignored."""
    out = {}
    for line in lines:
        match = _SAMPLE_RE.match(line)
        if match:
            out[(match.group(1), match.group(2))] = float(match.group(3))
    return out


def firing_zones(expr, samples):
    """The set of `zone` labels an expr selects over one instant of samples."""
    firing = set()
    for arm in expr.split(" or "):
        arm, _ = unbridge(arm.strip())
        match = _CMP_RE.match(arm)
        if match:
            name, op, threshold = match.group(1), match.group(2), float(match.group(3))
            firing |= {zone for (series, zone), value in samples.items()
                       if series == name and _OPS[op](value, threshold)}
            continue
        match = _ABSENT_RE.match(arm)
        if match:
            if not any(series == match.group(1) for series, _ in samples):
                firing.add("<absent>")
            continue
        raise AssertionError(f"expr arm not modelled by this evaluator: {arm!r} (in {expr!r})")
    return firing


def _fixture_fetch(table_requests, table_firewall, zone_name="minutark.ee"):
    """Build a fetch function that returns pre-built fixture data for a zone."""
    def fetch(zone_id, start, end):
        return zone_name, table_requests, table_firewall
    return fetch


def _fixture_fetch_failing():
    """Build a fetch function that always raises (simulates a zone that stops answering)."""
    def fetch(zone_id, start, end):
        raise RuntimeError(f"zone {zone_id} is not answering")
    return fetch


def _exposition(requests_rows, firewall_rows, zone_ids=(_Z_PRODUCT,)):
    lines = []
    collect(lines, fetch=_fixture_fetch(requests_rows, firewall_rows), zone_ids=list(zone_ids))
    return lines


def self_test():
    """`python3 edge-probe.py --self-test` — recorded fixtures through the real collector, then
    through the committed alert expressions."""
    global _errors

    # 1. Today's fixture → quiet state: no traffic, no events, probe_ok=1.
    today = _exposition(_TODAY_REQUESTS, _TODAY_FIREWALL)
    body = "\n".join(today)
    assert 'cloudflare_edge_probe_ok{zone="minutark.ee"} 1' in body, \
        f"missing probe_ok sample\n--- exposition ---\n{body}"
    # No request or rate-limit DATA series in quiet state (HELP/TYPE lines carry the name)
    assert not any(l.startswith("cloudflare_edge_requests_total{") for l in body.splitlines()), \
        "quiet state must emit no request data series"
    assert not any(l.startswith("cloudflare_edge_rate_limit_events_total{") for l in body.splitlines()), \
        "quiet state must emit no rate-limit data series"

    # 2. Flipped fixture → traffic with cache misses and rate-limit events.
    flipped = _exposition(_FLIPPED_REQUESTS, _FLIPPED_FIREWALL)
    body = "\n".join(flipped)
    for sample in (
        'cloudflare_edge_requests_total{host="mcp.minutark.ee",status="200",zone="minutark.ee"} 42',
        'cloudflare_edge_requests_total{host="mcp.minutark.ee",status="429",zone="minutark.ee"} 5',
        'cloudflare_edge_requests_total{host="minutark.ee",status="200",zone="minutark.ee"} 100',
        'cloudflare_edge_cache_hit_ratio{host="minutark.ee",zone="minutark.ee"} 1',
        'cloudflare_edge_cache_hit_ratio{host="mcp.minutark.ee",zone="minutark.ee"} 0',
        'cloudflare_edge_rate_limit_events_total{action="rate_limit",host="mcp.minutark.ee",zone="minutark.ee"} 3',
        'cloudflare_edge_probe_ok{zone="minutark.ee"} 1',
    ):
        assert sample in body, f"missing sample: {sample}\n--- exposition ---\n{body}"

    # 3. The committed rules, read from disk.
    exprs = rule_exprs()
    blind = "CloudflareEdgeProbeBlind"
    assert blind in exprs, f"{blind} is not in {RULE_FILE} (renamed? deleted?): {sorted(exprs)}"
    # The retired CloudflareEdge5xx must stay retired
    assert "CloudflareEdge5xx" not in exprs, \
        "CloudflareEdge5xx was retired in #350 — its input series cannot be produced for free " \
        "zones; re-adding it needs the edge-probe's metric names, not the old cloudflare_zone_* ones"

    # 3b. The #334 restart-gap bridge, pinned as literals.
    for name, want in ((blind, ("min", "10m")),):
        got = bridges(exprs[name])
        assert got and all(bridge == want for bridge in got), \
            f"{name} must bridge EVERY arm with {want[0]} by (zone) / {want[0]}_over_time[{want[1]}]" \
            f" — got {got} in {exprs[name]!r}"

    # 4. Replay: today's state is quiet, on every rule.
    quiet = samples_of(today)
    for name in (blind,):
        assert firing_zones(exprs[name], quiet) == set(), \
            f"{name} fires on today's state ({exprs[name]!r})"

    # 5. Replay: the flipped fixture fires — probe_ok is still 1, so blind alert stays quiet.
    flipped_samples = samples_of(flipped)
    assert firing_zones(exprs[blind], flipped_samples) == set(), \
        "a healthy probe must not fire the blind alert"

    # 6. A zone that stops answering is blind, not silently safe.
    before = _errors
    broken_lines = []
    collect(broken_lines, fetch=_fixture_fetch_failing(), zone_ids=[_Z_PRODUCT])
    broken = samples_of(broken_lines)
    assert not any(series == "cloudflare_edge_requests_total" for series, _ in broken), \
        "a failed read must emit NO request series"
    assert broken[("cloudflare_edge_probe_ok", _Z_PRODUCT)] == 0
    assert firing_zones(exprs[blind], broken) == {_Z_PRODUCT}
    assert _errors == before + 1, \
        "a failed read must count toward cloudflare_edge_probe_errors_total"
    _errors = before

    # 7. A probe that is gone entirely fires the blind alert through its absent() arm.
    assert firing_zones(exprs[blind], {}) == {"<absent>"}, \
        f"{blind} must survive the series disappearing: {exprs[blind]!r}"

    print("cloudflare edge-probe self-test: OK (parser, today's exposition, and the committed "
          f"{blind} expr replayed against flipped + blind fixtures; the retired "
          "CloudflareEdge5xx asserted absent)")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    if not TOKEN:
        sys.exit("cloudflare-edge-probe: CF_API_TOKEN is empty/unset — refusing to start")
    if not ZONE_IDS:
        sys.exit("cloudflare-edge-probe: CF_EDGE_ZONE_IDS is empty — refusing to start blind")
    threading.Thread(target=poll_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()