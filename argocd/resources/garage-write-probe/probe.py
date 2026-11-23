#!/usr/bin/env python3
"""
Garage client-perspective write probe (homelab#1560, FU-093).

Executes a signed PUT→GET→DELETE round-trip every minute against the in-cluster ClusterIP
(http://garage.garage.svc.cluster.local:3900) to detect write-path failures that server-side
metrics miss. Times each leg and pushes garage_write_probe_* metrics to the pushgateway.

The probe does not fail: monitoring being down is not a reason to exit non-zero.
"""

import os
import time
import hashlib
import hmac
from datetime import datetime, timezone
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# Configuration from environment
GARAGE_ENDPOINT = os.environ.get("GARAGE_ENDPOINT", "http://garage.garage.svc.cluster.local:3900")
BUCKET = os.environ.get("GARAGE_BUCKET", "platform-probe")
ACCESS_KEY = os.environ.get("AWS_ACCESS_KEY_ID", "")
SECRET_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
PUSHGATEWAY_URL = os.environ.get(
    "PUSHGATEWAY_URL", "http://prometheus-pushgateway.monitoring.svc.cluster.local:9091"
)

PROBE_DATA = b"x" * (64 * 1024)  # 64 KiB of data


def _sigv4_components(method, bucket, timestamp_str, access_key, secret_key, region="garage", service="s3"):
    """
    The three SigV4 steps for a path-style request to Garage, returned individually so that
    --self-test can pin each one. sign_request() is a thin wrapper over this.
    """
    amz_date = datetime.fromtimestamp(float(timestamp_str), tz=timezone.utc).strftime(
        "%Y%m%dT%H%M%SZ"
    )
    datestamp = amz_date[:8]

    # Canonical request: method, path, query params (empty), headers, signed headers, payload hash
    canonical_uri = f"/{bucket}/probe-{timestamp_str}"
    canonical_querystring = ""
    host_header = "garage.garage.svc.cluster.local:3900"
    payload_hash = "UNSIGNED-PAYLOAD"

    canonical_headers = f"host:{host_header}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n"
    signed_headers = "host;x-amz-content-sha256;x-amz-date"

    canonical_request = f"{method}\n{canonical_uri}\n{canonical_querystring}\n{canonical_headers}\n{signed_headers}\n{payload_hash}"

    canonical_request_hash = hashlib.sha256(canonical_request.encode()).hexdigest()
    credential_scope = f"{datestamp}/{region}/{service}/aws4_request"
    string_to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{credential_scope}\n{canonical_request_hash}"

    k_date = hmac.new(f"AWS4{secret_key}".encode(), datestamp.encode(), hashlib.sha256).digest()
    k_region = hmac.new(k_date, region.encode(), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service.encode(), hashlib.sha256).digest()
    k_signing = hmac.new(k_service, b"aws4_request", hashlib.sha256).digest()
    signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()

    authorization = f"AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope}, SignedHeaders={signed_headers}, Signature={signature}"

    return {
        "amz_date": amz_date,
        "payload_hash": payload_hash,
        "canonical_request_hash": canonical_request_hash,
        "string_to_sign": string_to_sign,
        "signing_key": k_signing.hex(),
        "signature": signature,
        "authorization": authorization,
    }


def sign_request(method, bucket, key, timestamp_str):
    """
    S3 signature v4 for path-style requests to Garage.
    """
    c = _sigv4_components(method, bucket, timestamp_str, ACCESS_KEY, SECRET_KEY)
    return {
        "Authorization": c["authorization"],
        "x-amz-date": c["amz_date"],
        "x-amz-content-sha256": c["payload_hash"],
    }


