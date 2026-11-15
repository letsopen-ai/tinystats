"""Materialize Mac signing credentials in a private job-scoped directory."""
import base64
from contextlib import contextmanager
import os
from pathlib import Path
import signal
import shutil
import stat
import threading


def hosted_temp(environment):
    if (os.geteuid() == 0 or environment.get('GITHUB_ACTIONS') != 'true'
            or environment.get('RUNNER_ENVIRONMENT') != 'github-hosted'):
        raise ValueError('Expected a non-root GitHub-hosted Actions runner')
    value = environment.get('RUNNER_TEMP', '')
    parent = Path(value)
    if not value or not parent.is_absolute():
        raise ValueError('RUNNER_TEMP must be an absolute owned directory')
    mode = parent.lstat()
    if not stat.S_ISDIR(mode.st_mode) or mode.st_uid != os.getuid():
        raise ValueError('RUNNER_TEMP must be a real owned directory')
    # Hosted images may provision _temp with broader permissions. Restrict it
    # before creating signing material; this VM belongs to this job alone.
    parent.chmod(0o700)
    return parent


@contextmanager
def materialize(environment, parent):
    names = ('MACOS_CERTIFICATE_P12_BASE64', 'MACOS_CERTIFICATE_PASSWORD',
             'APPLE_NOTARY_API_KEY_P8', 'APPLE_NOTARY_KEY_ID', 'APPLE_NOTARY_ISSUER_ID')
    values = {name: environment.get(name, '') for name in names}
    if any(not isinstance(v, str) or not v for v in values.values()):
        raise ValueError('A required Mac signing credential is missing')
    try:
        certificate = base64.b64decode(values['MACOS_CERTIFICATE_P12_BASE64'], validate=True)
    except ValueError:
        raise ValueError('Invalid signing certificate format') from None
    if not certificate or 'PRIVATE KEY' not in values['APPLE_NOTARY_API_KEY_P8']:
        raise ValueError('Invalid signing credential content')
    parent = Path(parent)
    if (parent.is_symlink() or not parent.is_dir() or parent.stat().st_uid != os.getuid()
            or parent.stat().st_mode & 0o077):
        raise ValueError('Temporary parent must be a private owned directory')
    if threading.current_thread() is not threading.main_thread():
        raise RuntimeError('Credential staging requires the main thread')
    previous = signal.getsignal(signal.SIGTERM)
    def terminate(signum, frame): raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, terminate)
    try:
        root = parent / 'tinystats-signing'
        try:
            root.mkdir(mode=0o700)  # Exclusive creation also rejects stale directories/symlinks.
        except FileExistsError:
            raise RuntimeError('Signing staging directory already exists') from None
        try:
            for name, content in (('certificate.p12', certificate), ('AuthKey.p8', values['APPLE_NOTARY_API_KEY_P8'].encode())):
                fd = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, 'wb') as stream: stream.write(content)
            yield root
        finally:
            shutil.rmtree(root)
    finally:
        signal.signal(signal.SIGTERM, previous)
