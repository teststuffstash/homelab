#!/usr/bin/env python3
"""Credential-expiry belt, Cloudflare leg → Prometheus (FU-156).

WHY this exists: every minted credential here carries a ≤1-year TTL on purpose, and a tracker
line saying "renew X before January" relies on a human reading it in time. Expiry is TELEMETRY:
one gauge, one alert, the same shape blackbox's `probe_ssl_earliest_cert_expiry` gives certs.
Design: docs/secrets.md §Credential expiry is telemetry, not documentation.

    credential_expiry_timestamp_seconds{provider="cloudflare", credential="<token name>"}

One series per token returned by `GET /user/tokens` that HAS an `expires_on`. A never-expiring
token emits NOTHING on this gauge — there is no date to alert on, and a sentinel value (0, +Inf)
would only be something every expr has to filter out. Absence on this gauge therefore means
"no expiry", which is exactly why it must never ALSO be able to mean "poller dead" — that is
`credential_expiry_probe_ok` (FU-150's silent-expiry class: absence is never agreement). It is
computed at SCRAPE time: 1 only when the last poll succeeded, listed ≥1 token, and is younger
than 3 poll intervals — so a hung poll loop behind a live HTTP server reads 0, not stale-1.

Credential: `homelab-token-inventory-read` (User: API Tokens: Read — user-scoped, so the
observability token beside it cannot carry it; tofu/cloudflare-token/inventory-read.tf), wallet
`cloudflare-inventory-read` → Infisical CLOUDFLARE_INVENTORY_READ → ESO Secret
`cloudflare-inventory-read` (credential-expiry-externalsecret.yaml). It lists token METADATA
(names, status, expiry); no endpoint it can reach returns a token value.

Token statuses: `active` and `expired` emit (an expired token is the alert's loudest case — the
value is in the past); `disabled` tokens are switched off deliberately and emit nothing. Two
tokens sharing a name get the token-id prefix appended so neither series collides.

Declared-expiry credentials (client .p12s, classic PATs) are NOT this file's — they are the
belt's second half (FU-156) and will emit the same metric under their own `provider`.

Runs from a ConfigMap on a stock python image (the spend-probe pattern beside this file) —
stdlib only, no state. Config (env): CF_API_TOKEN, POLL_INTERVAL_SECONDS (600), LISTEN_PORT (9507).

Self-test (no network, no credential):
    python3 argocd/resources/cloudflare-exporter/credential-expiry-probe.py --self-test
Covers the collector (parsing, skip rules, pagination, duplicates, probe_ok). Alert behaviour
over time is credential-expiry.promtool-test (`devbox run prometheus-rules-lint`).
"""

import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API = "https://api.cloudflare.com/client/v4"
PROVIDER = "cloudflare"

TOKEN = os.environ.get("CF_API_TOKEN", "").strip()
# Expiries move on a scale of months; 10 min keeps the probe_ok signal fresh at one GET/poll.
INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "600"))
PORT = int(os.environ.get("LISTEN_PORT", "9507"))
STALE_AFTER = 3 * INTERVAL

_lock = threading.Lock()
_series = []          # rendered expiry lines from the last SUCCESSFUL poll
_counts = (0, 0)      # (tokens listed, tokens with an expiry) from the last successful poll
_last_success = 0
_last_ok = False
_errors = 0


def api_get(path):
    """GET a Cloudflare v4 path; return the whole envelope. Raises on transport/envelope failure."""
    req = urllib.request.Request(API + path, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/json",
        "User-Agent": "homelab-credential-expiry-probe",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"GET {path} → HTTP {exc.code}: {exc.read()[:300]!r}") from None
    if not payload.get("success"):
        raise RuntimeError(f"GET {path} → success=false: {payload.get('errors')}")
    return payload


def list_tokens(fetch=api_get):
    tokens, page = [], 1
    while True:
        env = fetch(f"/user/tokens?per_page=50&page={page}")
        tokens += env.get("result") or []
        info = env.get("result_info") or {}
        if page >= int(info.get("total_pages") or 1):
            return tokens
        page += 1


def parse_ts(value):
    return int(datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp())


def esc(value):
    return str(value).replace("\\", r"\\").replace('"', r"\"").replace("\n", r"\n")


def expiry_lines(tokens):
    """→ (lines, n_with_expiry). Raises if an expires_on is unparseable (a token whose date we
    cannot read must not silently drop out of the belt — the poll fails, probe_ok goes 0)."""
    names = [t.get("name") or t.get("id", "?") for t in tokens]
    lines = []
    for tok, name in zip(tokens, names):
        if not tok.get("expires_on") or str(tok.get("status", "")).lower() == "disabled":
            continue
        if names.count(name) > 1:
            name = f"{name} ({str(tok.get('id', ''))[:8]})"
        lines.append(f'credential_expiry_timestamp_seconds{{provider="{PROVIDER}",'
                     f'credential="{esc(name)}"}} {parse_ts(tok["expires_on"])}')
    return sorted(lines), len(lines)


def poll_once(fetch=api_get):
    global _series, _counts, _last_success, _last_ok, _errors
    try:
        tokens = list_tokens(fetch)
        if not tokens:  # the inventory token lists itself — zero means a broken read, not "none"
            raise RuntimeError("token list is empty")
        lines, n = expiry_lines(tokens)
        with _lock:
            _series, _counts, _last_success, _last_ok = lines, (len(tokens), n), int(time.time()), True
    except Exception as exc:
        with _lock:
            _last_ok = False
            _errors += 1
        print(f"poll failed: {exc}", flush=True)


