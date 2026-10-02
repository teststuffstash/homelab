#!/usr/bin/env python3
"""
OPNsense config.xml backup + click detector (FU-013, router leg).

Once a day:
  1. GET  <router>/api/core/backup/download/this   (the newest /conf/backup revision == the running
     config) with the read-only `backup-puller` API user;
  2. age-encrypt it to AGE_RECIPIENT (the public half is in git; the identity is the wallet entry
     opnsense-config-backup-age-identity, so only DR can read it) and PUT it to the private Garage
     bucket as <prefix>/config-<run UTC>-<revision time>.xml.age;
  3. prune: objects older than RETENTION_DAYS go, but the newest MIN_KEEP always stay;
  4. GET  <router>/api/core/backup/backups/this and count the revisions made since the previous run
     whose author is not an allowed identity (the click detector);
  5. push opnsense_config_* gauges to the pushgateway. A successful run PUTs (the whole group is
     replaced, so a username that no longer clicks drops out instead of being re-served forever);
     a failed run POSTs only its heartbeat, which keeps the last success time where it was.

The run DATE used by retention and by the click window comes from the object KEY, never from S3
LastModified: an object-copy restore rewrites every LastModified (docs/garage.md §"What an
OBJECT-COPY restore resets"), and a restore must not make the backups look new or reopen a window.

age: pyrage (rage's Python binding) from ONE hash-pinned wheel fetched through the in-cluster
pypi-cache — no pip, no index, no runtime package manager. Output is standard age; `age -d -i`
decrypts it.

Exit code: non-zero when the backup did not land (so CronJobNotSucceeding sees it). A failed push
to the pushgateway never fails the run — the stale belt is its detector.

Local runs (test VM / DR drills): PUSHGATEWAY_URL="" skips the push; metrics are always printed.
"""

import datetime as dt
import hashlib
import hmac
import io
import os
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ENV = os.environ.get

# The router is DIALLED by address and VERIFIED by name: opnsense.teststuff.net also has a public
# record (the WAN address), so resolving it from a pod can pick the wrong door — while the LE cert
# the web GUI serves on the LAN address is for that name (the acme role's "restart web gui" spec).
OPN_ADDR = ENV("OPNSENSE_ADDR", "192.168.2.1")
OPN_TLS_NAME = ENV("OPNSENSE_TLS_NAME", "opnsense.teststuff.net")
OPN_TLS_VERIFY = ENV("OPNSENSE_TLS_VERIFY", "1") == "1"
OPN_KEY = ENV("OPNSENSE_API_KEY", "")
OPN_SECRET = ENV("OPNSENSE_API_SECRET", "")

AGE_RECIPIENT = ENV("AGE_RECIPIENT", "")
WHEEL_URL = ENV("PYRAGE_WHEEL_URL", "")
WHEEL_SHA256 = ENV("PYRAGE_WHEEL_SHA256", "")

S3_ENDPOINT = ENV("S3_ENDPOINT", "http://garage.garage.svc.cluster.local:3900").rstrip("/")
S3_REGION = ENV("S3_REGION", "garage")
S3_BUCKET = ENV("S3_BUCKET", "opnsense-config-backup")
S3_PREFIX = ENV("S3_PREFIX", "opnsense-fw").strip("/")
S3_KEY_ID = ENV("AWS_ACCESS_KEY_ID", "")
S3_SECRET = ENV("AWS_SECRET_ACCESS_KEY", "")

RETENTION_DAYS = int(ENV("RETENTION_DAYS", "90"))
MIN_KEEP = int(ENV("MIN_KEEP", "30"))
FIRST_RUN_WINDOW_S = int(ENV("FIRST_RUN_WINDOW_SECONDS", str(26 * 3600)))

# Allowed authors. API writes are recorded as "<user>@<client ip>"; system scripts as "(root)".
ALLOWED_USERS = [u for u in ENV("ALLOWED_USERS", "automation,backup-puller").split(",") if u]
# "(root)" is allowed only with a description matching this. Two system writers are known:
#  - the ACME client's renewal hook (every renewal writes the cert into config.xml; 28 of prod's
#    100 revisions on 2026-09-29);
#  - "Updated plugin interface configuration": the system re-registering plugin interfaces after a
#    plugin reconfigure — the wireguard play produced it on the test VM (2026-09-29). It is a
#    derived revision: the write that caused it is recorded separately under its own author.
# Any other "(root)" revision is unexplained and is flagged, which is how a new system writer
# gets noticed and added here.
SYSTEM_ALLOWED_RE = re.compile(
    ENV(
        "SYSTEM_ALLOWED_RE",
        r"^(/usr/local/opnsense/scripts/OPNsense/AcmeClient/lecert\.php made changes"
        # firmware updates migrate the config schema as (root) — machine-made, like the ACME renewal
        # (prod 26.1 -> 26.7.4, 2026-09-29: three run_migrations.php revisions; the test-VM trial also
        # saw firmware/register.php on plugin installs — docs/opnsense-test-vm.md §official update path)
        r"|/usr/local/opnsense/\S*/run_migrations\.php made changes"
        r"|/usr/local/opnsense/\S*/firmware/register\.php made changes"
        r"|Updated plugin interface configuration)$",
    )
)

