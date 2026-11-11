"""Select the explicit private signing keychain in unattended release sessions."""
import os
from pathlib import Path


def identity_keychain_arguments(environment):
    value = environment.get('TINYSTATS_SIGNING_KEYCHAIN')
    if value is None:
        return []
    path = Path(value)
    if (not value or path.is_symlink() or not path.is_file()
            or path.stat().st_mode & 0o077 or path.stat().st_uid != os.getuid()):
        raise ValueError('Signing keychain must be a private owned regular file')
    return [str(path)]


def codesign_keychain_arguments(environment):
    paths = identity_keychain_arguments(environment)
    return ['--keychain', *paths] if paths else []


if __name__ == '__main__':
    identity_keychain_arguments(os.environ)
