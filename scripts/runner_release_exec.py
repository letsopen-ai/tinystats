"""Staged direct Actions entry point for TinyStats signed releases."""
import json
import os
from pathlib import Path
import pwd
import re
import sys

from actions_release_guard import from_environment
from runner_keychain import signing_keychain
from runner_macos_secrets import materialize
from runner_process import command
from runner_release_lock import release_lock

ROOT = Path(__file__).resolve().parents[1]
SECRET_NAMES = ('MACOS_CERTIFICATE_P12_BASE64', 'MACOS_CERTIFICATE_PASSWORD',
                'APPLE_NOTARY_API_KEY_P8', 'APPLE_NOTARY_KEY_ID', 'APPLE_NOTARY_ISSUER_ID')


def run(environment):
    os.umask(0o077)
    # Keep raw job secrets out of unrelated subprocess environments.
    for name in SECRET_NAMES:
        os.environ.pop(name, None)
    identity = pwd.getpwuid(os.geteuid())
    if (os.geteuid() == 0 or identity.pw_name != 'release-runner'
            or Path(environment.get('HOME', '')).resolve() != Path(identity.pw_dir).resolve()):
        raise ValueError('Expected the dedicated non-root release-runner account')
    if not environment.get('GH_TOKEN'):
        raise ValueError('A job-scoped GitHub token is required')
    team = environment.get('APPLE_TEAM_ID', '')
    fingerprint = environment.get('MACOS_CERTIFICATE_FINGERPRINT', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', team) or not re.fullmatch(r'[A-Fa-f0-9]{40}', fingerprint):
        raise ValueError('Signing identity anchor is missing')
    event = json.loads(Path(environment['GITHUB_EVENT_PATH']).read_text())
    commit = (event.get('workflow_run') or {}).get('head_sha')
    from_environment(commit)
    from release_signed import source_commit, verify_ci_validation
    if source_commit() != commit:
        raise ValueError('Release source differs from triggering CI')
    verify_ci_validation(commit)
    home = Path(environment['HOME'])
    parent = home / 'Library/Caches/MacCIReleaseSecrets'
    parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    if parent.is_symlink() or parent.stat().st_uid != os.getuid() or parent.stat().st_mode & 0o077:
        raise ValueError('Release staging directory must be private and owned')
    with release_lock(home):
        if any(parent.iterdir()):
            raise RuntimeError('Previous release staging remains; inspect before retrying')
        with materialize(environment, parent) as root:
            with signing_keychain(root, root / 'certificate.p12', environment['MACOS_CERTIFICATE_PASSWORD']) as keychain:
                child = {key: value for key, value in environment.items() if key not in SECRET_NAMES}
                child.update({'TINYSTATS_DEVELOPER_ID': fingerprint, 'APPLE_TEAM_ID': team,
                    'TELEFRAME_NOTARY_PROFILE': 'tinystats-ci', 'TELEFRAME_NOTARY_KEYCHAIN': str(keychain)})
                command(['xcrun', 'notarytool', 'store-credentials', 'tinystats-ci',
                         '--key', root / 'AuthKey.p8', '--key-id', environment['APPLE_NOTARY_KEY_ID'],
                         '--issuer', environment['APPLE_NOTARY_ISSUER_ID'], '--keychain', keychain],
                        cwd=ROOT, timeout=120, env=child)
                from_environment(commit)
                command([sys.executable, ROOT / 'scripts/release_signed.py', '--actions-direct'],
                        cwd=ROOT, timeout=21000, capture=False, env=child)


if __name__ == '__main__':
    run(dict(os.environ))
