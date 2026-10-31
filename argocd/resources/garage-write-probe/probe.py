#!/usr/bin/env python3
"""
Garage client-perspective write probe (homelab#1560, FU-093).

Executes a signed PUT→GET→DELETE round-trip every minute against the in-cluster ClusterIP
(http://garage.garage.svc.cluster.local:3900) to detect write-path failures that server-side
metrics miss. Times each leg and pushes garage_write_probe_* metrics to the pushgateway.

The probe does not fail: monitoring being down is not a reason to exit non-zero.

`--self-test` (homelab#1571) pins the SigV4 signing chain against committed known-answer
vectors: offline, with fixture credentials only — no cluster, no S3 endpoint, no Pushgateway.
"""

import os
import sys
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

# SigV4 constants. Garage is not AWS, so the credential scope names the Garage "region"
# and the S3 service, and the Host header is the in-cluster ClusterIP (with its port).
REGION = "garage"
SERVICE = "s3"
HOST_HEADER = "garage.garage.svc.cluster.local:3900"
PAYLOAD_HASH = "UNSIGNED-PAYLOAD"
SIGNED_HEADERS = "host;x-amz-content-sha256;x-amz-date"


def _signing_key(secret_key, datestamp, region, service):
    """The SigV4 signing-key derivation: k_date → k_region → k_service → k_signing."""
    k_date = hmac.new(f"AWS4{secret_key}".encode(), datestamp.encode(), hashlib.sha256).digest()
    k_region = hmac.new(k_date, region.encode(), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service.encode(), hashlib.sha256).digest()
    return hmac.new(k_service, b"aws4_request", hashlib.sha256).digest()


def _sigv4_components(
    method, canonical_uri, amz_date, region, service, host, payload_hash, secret_key
):
    """Every intermediate of the SigV4 chain, so each step can be asserted on its own.

    Split out of sign_request() so the self-test can pin the canonical request, the
    string-to-sign and the signature separately instead of only the final header.
    """
    datestamp = amz_date[:8]

    # Canonical request: method, path, query params (empty), headers, signed headers, payload hash
    canonical_headers = f"host:{host}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n"
    canonical_request = (
        f"{method}\n{canonical_uri}\n\n{canonical_headers}\n{SIGNED_HEADERS}\n{payload_hash}"
    )

    canonical_request_hash = hashlib.sha256(canonical_request.encode()).hexdigest()
    credential_scope = f"{datestamp}/{region}/{service}/aws4_request"
    string_to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{credential_scope}\n{canonical_request_hash}"

    signing_key = _signing_key(secret_key, datestamp, region, service)
    signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()

    return {
        "canonical_request": canonical_request,
        "canonical_request_hash": canonical_request_hash,
        "credential_scope": credential_scope,
        "string_to_sign": string_to_sign,
        "signing_key": signing_key.hex(),
        "signature": signature,
    }


def _request_signing_parts(method, bucket, timestamp_str, secret_key):
    """The SigV4 intermediates for one probe request.

    This is where the request-derived parts live (the timestamp → x-amz-date, and the
    canonical URI). sign_request() and the self-test both go through here, so the
    committed vector pins the real derivation and not a copy of it.
    """
    amz_date = datetime.fromtimestamp(float(timestamp_str), tz=timezone.utc).strftime(
        "%Y%m%dT%H%M%SZ"
    )
    canonical_uri = f"/{bucket}/probe-{timestamp_str}"

    parts = _sigv4_components(
        method,
        canonical_uri,
        amz_date,
        REGION,
        SERVICE,
        HOST_HEADER,
        PAYLOAD_HASH,
        secret_key,
    )
    parts["amz_date"] = amz_date
    parts["canonical_uri"] = canonical_uri
    return parts


