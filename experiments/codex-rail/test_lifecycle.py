import copy
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import replace
import threading
import traceback
import unittest
from lifecycle import Code, Credential, Failure, Lifecycle, Record, Revoked


class MemoryStore:
    """Fake durable medium survives owner replacement; not a production backend."""
    def __init__(self, credential):
        self.record = Record(credential)
        self.mutex = threading.Lock()
        self.writes = 0
        self.fail_at = None
        self.commit_then_fail = False

    def lock(self):
        return self.mutex

    def load(self):
        return copy.deepcopy(self.record)

    def save(self, record):
        self.writes += 1
        if self.writes == self.fail_at:
            if self.commit_then_fail:
                self.record = copy.deepcopy(record)
            raise RuntimeError("DUMMY-SECRET storage detail")
        self.record = copy.deepcopy(record)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000
        self.old = Credential("DUMMY-SECRET-access", "DUMMY-SECRET-refresh", "dummy-account", 1001)
        self.new = replace(self.old, access_token="DUMMY-SECRET-new", refresh_token="DUMMY-SECRET-rotated", expires_at=2000)
        self.store = MemoryStore(self.old)
        self.calls = 0

    def exchange(self, old):
        self.assertEqual(old, self.old)
        self.assertEqual(self.store.record.state, "refreshing")
        self.calls += 1
        return self.new

    def owner(self, exchange=None):
        return Lifecycle(self.store, exchange or self.exchange, lambda: self.now)

    def failure(self, owner, code):
        try:
            owner.acquire()
        except Failure as error:
            self.assertEqual(error.code, code)
            self.assertNotIn("DUMMY-SECRET", ''.join(traceback.format_exception(error)))
            self.assertIsNone(error.__context__)
        else:
            self.fail("expected typed failure")

    def test_multiple_owners_serialize_rotation_and_restart(self):
        owners = [self.owner() for _ in range(16)]
        with ThreadPoolExecutor(max_workers=16) as pool:
            results = list(pool.map(lambda owner: owner.acquire(), owners))
        self.assertEqual(results, [self.new] * 16)
        self.assertEqual(self.calls, 1)
        self.assertEqual(self.owner().acquire(), self.new)
        self.assertEqual(self.store.record.credential.refresh_token, self.new.refresh_token)

    def test_fresh_credential_does_not_refresh(self):
        self.now = 900
        self.assertEqual(self.owner().acquire(), self.old)
        self.assertEqual(self.calls, 0)

    def test_marker_write_failure_prevents_exchange(self):
        self.store.fail_at = 1
        self.failure(self.owner(), Code.STORE)
        self.assertEqual(self.calls, 0)
        self.assertEqual(self.owner().acquire(), self.new)

    def test_rotation_write_failure_blocks_restart(self):
        self.store.fail_at = 2
        self.failure(self.owner(), Code.STORE)
        self.failure(self.owner(), Code.RECOVERY)
        self.assertEqual(self.calls, 1)

    def test_ambiguous_save_reloads_committed_rotation(self):
        self.store.fail_at, self.store.commit_then_fail = 2, True
        self.failure(self.owner(), Code.STORE)
        self.assertEqual(self.owner().acquire(), self.new)
        self.assertEqual(self.calls, 1)

    def test_process_crash_after_exchange_requires_recovery(self):
        def crash(old):
            self.exchange(old)
            raise SystemExit("simulated power loss")
        with self.assertRaises(SystemExit):
            self.owner(crash).acquire()
        self.failure(self.owner(), Code.RECOVERY)
        self.assertEqual(self.calls, 1)

    def test_uncertain_transport_error_is_redacted_and_not_retried(self):
        def timeout(old):
            raise TimeoutError("DUMMY-SECRET upstream response")
        self.failure(self.owner(timeout), Code.REFRESH)
        self.failure(self.owner(), Code.RECOVERY)

    def test_revocation_survives_restart(self):
        def revoked(old):
            raise Revoked("DUMMY-SECRET invalid grant")
        self.failure(self.owner(revoked), Code.REVOKED)
        self.failure(self.owner(), Code.REVOKED)

    def test_explicit_revocation_blocks_cached_access(self):
        self.now = 900
        self.owner().revoke()
        self.failure(self.owner(), Code.REVOKED)
        self.assertEqual(self.calls, 0)

    def test_invalid_rotated_credentials_fail_closed(self):
        for new in (replace(self.new, account_id="other"), replace(self.new, access_token="bad\n"),
                    replace(self.new, expires_at=float('nan')), replace(self.new, expires_at=999), None):
            with self.subTest(new=new):
                self.store = MemoryStore(self.old)
                self.failure(self.owner(lambda old: new), Code.INVALID)
                self.failure(self.owner(), Code.RECOVERY)

    def test_lock_failure_is_redacted(self):
        @contextmanager
        def broken():
            raise RuntimeError("DUMMY-SECRET lock error")
            yield
        self.store.lock = broken
        self.failure(self.owner(), Code.STORE)

    def test_next_refresh_uses_persisted_rotated_token(self):
        self.owner().acquire()
        self.now = 1990
        third = replace(self.new, expires_at=3000, refresh_token="DUMMY-SECRET-third")
        def exchange(rotated):
            self.assertEqual(rotated, self.new)
            return third
        self.assertEqual(self.owner(exchange).acquire(), third)

    def test_revocation_save_failure_still_blocks_restart(self):
        self.store.fail_at = 2
        def revoked(old):
            raise Revoked("DUMMY-SECRET revoked")
        self.failure(self.owner(revoked), Code.STORE)
        self.failure(self.owner(), Code.RECOVERY)

    def test_marker_commit_then_failure_never_exchanges(self):
        self.store.fail_at, self.store.commit_then_fail = 1, True
        self.failure(self.owner(), Code.STORE)
        self.failure(self.owner(), Code.RECOVERY)
        self.assertEqual(self.calls, 0)

    def test_repr_redacts_credentials(self):
        self.assertNotIn("DUMMY-SECRET", repr(self.old))
        self.assertNotIn("DUMMY-SECRET", repr(self.store.record))


if __name__ == '__main__':
    unittest.main()
