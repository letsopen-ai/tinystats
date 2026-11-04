"""Serialize cooperating release jobs that share a persistent macOS account."""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import stat
import time


@contextmanager
def release_lock(home, wait_seconds=0):
    root = Path(home) / 'Library' / 'Application Support' / 'Mac CI Release Lock'
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = root.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise ValueError('Release lock directory must be owned and private')
    path = root / 'release.lock'
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077 or st.st_nlink != 1:
            raise ValueError('Release lock file must be owned and private')
        deadline = time.monotonic() + wait_seconds
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError('Another release job is already using this account') from None
                time.sleep(min(5, remaining))
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