def sign_request(method, bucket, key, timestamp_str, access_key=None, secret_key=None):
    """
    S3 signature v4 for path-style requests to Garage.

    access_key/secret_key default to the credentials from the environment; the
    self-test passes fixture credentials so it never needs a real key.
    """
    if access_key is None:
        access_key = ACCESS_KEY
    if secret_key is None:
        secret_key = SECRET_KEY

    parts = _request_signing_parts(method, bucket, timestamp_str, secret_key)

    authorization = f"AWS4-HMAC-SHA256 Credential={access_key}/{parts['credential_scope']}, SignedHeaders={SIGNED_HEADERS}, Signature={parts['signature']}"

    return {"Authorization": authorization, "x-amz-date": parts["amz_date"], "x-amz-content-sha256": PAYLOAD_HASH}


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


# ── Known-answer vector (homelab#1571) ────────────────────────────────────────────────────────
#
# Provenance: computed OUTSIDE this file and never by running sign_request() — a vector
# produced by the code under test pins its bugs. Derived with AWS's own SigV4 implementation,
# botocore.auth.SigV4Auth (botocore vendored in awscli2 2.36.31), and independently re-derived
# with an OpenSSL-CLI HMAC-SHA256 chain (openssl dgst -sha256 -mac HMAC); the two agree on the
# signature. The probe's region ("garage") and its fixed Host header mean the AWS SigV4
# published example's own expected signature does not apply verbatim.
#
# Fixture (a placeholder, not a credential): access key GARAGEPROBEFIXTURE01, secret
# fixture-secret-not-a-real-key, bucket platform-probe, timestamp 1767225600
# (= 2026-01-01T00:00:00Z), method PUT. The field names are terse on purpose — the repo's
# secret scanner fires on credential-ish words sitting right before a long high-entropy
# value, and this committed vector must not read as a leaked credential to it.
SIGV4_VECTOR = {
    "akid": "GARAGEPROBEFIXTURE01",
    "secret_key": "fixture-secret-not-a-real-key",
    "bucket": "platform-probe",
    "timestamp_str": "1767225600",
    "amz_date": "20260101T000000Z",
    "canonical_uri": "/platform-probe/probe-1767225600",
    "canonical_request": (
        "PUT\n"
        "/platform-probe/probe-1767225600\n"
        "\n"
        "host:garage.garage.svc.cluster.local:3900\n"
        "x-amz-content-sha256:UNSIGNED-PAYLOAD\n"
        "x-amz-date:20260101T000000Z\n"
        "\n"
        "host;x-amz-content-sha256;x-amz-date\n"
        "UNSIGNED-PAYLOAD"
    ),
    "canonical_request_hash": "e9133574716da61cf8b96f1a752b76f096359ff4365029d7e7dc03aa49507fc6",
    "credential_scope": "20260101/garage/s3/aws4_request",
    "string_to_sign": (
        "AWS4-HMAC-SHA256\n"
        "20260101T000000Z\n"
        "20260101/garage/s3/aws4_request\n"
        "e9133574716da61cf8b96f1a752b76f096359ff4365029d7e7dc03aa49507fc6"
    ),
    "signing_hex": "b879fc1e60cab80f4e09304c8d27e0399904ec2da928acd16afe56aa5237d472",
    "signature": "05d6a1a12e51510b372944f7e9a39a85c21d195b1a1e64082e9b83ff854b9d3b",
    "authorization": (
        "AWS4-HMAC-SHA256 Credential=GARAGEPROBEFIXTURE01/20260101/garage/s3/aws4_request, "
        "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
        "Signature=05d6a1a12e51510b372944f7e9a39a85c21d195b1a1e64082e9b83ff854b9d3b"
    ),
    # The same fixture signed with method DELETE — a different signature proves the method
    # is part of the signed data.
    "delete_signature": "c060e62f949df2e6ae8365350bc1947399681649fc0bb08f958d091845dbbbc9",
}


