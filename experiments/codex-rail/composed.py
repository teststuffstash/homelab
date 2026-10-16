"""Offline composition seam. No gateway imports, live endpoints, or session service."""
from contextlib import contextmanager
from http.client import HTTPConnection
from threading import Lock

from adapter import Observation, Refused, http_failure, prepare, relay
from headroom import Verdict


class LoopbackTransport:
    """Deliberately restricted HTTP test transport; never a production HTTP client."""
    def __init__(self, port, timeout=1):
        self.port, self.timeout = port, timeout
        self.opens = self.closed = 0
        self.counter_lock = Lock()

    def open(self, body, headers):
        connection = HTTPConnection("127.0.0.1", self.port, timeout=self.timeout)
        with self.counter_lock:
            self.opens += 1
        closed = False
        response = None
        def close():
            nonlocal closed
            if not closed:
                closed = True
                if response is not None:
                    response.close()
                connection.close()
                with self.counter_lock:
                    self.closed += 1
        code = None
        try:
            connection.request("POST", "/responses", body, headers)
            response = connection.getresponse()
            code = http_failure(response.status)
            if code is None and response.getheader("Content-Type", "").split(';')[0] != "text/event-stream":
                code = "upstream-content-type"
        except Exception:
            code = "upstream-transport-error"
        if code:
            close()
            raise Refused(code)
        def chunks():
            while chunk := response.read1(4096):
                yield chunk
        return chunks(), close


class Rail:
    def __init__(self, lifecycle, headroom, transport, token, model):
        self.lifecycle, self.headroom, self.transport = lifecycle, headroom, transport
        self.token, self.model = token, model

    def check_headroom(self):
        verdict = self.headroom.verdict()
        if verdict != Verdict.ADMIT:
            raise Refused(verdict.value)

    @contextmanager
    def request(self, body, headers):
        # Validate worker auth/model/body before inspecting quota or touching credentials.
        prepare(body, headers, session_token=self.token, model=self.model,
                access_token="dummy-preflight")
        self.check_headroom()
        credential = self.lifecycle.acquire()
        # Refresh may have blocked long enough for the quota observation to expire.
        self.check_headroom()
        body, outgoing = prepare(body, headers, session_token=self.token, model=self.model,
                                 access_token=credential.access_token, account_id=credential.account_id)
        chunks, close = self.transport.open(body, outgoing)
        observation = Observation()
        stream = relay(chunks, observation, close)
        try:
            yield stream, observation
        finally:
            stream.close()
            # A generator closed before first iteration never executes its finally block.
            close()  # The transport close contract is idempotent.
