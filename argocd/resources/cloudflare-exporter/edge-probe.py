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
    "# HELP cloudflare_edge_requests_total Cumulative request count by zone, host and edge status.",
    "# TYPE cloudflare_edge_requests_total counter",
    "# HELP cloudflare_edge_cached_requests_total Cumulative count of the subset served from cache (hit/stale/revalidated), by zone and host. Ratio is the CONSUMER's division: rate(cached)/rate(requests).",
    "# TYPE cloudflare_edge_cached_requests_total counter",
    "# HELP cloudflare_edge_rate_limit_events_total Cumulative firewall events of EVERY action (block, skip, rate_limit, managed_challenge, ...) by zone, host and action. The name is historical: it is not rate-limit-only.",
    "# TYPE cloudflare_edge_rate_limit_events_total counter",
    "# HELP cloudflare_edge_firewall_events_host_action_source_total Cumulative firewall events by zone, host, action and source (the product/phase that acted: firewallCustom, firewallManaged, rateLimiter, securityLevel, bic, ...).",
    "# TYPE cloudflare_edge_firewall_events_host_action_source_total counter",
    "# HELP cloudflare_edge_probe_ok 1 when the edge poll succeeded for the zone this poll. 0 or absent means the counters above are STALE, not safe.",
    "# TYPE cloudflare_edge_probe_ok gauge",
]

# ── cumulative counter state (the #572 lesson) ──────────────────────────────────────────────
# The first cut re-published each 5-minute window's count under a `_total` name declared
# `counter`. Three defects fell out of that one lie, and a consumer doing the CONVENTIONALLY
# CORRECT thing (`rate()` on a counter) got nonsense from all three:
#   1. the value rose AND FELL, so rate() read every decrease as a counter reset;
#   2. the 300s lookback against a 120s poll made windows overlap 2.5x — double counting;
#   3. only label sets seen in the last window were emitted, so series churned in and out of
#      existence (measured 2026-09-17: 14 series over 12h, 0 at any given instant, which is
#      also what misled oracle-fleet#572's test author into asserting only that the query
#      PARSES).
# So the probe keeps its own totals. Per-bucket counts are deduped by the row's own `datetime`
# dimension and only the INCREASE is added; every label set ever seen is emitted on every
# scrape. These are now real Prometheus counters: monotonic for a process lifetime, resetting
# only on restart — which rate()/increase() handle natively.
_totals_req = {}     # (zone, host, status) -> cumulative requests
_totals_cached = {}  # (zone, host)         -> cumulative cache-served requests
_totals_fw = {}      # (zone, host, action) -> cumulative firewall events (every action)
_totals_fw_src = {}  # (zone, host, action, source) -> the same, split by the acting product
_buckets = {}        # dedupe: bucket key -> (count already counted, first-seen epoch)

# Buckets are datetime-anchored, so a bucket older than the lookback can never be re-reported.
# 1800s is 6x the lookback and 15x the poll interval — generous, and it bounds memory.
BUCKET_TTL_SECONDS = 1800


def _accumulate(key, count, now):
    """Return the INCREASE for one datetime-anchored bucket, remembering what was counted.

    Overlapping poll windows re-report the same bucket; only its growth is new. Adaptive
    sampling can also revise a bucket DOWN between polls — a negative delta is dropped rather
    than subtracted, because a counter must never go backwards."""
    seen, first = _buckets.get(key, (0, now))
    _buckets[key] = (max(seen, count), first)
    return max(0, count - seen)


def _prune_buckets(now):
    """Forget buckets the API can no longer re-report, so the dedupe map stays bounded."""
    for key in [k for k, (_c, first) in _buckets.items() if now - first > BUCKET_TTL_SECONDS]:
        del _buckets[key]