def probe_ok(now=None):
    now = time.time() if now is None else now
    return 1 if _last_ok and _last_success and now - _last_success <= STALE_AFTER else 0


def render(now=None):
    p = f'provider="{PROVIDER}"'
    with _lock:
        ok = probe_ok(now)
        body = [
            "# HELP credential_expiry_timestamp_seconds Unix time a credential expires. Never-expiring credentials emit no series.",
            "# TYPE credential_expiry_timestamp_seconds gauge",
            *_series,
            "# HELP credential_expiry_probe_ok 1 when the last poll succeeded and is fresh (<3 poll intervals). 0 or absent = the expiry gauge is UNKNOWN, not clear.",
            "# TYPE credential_expiry_probe_ok gauge",
            f"credential_expiry_probe_ok{{{p}}} {ok}",
            "# HELP credential_expiry_probe_last_success_timestamp_seconds Unix time of the last successful poll.",
            "# TYPE credential_expiry_probe_last_success_timestamp_seconds gauge",
            f"credential_expiry_probe_last_success_timestamp_seconds{{{p}}} {_last_success}",
            "# HELP credential_expiry_credentials_listed Credentials the provider listed on the last successful poll.",
            "# TYPE credential_expiry_credentials_listed gauge",
            f"credential_expiry_credentials_listed{{{p}}} {_counts[0]}",
            "# HELP credential_expiry_credentials_expiring Listed credentials that carry an expiry (= series on the gauge above).",
            "# TYPE credential_expiry_credentials_expiring gauge",
            f"credential_expiry_credentials_expiring{{{p}}} {_counts[1]}",
            "# TYPE credential_expiry_probe_errors_total counter",
            f"credential_expiry_probe_errors_total{{{p}}} {_errors}",
        ]
    return "\n".join(body) + "\n"


def poll_forever():
    while True:
        poll_once()
        time.sleep(INTERVAL)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/metrics", "/healthz", "/"):
            self.send_error(404)
            return
        if self.path == "/healthz":
            ok = probe_ok()
            body = b"ok\n" if ok else b"stale\n"
            self.send_response(200 if ok else 503)
            ctype = "text/plain; charset=utf-8"
        else:
            body = render().encode()
            self.send_response(200)  # see spend-probe.py: without it the first header IS the status line
            ctype = "text/plain; version=0.0.4; charset=utf-8"
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def self_test():
    global _last_ok, _last_success, _series, _counts
    t = lambda name, exp, status="active", id_="0123456789ab": {
        "id": id_, "name": name, "status": status, "expires_on": exp}
    page1 = {"success": True, "result_info": {"page": 1, "total_pages": 2}, "result": [
        t("homelab-acme-dns", "2027-01-01T00:00:00Z"),
        t("Create Additional Tokens", "2027-01-08T23:59:59Z"),
        t("homelab-token-inventory-read", None),
        t("old-disabled", "2026-01-01T00:00:00Z", status="disabled"),
    ]}
    page2 = {"success": True, "result_info": {"page": 2, "total_pages": 2}, "result": [
        t("dup", "2026-11-01T00:00:00Z", id_="aaaaaaaa1111"),
        t("dup", "2026-12-01T00:00:00Z", id_="bbbbbbbb2222"),
        t("gone-stale", "2026-10-01T00:00:00Z", status="expired"),
    ]}
    pages = {1: page1, 2: page2}
    poll_once(lambda path: pages[int(path.rsplit("=", 1)[1])])
    out = render()
    want = {
        'credential="homelab-acme-dns"} 1798761600',
        'credential="Create Additional Tokens"} 1799452799',
        'credential="dup (aaaaaaaa)"} 1793491200',
        'credential="dup (bbbbbbbb)"} 1796083200',
        'credential="gone-stale"} 1790812800',
    }
    got = {l.split(",", 1)[1] for l in out.splitlines() if l.startswith("credential_expiry_timestamp_seconds{")}
    assert got == want, f"expiry series mismatch:\n got  {sorted(got)}\n want {sorted(want)}"
    assert 'credential_expiry_probe_ok{provider="cloudflare"} 1' in out
    assert 'credential_expiry_credentials_listed{provider="cloudflare"} 7' in out
    assert 'credential_expiry_credentials_expiring{provider="cloudflare"} 5' in out
    # stale: a hung loop behind a live server must read 0 at scrape time
    assert probe_ok(now=time.time() + STALE_AFTER + 1) == 0
    # a failed poll keeps the last good series but drops probe_ok to 0 — the alert reads UNKNOWN
    poll_once(lambda path: (_ for _ in ()).throw(RuntimeError("HTTP 401")))
    out = render()
    assert 'credential_expiry_probe_ok{provider="cloudflare"} 0' in out and len(got) == 5
    # an empty list is a broken read, never "nothing expiring"
    _last_ok = True
    poll_once(lambda path: {"success": True, "result_info": {"total_pages": 1}, "result": []})
    assert probe_ok() == 0
    # an unparseable date fails the poll instead of dropping the token
    poll_once(lambda path: {"success": True, "result_info": {"total_pages": 1},
                            "result": [t("x", "not-a-date")]})
    assert probe_ok() == 0
    print("credential-expiry-probe self-test: ok")


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        self_test()
        sys.exit(0)
    if not TOKEN:
        sys.exit("CF_API_TOKEN is empty")
    threading.Thread(target=poll_forever, daemon=True).start()
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
