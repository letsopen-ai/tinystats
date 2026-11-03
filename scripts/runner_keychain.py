"""Create a job-scoped macOS signing keychain; never use the login keychain.

The caller serializes release jobs under this OS user and owns the surrounding
private temporary directory. This module does not read GitHub secrets itself.
"""
from contextlib import contextmanager
import os
from pathlib import Path
import secrets
import shlex
import subprocess


def _security(*args):
    try:
        result = subprocess.run(['/usr/bin/security', *map(str, args)], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError('Temporary signing keychain operation did not complete') from None
    if result.returncode:
        raise RuntimeError('Temporary signing keychain operation failed')
    return result.stdout


def _security_private(*args):
    """Send sensitive arguments over stdin instead of the process argument list."""
    values = list(map(str, args))
    if any('\n' in value or '\r' in value or '\x00' in value for value in values):
        raise ValueError('Unsupported signing password characters')
    def quote(value):
        return '"' + value.replace('\\', '\\\\').replace('\"', '\\\"') + '"'
    command = ' '.join(quote(value) for value in values) + '\n'
    try:
        result = subprocess.run(['/usr/bin/security', '-i'], input=command,
                                capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError('Temporary signing keychain operation did not complete') from None
    if result.returncode:
        raise RuntimeError('Temporary signing keychain operation failed')
    return result.stdout


def _search_list():
    return shlex.split(_security('list-keychains', '-d', 'user'))


@contextmanager
def signing_keychain(directory, certificate, password):
    directory, certificate = Path(directory), Path(certificate)
    if os.geteuid() == 0:
        raise ValueError('Signing must not run as root')
    if directory.is_symlink() or not directory.is_dir() or directory.stat().st_mode & 0o077:
        raise ValueError('Signing directory must be private')
    if certificate.is_symlink() or not certificate.is_file() or certificate.stat().st_mode & 0o077 or not password:
        raise ValueError('A private certificate file and password are required')
    keychain = directory / 'release-signing.keychain-db'
    if keychain.exists() or keychain.is_symlink():
        raise ValueError('Temporary keychain already exists')
    initial = _search_list()
    key_password = secrets.token_urlsafe(32)
    created = False
    attached = False
    try:
        _security('create-keychain', '-p', key_password, keychain)
        created = True
        keychain.chmod(0o600)
        _security('set-keychain-settings', '-lut', '21600', keychain)
        _security('unlock-keychain', '-p', key_password, keychain)
        _security_private('import', certificate, '-k', keychain, '-P', password,
                  '-T', '/usr/bin/codesign', '-T', '/usr/bin/security')
        _security('set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', key_password, keychain)
        # Use the current list, not a stale snapshot, to avoid dropping other entries.
        current = _search_list()
        attached = True  # Treat a failed search-list update as an unknown outcome.
        _security('list-keychains', '-d', 'user', '-s', keychain, *[p for p in current if Path(p).resolve() != keychain.resolve()])
        yield keychain
    finally:
        if attached:
            try:
                current = _search_list()
                remaining = [p for p in current if Path(p).resolve() != keychain.resolve()]
                if not remaining:
                    remaining = initial
                _security('list-keychains', '-d', 'user', '-s', *remaining)
            finally:
                if created:
                    _security('delete-keychain', keychain)
        elif created:
            _security('delete-keychain', keychain)
