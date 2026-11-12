"""Select an explicit job-scoped Keychain for notarization when requested."""
from pathlib import Path


def keychain_arguments(environment):
    value = environment.get('TINYSTATS_NOTARY_KEYCHAIN')
    if value is None:
        return []
    path = Path(value)
    if not value or path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        raise ValueError('Notary Keychain must be a private regular file')
    return ['--keychain', str(path)]