# Known-answer vector for --self-test. Provenance: computed INDEPENDENTLY of this file, by
# hand with the openssl/sha256sum CLIs following the AWS SigV4 spec (docs.aws.amazon.com
# "Signature Version 4 signing process"): sha256 of the canonical request, then the
# HMAC-SHA256 chain AWS4+secret -> date -> region -> service -> "aws4_request" -> string-to-sign.
# AWS's published example signature does not apply verbatim (region "garage", fixed Host,
# UNSIGNED-PAYLOAD), so this is the same procedure on this probe's inputs. The key/secret
# are the AWS documentation example pair, not credentials.
# Timestamp 1767225600 = 2026-01-01T00:00:00Z.
_VEC = {
    "ak": "AKIDEXAMPLE",
    "sk": "wJalrXUtnFEMI/K7MDENG" + "+bPxRfiCYEXAMPLEKEY",
    "bucket": "platform-probe",
    "ts": "1767225600",
    "amz_date": "20260101T000000Z",
    "PUT": {
        "crh": "e9133574716da61cf8b96f1a752b76f096359ff4365029d7e7dc03aa49507fc6",
        "sts": "AWS4-HMAC-SHA256\n20260101T000000Z\n20260101/garage/s3/aws4_request\n"
        "e9133574716da61cf8b96f1a752b76f096359ff4365029d7e7dc03aa49507fc6",
        "sig": "6cbc620bcba3764b37d7d657bdd0488c835bc6249c557145fa51f67e15ae2b86",
    },
    "DELETE": {
        "crh": "40562084061f8f7396ee1016e14ba6255ddfe55a74bead7f52f14fbd523a219e",
        "sig": "7b2a6a18219b7d9bf33efa9d068c95fa1ec91792525c0412c69448f126cb917f",
    },
    "kdf": "a908db7ea3c833d3474e1a336dab06c1aba690006a9c7712641567bbf07647bd",
}


def self_test():
    """Offline known-answer test of the SigV4 chain. Silent on success; names failing steps."""
    v = _VEC
    fails = []

    def check(name, got, want):
        if got != want:
            fails.append(f"FAIL {name}: got {got!r}, want {want!r}")

    def comp(method="PUT", ts=v["ts"], **kw):
        return _sigv4_components(method, v["bucket"], ts, v["ak"], v["sk"], **kw)

    put = comp()
    check("x-amz-date", put["amz_date"], v["amz_date"])
    check("canonical request hash", put["canonical_request_hash"], v["PUT"]["crh"])
    check("string-to-sign", put["string_to_sign"], v["PUT"]["sts"])
    check("signing key derivation", put["signing_key"], v["kdf"])
    check("signature", put["signature"], v["PUT"]["sig"])
    scope = "20260101/garage/s3/aws4_request"
    want_auth = (
        f"AWS4-HMAC-SHA256 Credential={v['ak']}/{scope}, "
        f"SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={v['PUT']['sig']}"
    )
    check("Authorization header", put["authorization"], want_auth)

    dele = comp("DELETE")
    check("DELETE canonical request hash", dele["canonical_request_hash"], v["DELETE"]["crh"])
    check("DELETE signature", dele["signature"], v["DELETE"]["sig"])
    if dele["signature"] == put["signature"]:
        fails.append("FAIL method is signed: DELETE signature equals PUT signature")

    # Every other input must move the signature (a step that stops being signed is caught).
    for name, other in (
        ("x-amz-date", comp(ts="1767225601")),
        ("canonical URI", _sigv4_components("PUT", "other-bucket", v["ts"], v["ak"], v["sk"])),
        ("region scope", comp(region="us-east-1")),
        ("service scope", comp(service="s4")),
        ("secret", _sigv4_components("PUT", v["bucket"], v["ts"], v["ak"], v["sk"] + "x")),
    ):
        if other["signature"] == put["signature"]:
            fails.append(f"FAIL {name} is not signed: signature unchanged")

    # The public wrapper must carry the vector through (module creds swapped for the fixture).
    global ACCESS_KEY, SECRET_KEY
    saved = (ACCESS_KEY, SECRET_KEY)
    ACCESS_KEY, SECRET_KEY = v["ak"], v["sk"]
    try:
        h = sign_request("PUT", v["bucket"], f"probe-{v['ts']}", v["ts"])
    finally:
        ACCESS_KEY, SECRET_KEY = saved
    check("sign_request Authorization", h["Authorization"], want_auth)
    check("sign_request x-amz-date", h["x-amz-date"], v["amz_date"])
    check("sign_request x-amz-content-sha256", h["x-amz-content-sha256"], "UNSIGNED-PAYLOAD")

    for f in fails:
        print(f)
    if fails:
        print(f"garage-write-probe self-test: FAILED ({len(fails)} checks)")
        return 1
    return 0


def http_request(method, path, data=None, headers=None):
    """Execute an HTTP request and return (elapsed_seconds, response_body)."""
    url = f"{GARAGE_ENDPOINT}{path}"
    if headers is None:
        headers = {}
    headers["User-Agent"] = "garage-write-probe/1.0"

    req = Request(url, data=data, headers=headers, method=method)
    start = time.time()
    try:
        with urlopen(req, timeout=30) as response:
            body = response.read()
            elapsed = time.time() - start
            return elapsed, body
    except (URLError, HTTPError) as e:
        elapsed = time.time() - start
        raise RuntimeError(f"{method} {path} failed after {elapsed:.2f}s: {e}") from e


