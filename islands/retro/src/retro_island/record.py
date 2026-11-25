"""The recorder: ONE `GET <base-url>/api/v1/query?query=<promql>` per run, one entry holding the whole answer.

    python3 -m retro_island.record --base-url <url> --query <promql> --out <entry file> --recorded-by <text>

Any HTTP status is an answer. A transport failure (no HTTP status) writes nothing and exits non-zero.
No credential is sent or stored. Never run by a test or `ci.sh` against a live surface.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

PATH = "/api/v1/query"


def record(base_url: str, query: str, recorded_by: str, timeout: float = 30.0) -> dict:
    url = f"{base_url.rstrip('/')}{PATH}?{urllib.parse.urlencode({'query': query})}"
    recorded_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 - the one GET
            status, data = resp.status, resp.read()
    except urllib.error.HTTPError as e:  # an HTTP status is an answer
        status, data = e.code, e.read()
    return {
        "surface": "prometheus",
        "request": {"method": "GET", "path": PATH, "query": {"query": query}},
        "recorded_at": recorded_at,
        "recorded_by": recorded_by,
        "status": status,
        "body": data.decode("utf-8"),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="retro_island.record")
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--query", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--recorded-by", required=True)
    a = ap.parse_args(argv)
    try:
        entry = record(a.base_url, a.query, a.recorded_by)
    except (urllib.error.URLError, OSError, ValueError) as e:
        print(f"record: no answer: {e}", file=sys.stderr)
        return 1
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(entry, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