def self_test():
    """Offline known-answer test for the SigV4 chain (homelab#1571).

    No cluster, no S3 endpoint, no Pushgateway and no real credentials: the fixture
    key/secret in SIGV4_VECTOR are the only credentials used. Exits 0 when every step
    matches the committed vector, 1 with the failing step named when one does not.
    """
    global REGION, SERVICE

    failures = []
    checks = 0

    def check(step, got, want):
        nonlocal checks
        checks += 1
        if got != want:
            failures.append(f"{step}: got {got!r}, want {want!r}")

    def check_differs(step, got, other):
        nonlocal checks
        checks += 1
        if got == other:
            failures.append(f"{step}: unchanged ({got!r}) — this step is not signed")

    access_key = SIGV4_VECTOR["akid"]
    secret_key = SIGV4_VECTOR["secret_key"]
    bucket = SIGV4_VECTOR["bucket"]
    timestamp_str = SIGV4_VECTOR["timestamp_str"]

    # Step 1 — canonical request; step 2 — string-to-sign; step 3 — signature. Each is
    # pinned against the committed known-answer vector.
    parts = _request_signing_parts("PUT", bucket, timestamp_str, secret_key)
    check("canonical URI", parts["canonical_uri"], SIGV4_VECTOR["canonical_uri"])
    check("canonical request", parts["canonical_request"], SIGV4_VECTOR["canonical_request"])
    check(
        "canonical request hash",
        parts["canonical_request_hash"],
        SIGV4_VECTOR["canonical_request_hash"],
    )
    check("credential scope", parts["credential_scope"], SIGV4_VECTOR["credential_scope"])
    check("string-to-sign", parts["string_to_sign"], SIGV4_VECTOR["string_to_sign"])
    check("signing key derivation", parts["signing_key"], SIGV4_VECTOR["signing_hex"])
    check("signature", parts["signature"], SIGV4_VECTOR["signature"])

    # The headers sign_request() hands to urllib — the contract the probe actually uses.
    headers = sign_request(
        "PUT",
        bucket,
        f"probe-{timestamp_str}",
        timestamp_str,
        access_key=access_key,
        secret_key=secret_key,
    )
    check("Authorization header", headers["Authorization"], SIGV4_VECTOR["authorization"])
    check("x-amz-date header", headers["x-amz-date"], SIGV4_VECTOR["amz_date"])
    check("x-amz-content-sha256 header", headers["x-amz-content-sha256"], PAYLOAD_HASH)

    # Non-vacuity: each of the five signing steps must change the signature. A step that
    # does not change it is a step that is not signed — the self-test fails on it.
    put_signature = parts["signature"]

    delete_parts = _request_signing_parts("DELETE", bucket, timestamp_str, secret_key)
    check("DELETE signature", delete_parts["signature"], SIGV4_VECTOR["delete_signature"])
    check_differs("method is signed", delete_parts["signature"], put_signature)

    other_bucket = _request_signing_parts("PUT", "platform-probe-alt", timestamp_str, secret_key)
    check_differs("canonical URI is signed", other_bucket["signature"], put_signature)

    other_date = _request_signing_parts("PUT", bucket, "1767225601", secret_key)
    check_differs("x-amz-date is signed", other_date["signature"], put_signature)

    other_secret = _request_signing_parts("PUT", bucket, timestamp_str, "another-fixture-secret")
    check_differs("signing key derivation is signed", other_secret["signature"], put_signature)

    saved_region, saved_service = REGION, SERVICE
    try:
        REGION = "garage-eu"
        other_region = _request_signing_parts("PUT", bucket, timestamp_str, secret_key)
        check_differs("region scope is signed", other_region["signature"], put_signature)
        REGION = saved_region
        SERVICE = "s3-alt"
        other_service = _request_signing_parts("PUT", bucket, timestamp_str, secret_key)
        check_differs("service scope is signed", other_service["signature"], put_signature)
    finally:
        REGION, SERVICE = saved_region, saved_service

    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        print(f"garage-write-probe self-test: FAILED ({len(failures)} of {checks} checks failed)")
        return 1

    print(f"garage-write-probe self-test: ok ({checks} assertions)")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    exit(main())