PUSHGATEWAY_URL = ENV("PUSHGATEWAY_URL", "http://prometheus-pushgateway.monitoring.svc.cluster.local:9091")
PUSH_JOB = "opnsense_config_backup"

KEY_RE = re.compile(r"/config-(\d{8}T\d{6}Z)-[0-9.]+\.xml\.age$")


def log(msg):
    print(f"{dt.datetime.now(dt.timezone.utc).strftime('%H:%M:%SZ')} {msg}", flush=True)


# ── the router ─────────────────────────────────────────────────────────────────────────────────


def opn_get(path):
    import base64
    import http.client
    import socket

    ctx = ssl.create_default_context()
    if not OPN_TLS_VERIFY:  # test VM only (self-signed); prod verifies the router's LE cert
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

    class Pinned(http.client.HTTPSConnection):
        def connect(self):
            raw = socket.create_connection((OPN_ADDR, 443), timeout=60)
            self.sock = ctx.wrap_socket(raw, server_hostname=OPN_TLS_NAME)

    auth = base64.b64encode(f"{OPN_KEY}:{OPN_SECRET}".encode()).decode()
    conn = Pinned(OPN_TLS_NAME, 443, timeout=60)
    try:
        conn.request("GET", f"/api/{path}", headers={"Authorization": f"Basic {auth}", "Host": OPN_TLS_NAME})
        r = conn.getresponse()
        body = r.read()
    finally:
        conn.close()
    if r.status != 200:
        raise RuntimeError(f"GET /api/{path}: HTTP {r.status}")
    return body


def check_config(body):
    """The download must be a whole OPNsense config; returns its <revision><time> (float)."""
    root = ET.fromstring(body)  # raises on truncation
    if root.tag != "opnsense":
        raise RuntimeError(f"download is not an OPNsense config (root <{root.tag}>)")
    rev = root.find("revision/time")
    if rev is None or not (rev.text or "").strip():
        raise RuntimeError("config has no <revision><time>")
    return float(rev.text)


def classify(items, since):
    """Unattributed revisions newer than `since` → {username: count}. Pure: fixture-testable."""
    out = {}
    for it in items:
        try:
            t = float(it.get("time", "0"))
        except ValueError:
            continue
        if t <= since:
            continue
        user = it.get("username", "")
        if any(user.startswith(f"{u}@") for u in ALLOWED_USERS):
            continue
        if user == "(root)" and SYSTEM_ALLOWED_RE.match(it.get("description", "")):
            continue
        out[user or "(empty)"] = out.get(user or "(empty)", 0) + 1
        log(f"UNATTRIBUTED revision {it.get('time_iso', t)} by {user!r}: {it.get('description', '')!r}")
    return out


# ── age via the pinned wheel ───────────────────────────────────────────────────────────────────


def load_pyrage():
    if not (WHEEL_URL and WHEEL_SHA256):
        raise RuntimeError("PYRAGE_WHEEL_URL / PYRAGE_WHEEL_SHA256 unset")
    with urllib.request.urlopen(WHEEL_URL, timeout=60) as r:
        blob = r.read()
    got = hashlib.sha256(blob).hexdigest()
    if got != WHEEL_SHA256:
        raise RuntimeError(f"pyrage wheel sha256 {got} != pinned {WHEEL_SHA256}")
    dest = "/tmp/pylib"
    zipfile.ZipFile(io.BytesIO(blob)).extractall(dest)
    sys.path.insert(0, dest)
    import pyrage  # noqa: E402  (only importable after the extract)

    return pyrage


# ── Garage (S3 SigV4, path-style) ──────────────────────────────────────────────────────────────


