from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import json
import tempfile
import threading
import traceback
import unittest

from adapter import Refused
from compat import MODEL, TOKEN, completion
from composed_fixture import Harness, upstream
from lifecycle import Failure, Revoked

BODY = json.dumps({'model': MODEL, 'stream': True, 'store': False, 'input': []}).encode()
HEADERS = {'Authorization': 'Bearer ' + TOKEN, 'Cookie': 'dummy-inbound-secret',
           'ChatGPT-Account-ID': 'dummy-attacker'}


@contextmanager
def setup(**kwargs):
    timeout = kwargs.pop('timeout', 1)
    with tempfile.TemporaryDirectory() as directory, upstream(**kwargs) as (port, remote):
        yield Harness(directory, port, timeout), remote


def consume(harness):
    with harness.rail.request(BODY, HEADERS) as (stream, observation):
        data = b''.join(stream)
    return data, observation


class ComposedTests(unittest.TestCase):
    def test_success_duplicate_terminal_accounted_once(self):
        chunks = completion()
        chunks += [chunks[-1].replace(b'"input_tokens": 7', b'"input_tokens": 999')]
        with setup(chunks=chunks) as (h, remote):
            data, obs = consume(h)
            self.assertEqual(data, b''.join(chunks))
            self.assertEqual((obs.outcome, obs.input_tokens, obs.output_tokens), ('completed', 7, 3))
            self.assertEqual((h.refreshes, remote['requests'], h.transport.closed), (1, 1, 1))
            self.assertEqual(remote['auth_ok'], [True])

    def test_invalid_session_and_model_never_touch_oauth_or_upstream(self):
        with setup() as (h, remote):
            for body, headers, code in ((BODY, {}, 'session-unknown'),
                    (BODY.replace(MODEL.encode(), b'other'), HEADERS, 'model-not-session')):
                with self.assertRaisesRegex(Refused, code):
                    with h.rail.request(body, headers):
                        self.fail('request admitted')
            self.assertEqual((h.refreshes, remote['requests']), (0, 0))

    def test_quota_refusals_never_refresh_or_connect(self):
        for mode in ('unknown', 'stale', 'limited'):
            with self.subTest(mode=mode), setup() as (h, remote):
                if mode == 'unknown':
                    h.headroom.snapshot = None
                elif mode == 'stale':
                    h.now = 1120
                else:
                    from dataclasses import replace
                    h.headroom.snapshot = replace(h.headroom.snapshot, limited=True)
                with self.assertRaisesRegex(Refused, 'quota-' + mode):
                    consume(h)
                self.assertEqual((h.refreshes, remote['requests'], h.transport.opens), (0, 0, 0))

    def test_slow_refresh_rechecks_freshness(self):
        with setup() as (h, remote):
            def slow(old):
                new = h.exchange(old)
                h.now = 1120
                return new
            h.lifecycle.exchange = slow
            with self.assertRaisesRegex(Refused, 'quota-stale'):
                consume(h)
            self.assertEqual((h.refreshes, remote['requests']), (1, 0))

    def test_concurrent_requests_share_one_rotation(self):
        with setup() as (h, remote):
            barrier = threading.Barrier(8)
            def request(_):
                barrier.wait(timeout=5)
                return consume(h)[1].outcome
            with ThreadPoolExecutor(max_workers=8) as pool:
                self.assertEqual(list(pool.map(request, range(8))), ['completed'] * 8)
            self.assertEqual(h.refreshes, 1)
            self.assertEqual(remote['requests'], 8)
            self.assertEqual(h.transport.closed, 8)
            self.assertTrue(all(remote['auth_ok']))

    def test_revocation_and_uncertain_refresh_are_typed_and_redacted(self):
        for exception, code in ((Revoked, 'credential-revoked'), (TimeoutError, 'credential-refresh-uncertain')):
            with self.subTest(code=code), setup() as (h, remote):
                def fail(old):
                    raise exception('DUMMY-PRIVATE-BODY')
                h.lifecycle.exchange = fail
                try:
                    consume(h)
                except Failure as error:
                    self.assertEqual(str(error), code)
                    self.assertNotIn('DUMMY-PRIVATE-BODY', ''.join(traceback.format_exception(error)))
                    self.assertIsNone(error.__context__)
                else:
                    self.fail('missing failure')
                with self.assertRaises(Failure):
                    consume(h)
                self.assertEqual(remote['requests'], 0)

    def test_http_errors_close_without_redirect_or_retry(self):
        for status, code in ((302, 'upstream-http-error'), (401, 'upstream-auth'),
                             (429, 'upstream-rate-limited'), (500, 'upstream-http-error')):
            with self.subTest(status=status), setup(status=status) as (h, remote):
                with self.assertRaisesRegex(Refused, code):
                    consume(h)
                self.assertEqual((remote['requests'], h.transport.opens, h.transport.closed), (1, 1, 1))

    def test_bad_content_type_and_malformed_or_truncated_stream(self):
        cases = [({'content_type': 'application/json'}, 'upstream-content-type'),
                 ({'chunks': [b'data: DUMMY-PRIVATE-BODY\n\n']}, 'upstream-event-invalid'),
                 ({'chunks': completion()[:2]}, 'upstream-stream-truncated')]
        for kwargs, code in cases:
            with self.subTest(code=code), setup(**kwargs) as (h, remote):
                with self.assertRaisesRegex(Refused, code):
                    consume(h)
                self.assertEqual((remote['requests'], h.transport.closed), (1, 1))

    def test_timeouts_before_headers_and_during_stream_close_once(self):
        for mode in ('pause_headers', 'pause_body'):
            with self.subTest(mode=mode), setup(timeout=0.1, **{mode: True}) as (h, remote):
                with self.assertRaisesRegex(Refused, 'upstream-transport-error'):
                    consume(h)
                self.assertEqual((remote['requests'], h.transport.closed), (1, 1))

    def test_cancellation_closes_without_replay_or_drain(self):
        with setup(pause_body=True) as (h, remote):
            with h.rail.request(BODY, HEADERS) as (stream, obs):
                self.assertTrue(next(stream))
                self.assertFalse(remote['release'].is_set())
            self.assertEqual(obs.outcome, 'cancelled')
            self.assertEqual((remote['requests'], h.transport.closed), (1, 1))

    def test_close_before_consumption_releases_transport(self):
        with setup(pause_body=True) as (h, remote):
            with h.rail.request(BODY, HEADERS):
                pass
            self.assertEqual((remote['requests'], h.transport.closed), (1, 1))


if __name__ == '__main__':
    unittest.main()
