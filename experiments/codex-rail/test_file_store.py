import multiprocessing
import os
from pathlib import Path
import tempfile
import unittest

from file_store import FileStore
from lifecycle import Credential, Failure, Lifecycle, Record


OLD = Credential('dummy-old-access', 'dummy-old-refresh', 'dummy-account', 1001)
NEW = Credential('dummy-rotated-access', 'dummy-rotated-refresh', 'dummy-account', 3000)


def worker(directory, start, entered, mode):
    class Store(FileStore):
        def save(self, record):
            super().save(record)
            if mode == 'after-save' and record.credential == NEW:
                os._exit(24)
    store = Store(directory)
    def exchange(old):
        if old != OLD:
            raise RuntimeError('unexpected dummy credential')
        # Executed within the file-store lock, so increments must serialize too.
        with (Path(directory) / 'exchanges').open('a') as output:
            output.write('exchange\n')
            output.flush()
            os.fsync(output.fileno())
        entered.set()
        if mode == 'after-exchange':
            # Parent terminates the process here, after marker and fake rotation.
            multiprocessing.Event().wait(30)
        return NEW
    if not start.wait(5):
        raise RuntimeError('start timeout')
    Lifecycle(store, exchange, lambda: 1000).acquire()


class FileStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = FileStore(self.temp.name)
        with self.store.lock():
            self.store.save(Record(OLD))
        self.context = multiprocessing.get_context('spawn')
        self.start = self.context.Event()
        self.entered = self.context.Event()
        self.processes = []
        self.addCleanup(self.stop)

    def stop(self):
        for process in self.processes:
            if process.is_alive():
                process.terminate()
            process.join(5)

    def spawn(self, mode):
        process = self.context.Process(target=worker,
            args=(self.temp.name, self.start, self.entered, mode))
        self.processes.append(process)
        process.start()
        return process

    def test_processes_share_rotation_and_restart_reads_durable_result(self):
        processes = [self.spawn('normal') for _ in range(6)]
        self.start.set()
        for process in processes:
            process.join(10)
            self.assertEqual(process.exitcode, 0)
        def unexpected(_):
            self.fail('restart tried another refresh')
        self.assertEqual(Lifecycle(FileStore(self.temp.name), unexpected, lambda: 1000).acquire(), NEW)
        self.assertEqual((Path(self.temp.name) / 'exchanges').read_text(), 'exchange\n')
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(Path(self.temp.name).glob('rotation-*')), [])

    def test_killed_owner_releases_lock_but_rotation_requires_recovery(self):
        process = self.spawn('after-exchange')
        self.start.set()
        self.assertTrue(self.entered.wait(5))
        process.terminate()
        process.join(5)
        def unexpected(_):
            self.fail('recovery retried the old token')
        with self.assertRaisesRegex(Failure, 'credential-recovery-required'):
            Lifecycle(FileStore(self.temp.name), unexpected, lambda: 1000).acquire()
        with self.store.lock():
            self.assertEqual(self.store.load().state, 'refreshing')

    def test_exit_after_durable_save_recovers_replacement(self):
        process = self.spawn('after-save')
        self.start.set()
        process.join(10)
        self.assertEqual(process.exitcode, 24)
        self.assertEqual(Lifecycle(FileStore(self.temp.name), None, lambda: 1000).acquire(), NEW)


if __name__ == '__main__':
    unittest.main()