def s3(method, key="", query=None, body=b""):
    query = query or {}
    u = urllib.parse.urlsplit(S3_ENDPOINT)
    path = "/" + S3_BUCKET + ("/" + urllib.parse.quote(key, safe="/-_.~") if key else "")
    cq = "&".join(
        f"{urllib.parse.quote(k, safe='-_.~')}={urllib.parse.quote(str(v), safe='-_.~')}"
        for k, v in sorted(query.items())
    )
    now = dt.datetime.now(dt.timezone.utc)
    amz_date, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()
    headers = {"host": u.netloc, "x-amz-content-sha256": payload_hash, "x-amz-date": amz_date}
    signed = ";".join(sorted(headers))
    canonical = "\n".join(
        [method, path, cq, "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)), signed, payload_hash]
    )
    scope = f"{day}/{S3_REGION}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    k = f"AWS4{S3_SECRET}".encode()
    for part in (day, S3_REGION, "s3", "aws4_request"):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = f"AWS4-HMAC-SHA256 Credential={S3_KEY_ID}/{scope}, SignedHeaders={signed}, Signature={sig}"
    url = f"{S3_ENDPOINT}{path}" + (f"?{cq}" if cq else "")
    req = urllib.request.Request(url, data=body if method == "PUT" else None, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def s3_list():
    keys, token = [], None
    ns = "{http://s3.amazonaws.com/doc/2006-03-01/}"
    while True:
        q = {"list-type": "2", "prefix": S3_PREFIX + "/"}
        if token:
            q["continuation-token"] = token
        root = ET.fromstring(s3("GET", query=q))
        keys += [c.findtext(f"{ns}Key") for c in root.findall(f"{ns}Contents")]
        if root.findtext(f"{ns}IsTruncated") != "true":
            return keys
        token = root.findtext(f"{ns}NextContinuationToken")


def key_time(key):
    m = KEY_RE.search(key)
    if not m:
        return None
    return dt.datetime.strptime(m.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc).timestamp()


def to_prune(keys, now):
    """Keys past RETENTION_DAYS, never touching the newest MIN_KEEP. Unparseable keys are kept."""
    dated = sorted(((key_time(k), k) for k in keys if key_time(k) is not None), reverse=True)
    cutoff = now - RETENTION_DAYS * 86400
    return [k for i, (t, k) in enumerate(dated) if i >= MIN_KEEP and t < cutoff]


# ── metrics ────────────────────────────────────────────────────────────────────────────────────


def push(lines, method="PUT"):
    text = "\n".join(lines) + "\n"  # the trailing newline is load-bearing (garage-write-probe, 400s)
    print("--- metrics ---\n" + text, end="", flush=True)
    if not PUSHGATEWAY_URL:
        return
    url = f"{PUSHGATEWAY_URL}/metrics/job/{PUSH_JOB}/router/{S3_PREFIX}"
    try:
        req = urllib.request.Request(url, data=text.encode(), method=method, headers={"Content-Type": "text/plain"})
        with urllib.request.urlopen(req, timeout=10) as r:
            r.read()
    except Exception as e:  # noqa: BLE001 — never fail the run on the monitoring leg
        log(f"WARN pushgateway push failed (the backup itself is judged separately): {e}")


def main():
    start = time.time()
    run_stamp = dt.datetime.fromtimestamp(start, dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    m = [f"opnsense_config_backup_last_run_timestamp_seconds {int(start)}"]
    ok = True

    # 1. download + sanity
    body = opn_get("core/backup/download/this")
    rev_time = check_config(body)
    log(f"downloaded config.xml: {len(body)} bytes, revision {rev_time:.0f}")
    m += [f"opnsense_config_backup_size_bytes {len(body)}", f"opnsense_config_revision_timestamp_seconds {rev_time:.0f}"]

    # 2. the click window starts at the previous run (read BEFORE this run's upload)
    keys = s3_list()
    prev = max((t for t in map(key_time, keys) if t is not None), default=None)
    since = prev if prev is not None else start - FIRST_RUN_WINDOW_S
    log(f"{len(keys)} existing object(s); click window since {dt.datetime.fromtimestamp(since, dt.timezone.utc).isoformat()}")

    # 3. encrypt + upload
    pyrage = load_pyrage()
    blob = pyrage.encrypt(body, [pyrage.x25519.Recipient.from_str(AGE_RECIPIENT)])
    key = f"{S3_PREFIX}/config-{run_stamp}-{rev_time:.0f}.xml.age"
    s3("PUT", key, body=blob)
    log(f"uploaded s3://{S3_BUCKET}/{key} ({len(blob)} bytes)")
    keys.append(key)

    # 4. retention
    doomed = to_prune(keys, start)
    for k in doomed:
        try:
            s3("DELETE", k)
            log(f"pruned {k}")
        except Exception as e:  # noqa: BLE001
            log(f"WARN prune of {k} failed: {e}")
            ok = False
    m.append(f"opnsense_config_backup_objects {len(keys) - len(doomed)}")

    # 5. click detector
    import json

    items = json.loads(opn_get("core/backup/backups/this")).get("items", [])
    clicks = classify(items, since)
    for user, n in sorted(clicks.items()):
        esc = user.replace("\\", "\\\\").replace('"', '\\"')
        m.append(f'opnsense_config_unattributed_revisions{{username="{esc}"}} {n}')
    m.append(f"opnsense_config_click_window_start_seconds {since:.0f}")
    log(f"click detector: {sum(clicks.values())} unattributed revision(s) in the window")

    if ok:
        m.append(f"opnsense_config_backup_last_success_timestamp_seconds {int(time.time())}")
    push(m)
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001
        log(f"FAILED: {e}")
        # Keep the heartbeat moving so "the job runs but fails" and "the job does not run" read apart
        # on the dashboard. POST, not PUT: a PUT would delete last_success along with the group and
        # turn one transient failure into an immediate absent() page instead of a 26 h staleness.
        push([f"opnsense_config_backup_last_run_timestamp_seconds {int(time.time())}"], method="POST")
        sys.exit(1)
