#!/usr/bin/env python3
"""A stub Prometheus for the harness: GET /api/v1/query answered from a fixture file.
usage: stub-prometheus.py <fixture.json> <port-file>   (binds 127.0.0.1:0, writes the port, serves until killed)
The first route whose `contains` is a substring of the `query` parameter answers; none → HTTP 404."""
import http.server, json, sys, urllib.parse

routes = json.load(open(sys.argv[1]))["routes"]

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("query", [""])[0]
        for r in routes:
            if r["contains"] in q:
                body = json.dumps(r["body"]).encode()
                self.send_response(r["status"]); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
                return
        self.send_response(404); self.end_headers()
    def log_message(self, *a): pass

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(srv.server_address[1]))
srv.serve_forever()
