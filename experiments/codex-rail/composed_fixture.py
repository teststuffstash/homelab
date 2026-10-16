"""Native Codex -> offline composition -> loopback fake Responses server."""
import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import tempfile
import threading

from adapter import Refused
from compat import MODEL, TOKEN, completion, run
from composed import LoopbackTransport, Rail
from file_store import FileStore
from headroom import Headroom
from lifecycle import Credential, Failure, Lifecycle, Record


@contextmanager
def server(handler):
    class Server(ThreadingHTTPServer):
        request_queue_size = 32
    instance = Server(('127.0.0.1', 0), handler)
    thread = threading.Thread(target=instance.serve_forever, daemon=True)
    thread.start()
    try:
        yield instance.server_port
    finally:
        instance.shutdown()
        instance.server_close()
        thread.join()


class QuietHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass


@contextmanager
def upstream(*, chunks=None, status=200, content_type='text/event-stream', pause_headers=False,
             pause_body=False):
    state = {'requests': 0, 'auth_ok': [], 'entered': threading.Event(), 'release': threading.Event()}
    mutex = threading.Lock()
    chunks = completion() if chunks is None else chunks
    class Handler(QuietHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            with mutex:
                state['requests'] += 1
                state['auth_ok'].append(self.path == '/responses'
                    and self.headers.get('Authorization') == 'Bearer dummy-rotated-access'
                    and self.headers.get('ChatGPT-Account-ID') == 'dummy-account'
                    and self.headers.get('Cookie') is None)
            state['entered'].set()
            try:
                if pause_headers:
                    state['release'].wait(3)
                self.send_response(status)
                self.send_header('Content-Type', content_type)
                # A hostile redirect target must never be followed by the test transport.
                self.send_header('Location', 'http://127.0.0.1:1/never-follow')
                self.end_headers()
                for index, chunk in enumerate(chunks):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    if pause_body and index == 0:
                        state['release'].wait(3)
            except (BrokenPipeError, ConnectionResetError):
                pass
    with server(Handler) as port:
        try:
            yield port, state
        finally:
            state['release'].set()


class Harness:
    def __init__(self, directory, port, timeout=1):
        self.now = 1000
        self.refreshes = 0
        self.store = FileStore(directory)
        with self.store.lock():
            self.store.save(Record(Credential('dummy-expiring-access', 'dummy-refresh', 'dummy-account', 1001)))
        self.headroom = Headroom(lambda: self.now)
        self.headroom.observe({'observed_at': 1000, 'source': 'poll', 'limited': False, 'windows': [
            {'used_percent': 20, 'resets_at': 2000, 'window_minutes': 300},
            {'used_percent': 64, 'resets_at': 9000, 'window_minutes': 10080}]})
        self.transport = LoopbackTransport(port, timeout)
        self.lifecycle = Lifecycle(self.store, self.exchange, lambda: self.now)
        self.rail = Rail(self.lifecycle, self.headroom, self.transport, TOKEN, MODEL)

    def exchange(self, credential):
        if credential.refresh_token != 'dummy-refresh':
            raise RuntimeError('unexpected fake refresh input')
        self.refreshes += 1
        return Credential('dummy-rotated-access', 'dummy-rotated-refresh', 'dummy-account', 3000)


@contextmanager
def fixture():
    with tempfile.TemporaryDirectory(prefix='codex-composed-') as directory, upstream() as (port, remote):
        harness = Harness(directory, port)
        evidence = {'requests': [], 'errors': [], 'closed': 0}
        class Handler(QuietHandler):
            def do_POST(self):
                if self.path != '/openai/v1/responses':
                    self.send_error(404)
                    return
                try:
                    size = int(self.headers.get('Content-Length', '0'))
                except ValueError:
                    size = 0
                if not 0 < size <= 2 * 1024 * 1024:
                    self.send_error(413)
                    return
                body = self.rfile.read(size)
                started = False
                try:
                    with harness.rail.request(body, dict(self.headers)) as (stream, observation):
                        doc = json.loads(body)
                        evidence['requests'].append({'path': self.path, 'model': doc['model'],
                            'stream': doc['stream'], 'store': doc['store'],
                            'input_is_array': isinstance(doc['input'], list),
                            'auth_replaced': all(remote['auth_ok'])})
                        self.send_response(200)
                        self.send_header('Content-Type', 'text/event-stream')
                        self.end_headers()
                        started = True
                        for chunk in stream:
                            self.wfile.write(chunk)
                            self.wfile.flush()
                    evidence['observation'] = vars(observation)
                except (Refused, Failure) as error:
                    evidence['errors'].append(str(error))
                    if not started:
                        self.send_error(503, str(error))
                except (BrokenPipeError, ConnectionResetError):
                    evidence['errors'].append('downstream-cancelled')
                finally:
                    evidence['closed'] = harness.transport.closed
                    evidence['refreshes'] = harness.refreshes
                    evidence['upstream_requests'] = remote['requests']
        with server(Handler) as gateway_port:
            yield f'http://127.0.0.1:{gateway_port}/openai/v1', evidence
        if harness.refreshes != 1 or not all(remote['auth_ok']):
            raise RuntimeError('composed fixture boundary failed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--expect-version', required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.codex, args.expect_version, fixture_factory=fixture), indent=2))
