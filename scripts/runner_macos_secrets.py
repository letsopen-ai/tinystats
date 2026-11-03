"""Materialize Mac signing credentials in a private job-scoped directory."""
import base64
from contextlib import contextmanager
import os
from pathlib import Path
import signal
import tempfile
import threading


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
    if parent.is_symlink() or not parent.is_dir():
        raise ValueError('Temporary parent must be a directory')
    if threading.current_thread() is not threading.main_thread():
        raise RuntimeError('Credential staging requires the main thread')
    previous = signal.getsignal(signal.SIGTERM)
    def terminate(signum, frame): raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, terminate)
    try:
        with tempfile.TemporaryDirectory(prefix='tinystats-release-', dir=parent) as temporary:
            root = Path(temporary); root.chmod(0o700)
            for name, content in (('certificate.p12', certificate), ('AuthKey.p8', values['APPLE_NOTARY_API_KEY_P8'].encode())):
                fd = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, 'wb') as stream: stream.write(content)
            yield root
    finally:
        signal.signal(signal.SIGTERM, previous)