def push_metrics(metrics):
    """Push metrics to pushgateway. Best-effort, never fails the probe."""
    if not PUSHGATEWAY_URL:
        print("PUSHGATEWAY_URL not set; skipping push")
        return

    metric_lines = "\n".join(metrics.values())
    metric_lines += f"\ngarage_write_probe_last_run_timestamp {int(time.time())}\n"
    # The trailing newline is load-bearing: the pushgateway's text parser rejects a stream that
    # does not end in one (HTTP 400), which is how every push 2026-09-08 → 09-10 was dropped
    # while the probe itself passed — and why the belts below never saw a series.
    payload = metric_lines.encode()

    try:
        req = Request(
            f"{PUSHGATEWAY_URL}/metrics/job/garage_write_probe",
            data=payload,
            headers={"Content-Type": "text/plain"},
            method="POST",
        )
        with urlopen(req, timeout=5) as response:
            response.read()
        print("Pushed metrics to pushgateway")
    except Exception as e:
        print(f"WARN could not push metrics (the probe itself already ran): {e}")


def main():
    timestamp = str(int(time.time()))
    metrics = {}
    success = True

    # PUT
    try:
        put_headers = sign_request("PUT", BUCKET, f"probe-{timestamp}", timestamp)
        put_elapsed, _ = http_request(
            "PUT", f"/{BUCKET}/probe-{timestamp}", data=PROBE_DATA, headers=put_headers
        )
        print(f"PUT succeeded in {put_elapsed:.2f}s")
        metrics["put_success"] = f'garage_write_probe_success{{leg="put"}} 1'
        metrics["put_seconds"] = f'garage_write_probe_seconds{{leg="put"}} {put_elapsed}'
    except Exception as e:
        print(f"PUT failed: {e}")
        metrics["put_success"] = 'garage_write_probe_success{leg="put"} 0'
        metrics["put_seconds"] = 'garage_write_probe_seconds{leg="put"} 0'
        success = False

    # GET
    try:
        get_headers = sign_request("GET", BUCKET, f"probe-{timestamp}", timestamp)
        get_elapsed, get_body = http_request(
            "GET", f"/{BUCKET}/probe-{timestamp}", headers=get_headers
        )
        if get_body != PROBE_DATA:
            raise RuntimeError(f"GET body mismatch: expected {len(PROBE_DATA)} bytes, got {len(get_body)}")
        print(f"GET succeeded in {get_elapsed:.2f}s")
        metrics["get_success"] = f'garage_write_probe_success{{leg="get"}} 1'
        metrics["get_seconds"] = f'garage_write_probe_seconds{{leg="get"}} {get_elapsed}'
    except Exception as e:
        print(f"GET failed: {e}")
        metrics["get_success"] = 'garage_write_probe_success{leg="get"} 0'
        metrics["get_seconds"] = 'garage_write_probe_seconds{leg="get"} 0'
        success = False

    # DELETE
    try:
        delete_headers = sign_request("DELETE", BUCKET, f"probe-{timestamp}", timestamp)
        delete_elapsed, _ = http_request(
            "DELETE", f"/{BUCKET}/probe-{timestamp}", headers=delete_headers
        )
        print(f"DELETE succeeded in {delete_elapsed:.2f}s")
        metrics["delete_success"] = f'garage_write_probe_success{{leg="delete"}} 1'
        metrics["delete_seconds"] = f'garage_write_probe_seconds{{leg="delete"}} {delete_elapsed}'
    except Exception as e:
        print(f"DELETE failed: {e}")
        metrics["delete_success"] = 'garage_write_probe_success{leg="delete"} 0'
        metrics["delete_seconds"] = 'garage_write_probe_seconds{leg="delete"} 0'
        success = False

    # Push metrics (best-effort)
    push_metrics(metrics)

    # Exit code: always 0 unless the probe itself errors (not monitoring errors)
    if success:
        print("Probe completed successfully")
    else:
        print("Probe completed with failures")
    return 0


if __name__ == "__main__":
    import sys

    if "--self-test" in sys.argv[1:]:
        exit(self_test())
    exit(main())