def _reset_totals():
    """Drop all cumulative state. Self-test only — each fixture case starts from a fresh process."""
    _totals_req.clear()
    _totals_cached.clear()
    _totals_fw.clear()
    _totals_fw_src.clear()
    _buckets.clear()


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
                count
                dimensions {
                  datetime
                  clientRequestHTTPHost
                  edgeResponseStatus
                  cacheStatus
                }
                sum {
                  edgeResponseBytes
                }
              }
              firewallEventsAdaptive(
                limit: 10000
                filter: {datetime_gt: $start, datetime_lt: $end}
                orderBy: [datetime_DESC]
              ) {
                datetime
                clientRequestHTTPHost
                action
                source
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
    # GraphQL envelope: {"data": …, "errors": null} — there is NO REST `success` field here
    # (that guard raised on every response, #1340 residual). Errors are the signal.
    if payload.get("errors"):
        raise RuntimeError(f"GraphQL query → errors: {payload['errors']}")
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

    probe_ok = []  # (zone label, 1|0) — emitted after the counters, one row per CONFIGURED zone
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

            # Accumulate into the cumulative counters, deduped by each row's own datetime
            # bucket so the overlapping poll windows cannot double-count.
            for row in requests_rows:
                dims = row.get("dimensions", {})
                host = dims.get("clientRequestHTTPHost", "unknown")
                status = str(dims.get("edgeResponseStatus", "0"))
                cache = dims.get("cacheStatus") or "unknown"
                stamp = dims.get("datetime", "")
                delta = _accumulate(("req", zone_name, stamp, host, status, cache),
                                    row.get("count", 0), now)
                # setdefault BEFORE the delta: a label set seen with no growth still deserves a
                # series, and a host whose traffic is all misses must publish cached=0 rather
                # than nothing — else the consumer's rate(cached)/rate(requests) has no
                # numerator and the panel reads empty instead of "zero percent cached".
                _totals_req.setdefault((zone_name, host, status), 0)
                _totals_cached.setdefault((zone_name, host), 0)
                if delta:
                    _totals_req[(zone_name, host, status)] += delta
                    if cache.lower() in ("hit", "stale", "revalidated"):
                        _totals_cached[(zone_name, host)] += delta

            # firewallEventsAdaptive returns flat event rows (one per event), so a bucket's count
            # is the number of rows sharing a (datetime, host, action). Identical events within
            # one datetime are indistinguishable — which is exactly why the dedupe compares
            # COUNTS PER BUCKET instead of trying to remember individual events.
            fw_buckets = {}
            for row in firewall_rows:
                key = (row.get("datetime", ""),
                       row.get("clientRequestHTTPHost", "unknown"),
                       row.get("action", "unknown"))
                fw_buckets[key] = fw_buckets.get(key, 0) + 1
            for (stamp, host, action), count in sorted(fw_buckets.items()):
                delta = _accumulate(("fw", zone_name, stamp, host, action), count, now)
                label_key = (zone_name, host, action)
                _totals_fw[label_key] = _totals_fw.get(label_key, 0) + delta

            # The same events split by `source` — which product/rule phase acted. Deduped on its
            # own bucket key so the aggregate series above stays byte-identical.
            src_buckets = {}
            for row in firewall_rows:
                key = (row.get("datetime", ""),
                       row.get("clientRequestHTTPHost", "unknown"),
                       row.get("action", "unknown"),
                       row.get("source") or "unknown")
                src_buckets[key] = src_buckets.get(key, 0) + 1
            for (stamp, host, action, source), count in sorted(src_buckets.items()):
                delta = _accumulate(("fwsrc", zone_name, stamp, host, action, source), count, now)
                label_key = (zone_name, host, action, source)
                _totals_fw_src[label_key] = _totals_fw_src.get(label_key, 0) + delta

        except Exception as exc:
            failed += 1
            _errors += 1
            print(f"zone {zone_id}: edge poll failed: {exc}", flush=True)

        probe_ok.append((zone_name, 0 if failed else 1))

    _prune_buckets(now)

    # Emit EVERY label set ever seen, not just this window's — the churn fix. A counter that
    # stops incrementing HOLDS its value; it does not disappear. A zone that stops answering
    # therefore shows flat counters plus probe_ok=0, which is "stale", not "zero traffic".
    for (zone, host, status), value in sorted(_totals_req.items()):
        lines.append(metric("cloudflare_edge_requests_total",
                            {"zone": zone, "host": host, "status": status}, value))
    for (zone, host), value in sorted(_totals_cached.items()):
        lines.append(metric("cloudflare_edge_cached_requests_total",
                            {"zone": zone, "host": host}, value))
    for (zone, host, action), value in sorted(_totals_fw.items()):
        lines.append(metric("cloudflare_edge_rate_limit_events_total",
                            {"zone": zone, "host": host, "action": action}, value))
    for (zone, host, action, source), value in sorted(_totals_fw_src.items()):
        lines.append(metric("cloudflare_edge_firewall_events_host_action_source_total",
                            {"zone": zone, "host": host, "action": action, "source": source},
                            value))
    for zone_label, value in probe_ok:
        lines.append(metric("cloudflare_edge_probe_ok", {"zone": zone_label}, value))


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
        # The status line is NOT implied by send_header(): without send_response() the first
        # header goes out AS the status line and Prometheus reads `malformed HTTP status code
        # "text/plain;"` — every probe target down, both *ProbeBlind alerts firing (2026-09-03).
        self.send_response(200)
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
        "count": 42,
        "dimensions": {
            "datetime": "2026-09-02T18:50:00Z",
            "clientRequestHTTPHost": "mcp.minutark.ee",
            "edgeResponseStatus": 200,
            "cacheStatus": "miss",
        },
        "sum": {"edgeResponseBytes": 16384},
    },
    {
        "count": 5,
        "dimensions": {
            "datetime": "2026-09-02T18:50:00Z",
            "clientRequestHTTPHost": "mcp.minutark.ee",
            "edgeResponseStatus": 429,
            "cacheStatus": "unknown",
        },
        "sum": {"edgeResponseBytes": 512},
    },
    {
        "count": 100,
        "dimensions": {
            "datetime": "2026-09-02T18:50:00Z",
            "clientRequestHTTPHost": "minutark.ee",
            "edgeResponseStatus": 200,
            "cacheStatus": "hit",
        },
        "sum": {"edgeResponseBytes": 40960},
    },
]
_FLIPPED_FIREWALL = [
    {
        "datetime": "2026-09-02T18:50:00Z",
        "clientRequestHTTPHost": "mcp.minutark.ee",
        "action": "rate_limit",
        "source": "rateLimiter",
    },
    {
        "datetime": "2026-09-02T18:50:00Z",
        "clientRequestHTTPHost": "mcp.minutark.ee",
        "action": "rate_limit",
        "source": "rateLimiter",
    },
    {
        "datetime": "2026-09-02T18:50:00Z",
        "clientRequestHTTPHost": "mcp.minutark.ee",
        "action": "rate_limit",
        "source": "rateLimiter",
    },
    # Recorded 2026-09-24 (oracle handoff): the zone's "Block AI bots" managed rule 403-ing
    # GPTBot/ClaudeBot on the consumer host — the case the `source` split exists to name.
    {
        "datetime": "2026-09-02T18:50:00Z",
        "clientRequestHTTPHost": "minutark.ee",
        "action": "block",
        "source": "firewallManaged",
    },
    {
        "datetime": "2026-09-02T18:50:00Z",
        "clientRequestHTTPHost": "minutark.ee",
        "action": "block",
        "source": "firewallManaged",
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


def _exposition(requests_rows, firewall_rows, zone_ids=(_Z_PRODUCT,), reset=True):
    """One poll through the REAL collector.

    `reset=False` KEEPS the cumulative counters, which is how the multi-poll cases below
    exercise dedupe, persistence and monotonicity — the three properties the first cut's
    windowed-republish shape silently violated."""
    if reset:
        _reset_totals()
    lines = []
    collect(lines, fetch=_fixture_fetch(requests_rows, firewall_rows), zone_ids=list(zone_ids))
    return lines


def _handler_check(sample):
    """GET /metrics, /healthz, /nope through a REAL ThreadingHTTPServer on an ephemeral port. The
    fixtures above stop at the collector; this is the one seam that sees the STATUS LINE — which
    send_header() does not imply (2026-09-03: /metrics went out header-first, Prometheus read
    `malformed HTTP status code "text/plain;"`, every probe target down, both belts blind)."""
    global _body, _last_success
    import http.client
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    saved_body, saved_success = _body, _last_success
    try:
        with _lock:
            _body = f"# self-test exposition\n{sample}\n"

        def get(path):
            conn = http.client.HTTPConnection("127.0.0.1", srv.server_address[1], timeout=5)
            conn.request("GET", path)
            resp = conn.getresponse()
            data = resp.read()
            conn.close()
            return resp.status, resp.getheader("Content-Type") or "", data

        status, ctype, data = get("/metrics")
        assert status == 200, f"/metrics answered {status}, not 200"
        assert "version=0.0.4" in ctype, f"/metrics Content-Type {ctype!r} is not the exposition type"
        assert sample.encode() in data, "/metrics body must be the collector's exposition"
        _last_success = 0
        assert get("/healthz")[0] == 503, "/healthz must be 503 before the first successful poll"
        _last_success = time.time()
        assert get("/healthz")[0] == 200, "/healthz must be 200 after a fresh success"
        assert get("/nope")[0] == 404
    finally:
        srv.shutdown()
        srv.server_close()
        with _lock:
            _body = saved_body
        _last_success = saved_success


def _transport_check():
    """graphql_query() through a fake urlopen. The GraphQL envelope is {"data": …, "errors": null}
    — it has NO REST `success` field — and the collect(fetch=…) seam above cannot reach this guard
    by construction (#1340's residual: the fixture rewrite was green while every live poll raised)."""
    import io

    class _Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def fake(payload):
        return lambda req, timeout=None: _Resp(json.dumps(payload).encode())

    real = urllib.request.urlopen
    try:
        urllib.request.urlopen = fake({"data": {"viewer": {"zones": [{
            "httpRequestsAdaptiveGroups": _FLIPPED_REQUESTS,
            "firewallEventsAdaptive": _FLIPPED_FIREWALL,
        }]}}, "errors": None})
        req_rows, fw_rows = graphql_query(_Z_PRODUCT, "2026-09-02T18:45:00Z", "2026-09-02T18:50:00Z")
        assert req_rows == _FLIPPED_REQUESTS and fw_rows == _FLIPPED_FIREWALL, \
            "a clean GraphQL envelope (errors: null, no success field) must yield the rows"
        urllib.request.urlopen = fake({"data": None, "errors": [{"message": 'unknown field "requests"'}]})
        try:
            graphql_query(_Z_PRODUCT, "a", "b")
            raise AssertionError("a non-empty errors list must raise")
        except RuntimeError as exc:
            assert "unknown field" in str(exc), f"the raise must carry the API's message: {exc}"
    finally:
        urllib.request.urlopen = real


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
    assert not any(l.startswith("cloudflare_edge_cached_requests_total{") for l in body.splitlines()), \
        "quiet state must emit no cached-request data series"
    assert not any(l.startswith("cloudflare_edge_firewall_events_host_action_source_total{")
                   for l in body.splitlines()), \
        "quiet state must emit no firewall-source data series"

    # 2. Flipped fixture → traffic with cache misses and rate-limit events.
    flipped = _exposition(_FLIPPED_REQUESTS, _FLIPPED_FIREWALL)
    body = "\n".join(flipped)
    for sample in (
        'cloudflare_edge_requests_total{host="mcp.minutark.ee",status="200",zone="minutark.ee"} 42',
        'cloudflare_edge_requests_total{host="mcp.minutark.ee",status="429",zone="minutark.ee"} 5',
        'cloudflare_edge_requests_total{host="minutark.ee",status="200",zone="minutark.ee"} 100',
        'cloudflare_edge_cached_requests_total{host="minutark.ee",zone="minutark.ee"} 100',
        'cloudflare_edge_cached_requests_total{host="mcp.minutark.ee",zone="minutark.ee"} 0',
        'cloudflare_edge_rate_limit_events_total{action="rate_limit",host="mcp.minutark.ee",zone="minutark.ee"} 3',
        'cloudflare_edge_rate_limit_events_total{action="block",host="minutark.ee",zone="minutark.ee"} 2',
        'cloudflare_edge_firewall_events_host_action_source_total{action="rate_limit",host="mcp.minutark.ee",source="rateLimiter",zone="minutark.ee"} 3',
        'cloudflare_edge_firewall_events_host_action_source_total{action="block",host="minutark.ee",source="firewallManaged",zone="minutark.ee"} 2',
        'cloudflare_edge_probe_ok{zone="minutark.ee"} 1',
    ):
        assert sample in body, f"missing sample: {sample}\n--- exposition ---\n{body}"

    # 2b. DEDUPE — the same bucket polled twice must not double-count. In production every
    # bucket IS re-reported: the lookback is 300s against a 120s poll, so windows overlap 2.5x
    # and the first cut added each bucket again on every pass.
    _exposition(_FLIPPED_REQUESTS, _FLIPPED_FIREWALL)                           # poll 1 (resets)
    twice = "\n".join(_exposition(_FLIPPED_REQUESTS, _FLIPPED_FIREWALL, reset=False))   # poll 2
    for sample in (
        'cloudflare_edge_requests_total{host="mcp.minutark.ee",status="200",zone="minutark.ee"} 42',
        'cloudflare_edge_requests_total{host="minutark.ee",status="200",zone="minutark.ee"} 100',
        'cloudflare_edge_rate_limit_events_total{action="rate_limit",host="mcp.minutark.ee",zone="minutark.ee"} 3',
        'cloudflare_edge_firewall_events_host_action_source_total{action="block",host="minutark.ee",source="firewallManaged",zone="minutark.ee"} 2',
    ):
        assert sample in twice, (
            "re-polling an already-counted bucket changed its total — dedupe is broken.\n"
            f"missing: {sample}\n--- exposition ---\n{twice}")

    # 2c. PERSISTENCE — a label set absent from the CURRENT window keeps its series. This is
    # the churn defect: measured live 2026-09-17, an instant query found the series only 26% of
    # the time, which is what led oracle-fleet#572's author to assert merely that the query
    # parses (the series looked absent, so the panel was never given a real assertion).
    quiet_after = "\n".join(_exposition(_TODAY_REQUESTS, _TODAY_FIREWALL, reset=False))
    assert 'cloudflare_edge_requests_total{host="minutark.ee",status="200",zone="minutark.ee"} 100' in quiet_after, (
        "a counter must HOLD its value when its label set leaves the window\n"
        f"--- exposition ---\n{quiet_after}")

    # 2d. MONOTONICITY — a NEW datetime bucket adds; a bucket the API revises DOWN (adaptive
    # sampling does this) must never decrement.
    later = [dict(_FLIPPED_REQUESTS[0], dimensions=dict(
        _FLIPPED_REQUESTS[0]["dimensions"], datetime="2026-09-02T18:51:00Z"))]
    grew = "\n".join(_exposition(later, [], reset=False))
    assert 'cloudflare_edge_requests_total{host="mcp.minutark.ee",status="200",zone="minutark.ee"} 84' in grew, (
        "a new datetime bucket must ADD to the total (42 + 42)\n"
        f"--- exposition ---\n{grew}")
    revised = [dict(_FLIPPED_REQUESTS[0], count=1)]  # same bucket, sampled lower
    held = "\n".join(_exposition(revised, [], reset=False))
    assert 'cloudflare_edge_requests_total{host="mcp.minutark.ee",status="200",zone="minutark.ee"} 84' in held, (
        "a downward-revised bucket must never decrement a counter\n"
        f"--- exposition ---\n{held}")

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
    _reset_totals()
    broken_lines = []
    collect(broken_lines, fetch=_fixture_fetch_failing(), zone_ids=[_Z_PRODUCT])
    broken = samples_of(broken_lines)
    # Checked against the RAW lines, not samples_of(): that parser only captures zone-only
    # series, so the old `series == "cloudflare_edge_requests_total"` form could never have
    # matched a host/status-labelled sample and passed vacuously.
    assert not any(l.startswith("cloudflare_edge_requests_total{") for l in broken_lines), \
        "a failed read with no prior data must emit NO request series"
    assert broken[("cloudflare_edge_probe_ok", _Z_PRODUCT)] == 0
    assert firing_zones(exprs[blind], broken) == {_Z_PRODUCT}
    assert _errors == before + 1, \
        "a failed read must count toward cloudflare_edge_probe_errors_total"
    _errors = before

    # 6b. A failure AFTER data has been seen KEEPS the counters and flips probe_ok. Holding the
    # last value is correct counter behaviour; probe_ok is the only thing that can tell a
    # consumer those flat counters are stale rather than genuinely idle.
    before = _errors
    _exposition(_FLIPPED_REQUESTS, _FLIPPED_FIREWALL)
    stale_lines = []
    collect(stale_lines, fetch=_fixture_fetch_failing(), zone_ids=[_Z_PRODUCT])
    stale = "\n".join(stale_lines)
    assert 'cloudflare_edge_requests_total{host="minutark.ee",status="200",zone="minutark.ee"} 100' in stale, (
        f"counters must survive a failed poll\n--- exposition ---\n{stale}")
    assert f'cloudflare_edge_probe_ok{{zone="{_Z_PRODUCT}"}} 0' in stale, \
        "a failed poll must still emit probe_ok=0 for the configured zone"
    assert _errors == before + 1
    _errors = before
    _reset_totals()

    # 7. A probe that is gone entirely fires the blind alert through its absent() arm.
    assert firing_zones(exprs[blind], {}) == {"<absent>"}, \
        f"{blind} must survive the series disappearing: {exprs[blind]!r}"

    # 8. The HTTP handler over a real socket — status line, exposition type, healthz gate.
    _handler_check('cloudflare_edge_probe_ok{zone="minutark.ee"} 1')

    # 9. The GraphQL transport guard through a fake urlopen — the seam the fixtures cannot reach.
    _transport_check()

    print("cloudflare edge-probe self-test: OK (parser, handler over a real socket, GraphQL "
          "transport guard, today's exposition, counter semantics — dedupe across overlapping "
          "windows, persistence when a label set leaves the window, monotonicity under a "
          f"downward-revised bucket, survival of a failed poll — and the committed {blind} expr "
          "replayed against flipped + blind fixtures; the retired CloudflareEdge5xx asserted "
          "absent)")
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