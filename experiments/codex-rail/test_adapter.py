"""Offline contract rows for the proposed Responses seam (not enforced GW specs)."""
import json
import unittest
from adapter import Events, Observation, Refused, http_failure, prepare, relay


def event(kind="response.completed", **response):
    response = {"status": "completed", "usage": {"input_tokens": 7, "output_tokens": 3}, **response}
    return b"data: " + json.dumps({"type": kind, "response": response}).encode() + b"\n\n"


class AdapterTests(unittest.TestCase):
    def test_request_boundary(self):
        body = json.dumps({"model": "fixture-model", "stream": True, "store": False, "input": []}).encode()
        headers = {"Authorization": "Bearer dummy-session", "Cookie": "secret",
                   "ChatGPT-Account-ID": "attacker", "x-api-key": "secret"}
        options = dict(session_token="dummy-session", model="fixture-model",
                       access_token="dummy-upstream", account_id="fixture-account")
        raw, sent = prepare(body, headers, **options)
        self.assertEqual(raw, body)
        self.assertEqual(sent, {"authorization": "Bearer dummy-upstream", "content-type": "application/json",
                               "accept": "text/event-stream", "chatgpt-account-id": "fixture-account"})
        rows = [(b"{", headers, "malformed-body"),
                (b"[]", headers, "malformed-body"),
                (body.replace(b"fixture-model", b"wrong"), headers, "model-not-session"),
                (body.replace(b'"stream": true', b'"stream": false'), headers, "responses-mode-unsupported"),
                (body.replace(b'"input": []', b'"input": "bad"'), headers, "responses-input-invalid"),
                (body, {}, "session-unknown"), (body, {"Authorization": "Bearer é"}, "session-unknown")]
        for payload, hdrs, code in rows:
            with self.subTest(code=code), self.assertRaisesRegex(Refused, "^" + code + "$"):
                prepare(payload, hdrs, **options)

    def test_every_chunk_boundary_and_crlf(self):
        raw = b": heartbeat\r\n\r\n" + event().replace(b"\n", b"\r\n")
        for split in range(len(raw) + 1):
            with self.subTest(split=split):
                obs, closed = Observation(), []
                self.assertEqual(b"".join(relay([raw[:split], raw[split:]], obs, lambda: closed.append(1))), raw)
                self.assertEqual((obs.outcome, obs.input_tokens, obs.output_tokens), ("completed", 7, 3))
                self.assertEqual(closed, [1])

    def test_terminal_usage_after_large_stream(self):
        delta = b'data: {"type":"response.output_text.delta","delta":"hello"}\n\n'
        obs = Observation()
        total = sum(len(c) for c in relay(iter([delta] * 100000 + [event(), event(usage={"input_tokens": 99})]), obs, lambda: None))
        self.assertGreater(total, 4 * 1024 * 1024)
        self.assertEqual(obs.input_tokens, 7)

    def test_failures_are_not_completions(self):
        for kind, outcome in [("response.failed", "failed"), ("response.incomplete", "incomplete"), ("error", "failed")]:
            with self.subTest(kind=kind):
                obs = Observation()
                list(relay([event(kind, status=outcome)], obs, lambda: None))
                self.assertEqual(obs.outcome, outcome)

    def test_unknown_usage_is_not_zero(self):
        obs = Observation()
        list(relay([event(usage={"input_tokens": True, "output_tokens": -1})], obs, lambda: None))
        self.assertIsNone(obs.input_tokens)
        self.assertIsNone(obs.output_tokens)

    def test_protocol_errors_close_upstream(self):
        rows = [(b"data: [DONE]\n\n", "upstream-stream-truncated"),
                (event()[:-2], "upstream-stream-truncated"),
                (b"data: secret-invalid-json\n\n", "upstream-event-invalid"),
                (b"data: []\n\n", "upstream-event-invalid"),
                (b":" + b"a" * 1024, "upstream-event-too-large"),
                (event(status="failed"), "upstream-terminal-invalid")]
        for raw, code in rows:
            with self.subTest(code=code):
                closed = []
                with self.assertRaisesRegex(Refused, "^" + code + "$"):
                    list(relay([raw], Observation(), lambda: closed.append(1), 512))
                self.assertEqual(closed, [1])

    def test_multiline_sse(self):
        raw = b'data: {"type":"response.completed",\ndata: "response":{"status":"completed"}}\n\n'
        obs = Observation()
        list(relay([bytes([byte]) for byte in raw], obs, lambda: None))
        self.assertEqual(obs.outcome, "completed")

    def test_cancellation_closes_without_draining(self):
        consumed, closed, obs = [], [], Observation()
        def chunks():
            consumed.append(1)
            yield b": first\n\n"
            consumed.append(2)
            yield event()
        stream = relay(chunks(), obs, lambda: closed.append(1))
        next(stream)
        stream.close()
        self.assertEqual(consumed, [1])
        self.assertEqual(closed, [1])
        self.assertEqual(obs.outcome, "cancelled")

    def test_transport_error_is_sanitized(self):
        def chunks():
            yield b": first\n\n"
            raise TimeoutError("secret upstream details")
        obs, closed = Observation(), []
        with self.assertRaisesRegex(Refused, "^upstream-transport-error$"):
            list(relay(chunks(), obs, lambda: closed.append(1)))
        self.assertEqual(obs.outcome, "transport-error")
        self.assertEqual(closed, [1])

    def test_http_failure_codes(self):
        for status, code in [(200, None), (401, "upstream-auth"), (403, "upstream-auth"),
                             (429, "upstream-rate-limited"), (302, "upstream-http-error"), (500, "upstream-http-error")]:
            with self.subTest(status=status):
                self.assertEqual(http_failure(status), code)


if __name__ == "__main__":
    unittest.main()
