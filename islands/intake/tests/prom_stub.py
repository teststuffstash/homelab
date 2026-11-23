#!/usr/bin/env python3
"""prom_stub — a Prometheus `/api/v1/query` that answers from a fixture file (homelab#3603; tests only).

  python3 -I islands/intake/tests/prom_stub.py <fixture.json> <port-file> [<request-log>]

Listens on 127.0.0.1, on a port the kernel picks; the port is written to <port-file> once the socket
listens. A request is `GET /<scenario>/api/v1/query?query=…&time=…` — the scenario is the path prefix, so
one server holds every case and a caller's `--prometheus http://127.0.0.1:<port>/<scenario>` picks one (the
prefix is also what a kube-API service-proxy URL looks like). Each request is appended to <request-log> as
one JSON line `{"scenario", "query", "time"}` before it is answered.

The fixture is `{"scenarios": {"<name>": [rule, …]}}`; the first rule that matches answers:

  has         a substring the query must contain            from / to   bounds on `time` (epoch seconds, inclusive)
  fail_first  the first N requests this rule matches are answered HTTP 500, the rest as the rule says

and then exactly one of:

  value       "5"            → a vector with that one sample, stamped with the request's time (or `ts`)
  values      ["1", "2"]     → a vector with one sample per entry;  [] is an answer with no sample
  json        any value      → sent as the body, HTTP `status` (default 200)
  text        a string       → sent as it is, HTTP `status` (default 200)
  redirect    a path         → HTTP 302 to it, on this server
  hang        seconds        → sleeps, then answers `value` "0"
  truncate    a value        → the full one-sample body, under a Content-Length 40 bytes longer; then closes
  pad         bytes          → a valid one-sample answer followed by that much whitespace
  drip        [gap, count]   → the headers, then one blank every `gap` seconds, `count` times, then a one-sample body

A request no rule matches is HTTP 404. The server exits by itself after 300 s: a harness that died cannot
leave it behind.
"""
import http.server
import json
import os
import sys
import threading
import time
import urllib.parse

LIFETIME_S = 300


def _vector(values, ts):
    return {"status": "success", "data": {"resultType": "vector", "result": [
        {"metric": {"n": str(i)}, "value": [ts, v]} for i, v in enumerate(values)]}}


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quiet
        pass

    def _send(self, status, body, ctype="application/json", extra_length=0, headers=()):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body) + extra_length))
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Connection", "close")
        self.close_connection = True
        try:
            self.end_headers()
            self.wfile.write(body)
        except OSError:  # the caller has gone (a row that makes it give up): nothing to say
            pass

    def do_GET(self):
        srv = self.server
        url = urllib.parse.urlsplit(self.path)
        marker = "/api/v1/query"
        scenario = url.path[1:-len(marker)] if url.path.endswith(marker) else None
        qs = urllib.parse.parse_qs(url.query)
        query, when = (qs.get("query") or [""])[0], (qs.get("time") or [""])[0]
        entry = {"scenario": scenario, "query": query, "time": when}
        with srv.lock:
            srv.requests.append(entry)
            if srv.log_path:
                with open(srv.log_path, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps(entry) + "\n")
        try:
            at = float(when)
        except ValueError:
            return self._send(400, b'{"status":"error","errorType":"bad_data","error":"bad time"}')
        rule = None
        for i, r in enumerate(srv.scenarios.get(scenario, [])):
            if "has" in r and r["has"] not in query:
                continue
            if "from" in r and at < r["from"]:
                continue
            if "to" in r and at > r["to"]:
                continue
            rule, key = r, (scenario, i)
            break
        if rule is None:
            return self._send(404, b"no rule matches\n", "text/plain")
        with srv.lock:
            srv.hits[key] = srv.hits.get(key, 0) + 1
            hit = srv.hits[key]
        if hit <= rule.get("fail_first", 0):
            return self._send(500, b"Internal Server Error\n", "text/plain")
        ts = rule.get("ts", at)
        if "redirect" in rule:
            return self._send(302, b"", headers=(("Location", rule["redirect"]),))
        if "hang" in rule:
            time.sleep(rule["hang"])
            return self._send(200, json.dumps(_vector(["0"], ts)).encode())
        if "drip" in rule:
            gap, count = rule["drip"]
            body = json.dumps(_vector(["1"], ts)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body) + count))
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            try:
                for _ in range(count):
                    self.wfile.write(b" ")
                    self.wfile.flush()
                    time.sleep(gap)
                self.wfile.write(body)
            except OSError:  # the caller gave up, as it should
                pass
            return None
        if "truncate" in rule:
            return self._send(200, json.dumps(_vector([rule["truncate"]], ts)).encode(), extra_length=40)
        if "pad" in rule:
            return self._send(200, json.dumps(_vector(["1"], ts)).encode() + b" " * rule["pad"])
        if "text" in rule:
            return self._send(rule.get("status", 200), rule["text"].encode(), "text/plain")
        if "json" in rule:
            return self._send(rule.get("status", 200), json.dumps(rule["json"]).encode())
        values = [rule["value"]] if "value" in rule else rule["values"]
        return self._send(200, json.dumps(_vector(values, ts)).encode())


def serve(fixture, log_path=None):
    """Start the stub in a daemon thread → the server (`.server_port`, `.requests`, `.shutdown()`)."""
    with open(fixture, encoding="utf-8") as fh:
        scenarios = json.load(fh)["scenarios"]
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    srv.daemon_threads = True
    srv.scenarios, srv.log_path = scenarios, log_path
    srv.requests, srv.hits, srv.lock = [], {}, threading.Lock()
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__.split("\n")[2].strip(), file=sys.stderr)
        return 64
    srv = serve(argv[0], argv[2] if len(argv) == 3 else None)
    tmp = argv[1] + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(f"{srv.server_port}\n")
    os.replace(tmp, argv[1])
    time.sleep(LIFETIME_S)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
