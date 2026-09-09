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


def sign_request(method, bucket, key, timestamp_str):
    """
    S3 signature v4 for path-style requests to Garage.
    """
    region = "garage"
    service = "s3"
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
    string_to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{datestamp}/{region}/{service}/aws4_request\n{canonical_request_hash}"

    k_date = hmac.new(f"AWS4{SECRET_KEY}".encode(), datestamp.encode(), hashlib.sha256).digest()
    k_region = hmac.new(k_date, region.encode(), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service.encode(), hashlib.sha256).digest()
    k_signing = hmac.new(k_service, b"aws4_request", hashlib.sha256).digest()
    signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()

    credential_scope = f"{datestamp}/{region}/{service}/aws4_request"
    authorization = f"AWS4-HMAC-SHA256 Credential={ACCESS_KEY}/{credential_scope}, SignedHeaders={signed_headers}, Signature={signature}"

    return {"Authorization": authorization, "x-amz-date": amz_date, "x-amz-content-sha256": payload_hash}


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
    metric_lines += f"\ngarage_write_probe_last_run_timestamp {int(time.time())}"
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
    exit(main())
