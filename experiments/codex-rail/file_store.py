"""Disposable POSIX test backend. Dummy credentials only; not Infisical write-back."""
from contextlib import contextmanager
from dataclasses import asdict
import fcntl
import json
import os
from pathlib import Path
import tempfile

from lifecycle import Credential, Record


class FileStore:
    """Call load/save only while holding lock. Caller owns a private temporary directory.

    A separate stable lock inode survives atomic data replacement. Local flock is not
    distributed fencing, and no claim is made about network filesystems/power loss.
    """
    def __init__(self, directory):
        self.directory = Path(directory)
        self.path = self.directory / "record.json"

    @contextmanager
    def lock(self):
        fd = os.open(self.directory / "record.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    def load(self):
        data = json.loads(self.path.read_text())
        return Record(Credential(**data['credential']), data['state'])

    def save(self, record):
        fd, name = tempfile.mkstemp(prefix="rotation-", dir=self.directory)
        try:
            with os.fdopen(fd, 'w') as output:
                json.dump(asdict(record), output)
                output.flush()
                os.fsync(output.fileno())
            os.replace(name, self.path)
            directory = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(name):
                os.unlink(name)
