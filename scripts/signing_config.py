"""Select the explicit private signing keychain in unattended release sessions."""
import os
import re
import subprocess
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


def verify_certificate_team(environment, fingerprint, team):
    """Bind the selected identity's SHA-1 to its certificate's actual subject OU."""
    listing = subprocess.run(['/usr/bin/security', 'find-certificate', '-a', '-p',
                              *identity_keychain_arguments(environment)],
                             check=True, capture_output=True, text=True, timeout=30).stdout
    for pem in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', listing, re.S):
        details = subprocess.run(['/usr/bin/openssl', 'x509', '-noout', '-sha1', '-fingerprint',
                                  '-subject', '-nameopt', 'sep_multiline'],
                                 input=pem, check=True, capture_output=True, text=True, timeout=30).stdout
        digest = re.search(r'(?im)^sha1 Fingerprint=([0-9a-f:]+)$', details)
        if digest and digest[1].replace(':', '').upper() == fingerprint.upper():
            units = re.findall(r'^\s*OU\s*=\s*(.*?)\s*$', details, re.M)
            if units != [team]:
                raise RuntimeError('Signing certificate subject OU does not match the Apple team')
            return
    raise RuntimeError('Signing certificate fingerprint is unavailable')


if __name__ == '__main__':
    identity_keychain_arguments(os.environ)
