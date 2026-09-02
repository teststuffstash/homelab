#!/usr/bin/env python3
"""Cloudflare spend-toggle drift probe → Prometheus (homelab#217).

WHY this exists: the Cloudflare account has a payment card attached, and with a card on file a
plan change bills silently. This is the BELT: it cannot prevent the change, it makes it loud.
Purchase-shaped spend is otherwise closed — no token carries Billing groups (`devbox run
cloudflare-token-audit`). Design + doctrine: docs/cloudflare.md §Spend surface.

⚠ THE ARGO LEG WAS RETIRED 2026-08-12 (it shipped assuming `PATCH /zones/{id}/argo/smart_routing`
was gated by Zone Settings Write). The host-side admin-token session settled it: the argo
endpoint answers 1015 `Cause(s): smart_routing` to EVERY mintable scope — admin, Zone Settings
Read+Write, and the legacy all-read-groups template alike — no Argo permission group exists in
the catalog, and the endpoint docs name no accepted-permissions line. The setting is
ENTITLEMENT-gated, not permission-gated: no credential we hold can read OR write it, so a leg
polling it can only ever be blind (it spent 3 days raising per poll), and "1015 ⇒ off" cannot be
verified without buying the entitlement. Conservative option taken: the leg is gone, the
dashboard-toggle residual is caught by the audit log (`Account Settings Read` on the
observability token — an on-demand jail read, docs/cloudflare.md §spend surface has the verdict
table). What remains here is the PLAN gauge + probe_ok.

WHY a second poller in `monitoring` and not a change to the exporter next door: that exporter is
upstream `ghcr.io/lablabs/cloudflare_exporter` — a third-party binary with none of our code in it,
so it cannot grow these gauges. The one-poller doctrine still holds: same namespace, same
credential (the ESO-delivered `cloudflare-exporter-token` ← Infisical CLOUDFLARE_OBSERVABILITY_READ,
which carries Zone Settings READ), different API surface — the exporter polls GraphQL analytics,
this polls the zone-settings REST surface. NOT routed through `cf-api-proxy`: that allowlist
deliberately 403s `argo/*` and settings paths, and injects a different token.

⚠ It also covers a zone the exporter structurally cannot see: `CF_EXCLUDE_ZONES` drops
teststuff.net from the exporter's batched query (#132), so both product zone ids are configured
here explicitly and independently of that exclusion.

Runs from a ConfigMap on a stock python image (spend-probe-deployment.yaml next to this file;
kustomize's configMapGenerator hash rolls the pod on edits) — stdlib only, no state, each poll
re-reads the full truth. Same shape as github-exporter.py and openrouter-proxy/router.py.

Config (env): CF_API_TOKEN (Zone Settings Read on the configured zones), CF_SPEND_ZONE_IDS
(comma-separated zone ids), POLL_INTERVAL_SECONDS (120), LISTEN_PORT (9505).

Self-test (no network, no credential):
    python3 argocd/resources/cloudflare-exporter/spend-probe.py --self-test
It replays recorded API shapes — today's and a FLIPPED one — through the real collector AND
through the alert expressions scraped out of the committed prometheusrule.yaml. See §self-test
for exactly what that does and does not prove.
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

API = "https://api.cloudflare.com/client/v4"

TOKEN = os.environ.get("CF_API_TOKEN", "").strip()
# The two PRODUCT zones (ids are not secrets — the sibling deployment already carries one in
# plain env). eid-demo.com is deliberately OUT of scope: it is legitimately Pro, sits outside
# every write token's zone map, and is not homelab's to watch.
ZONE_IDS = [z.strip() for z in os.environ.get("CF_SPEND_ZONE_IDS", "").split(",") if z.strip()]
# Drift detection, not latency-sensitive: matched to the sibling exporter's 120s scrape rather
# than tuned. One GET per zone per poll — negligible against Cloudflare's 1200/5min limit.
INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "120"))
PORT = int(os.environ.get("LISTEN_PORT", "9505"))

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
    "# HELP cloudflare_zone_plan_is_free 1 when the zone's plan.legacy_id is \"free\", else 0.",
    "# TYPE cloudflare_zone_plan_is_free gauge",
    "# HELP cloudflare_zone_spend_probe_ok 1 when BOTH spend reads succeeded for the zone this poll. 0 or absent means the gauges above are unknown, NOT safe.",
    "# TYPE cloudflare_zone_spend_probe_ok gauge",
]


def api_get(path):
    """GET a Cloudflare v4 path and return `result`. Raises on transport or envelope failure."""
    req = urllib.request.Request(
        API + path,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/json",
            "User-Agent": "homelab-cloudflare-spend-probe",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as exc:  # the body carries Cloudflare's error code + message
        raise RuntimeError(f"GET {path} → HTTP {exc.code}: {exc.read()[:300]!r}") from None
    if not payload.get("success"):
        raise RuntimeError(f"GET {path} → success=false: {payload.get('errors')}")
    return payload.get("result")


def esc(value):
    return str(value).replace("\\", r"\\").replace('"', r"\"").replace("\n", r"\n")


def metric(name, labels, value):
    inner = ",".join(f'{k}="{esc(v)}"' for k, v in sorted(labels.items()))
    return f"{name}{{{inner}}} {value}"


def plan_is_free(result):
    """Same asymmetry: an unreadable plan must not render as "not free" (a false page) NOR as
    "free" (a false all-clear) — it raises, and the blind alert owns the case."""
    legacy = str(((result or {}).get("plan") or {}).get("legacy_id", "")).strip().lower()
    if not legacy:
        raise ValueError("zone result carries no plan.legacy_id")
    return 1 if legacy == "free" else 0


def collect(lines, fetch=api_get, zone_ids=None):
    """Emit the three per-zone gauges. Every configured zone emits `spend_probe_ok` no matter
    what failed, so a zone that silently stops answering is visible as a zone, not as a gap."""
    global _errors
    lines += HEADERS
    for zone_id in zone_ids if zone_ids is not None else ZONE_IDS:
        # Label value is the zone NAME from the API; a zone whose name lookup fails falls back to
        # its id so the sample is never dropped (an id label is still unambiguous, just uglier).
        zone, failed = zone_id, 0
        try:
            result = fetch(f"/zones/{zone_id}")
            zone = str((result or {}).get("name") or zone_id)
            lines.append(metric("cloudflare_zone_plan_is_free", {"zone": zone}, plan_is_free(result)))
        except Exception as exc:
            failed += 1
            _errors += 1
            print(f"zone {zone_id}: plan read failed: {exc}", flush=True)
        lines.append(metric("cloudflare_zone_spend_probe_ok", {"zone": zone}, 0 if failed else 1))


def poll_forever():
    global _body, _last_success
    while True:
        lines, before = [], _errors
        try:
            collect(lines)
        except Exception as exc:  # collect() swallows per-zone failures; this is the unexpected rest
            print(f"collect failed: {exc}", flush=True)
        if _errors == before and ZONE_IDS:
            _last_success = int(time.time())
        lines += [
            "# TYPE cloudflare_spend_probe_errors_total counter",
            f"cloudflare_spend_probe_errors_total {_errors}",
            "# HELP cloudflare_spend_probe_last_success_timestamp Epoch of the last poll where every configured zone read cleanly.",
            "# TYPE cloudflare_spend_probe_last_success_timestamp gauge",
            f"cloudflare_spend_probe_last_success_timestamp {_last_success}",
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
# Same shape as `router.py --self-test` / `github-exporter.py --self-test`, and it carries the
# acceptance criterion "the rule fires in a replay with a flipped fixture" as far as this repo's
# toolbox allows.
#
# ⚠ HONESTY, because a check that overstates itself is the failure class this platform keeps
# paying for (FU-108/FU-125/FU-131): this is NOT `promtool test rules`. promtool is not in this
# repo's devbox.json and adding it is outside the fixer's write ceiling (devbox.json and the
# CI-invoked scripts/ are off-limits to an agent branch — CI would run them FROM that branch), so
# there is no time-series replay and no `for:` duration is exercised here.
#
# What it DOES prove, which is the part that actually breaks: the alert expressions are read out
# of the COMMITTED prometheusrule.yaml — not restated here — and evaluated against the exposition
# the REAL collector builds from recorded API shapes. A metric renamed on one side only, an
# inverted gauge polarity (`plan_is_free == 0` vs `> 0`), a comparison against the wrong constant,
# or a zone that stops emitting all fail this. The evaluator understands EXACTLY two expression
# forms and RAISES on anything else, so an expr it cannot model can never pass silently.
#
# ⚠ …and since homelab#334 those two forms may carry the restart-gap BRIDGE
# (`max|min by (zone) (max|min_over_time(<metric>[10m]))`, plus `absent(…_over_time(…))`). Over the
# ONE instant this evaluator models, a bridge is a no-op — a range function over a single sample is
# that sample, and `by (zone)` over one series per zone is the identity — so it is stripped before
# the arm is evaluated and everything above still holds unchanged. What that also means is that the
# one thing this evaluator structurally CANNOT see is the direction: at one instant `min_over_time`
# and `max_over_time` are the same number, while in production the wrong one delays a real plan
# upgrade by the whole range. So the direction and the range are pinned as literals in step 3b
# instead of inferred, and the behaviour over time — `for:` windows, scrape holes, the absent() arm
# transition — belongs to `promtool test rules` over spend-belt.promtool-test beside this file
# (`devbox run prometheus-rules-lint`). Neither check subsumes the other.

_Z_PLATFORM = "6b63f95592a9e036f8b8f6934511d321"  # teststuff.net
_Z_PRODUCT = "fa1b02951c29ee4828b8948d0dd7baaf"  # minutark.ee

# Recorded response shapes. TODAY = the state the issue records as current (plan free, both zones).
_TODAY = {
    f"/zones/{_Z_PLATFORM}": {"id": _Z_PLATFORM, "name": "teststuff.net",
                              "plan": {"legacy_id": "free", "name": "Free Website"}},
    f"/zones/{_Z_PRODUCT}": {"id": _Z_PRODUCT, "name": "minutark.ee",
                             "plan": {"legacy_id": "free", "name": "Free Website"}},
}
# FLIPPED: someone moved the product zone off free while the platform zone stays put — one
# drifted zone and one quiet one, so the test also proves the alert selects the RIGHT zone.
_FLIPPED = json.loads(json.dumps(_TODAY))
_FLIPPED[f"/zones/{_Z_PRODUCT}"]["plan"] = {"legacy_id": "pro", "name": "Pro Website"}

RULE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prometheusrule.yaml")

_ALERT_RE = re.compile(r"^\s*-\s*alert:\s*(\S+)\s*$")
_EXPR_RE = re.compile(r"^\s*expr:\s*(.+?)\s*$")
_SAMPLE_RE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)\{zone="([^"]*)"\}\s+(-?[\d.]+)$')
_CMP_RE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)\s*(==|!=|>=|<=|>|<)\s*(-?[\d.]+)$")
_ABSENT_RE = re.compile(r"^absent\(([a-zA-Z_:][a-zA-Z0-9_:]*)\)$")
_OPS = {"==": lambda a, b: a == b, "!=": lambda a, b: a != b, ">": lambda a, b: a > b,
        ">=": lambda a, b: a >= b, "<": lambda a, b: a < b, "<=": lambda a, b: a <= b}
# The homelab#334 restart-gap wrapper, in the only two places it appears. `zone` is hard-coded on
# purpose: it is the one label on these series that does NOT churn when the pod is replaced, and
# grouping by anything else (`job`, `instance`) either collapses the two product zones into one
# alert or keeps the churn the bridge exists to remove.
_BRIDGE_CMP_RE = re.compile(
    r"^(max|min) by \(zone\) \((max|min)_over_time\(([a-zA-Z_:][a-zA-Z0-9_:]*)\[(\d+[smhdwy])\]\)\)"
    r"\s*(==|!=|>=|<=|>|<)\s*(-?[\d.]+)$")
_BRIDGE_ABSENT_RE = re.compile(
    r"^absent\((max|min)_over_time\(([a-zA-Z_:][a-zA-Z0-9_:]*)\[(\d+[smhdwy])\]\)\)$")


def unbridge(arm):
    """One expr arm → (the arm with any #334 bridge stripped, (direction, range) or None).

    A bridge is a no-op over the single instant this evaluator models, so stripping it lets the two
    modelled forms below stay exactly as narrow as they were. The one thing checked here rather
    than ignored is coherence: an outer `max by (zone)` over an inner `min_over_time` (or the
    reverse) reads opposite ends of the same window, which is homelab#331's direction bug written
    into one expression, and it raises."""
    match = _BRIDGE_ABSENT_RE.match(arm)
    if match:
        return f"absent({match.group(2)})", (match.group(1), match.group(3))
    match = _BRIDGE_CMP_RE.match(arm)
    if match:
        agg, over, name, window, op, threshold = match.groups()
        if agg != over:
            raise AssertionError(
                f"bridged arm mixes directions — `{agg} by (zone)` over `{over}_over_time` in "
                f"{arm!r}: the aggregation and the range function must agree, or one of them is "
                "reading the wrong end of the window (the homelab#331 direction bug)")
        return f"{name} {op} {threshold}", (agg, window)
    return arm, None


def bridges(expr):
    """Every arm's (direction, range), None where an arm carries no #334 bridge at all."""
    return [unbridge(arm.strip())[1] for arm in expr.split(" or ")]


def rule_exprs(path=RULE_FILE):
    """alert name → expr, line-scanned out of the committed PrometheusRule. A line scan and not a
    YAML parse on purpose: the pod image is stdlib-only (no PyYAML) and vendoring a parser for a
    two-key lookup is worse than a regex the caller proves found what it expected."""
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
    """The set of `zone` labels an expr selects over one instant of samples.

    Supported: `<metric> <cmp> <number>` and `absent(<metric>)`, joined by ` or `, each optionally
    wrapped in the #334 restart-gap bridge (see unbridge). Anything else raises — an evaluator that
    shrugs at an expression it does not understand would report green on a rule it never checked."""
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


def _fixture_fetch(table):
    def fetch(path):
        if path not in table:
            raise RuntimeError(f"fixture has no {path}")
        return table[path]
    return fetch


def _exposition(table, zone_ids=(_Z_PLATFORM, _Z_PRODUCT)):
    lines = []
    collect(lines, fetch=_fixture_fetch(table), zone_ids=list(zone_ids))
    return lines


def self_test():
    """`python3 spend-probe.py --self-test` — recorded fixtures through the real collector, then
    through the committed alert expressions."""
    global _errors

    # 1. Parser: an unreadable field is an error, never a reading.
    assert plan_is_free({"plan": {"legacy_id": "free"}}) == 1
    assert plan_is_free({"plan": {"legacy_id": "pro"}}) == 0
    for bad in ({}, {"plan": {}}, {"plan": None}, None):
        try:
            plan_is_free(bad)
            raise AssertionError(f"plan_is_free({bad!r}) must raise, not guess")
        except ValueError:
            pass

    # 2. Today's fixture → the exact samples the issue's acceptance names (plan free, both zones).
    today = _exposition(_TODAY)
    body = "\n".join(today)
    for sample in (
        'cloudflare_zone_plan_is_free{zone="teststuff.net"} 1',
        'cloudflare_zone_plan_is_free{zone="minutark.ee"} 1',
        'cloudflare_zone_spend_probe_ok{zone="teststuff.net"} 1',
        'cloudflare_zone_spend_probe_ok{zone="minutark.ee"} 1',
    ):
        assert sample in body, f"missing sample: {sample}\n--- exposition ---\n{body}"

    # 3. The committed rules, read from disk — the test states the names it expects so a rename
    #    or a deleted alert fails here instead of silently reducing coverage.
    exprs = rule_exprs()
    plan, blind = ("CloudflareZonePlanNotFree", "CloudflareSpendProbeBlind")
    for name in (plan, blind):
        assert name in exprs, f"{name} is not in {RULE_FILE} (renamed? deleted?): {sorted(exprs)}"
    # …and the retired one STAYS retired: its input metric no longer exists, so a re-added rule
    # would be born permanently silent while looking like coverage (the argo leg, 2026-08-12).
    assert "CloudflareZoneSpendToggleEnabled" not in exprs, \
        "CloudflareZoneSpendToggleEnabled was retired with the argo leg (entitlement-gated, " \
        "2026-08-12) — its input series is never emitted, so this rule cannot fire; re-adding " \
        "it needs the leg back first (docs/cloudflare.md §spend surface)"

    # 3b. The #334 restart-gap bridge, pinned as literals because this evaluator cannot infer it:
    #     over one instant `min_over_time` and `max_over_time` are the same number, so a direction
    #     flipped here would be silent — and 10 minutes late in production, on the two LOW-is-bad
    #     gauges (spend-belt.promtool-test §2/7 executes exactly that). Every arm must be bridged:
    #     CloudflareSpendProbeBlind's absent() arm included, since an unbridged one swaps the
    #     alert's identity for a label-less one at every roll, which is a `for:` restart by another
    #     route (§3/7). Widening the range is a deliberate change, so it fails here too.
    for name, want in ((plan, ("min", "10m")), (blind, ("min", "10m"))):
        got = bridges(exprs[name])
        assert got and all(bridge == want for bridge in got), \
            f"{name} must bridge EVERY arm with {want[0]} by (zone) / {want[0]}_over_time[{want[1]}]" \
            f" — got {got} in {exprs[name]!r}"

    # 4. Replay: today's state is quiet, on every rule.
    quiet = samples_of(today)
    for name in (plan, blind):
        assert firing_zones(exprs[name], quiet) == set(), \
            f"{name} fires on today's state ({exprs[name]!r})"

    # 5. Replay: the flipped fixture fires — on the drifted zone only, never the quiet one.
    flipped = samples_of(_exposition(_FLIPPED))
    assert firing_zones(exprs[plan], flipped) == {"minutark.ee"}, firing_zones(exprs[plan], flipped)
    assert firing_zones(exprs[blind], flipped) == set(), "a drifted zone is still a READ zone"

    # 6. A zone that stops answering is blind, not silently safe: no gauge, probe_ok=0, and the
    #    blind alert names that zone while the plan alert stays quiet (nothing to assert on).
    #    The whole zone read fails here, so the name lookup does too — the zone label falls back
    #    to the id, which is the documented degradation (unambiguous, just uglier).
    before = _errors
    broken = samples_of(_exposition({}, zone_ids=(_Z_PLATFORM,)))
    assert not any(series == "cloudflare_zone_plan_is_free" for series, _ in broken), \
        "a failed read must emit NO gauge — an absent sample, never a fabricated value"
    assert broken[("cloudflare_zone_spend_probe_ok", _Z_PLATFORM)] == 0
    assert firing_zones(exprs[blind], broken) == {_Z_PLATFORM}
    assert firing_zones(exprs[plan], broken) == set()
    assert _errors == before + 1, "a failed read must count toward cloudflare_spend_probe_errors_total"
    _errors = before

    # 7. …and a probe that is gone entirely (pod dead, ESO secret pulled) fires the blind alert
    #    through its absent() arm. This is the FU-150 lesson: absence is the alert.
    assert firing_zones(exprs[blind], {}) == {"<absent>"}, \
        f"{blind} must survive the series disappearing: {exprs[blind]!r}"

    print("cloudflare spend-probe self-test: OK (parser, today's exposition, and the committed "
          f"{plan}/{blind} exprs replayed against flipped + blind fixtures; the retired argo "
          "leg asserted absent)")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    if not TOKEN:
        sys.exit("cloudflare-spend-probe: CF_API_TOKEN is empty/unset — refusing to start")
    if not ZONE_IDS:
        sys.exit("cloudflare-spend-probe: CF_SPEND_ZONE_IDS is empty — refusing to start blind")
    threading.Thread(target=poll_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
